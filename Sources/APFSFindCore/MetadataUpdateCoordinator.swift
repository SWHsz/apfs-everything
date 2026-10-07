import CAPFSShim
import CoreServices
import Darwin
import Foundation

public struct MetadataUpdatePolicy: Sendable {
    public var debounceSeconds: Double = 0.2
    public var smallBatchLimit = 64
    public var maxPendingEntries = 100_000
    public var maxLookupsPerSecond = 20_000
    public var stormParentCollapseThreshold = 512
    public init() {}
}

/// Event-driven trailing debounce on a utility queue; no per-write lookup or repeating timer.
public final class MetadataUpdateCoordinator: @unchecked Sendable {
    private let inboxLock = NSLock()
    private var inbox: [FileSystemEvent] = []
    private var inboxScheduled = false
    private var inboxOverflow = false
    private let queue = DispatchQueue(label:"apfsfind.metadata-events",qos:.utility)
    private let index: MetadataIndexCoordinator
    private let namespace: any NamespaceIndex
    private let root: String
    private let device: UInt64
    private let policy: MetadataUpdatePolicy
    private let metrics: Metrics
    private let invalidated: @Sendable () -> Void
    private let changed: @Sendable () -> Void
    private var pending: [String: Set<String>] = [:]
    private var collapsed: Set<String> = []
    private var discoveredSubtrees = Set<String>()
    private let scanCancellation = CancellationToken()
    private var work: DispatchWorkItem?
    private var epoch: UInt64 = 0
    private var maximumID: UInt64 = 0
    private var historyDone = false
    private var stopped = false
    private var suspended = false
    private var buffered: [FileSystemEvent] = []
    private var bufferOverflow = false
    private var renameOnly = Set<String>()
    private var renameOrigins: [String:(String,FileMetadataValue,EntryKind,MetadataQuerySnapshot)] = [:]
    private var recent: [String:FileMetadataValue] = [:]
    private var lookupWindow = ProcessInfo.processInfo.systemUptime
    private var lookupsInWindow = 0
    public init(root:String,device:UInt64,index:MetadataIndexCoordinator,namespace:any NamespaceIndex,
                metrics:Metrics,policy:MetadataUpdatePolicy = .init(),
                invalidated:@escaping @Sendable ()->Void,changed:@escaping @Sendable ()->Void = {}) {
        self.root = root; self.device = device; self.index = index; self.namespace = namespace
        self.metrics = metrics; self.policy = policy; self.invalidated = invalidated; self.changed = changed
    }
    public func enqueue(_ events:[FileSystemEvent]) {
        let schedule = inboxLock.withLock {
            let room = max(0,policy.maxPendingEntries-inbox.count)
            inbox.append(contentsOf:events.prefix(room)); inboxOverflow = inboxOverflow || events.count > room
            if inboxScheduled { return false }; inboxScheduled = true; return true
        }
        guard schedule else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let batch = self.inboxLock.withLock {
                let value = (self.inbox,self.inboxOverflow)
                self.inbox = []; self.inboxOverflow = false; self.inboxScheduled = false; return value
            }
            self.receive(batch.0)
            if batch.1 { self.metrics.record("metadata_inbox_overflows"); self.invalidated() }
        }
    }
    private func receive(_ events:[FileSystemEvent]) {
        guard !stopped else { return }
        if suspended {
            let room = max(0,policy.maxPendingEntries-buffered.count)
            buffered.append(contentsOf:events.prefix(room)); bufferOverflow = bufferOverflow || events.count > room
            return
        }
        let floor = index.replayFloor
        var replaying = index.isReplaying
        for e in events {
            metrics.record("metadata_events_received")
            let classification = EventClassifier.classify(e)
            let impact = MetadataEventImpact.classify(e)
            if impact == .invalidated || classification == .subtreeDirty {
                metrics.record("metadata_invalidations"); invalidated(); continue
            }
            if classification == .historyDone { historyDone = true; replaying = false; continue }
            if e.id != UInt64.max { maximumID = max(maximumID,e.id) }
            let ordinary:Bool
            switch classification {
            case .simpleCreate, .simpleRemove, .contentOnly: ordinary = true
            case .ambiguous:
                let renameFlags = UInt32(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemIsSymlink)
                ordinary = e.flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 && e.flags & ~renameFlags == 0
            default: ordinary = false
            }
            // An ambiguous/unknown event can conceal namespace creation even at an old ID.
            if replaying && ordinary && e.id > 0 && e.id != UInt64.max && e.id <= floor { metrics.record("metadata_overlap_skipped"); continue }
            guard impact != .none, let path = PathCanonicalizer.normalize(e.path),
                  PathCanonicalizer.isWithin(path,root:root) else { continue }
            let parent = PathCanonicalizer.parent(of:path)
            if collapsed.contains(parent) { metrics.record("metadata_events_deduplicated"); continue }
            let item = namespace.entry(at:path)
            if impact == .reconcileParent {
                collapsed.insert(item?.kind == .directory ? path : parent)
                metrics.record("metadata_parent_collapses")
            }
            let snapshot = index.capture()
            let oldRecord = snapshot.ordinal(path).map { snapshot.namespace!.record(at:$0) }
            if let item, item.kind == .directory,
               e.flags & UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed) != 0,
               (!index.baseDirectoryMatches(path:path,fileID:item.fileID) || e.flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0) {
                discoveredSubtrees.insert(path)
            }
            let fileID = item?.fileID ?? oldRecord.map { $0.fileID == 0 ? nil : $0.fileID } ?? nil
            let key = fileID.map { "\(device):\($0)" } ?? path
            let rename = e.flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 &&
                e.flags & UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemCreated) == 0
            if rename, item == nil, let record = oldRecord {
                renameOrigins[key] = (path,snapshot.value(path:path),record.kind,snapshot)
            }
            if rename { renameOnly.insert(path) } else { renameOnly.remove(path) }
            if pending[key] != nil { metrics.record("metadata_events_deduplicated") }
            pending[key,default:[]].insert(path)
            if e.flags & UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed) != 0,
               PathCanonicalizer.isWithin(parent,root:root) {
                let parentEntry = namespace.entry(at:parent)
                let parentKey = parentEntry?.fileID.map { "\(device):\($0)" } ?? parent
                pending[parentKey,default:[]].insert(parent)
            }
            if collapsed.count >= 16_384 || discoveredSubtrees.count >= 16_384 {
                pending.removeAll(); collapsed.removeAll(); discoveredSubtrees.removeAll(); invalidated(); return
            }
            if pending.count >= policy.maxPendingEntries {
                collapsed.formUnion(pending.values.flatMap { $0.map { PathCanonicalizer.parent(of:$0) } }); pending.removeAll()
                metrics.record("metadata_parent_collapses")
            }
        }
        if pending.isEmpty && collapsed.isEmpty { index.advance(maximumID,historyDone:historyDone); changed(); return }
        index.markPending(); changed()
        schedule(after:policy.debounceSeconds)
    }
    private func schedule(after delay:Double) {
        work?.cancel(); epoch &+= 1; let current = epoch
        let item = DispatchWorkItem { [weak self] in guard let self, self.epoch == current, !self.stopped else { return }; self.work = nil; self.drain() }
        work = item; queue.asyncAfter(deadline:.now()+delay,execute:item)
    }
    private func drain() {
        guard !pending.isEmpty || !collapsed.isEmpty || !discoveredSubtrees.isEmpty else { index.advance(maximumID,historyDone:historyDone); return }
        metrics.record("metadata_scheduler_wakeups")
        let now = ProcessInfo.processInfo.systemUptime
        if now-lookupWindow >= 1 { lookupWindow = now; lookupsInWindow = 0 }
        let paths = Set(pending.values.flatMap { $0 })
        var deferredPaths = Set<String>()
        if paths.count <= policy.smallBatchLimit && collapsed.isEmpty {
            let budget = max(1,policy.maxLookupsPerSecond)
            var reusedIdentities: [String:FileMetadataValue] = [:]
            var consumedOrigins = Set<String>()
            for path in paths {
                if renameOnly.contains(path), let item = namespace.entry(at:path),let id = item.fileID,
                   let origin = renameOrigins["\(device):\(id)"] {
                    if item.kind == .directory { index.reuseDirectoryRename(original:origin.0,destination:path,from:origin.3); discoveredSubtrees.remove(path) }
                    index.update(path:path,value:origin.1); consumedOrigins.insert("\(device):\(id)"); metrics.record("metadata_rename_reuses"); continue
                }
                if let item = namespace.entry(at:path), let id = item.fileID,
                   let value = reusedIdentities["\(device):\(id)"] {
                    index.update(path:path,value:value); metrics.record("metadata_fileid_lookup_reuses"); continue
                }
                if lookupsInWindow >= budget { deferredPaths.insert(path); continue }
                var record = APFSDirectoryEntry(); _ = apfs_deny_dataless_materialization()
                if path == "/" {
                    var directory = APFSDirectoryInfo()
                    if apfs_directory_info(path,device,1,&directory) == 0 {
                        index.update(path:path,value:.init(modificationTimeNanoseconds:FileMetadataValue.unixNanoseconds(seconds:directory.mtime_seconds,nanoseconds:directory.mtime_nanoseconds)))
                    }
                    lookupsInWindow += 1; metrics.record("metadata_lookups"); continue
                }
                let result = apfs_entry_info(path,device,&record); lookupsInWindow += 1; metrics.record("metadata_lookups")
                if result == 0 && record.device_id == device {
                    let v = FileMetadataValue(record), key = "\(record.device_id):\(record.file_id)"
                    recent[key] = v; reusedIdentities[key] = v; index.update(path:path,value:v)
                } else { index.update(path:path,value:nil) }
            }
            for key in consumedOrigins { renameOrigins.removeValue(forKey:key) }
        } else {
            let groups = Dictionary(grouping:paths,by:{PathCanonicalizer.parent(of:$0)})
            for (parent,items) in groups where items.count >= policy.stormParentCollapseThreshold {
                collapsed.insert(parent); metrics.record("metadata_parent_collapses")
            }
            let scanner = BulkScanner(root:root,workerCount:1,metrics:metrics)
            for parent in Set(groups.keys).union(collapsed) {
                let requestedPaths = groups[parent] ?? []
                let siblings = (namespace as? HybridIndex)?.childCount(of:parent) ?? requestedPaths.count
                // Sparse changes in huge directories use bounded metadata microbatches;
                // dense batches and collapsed storms continue to enumerate the parent.
                if !collapsed.contains(parent), requestedPaths.count < policy.stormParentCollapseThreshold,
                   requestedPaths.count * 8 < siblings {
                    let microLimit = min(64,max(1,policy.maxLookupsPerSecond))
                    for offset in stride(from:0,to:requestedPaths.count,by:microLimit) {
                        let chunk = Array(requestedPaths[offset..<min(offset+microLimit,requestedPaths.count)])
                        let instant = ProcessInfo.processInfo.systemUptime
                        if instant-lookupWindow >= 1 { lookupWindow = instant; lookupsInWindow = 0 }
                        if lookupsInWindow+chunk.count > max(1,policy.maxLookupsPerSecond) {
                            deferredPaths.formUnion(chunk); continue
                        }
                        lookupsInWindow += chunk.count
                        let pointers = chunk.map { strdup(($0 as NSString).lastPathComponent) }
                        defer { for p in pointers { free(p) } }
                        let names: [UnsafePointer<CChar>?] = pointers.map { pointer in pointer.map { UnsafePointer<CChar>($0) } }
                        var records = [APFSDirectoryEntry](repeating:APFSDirectoryEntry(),count:chunk.count)
                        let status = names.withUnsafeBufferPointer { n in records.withUnsafeMutableBufferPointer {
                            apfs_metadata_batch(parent,device,n.baseAddress,chunk.count,$0.baseAddress)
                        } }
                        metrics.record("metadata_parent_microbatches"); metrics.record("metadata_lookups",by:chunk.count)
                        for (path,record) in zip(chunk,records) {
                            index.update(path:path,value:status == 0 && record.error_code == 0 ? FileMetadataValue(record) : nil)
                        }
                    }
                    continue
                }
                metrics.record("metadata_parent_bulk_enumerations")
                do {
                    let entries = try scanner.readScannedDirectory(parent,rootDeviceID:device)
                    let requested = Set(groups[parent] ?? [])
                    var found = Set<String>()
                    for entry in entries where collapsed.contains(parent) || requested.contains(entry.namespace.path) {
                        if entry.namespace.kind == .directory,
                           !index.baseDirectoryMatches(path:entry.namespace.path,fileID:entry.namespace.fileID) {
                            discoveredSubtrees.insert(entry.namespace.path)
                        }
                        index.update(path:entry.namespace.path,value:entry.metadata); found.insert(entry.namespace.path)
                    }
                    for path in requested.subtracting(found) { index.update(path:path,value:nil) }
                } catch { invalidated() }
            }
        }
        // A directory moved into the watched root can arrive as one event, although
        // namespace reconciliation has discovered its entire pre-populated tree.
        // Fill those delta descendants with bulk metadata, never per-file stat.
        let scanner = BulkScanner(root:root,workerCount:1,metrics:metrics)
        let subtreeRoots = PathCanonicalizer.minimalRoots(Array(discoveredSubtrees))
        var remainingSubtrees = Set<String>()
        for (subtreeIndex,subtree) in subtreeRoots.enumerated() {
            var directories = [subtree]
            while let directory = directories.popLast(), !scanCancellation.isCancelled {
                let resources = SystemResourceSignals.shared.current()
                if resources.activeQueries > 0 || resources.memoryPressure == .critical {
                    remainingSubtrees.formUnion([directory]+directories+Array(subtreeRoots.dropFirst(subtreeIndex+1)))
                    metrics.record("metadata_subtree_yields"); break
                }
                do {
                    let entries = try scanner.readScannedDirectory(directory,rootDeviceID:device,cancellation:scanCancellation)
                    metrics.record("metadata_subtree_bulk_enumerations")
                    for entry in entries {
                        guard namespace.entry(at:entry.namespace.path) == entry.namespace else { continue }
                        index.update(path:entry.namespace.path,value:entry.metadata)
                        if BulkScanner.shouldTraverse(entry:entry.namespace,rootDeviceID:device) { directories.append(entry.namespace.path) }
                    }
                } catch {
                    if !scanCancellation.isCancelled { metrics.record("metadata_subtree_read_failures") }
                }
            }
        }
        discoveredSubtrees = remainingSubtrees
        if remainingSubtrees.count > 16_384 { discoveredSubtrees.removeAll(); invalidated(); return }
        if !remainingSubtrees.isEmpty {
            for path in remainingSubtrees { deferredPaths.insert(path) }
        }
        if recent.count > 4096 { recent.removeAll(keepingCapacity:true) }
        if renameOrigins.count > 4096 { renameOrigins.removeAll(keepingCapacity:true) }
        renameOnly.removeAll(keepingCapacity:true)
        pending.removeAll(keepingCapacity:true); collapsed.removeAll(keepingCapacity:true)
        if !deferredPaths.isEmpty {
            for path in deferredPaths { pending[path] = [path] }
            schedule(after:max(0.001,1-(ProcessInfo.processInfo.systemUptime-lookupWindow))); changed(); return
        }
        index.advance(maximumID,historyDone:historyDone); changed()
    }
    public func resetReplay() { queue.sync { historyDone = false; maximumID = index.processedCursor; index.restartReplay() } }
    public func suspend() { queue.sync { work?.cancel(); work = nil; epoch &+= 1; drain(); work?.cancel(); work = nil; epoch &+= 1; suspended = true } }
    public func resume() { queue.sync {
        suspended = false; let events = buffered; buffered = []; let overflow = bufferOverflow; bufferOverflow = false
        receive(events); if overflow { invalidated() }
    } }
    public func flush() { queue.sync { work?.cancel(); work = nil; epoch &+= 1; drain() } }
    public func stop() { scanCancellation.cancel(); queue.sync {
        work?.cancel(); work = nil; epoch &+= 1; stopped = true
        // Received callbacks have been classified before this barrier. Deferred
        // lookups keep the old processed fence; fast exit must not enumerate a
        // large pending tree. Restart replay recovers these unpersisted values.
        pending.removeAll(); collapsed.removeAll(); discoveredSubtrees.removeAll()
    } }
}
