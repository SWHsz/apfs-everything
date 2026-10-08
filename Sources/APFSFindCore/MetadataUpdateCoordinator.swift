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
    public var maxParentPagesPerSlice = 32
    public init() {}
}

/// Event-driven bounded debounce on a utility queue; no per-write lookup or repeating timer.
public final class MetadataUpdateCoordinator: @unchecked Sendable {
    private let inboxLock = NSLock()
    private var inbox: [String:FileSystemEvent] = [:]
    private var inboxHistoryDone = false
    private var inboxScheduled = false
    private var inboxOverflow = false
    private var inboxInvalidated = false
    private var inboxMaximumID: UInt64 = 0
    private let queue = DispatchQueue(label:"apfsfind.metadata-events",qos:.utility)
    private let index: MetadataIndexCoordinator
    private let namespace: any NamespaceIndex
    private let root: String
    private let device: UInt64
    private let policy: MetadataUpdatePolicy
    private let metrics: Metrics
    private let invalidated: @Sendable () -> Void
    private let changed: @Sendable () -> Void
    private let readDirectory: @Sendable (String, CancellationToken) throws -> [ScannedEntry]
    private var pending: [String: Set<String>] = [:]
    private var collapsed: Set<String> = []
    private var discoveredSubtrees = Set<String>()
    private var inboxRootRepair = false
    private var repeatInboxRootRepair = false
    private let scanCancellation = CancellationToken()
    private var work: DispatchWorkItem?
    private var epoch: UInt64 = 0
    private var maximumID: UInt64 = 0
    private var historyDone = false
    private var recoveryPending = false
    private var recoverySerial:UInt64 = 0
    private var stopped = false
    private var suspended = false
    private var buffered: [FileSystemEvent] = []
    private var bufferOverflow = false
    private var bufferedRootRepair = false
    private let pagedRepairs: Bool
    private let repairExclusions: [String]
    private var repairCursor: MetadataDirectoryCursor?
    private final class ParentSweep {
        let cursor: MetadataDirectoryCursor
        var requested: Set<String>, found = Set<String>()
        var all: Bool, repeatPass = false
        var entries = 0
        init(cursor:MetadataDirectoryCursor,requested:Set<String>,all:Bool) {
            self.cursor = cursor;self.requested = requested;self.all = all
        }
    }
    private var parentSweep: ParentSweep?
    private func matchesNamespace(_ entry:NamespaceEntry) -> Bool {
        guard let indexed = namespace.entry(at:entry.path) else {return false}
        return indexed.kind == entry.kind && indexed.isMountPoint == entry.isMountPoint &&
            (indexed.deviceID == 0 || indexed.deviceID == entry.deviceID) &&
            (indexed.fileID == nil || indexed.fileID == entry.fileID)
    }
    /// Each page is consumed before opening another one. Events received after
    /// the page was read require a second pass rather than resetting progress.
    private func refreshParentPage(_ parent:String,requested:Set<String>,all:Bool) throws -> Bool {
        if parentSweep?.cursor.path != parent {
            precondition(parentSweep == nil,"finish the active parent before another parent")
            parentSweep = ParentSweep(cursor:try MetadataDirectoryCursor(path:parent,device:device,excludedRoots:repairExclusions,metrics:metrics,pageMetric:"metadata_parent_bulk_pages"),requested:requested,all:all)
        }
        guard let sweep = parentSweep else {return true}
        sweep.requested.formUnion(requested);sweep.all = sweep.all || all
        guard sweep.requested.count <= policy.maxPendingEntries else {throw ScannerError(path:parent,code:EOVERFLOW)}
        guard let current = namespace.entry(at:parent),current.kind == .directory,
              current.fileID == nil || current.fileID == sweep.cursor.fileID else {
            sweep.cursor.close();parentSweep = nil
            // Namespace owns removal/replacement. A fresh callback will repair
            // the new directory; never continue its predecessor's descriptor.
            metrics.record("metadata_parent_identity_races");return true
        }
        let entries = try sweep.cursor.next(cancellation:scanCancellation)
        sweep.entries += entries.count
        guard sweep.entries <= 100_000 else {throw ScannerError(path:parent,code:EOVERFLOW)}
        noteBulkAllocation(entries.count)
        for entry in entries where sweep.all || sweep.requested.contains(entry.namespace.path) {
            // Bulk listing can include unindexed siblings. Do not retain orphan
            // metadata or revive a replaced file using an old directory page.
            guard matchesNamespace(entry.namespace) else {continue}
            if entry.namespace.kind == .directory,
               !index.baseDirectoryMatches(path:entry.namespace.path,fileID:entry.namespace.fileID) {discoveredSubtrees.insert(entry.namespace.path)}
            index.update(path:entry.namespace.path,value:entry.metadata)
            if sweep.requested.contains(entry.namespace.path) {sweep.found.insert(entry.namespace.path)}
            guard discoveredSubtrees.count < 16_384 else {throw ScannerError(path:parent,code:EOVERFLOW)}
        }
        guard sweep.cursor.finished else {return false}
        for path in sweep.requested.subtracting(sweep.found) {index.update(path:path,value:nil)}
        if sweep.repeatPass {
            parentSweep = ParentSweep(cursor:try MetadataDirectoryCursor(path:parent,device:device,excludedRoots:repairExclusions,metrics:metrics,pageMetric:"metadata_parent_bulk_pages"),requested:sweep.requested,all:sweep.all)
            metrics.record("metadata_parent_repeat_passes");return false
        }
        parentSweep = nil;return true
    }
    private func retainParentSweepForPublication() {
        guard let sweep = parentSweep else {return}
        for path in sweep.requested {pending[path,default:[]].insert(path)}
        if sweep.all {collapsed.insert(sweep.cursor.path)}
        sweep.cursor.close();parentSweep = nil
    }
    private var renameOnly = Set<String>()
    private struct RenameOrigin {
        let path: String
        let value: FileMetadataValue
        // Only directories need a frozen subtree source. Files retain scalars.
        let snapshot: MetadataQuerySnapshot?
        let retainedBytes: Int
    }
    private var renameOrigins: [String:RenameOrigin] = [:]
    private func originUsage() -> (count:Int,bytes:Int) {
        renameOrigins.values.reduce(into:(0,0)) { result,origin in
            if origin.snapshot != nil { result.0 += 1; result.1 += origin.retainedBytes }
        }
    }
    private func recordOrigins() {
        let usage = originUsage()
        metrics.set("metadata_rename_origins",to:renameOrigins.count)
        metrics.set("metadata_rename_origin_snapshots",to:usage.count)
        metrics.set("metadata_rename_origin_snapshot_bytes",to:usage.bytes)
    }
    private var localIOFailures: [String:Int] = [:]
    private var entriesSinceRelief = 0
    private var reliefQueued = false
    private func noteBulkAllocation(_ count: Int) {
        entriesSinceRelief = min(32_768,entriesSinceRelief + count)
        guard entriesSinceRelief >= 32_768, !reliefQueued else { return }
        reliefQueued = true
        queue.async { [weak self] in
            guard let self else { return }
            self.reliefQueued = false; self.entriesSinceRelief = 0
            guard !self.scanCancellation.isCancelled else { return }
            self.metrics.record("metadata_reconcile_allocator_relief_runs")
            self.metrics.record("metadata_reconcile_allocator_released_bytes",by:Int(apfs_release_allocator_pages()))
        }
    }
    private func needsRecovery(_ path: String, code: Int32) -> Bool {
        if code == EOVERFLOW { return true }
        let count = min(3, (localIOFailures[path] ?? 0) + 1)
        if localIOFailures[path] == nil && localIOFailures.count >= 4096 {
            metrics.record("metadata_local_retry_overflows"); return true
        }
        let previous = localIOFailures[path] ?? 0
        localIOFailures[path] = count
        metrics.record("metadata_local_io_retries")
        return count == 3 && previous < 3
    }
    private var lookupWindow = ProcessInfo.processInfo.systemUptime
    private var lookupsInWindow = 0
    public init(root:String,device:UInt64,index:MetadataIndexCoordinator,namespace:any NamespaceIndex,
                metrics:Metrics,policy:MetadataUpdatePolicy = .init(),
                invalidated:@escaping @Sendable ()->Void,changed:@escaping @Sendable ()->Void = {},
                readDirectory:(@Sendable (String,CancellationToken) throws -> [ScannedEntry])? = nil) {
        self.root = root; self.device = device; self.index = index; self.namespace = namespace
        self.metrics = metrics; self.policy = policy; self.invalidated = invalidated; self.changed = changed
        pagedRepairs = readDirectory == nil
        repairExclusions = BulkScanner.maintenanceExclusions(root:root)
        let scanner = BulkScanner(root:root,workerCount:1,metrics:metrics)
        self.readDirectory = readDirectory ?? { path,cancellation in
            try scanner.readScannedDirectory(path,rootDeviceID:device,cancellation:cancellation,maximumEntries:100_000,yieldToQueries:false)
        }
    }
    public func enqueue(_ events:[FileSystemEvent]) {
        let schedule = inboxLock.withLock {
            guard !scanCancellation.isCancelled else { return false }
            var coalesced = 0
            for incoming in events {
                if MetadataEventImpact.classify(incoming) == .invalidated { inboxInvalidated = true }
                if incoming.id != UInt64.max { inboxMaximumID = max(inboxMaximumID,incoming.id) }
                var event = incoming
                if event.flags & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 {
                    inboxHistoryDone = true
                    let remaining = event.flags & ~UInt32(kFSEventStreamEventFlagHistoryDone)
                    if remaining == 0 { continue }
                    event = .init(path:event.path,flags:remaining,id:event.id)
                }
                if let old = inbox[event.path] {
                    // Union flags preserves create/remove ambiguity and actual
                    // stream invalidation. Authoritative refresh observes now.
                    inbox[event.path] = .init(path:event.path,flags:old.flags | event.flags,id:max(old.id,event.id))
                    coalesced += 1
                } else if inbox.count < policy.maxPendingEntries { inbox[event.path] = event }
                else { inboxOverflow = true }
            }
            metrics.record("metadata_inbox_events_received",by:events.count)
            metrics.record("metadata_inbox_events_coalesced",by:coalesced)
            if inboxScheduled { return false }; inboxScheduled = true; return true
        }
        guard schedule else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let batch = self.inboxLock.withLock {
                var events = Array(self.inbox.values)
                // A replay fence follows every path refresh represented by it.
                if self.inboxHistoryDone { events.append(.init(path:self.root,flags:UInt32(kFSEventStreamEventFlagHistoryDone),id:UInt64.max)) }
                let value = (events,self.inboxOverflow,self.inboxInvalidated,self.inboxMaximumID,self.inboxHistoryDone)
                self.inbox = [:]; self.inboxHistoryDone = false; self.inboxOverflow = false
                self.inboxInvalidated = false; self.inboxMaximumID = 0; self.inboxScheduled = false; return value
            }
            autoreleasepool {
                if batch.1 && !batch.2 {
                    // We know every dropped path belongs to this watched root.
                    // Repair its metadata in bounded directory slices instead
                    // of allocating a full-volume bootstrap's private columns.
                    self.metrics.record("metadata_inbox_overflows")
                    self.repairOverflowedInbox(maximumID:batch.3,historyDone:batch.4)
                } else {
                    self.receive(batch.0)
                    if batch.1 { self.metrics.record("metadata_inbox_overflows"); self.requestRecovery(newStreamInvalidation:batch.2) }
                }
            }
        }
    }
    private func requestRecovery(newStreamInvalidation:Bool = false) {
        let first = !recoveryPending
        if first || newStreamInvalidation {recoverySerial &+= 1}
        recoveryPending = true;index.markPending()
        if first || newStreamInvalidation {metrics.record("metadata_recovery_requests");invalidated()}
        else {metrics.record("metadata_recovery_requests_coalesced")}
    }
    private func advanceCompletedCursor() {
        guard !recoveryPending, parentSweep == nil else {return}
        index.advance(maximumID,historyDone:historyDone)
    }
    public var recoveryTicket:UInt64 {queue.sync {recoverySerial}}
    public var needsRecovery:Bool {queue.sync {recoveryPending}}
    @discardableResult public func completeRecovery(ticket:UInt64) -> Bool {queue.sync {
        guard ticket == recoverySerial else {index.markPending();return false}
        recoveryPending = false;return true
    }}
    private func repairOverflowedInbox(maximumID:UInt64,historyDone:Bool) {
        guard !stopped, !scanCancellation.isCancelled else {return}
        self.maximumID = max(self.maximumID,maximumID)
        self.historyDone = self.historyDone || historyDone
        if suspended {
            bufferedRootRepair = true;return
        }
        if inboxRootRepair {repeatInboxRootRepair = true;metrics.record("metadata_inbox_scope_repeat")}
        else {inboxRootRepair = true;discoveredSubtrees.insert(root);metrics.record("metadata_inbox_scope_repairs")}
        index.markPending();metrics.set("pending_metadata_lookups",to:pending.count+collapsed.count+discoveredSubtrees.count+(parentSweep.map{max(1,$0.requested.count)} ?? 0))
        schedule(after:0.005);changed()
    }
    private func receive(_ events:[FileSystemEvent]) {
        guard !stopped, !scanCancellation.isCancelled else { return }
        if suspended {
            let room = max(0,policy.maxPendingEntries-buffered.count)
            buffered.append(contentsOf:events.prefix(room)); metrics.set("metadata_buffered_events",to:buffered.count); bufferOverflow = bufferOverflow || events.count > room
            return
        }
        let floor = index.replayFloor
        var replaying = index.isReplaying
        for e in events {
            // Foundation name/path folding can return autoreleased objects.
            // Retire them per event, rather than retaining an entire replay
            // callback's temporary objects until all paths are classified.
            let keepReceiving:Bool = autoreleasepool {
                metrics.record("metadata_events_received")
                let classification = EventClassifier.classify(e)
                let impact = MetadataEventImpact.classify(e)
                if impact == .invalidated {
                    metrics.record("metadata_invalidations"); requestRecovery(newStreamInvalidation:true); return true
                }
                if classification == .historyDone { historyDone = true; replaying = false; return true }
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
                if replaying && ordinary && e.id > 0 && e.id != UInt64.max && e.id <= floor { metrics.record("metadata_overlap_skipped"); return true }
                guard impact != .none, let path = PathCanonicalizer.normalize(e.path),
                      PathCanonicalizer.isWithin(path,root:root) else { return true }
                if classification == .subtreeDirty {
                    discoveredSubtrees.insert(namespace.entry(at:path)?.kind == .directory ? path : PathCanonicalizer.parent(of:path))
                }
                let parent = PathCanonicalizer.parent(of:path)
                if let sweep = parentSweep, parent == sweep.cursor.path || path == sweep.cursor.path {
                    sweep.repeatPass = true
                }
                if collapsed.contains(parent) {
                    metrics.record("metadata_events_deduplicated")
                    // Enumeration refreshes present siblings, but cannot clear
                    // a disappeared child's previous sidecar/delta value.
                    if impact == .remove {pending[path,default:[]].insert(path)}
                    return true
                }
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
                    if renameOrigins.count >= 4096 { renameOrigins = [:] }
                    var retained: MetadataQuerySnapshot?
                    var bytes = 0
                    if record.kind == .directory {
                        bytes = snapshot.overlay.estimatedBytes + 200
                        let usage = originUsage()
                        if snapshot.available && usage.count < 64 && usage.bytes + bytes <= 8 * 1024 * 1024 { retained = snapshot }
                        else { bytes = 0; metrics.record("metadata_rename_origin_snapshot_rejected") }
                    }
                    renameOrigins[key] = .init(path:path,value:snapshot.value(path:path),snapshot:retained,retainedBytes:bytes)
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
                    metrics.record("metadata_pending_frontier_overflows")
                    pending.removeAll(); collapsed.removeAll(); discoveredSubtrees.removeAll(); metrics.set("pending_metadata_lookups",to:0); requestRecovery(); return false
                }
                if pending.count >= policy.maxPendingEntries {
                    collapsed.formUnion(pending.values.flatMap { $0.map { PathCanonicalizer.parent(of:$0) } }); pending.removeAll()
                    metrics.record("metadata_parent_collapses")
                }
                return true
            }
            if !keepReceiving {return}
        }
        recordOrigins()
        if pending.isEmpty && collapsed.isEmpty && discoveredSubtrees.isEmpty && parentSweep == nil { advanceCompletedCursor(); changed(); return }
        metrics.set("pending_metadata_lookups",to:pending.count+collapsed.count+discoveredSubtrees.count+(parentSweep.map{max(1,$0.requested.count)} ?? 0)); index.markPending(); changed()
        schedule(after:policy.debounceSeconds)
    }
    private func schedule(after delay:Double) {
        // Continuous callbacks must not move the whole pending batch's deadline
        // forever. New paths coalesce into the existing one-shot batch.
        guard work == nil else { return }
        epoch &+= 1; let current = epoch
        let item = DispatchWorkItem { [weak self] in guard let self, self.epoch == current, !self.stopped else { return }; self.work = nil; autoreleasepool { self.drain() } }
        work = item; queue.asyncAfter(deadline:.now()+delay,execute:item)
    }
    private func drain() {
        guard !scanCancellation.isCancelled, !suspended else { return }
        let resources = ProcessResourceSample.capture()
        metrics.set("metadata_update_active",to:1)
        defer { metrics.set("metadata_update_active",to:0); metrics.recordResources("metadata_event_updates",since:resources) }
        guard !pending.isEmpty || !collapsed.isEmpty || !discoveredSubtrees.isEmpty || parentSweep != nil else { metrics.set("pending_metadata_lookups",to:0); advanceCompletedCursor(); return }
        metrics.record("metadata_scheduler_wakeups")
        let now = ProcessInfo.processInfo.systemUptime
        if now-lookupWindow >= 1 { lookupWindow = now; lookupsInWindow = 0 }
        let paths = Set(pending.values.flatMap { $0 })
        var deferredPaths = Set<String>()
        var deferredParents = Set<String>()
        var parentSliceYield = false
        var slowDeferred = false
        if paths.count <= policy.smallBatchLimit && collapsed.isEmpty && parentSweep == nil {
            let budget = max(1,policy.maxLookupsPerSecond)
            var reusedIdentities: [String:FileMetadataValue] = [:]
            var consumedOrigins = Set<String>()
            for path in paths {
                guard !scanCancellation.isCancelled else { return }
                if renameOnly.contains(path), let item = namespace.entry(at:path),let id = item.fileID,
                   let origin = renameOrigins["\(device):\(id)"] {
                    if item.kind == .directory {
                        if let source = origin.snapshot, index.reuseDirectoryRename(original:origin.path,destination:path,from:source) { discoveredSubtrees.remove(path) }
                        else { discoveredSubtrees.insert(path); metrics.record("metadata_rename_alias_cap_hits") }
                    }
                    index.update(path:path,value:origin.value); consumedOrigins.insert("\(device):\(id)"); metrics.record("metadata_rename_reuses"); continue
                }
                if let item = namespace.entry(at:path), let id = item.fileID,
                   let value = reusedIdentities["\(device):\(id)"] {
                    index.update(path:path,value:value); metrics.record("metadata_fileid_lookup_reuses"); continue
                }
                if lookupsInWindow >= budget { deferredPaths.insert(path);slowDeferred = true;continue }
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
                    reusedIdentities[key] = v; index.update(path:path,value:v)
                } else { index.update(path:path,value:nil) }
            }
            for key in consumedOrigins { renameOrigins.removeValue(forKey:key) }
        } else {
            let groups = Dictionary(grouping:paths,by:{PathCanonicalizer.parent(of:$0)})
            for (parent,items) in groups where items.count >= policy.stormParentCollapseThreshold {
                collapsed.insert(parent); metrics.record("metadata_parent_collapses")
            }
            let activeParent = parentSweep?.cursor.path
            let parents = (activeParent.map{[$0]} ?? []) + Array(Set(groups.keys).union(collapsed).filter{$0 != activeParent})
            let parentSliceStart = ProcessInfo.processInfo.systemUptime
            var parentAttempts = 0
            for (parentIndex,parent) in parents.enumerated() {
                guard !scanCancellation.isCancelled else { return }
                if parentAttempts > 0 && (parentAttempts >= 32 || ProcessInfo.processInfo.systemUptime-parentSliceStart >= 0.020) {
                    for remaining in parents[parentIndex...] {
                        deferredPaths.formUnion(groups[remaining] ?? [])
                        if collapsed.contains(remaining) {deferredParents.insert(remaining)}
                    }
                    parentSliceYield = true;metrics.record("metadata_parent_slice_yields");break
                }
                parentAttempts += 1
                let requestedPaths = groups[parent] ?? []
                let siblings = (namespace as? HybridIndex)?.childCount(of:parent) ?? requestedPaths.count
                // Sparse changes in huge directories use bounded metadata microbatches;
                // dense batches and collapsed storms continue to enumerate the parent.
                if parentSweep?.cursor.path != parent, !collapsed.contains(parent), requestedPaths.count < policy.stormParentCollapseThreshold,
                   requestedPaths.count * 8 < siblings {
                    let microLimit = min(64,max(1,policy.maxLookupsPerSecond))
                    for offset in stride(from:0,to:requestedPaths.count,by:microLimit) {
                        guard !scanCancellation.isCancelled else { return }
                        let chunk = Array(requestedPaths[offset..<min(offset+microLimit,requestedPaths.count)])
                        let instant = ProcessInfo.processInfo.systemUptime
                        if instant-lookupWindow >= 1 { lookupWindow = instant; lookupsInWindow = 0 }
                        if lookupsInWindow+chunk.count > max(1,policy.maxLookupsPerSecond) {
                            deferredPaths.formUnion(chunk);slowDeferred = true;continue
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
                    if pagedRepairs {
                        var completed = false
                        repeat {
                            completed = try autoreleasepool {try refreshParentPage(parent,requested:Set(requestedPaths),all:collapsed.contains(parent))}
                            if completed {break}
                            parentAttempts += 1
                        } while parentAttempts < min(32,max(1,policy.maxParentPagesPerSlice)) && ProcessInfo.processInfo.systemUptime-parentSliceStart < 0.020 && !scanCancellation.isCancelled
                        if !completed {
                            for remaining in parents.dropFirst(parentIndex+1) {
                                deferredPaths.formUnion(groups[remaining] ?? [])
                                if collapsed.contains(remaining) {deferredParents.insert(remaining)}
                            }
                            parentSliceYield = true;metrics.record("metadata_parent_slice_yields");break
                        }
                        localIOFailures.removeValue(forKey:parent);continue
                    }
                    let entries = try readDirectory(parent,scanCancellation)
                    noteBulkAllocation(entries.count)
                    localIOFailures.removeValue(forKey:parent)
                    let requested = Set(groups[parent] ?? [])
                    var found = Set<String>()
                    for entry in entries where collapsed.contains(parent) || requested.contains(entry.namespace.path) {
                        guard matchesNamespace(entry.namespace) else {continue}
                        if entry.namespace.kind == .directory,
                           !index.baseDirectoryMatches(path:entry.namespace.path,fileID:entry.namespace.fileID) {
                            discoveredSubtrees.insert(entry.namespace.path)
                        }
                        index.update(path:entry.namespace.path,value:entry.metadata); found.insert(entry.namespace.path)
                    }
                    for path in requested.subtracting(found) { index.update(path:path,value:nil) }
                } catch is MaintenanceYield {
                    // A query/pressure yield is retryable work, not a corrupt
                    // sidecar. Keep the collapsed parent even without item events.
                    deferredPaths.formUnion(requestedPaths); deferredParents.insert(parent)
                    slowDeferred = true
                    metrics.record("metadata_parent_yields")
                } catch {
                    if scanCancellation.isCancelled { return }
                    slowDeferred = true
                    let code = (error as? ScannerError)?.code ?? EIO
                    let interrupted = parentSweep
                    parentSweep?.cursor.close();parentSweep = nil
                    metrics.record("metadata_parent_read_failures")
                    metrics.record("metadata_parent_errno_\(code)")
                    if DirectoryReconciler.recovery(for:code,isRoot:parent == root) == .rebuild {
                        deferredPaths.formUnion(interrupted?.requested ?? [])
                        if needsRecovery(parent,code:code) { metrics.record("metadata_parent_recovery_requests"); requestRecovery() }
                        if code != EOVERFLOW { deferredParents.insert(parent) }
                    }
                    // Permission exclusions and disappearance races do not
                    // justify rescanning millions of unrelated metadata records.
                }
            }
        }
        // A directory moved into the watched root can arrive as one event, although
        // namespace reconciliation has discovered its entire pre-populated tree.
        // Fill those delta descendants with bulk metadata, never per-file stat.
        let subtreeRoots = PathCanonicalizer.minimalRoots(Array(discoveredSubtrees))
        var remainingSubtrees = Set<String>()
        let subtreeSliceStart = ProcessInfo.processInfo.systemUptime
        var subtreeDirectories = 0
        subtreeSlice: for (subtreeIndex,subtree) in subtreeRoots.enumerated() {
            var directories = [subtree]
            while let directory = directories.popLast(), !scanCancellation.isCancelled {
                let resources = SystemResourceSignals.shared.current()
                if subtreeDirectories > 0 && (subtreeDirectories >= 32 ||
                    ProcessInfo.processInfo.systemUptime-subtreeSliceStart >= 0.02 ||
                    resources.activeQueries > 0 || resources.memoryPressure == .critical) {
                    remainingSubtrees.formUnion([directory]+directories+Array(subtreeRoots.dropFirst(subtreeIndex+1)))
                    // The budget covers the whole slice. Continuing the outer
                    // loop re-merges every remaining suffix, producing quadratic
                    // work without reading another directory.
                    metrics.record("metadata_subtree_yields"); break subtreeSlice
                }
                do {
                    let paged = inboxRootRepair && pagedRepairs
                    let entries:[ScannedEntry]
                    if paged {
                        if repairCursor?.path != directory {
                            repairCursor?.close()
                            repairCursor = try MetadataDirectoryCursor(path:directory,device:device,excludedRoots:repairExclusions,metrics:metrics)
                        }
                        guard let cursor = repairCursor else {throw ScannerError(path:directory,code:EIO)}
                        // A removed/replaced directory must not continue reading
                        // its old descriptor under the replacement's pathname.
                        guard let current = namespace.entry(at:directory),current.kind == .directory,
                              current.fileID == nil || current.fileID == cursor.fileID else {
                            cursor.close();repairCursor = nil;continue
                        }
                        entries = try cursor.next(cancellation:scanCancellation)
                    } else {entries = try readDirectory(directory,scanCancellation)}
                    noteBulkAllocation(entries.count)
                    localIOFailures.removeValue(forKey:directory)
                    subtreeDirectories += 1 // A page is a bounded scheduling unit.
                    if !paged {metrics.record("metadata_subtree_bulk_enumerations")}
                    for entry in entries {
                        guard !scanCancellation.isCancelled else { return }
                        guard namespace.entry(at:entry.namespace.path) == entry.namespace else { continue }
                        index.update(path:entry.namespace.path,value:entry.metadata)
                        if BulkScanner.shouldTraverse(entry:entry.namespace,rootDeviceID:device) {
                            if paged {repairCursor?.children.append(entry.namespace.path)}
                            else {directories.append(entry.namespace.path)}
                        }
                    }
                    if paged,let cursor = repairCursor {
                        guard cursor.children.count+directories.count+remainingSubtrees.count <= 16_384 else {
                            throw ScannerError(path:directory,code:EOVERFLOW)
                        }
                        if cursor.finished {
                            directories += cursor.children;repairCursor = nil
                            metrics.record("metadata_subtree_bulk_enumerations")
                        } else {directories.append(directory)}
                    }
                } catch is MaintenanceYield {
                    remainingSubtrees.formUnion([directory]+directories+Array(subtreeRoots.dropFirst(subtreeIndex+1)))
                    metrics.record("metadata_subtree_yields"); break subtreeSlice
                } catch {
                    // Match namespace scanning: inaccessible descendants and
                    // normal disappearance races do not invalidate the entire
                    // sidecar. Unexpected I/O or the bounded enumeration limit
                    // still requests authoritative metadata recovery.
                    if scanCancellation.isCancelled {repairCursor?.close();repairCursor = nil;return}
                    let code = (error as? ScannerError)?.code ?? EIO
                    repairCursor?.close();repairCursor = nil
                    metrics.record("metadata_subtree_errno_\(code)")
                    if DirectoryReconciler.recovery(for:code,isRoot:directory == root) == .rebuild {
                        if needsRecovery(directory,code:code) { metrics.record("metadata_subtree_recovery_requests");requestRecovery() }
                        if code != EOVERFLOW { deferredParents.insert(directory) }
                    }
                    if !scanCancellation.isCancelled { metrics.record("metadata_subtree_read_failures") }
                }
            }
        }
        guard !scanCancellation.isCancelled else { return }
        discoveredSubtrees = remainingSubtrees
        if inboxRootRepair && remainingSubtrees.isEmpty {
            metrics.record("metadata_inbox_scope_passes")
            if repeatInboxRootRepair {
                repeatInboxRootRepair = false;discoveredSubtrees.insert(root);remainingSubtrees.insert(root)
            } else {inboxRootRepair = false}
        }
        if remainingSubtrees.count > 16_384 { metrics.record("metadata_subtree_frontier_overflows");discoveredSubtrees.removeAll();repairCursor?.close();repairCursor = nil;requestRecovery();return }
        recordOrigins()
        renameOnly.removeAll(keepingCapacity:true)
        pending.removeAll(keepingCapacity:true); collapsed = deferredParents
        if !deferredPaths.isEmpty || !deferredParents.isEmpty || parentSweep != nil {
            for path in deferredPaths { pending[path] = [path] }
            metrics.set("pending_metadata_lookups",to:pending.count+collapsed.count+discoveredSubtrees.count+(parentSweep.map{max(1,$0.requested.count)} ?? 0))
            schedule(after:parentSliceYield && !slowDeferred ? 0.005 : max(0.001,1-(ProcessInfo.processInfo.systemUptime-lookupWindow))); changed(); return
        }
        if !remainingSubtrees.isEmpty {
            metrics.set("pending_metadata_lookups",to:remainingSubtrees.count)
            schedule(after:0.005); changed(); return
        }
        metrics.set("pending_metadata_lookups",to:0); advanceCompletedCursor(); changed()
    }
    public func resetReplay() { queue.sync { historyDone = false; maximumID = index.processedCursor; index.restartReplay() } }
    public func suspend() { queue.sync { guard !scanCancellation.isCancelled else { return }; work?.cancel(); work = nil; epoch &+= 1; autoreleasepool { drain() }; work?.cancel(); work = nil; epoch &+= 1; retainParentSweepForPublication(); suspended = true } }
    public func resume() { queue.sync {
        guard !scanCancellation.isCancelled else { return }
        suspended = false; let events = buffered; buffered = []; metrics.set("metadata_buffered_events",to:0); let overflow = bufferOverflow; bufferOverflow = false
        let repair = bufferedRootRepair;bufferedRootRepair = false
        // Install the repair fence before receive's empty-batch fast path can
        // publish the maximum ID retained while publication was suspended.
        if repair {repairOverflowedInbox(maximumID:maximumID,historyDone:historyDone)}
        autoreleasepool { receive(events) }
        if overflow { requestRecovery(newStreamInvalidation:true) }
    } }
    public func flush() { queue.sync { work?.cancel(); work = nil; epoch &+= 1; autoreleasepool { drain() } } }
    /// Cancellation is lock-only and can interrupt a running bulk lookup before its queue barrier.
    public func requestStop() { scanCancellation.cancel() }
    public var pendingCount: Int {
        inboxLock.withLock { inbox.count } + ["pending_metadata_lookups","metadata_update_active","metadata_buffered_events"].reduce(0) { $0+metrics.snapshot()[$1,default:0] }
    }
    public func stop() { requestStop(); queue.sync {
        work?.cancel(); work = nil; epoch &+= 1; stopped = true
        // Received callbacks have been classified before this barrier. Deferred
        // lookups keep the old processed fence; fast exit must not enumerate a
        // large pending tree. Restart replay recovers these unpersisted values.
        pending.removeAll(); collapsed.removeAll(); discoveredSubtrees.removeAll()
        repairCursor?.close();repairCursor = nil
        parentSweep?.cursor.close();parentSweep = nil
        buffered.removeAll(); renameOrigins.removeAll(); recordOrigins(); localIOFailures.removeAll()
        inboxLock.withLock { inbox.removeAll() }; metrics.set("pending_metadata_lookups",to:0)
    } }
}
