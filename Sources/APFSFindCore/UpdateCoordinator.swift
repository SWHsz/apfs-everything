import Foundation
import CoreServices

public enum IndexState: String, Sendable { case scanning, replaying, live, dirty, rebuilding, stopped, failed }
/// A cheap lifecycle snapshot: it never acquires the index lock or waits for I/O.
public struct StartupStatus: Sendable {
    public let state: IndexState
    public let historyDone: Bool
    public let receivedEvents: Int
    public let processedEvents: Int
    public let pendingEvents: Int
    public let rebuilds: Int
    public let scannerEntries: Int
    public let scannerDirectories: Int
    public let automaticRebuildSuspended: Bool
    public let lastError: String?
    public let recoveryReason: String?
}
public struct VerificationResult: Sendable {
    public let missing: [String]
    public let extra: [String]
    public var isConsistent: Bool { missing.isEmpty && extra.isEmpty }
}
public struct CoordinatorStats {
    public let dictionary: [String: Any]
    public var description: String {
        dictionary.keys.sorted().map { "\($0): \(dictionary[$0]!)" }.joined(separator: "\n")
    }
}

/// The writer owns event processing, diffs, and scheduling. Queries access only
/// FileIndex's rwlock, and rebuilds enumerate on a separate background queue.
public final class UpdateCoordinator: @unchecked Sendable {
    public let root: String
    public let index: FileIndex
    public let metrics = Metrics()
    public let configuration: APFSFindConfiguration
    private let writer = DispatchQueue(label: "apfsfind.writer")
    private let builder = DispatchQueue(label: "apfsfind.rebuild", qos: .utility)
    private let buildGroup = DispatchGroup()
    private let watcher = FSEventsWatcher()
    private let cancellation = CancellationToken()
    private let debugEvents = ProcessInfo.processInfo.environment["APFSFIND_DEBUG_EVENTS"] == "1"
    private let stateLock = NSLock()
    private var state: IndexState = .scanning
    private var historyDone = false
    private var errorDescription: String?
    private var recoveryReason: String?
    private let inboxLock = NSLock()
    private var inbox: [FileSystemEvent] = []
    private var inboxOverflow = false
    private var inboxHistoryDone = false
    private var drainScheduled = false
    private var rootDevice: UInt64 = 0
    private var reconciler: DirectoryReconciler?
    private var rebuildScheduled = false
    private var building = false
    private var lastRebuildStart: TimeInterval = -.infinity
    private var failureCount = 0
    private var rebuildEvents: [FileSystemEvent] = []
    private var rebuildOverflow = false
    private var needsStreamRestart = false
    private var automaticRebuildSuspended = false

    public init(root: String, configuration: APFSFindConfiguration = .init()) throws {
        self.root = try PathCanonicalizer.canonicalRoot(root)
        self.index = FileIndex(root: self.root)
        self.configuration = configuration
    }
    public var currentState: IndexState { stateLock.withLock { state } }
    public func startupStatus() -> StartupStatus {
        let lifecycle = stateLock.withLock { (state, historyDone, errorDescription, recoveryReason) }
        let queued = inboxLock.withLock { inbox.count }
        let counts = metrics.snapshot()
        return StartupStatus(state: lifecycle.0, historyDone: lifecycle.1,
            receivedEvents: counts["fsevents_received", default: 0],
            processedEvents: counts["fsevents_processed", default: 0],
            pendingEvents: queued + counts["active_batch_size", default: 0],
            rebuilds: counts["full_rebuilds", default: 0],
            scannerEntries: counts["scanner_entries", default: 0],
            scannerDirectories: counts["scanner_directories", default: 0],
            automaticRebuildSuspended: counts["automatic_rebuild_suspended", default: 0] != 0,
            lastError: lifecycle.2, recoveryReason: lifecycle.3)
    }
    private func setState(_ value: IndexState, error: String? = nil) {
        stateLock.withLock { state = value; if let error { errorDescription = error } }
    }

    public func start(progress: (@Sendable (String) -> Void)? = nil) throws {
        // Capture before any directory enumeration: replay closes the initial scan gap.
        let e0 = FSEventsWatcher.currentEventID()
        progress?("[info] Initial scan: \(root) (\(configuration.workerCount) workers)")
        let progressQueue = DispatchQueue(label: "apfsfind.scan-progress")
        let timer = DispatchSource.makeTimerSource(queue: progressQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [metrics] in
            let counts = metrics.snapshot()
            if counts["initial_index_building", default: 0] != 0 {
                progress?("[info] Building memory index: \(counts["initial_index_entries", default: 0])/\(counts["scanner_entries", default: 0]) entries")
            } else {
                progress?("[info] Scanning: \(counts["scanner_entries", default: 0]) entries, \(counts["scanner_directories", default: 0]) directories read")
            }
        }
        timer.resume()
        defer { timer.cancel(); progressQueue.sync {} }
        do {
            let scanner = BulkScanner(root: root, workerCount: configuration.workerCount, metrics: metrics)
            let result = try scanner.scan(cancellation: cancellation)
            guard !cancellation.isCancelled, !result.cancelled else { setState(.stopped); return }
            metrics.set("initial_scan_ms", to: Int(result.elapsedMilliseconds))
            metrics.set("initial_index_building", to: 1)
            let buildStart = ProcessInfo.processInfo.systemUptime
            let initial = makePrivateIndex(result.entries, counter: "initial_index_entries")
            metrics.set("initial_index_build_ms", to: Int((ProcessInfo.processInfo.systemUptime - buildStart) * 1000))
            metrics.set("initial_index_building", to: 0)
            guard !cancellation.isCancelled else { setState(.stopped); return }
            index.replace(with: initial)
            rootDevice = result.rootDeviceID
            reconciler = DirectoryReconciler(scanner: scanner, index: index, rootDeviceID: rootDevice, metrics: metrics)
            let s = index.stats()
            timer.cancel()
            progressQueue.sync {}
            progress?(String(format: "[info] Scan complete: %d files, %d directories, %d unreadable; scan %.1f ms, index %.1f ms; replay from %llu",
                s.files, s.directories, result.unreadableDirectories, result.elapsedMilliseconds,
                (ProcessInfo.processInfo.systemUptime - buildStart) * 1000, e0))
            setState(.replaying)
            try startWatcher(since: e0)
            if cancellation.isCancelled { watcher.stop(); setState(.stopped) }
        } catch {
            setState(.failed, error: String(describing: error))
            throw error
        }
    }

    private func makePrivateIndex(_ entries: [NamespaceEntry], counter: String) -> FileIndex {
        let fresh = FileIndex(root: root)
        // Bounded chunks keep cancellation responsive during million-entry setup.
        // This private index is never visible to queries before the final swap.
        for offset in stride(from: 0, to: entries.count, by: 4096) {
            guard !cancellation.isCancelled else { break }
            let end = min(entries.count, offset + 4096)
            fresh.apply(entries[offset..<end].map { .upsert($0) })
            metrics.set(counter, to: end)
        }
        return fresh
    }

    private func startWatcher(since id: UInt64) throws {
        try watcher.start(root: root, since: id, latencyMilliseconds: configuration.latencyMilliseconds) { [weak self] events in
            self?.enqueue(events)
        }
    }
    /// The callback copies only event information and queues it. No filesystem I/O.
    public func enqueue(_ events: [FileSystemEvent]) {
        guard !cancellation.isCancelled else { return }
        metrics.record("fsevents_received", by: events.count)
        let schedule = inboxLock.withLock {
            let room = max(0, configuration.maxPendingEvents - inbox.count)
            if events.count > room { inboxOverflow = true }
            inbox.append(contentsOf: events.prefix(room))
            if events.contains(where: { $0.flags & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 }) {
                inboxHistoryDone = true
            }
            metrics.maximum("event_queue_high_watermark", inbox.count)
            if drainScheduled { return false }
            drainScheduled = true
            return true
        }
        if schedule {
            writer.asyncAfter(deadline: .now() + configuration.microBatchWindowMilliseconds / 1000) { [weak self] in
                self?.drain()
            }
        }
    }

    private func drain() {
        let (events, overflow, finished) = inboxLock.withLock {
            let result = (inbox, inboxOverflow, inboxHistoryDone)
            inbox = []; inboxOverflow = false; inboxHistoryDone = false; drainScheduled = false
            return result
        }
        guard !cancellation.isCancelled else { return }
        if !events.isEmpty { metrics.set("last_batch_size", to: events.count) }
        metrics.set("active_batch_size", to: events.count)
        defer {
            metrics.record("fsevents_processed", by: events.count)
            metrics.set("active_batch_size", to: 0)
        }
        if finished { stateLock.withLock { historyDone = true } }
        if building {
            let room = max(0, configuration.maxPendingEvents - rebuildEvents.count)
            rebuildEvents.append(contentsOf: events.prefix(room))
            if events.count > room || overflow { rebuildOverflow = true }
        }
        if overflow {
            metrics.record("queue_overflows")
            requestRebuild(invalidated: true, reason: "queue_overflow")
        }
        if let reconciler { process(events, into: index, using: reconciler, countMetrics: true, mayRebuild: true) }
        if stateLock.withLock({ historyDone }), currentState == .replaying { setState(.live) }
    }

    private func nearestIndexedParent(_ path: String, in target: FileIndex) -> String {
        if path == root { return root }
        var parent = PathCanonicalizer.parent(of: path)
        while parent != root && target.entry(at: parent)?.kind != .directory {
            guard PathCanonicalizer.isWithin(parent, root: root), parent != "/" else { return root }
            parent = PathCanonicalizer.parent(of: parent)
        }
        return parent
    }

    internal func process(_ events: [FileSystemEvent], into target: FileIndex, using reconciler: DirectoryReconciler,
                         countMetrics: Bool, mayRebuild: Bool) {
        var namespace: [(FileSystemEvent, EventClassification)] = []
        for event in events {
            let classification = EventClassifier.classify(event)
            if debugEvents && countMetrics {
                FileHandle.standardError.write(Data("[debug] flags=0x\(String(event.flags, radix: 16)) \(classification) \(event.path)\n".utf8))
            }
            switch classification {
            case .historyDone: continue
            case .contentOnly:
                if countMetrics { metrics.record("ignored_content_events") }
            case .invalidated:
                if countMetrics { metrics.record("dropped_invalidated_events") }
                if mayRebuild { requestRebuild(invalidated: true, reason: "stream_invalidated") }
            default: namespace.append((event, classification))
            }
        }
        let storm = namespace.count > configuration.directPatchBatchLimit
        var direct: [IndexMutation] = []
        var dirty: [String: (subtree: Bool, force: Bool)] = [:]
        func mark(_ path: String, subtree: Bool = false, force: Bool = true) {
            guard PathCanonicalizer.isWithin(path, root: root) else { return }
            let previous = dirty[path] ?? (false, false)
            dirty[path] = (previous.subtree || subtree, previous.force || force)
        }
        for (event, classification) in namespace {
            guard let path = PathCanonicalizer.normalize(event.path) else { mark(root, subtree: true); continue }
            if classification == .subtreeDirty && (path == root || PathCanonicalizer.isWithin(root, root: path)) {
                if mayRebuild { requestRebuild(invalidated: false, reason: "root_subtree_event") }
                else { mark(root, subtree: true) }
                continue
            }
            guard PathCanonicalizer.isWithin(path, root: root) else { continue }
            let parent = nearestIndexedParent(path, in: target)
            if storm {
                if classification == .subtreeDirty {
                    mark(target.entry(at: path)?.kind == .directory ? path : parent, subtree: true)
                } else { mark(parent) }
                continue
            }
            switch classification {
            case .simpleCreate(let kind):
                // fseventsd may retain Created across successive Modified events
                // even after FlushSync. A known same-kind file needs no namespace
                // update, and a late root Created duplicates the initial scan.
                if let existing = target.entry(at: path), existing.kind == kind,
                   kind != .directory || path == root {
                    if countMetrics {
                        metrics.record("duplicate_create_events")
                        let content = UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemInodeMetaMod |
                            kFSEventStreamEventFlagItemXattrMod | kFSEventStreamEventFlagItemFinderInfoMod | kFSEventStreamEventFlagItemChangeOwner)
                        if event.flags & content != 0 { metrics.record("ignored_content_events") }
                    }
                    continue
                }
                let immediateParent = PathCanonicalizer.parent(of: path)
                if path != root, kind != .directory,
                   let parentEntry = target.entry(at: immediateParent), parentEntry.kind == .directory,
                   !parentEntry.isMountPoint, parentEntry.deviceID == rootDevice {
                    direct.append(.upsert(NamespaceEntry(path: path, kind: kind, deviceID: rootDevice)))
                } else { mark(parent) }
            case .simpleRemove:
                if path == root { if mayRebuild { requestRebuild(invalidated: true, reason: "root_removed") } }
                else { direct.append(.remove(path)) }
            case .subtreeDirty:
                mark(target.entry(at: path)?.kind == .directory ? path : parent, subtree: true)
            case .ambiguous:
                let explicit = event.flags & UInt32(kFSEventStreamEventFlagItemCreated |
                    kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed |
                    kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount) != 0
                mark(parent, force: explicit)
            default: break
            }
        }
        var namespaceBits: [String: UInt32] = [:]
        let createRemove = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved)
        for (event, _) in namespace {
            guard let path = PathCanonicalizer.normalize(event.path), PathCanonicalizer.isWithin(path, root: root) else { continue }
            namespaceBits[path, default: 0] |= event.flags & createRemove
        }
        for (path, bits) in namespaceBits where bits == createRemove {
            mark(nearestIndexedParent(path, in: target))
        }
        for mutation in direct {
            let removedDirectory: String?
            switch mutation {
            case .remove(let path): removedDirectory = target.entry(at: path)?.kind == .directory ? path : nil
            case .upsert(let entry): removedDirectory = entry.kind != .directory && target.entry(at: entry.path)?.kind == .directory ? entry.path : nil
            }
            if let path = removedDirectory, direct.contains(where: { other in
                if case .upsert(let entry) = other { return entry.path != path && PathCanonicalizer.isWithin(entry.path, root: path) }
                return false
            }) { mark(nearestIndexedParent(path, in: target), subtree: true) }
        }
        var roots = PathCanonicalizer.minimalRoots(Array(dirty.keys))
        if roots.count > configuration.dirtyParentLimit && mayRebuild {
            requestRebuild(invalidated: false, reason: "dirty_parent_limit")
            dirty.removeAll()
            roots.removeAll()
        }
        if countMetrics { metrics.record("dirty_directories", by: roots.count) }
        func mutationPath(_ mutation: IndexMutation) -> String {
            switch mutation { case .upsert(let entry): entry.path; case .remove(let path): path }
        }
        // Diffs are authoritative within dirty scopes. Mixing a stale create or
        // remove with a diff prepared from the old index would resurrect ghosts.
        let patches = direct.filter { mutation in
            !roots.contains { PathCanonicalizer.isWithin(mutationPath(mutation), root: $0) }
        }
        var mutations = patches
        var retryParents = Set<String>()
        for directory in roots {
            let absorbed = dirty.keys.contains { $0 != directory && PathCanonicalizer.isWithin($0, root: directory) }
            let nestedPatch = direct.contains {
                let path = mutationPath($0)
                return PathCanonicalizer.isWithin(path, root: directory) && PathCanonicalizer.parent(of: path) != directory
            }
            let options = dirty[directory] ?? (true, true)
            let plan = reconciler.prepare(directory, subtree: options.subtree || absorbed || nestedPatch,
                                          force: options.force, cancellation: cancellation)
            mutations += plan.mutations
            retryParents.formUnion(plan.retryParents)
            if plan.requiresRebuild && mayRebuild { requestRebuild(invalidated: false, reason: "reconcile_error") }
            if plan.gateSkipped && mayRebuild {
                // A matching mtime is never the sole correctness evidence. Recheck
                // once without the gate; explicit namespace events bypass it already.
                writer.asyncAfter(deadline: .now() + configuration.rebuildDebounceMilliseconds / 1000) { [weak self] in
                    guard let self, !self.cancellation.isCancelled else { return }
                    if let current = self.reconciler {
                        self.repairDirectories([directory], into: self.index, using: current, mayRebuild: true)
                    }
                }
            }
        }
        target.apply(mutations) // One short write lock for the entire event microbatch.
        // A vanished directory cannot be treated as an empty successful read.
        // Its surviving parent determines removal/type replacement authoritatively.
        repairDirectories(Array(retryParents), into: target, using: reconciler, mayRebuild: mayRebuild)
        if countMetrics { metrics.record("direct_patches", by: patches.count) }
    }

    private func repairDirectories(_ paths: [String], into target: FileIndex,
                                   using reconciler: DirectoryReconciler, mayRebuild: Bool) {
        var pending = PathCanonicalizer.minimalRoots(paths)
        var seen = Set<String>()
        while !pending.isEmpty, !cancellation.isCancelled {
            var parents = Set<String>()
            for directory in pending where seen.insert(directory).inserted {
                let plan = reconciler.prepare(directory, force: true, cancellation: cancellation)
                target.apply(plan.mutations)
                parents.formUnion(plan.retryParents)
                if plan.requiresRebuild && mayRebuild {
                    requestRebuild(invalidated: false, reason: "reconcile_error")
                }
            }
            // Each race climbs toward the root, with a visited set as a guard.
            pending = PathCanonicalizer.minimalRoots(Array(parents)).filter { !seen.contains($0) }
        }
    }

    public func waitUntilLive(timeout: TimeInterval = 10) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        while ProcessInfo.processInfo.systemUptime < deadline && !cancellation.isCancelled {
            if currentState == .live { return true }
            if currentState == .failed || currentState == .stopped { return false }
            Thread.sleep(forTimeInterval: 0.002)
        }
        return currentState == .live
    }

    public func rebuild() {
        writer.async { [weak self] in
            guard let self else { return }
            self.automaticRebuildSuspended = false
            self.metrics.set("automatic_rebuild_suspended", to: 0)
            self.failureCount = 0
            self.requestRebuild(invalidated: false, reason: "manual")
        }
    }
    private func requestRebuild(invalidated: Bool, reason: String) {
        guard !cancellation.isCancelled else { return }
        metrics.record("rebuild_requests_" + reason)
        stateLock.withLock { recoveryReason = reason }
        if invalidated { needsStreamRestart = true }
        if !building { setState(.dirty) }
        guard !automaticRebuildSuspended else { return }
        guard !building, !rebuildScheduled else { return }
        rebuildScheduled = true
        let backoff = failureCount == 0 ? 0 : min(300, pow(2, Double(min(failureCount, 8))))
        let remaining = max(0, configuration.fullRebuildMinInterval - (Date.timeIntervalSinceReferenceDate - lastRebuildStart))
        let delay = max(configuration.rebuildDebounceMilliseconds / 1000, remaining, backoff)
        writer.asyncAfter(deadline: .now() + delay) { [weak self] in self?.beginRebuild() }
    }
    private func beginRebuild() {
        rebuildScheduled = false
        guard !building, !cancellation.isCancelled else { return }
        building = true; rebuildEvents = []; rebuildOverflow = false
        lastRebuildStart = Date.timeIntervalSinceReferenceDate
        let e0 = FSEventsWatcher.currentEventID()
        setState(.rebuilding)
        buildGroup.enter()
        builder.async { [weak self] in
            guard let self else { return }
            let result = Result {
                let scan = try BulkScanner(root: self.root, workerCount: self.configuration.workerCount,
                                           metrics: self.metrics).scan(cancellation: self.cancellation)
                self.metrics.set("rebuild_index_entries", to: 0)
                let fresh = self.makePrivateIndex(scan.entries, counter: "rebuild_index_entries")
                return PreparedIndex(index: fresh, rootDeviceID: scan.rootDeviceID, cancelled: scan.cancelled)
            }
            self.writer.async { [weak self] in self?.completeRebuild(result, since: e0) }
            self.buildGroup.leave()
        }
    }
    private struct PreparedIndex: Sendable {
        let index: FileIndex
        let rootDeviceID: UInt64
        let cancelled: Bool
    }
    private func completeRebuild(_ result: Result<PreparedIndex, Error>, since e0: UInt64) {
        building = false
        guard !cancellation.isCancelled else { return }
        do {
            let scan = try result.get()
            guard !scan.cancelled else { return }
            let fresh = scan.index
            rootDevice = scan.rootDeviceID
            let scanner = BulkScanner(root: root, workerCount: configuration.workerCount, metrics: metrics)
            let freshReconciler = DirectoryReconciler(scanner: scanner, index: fresh, rootDeviceID: rootDevice, metrics: metrics)
            // Apply all buffered namespace changes to the private index before the
            // exchange; callbacks queued later are processed by this same writer.
            process(rebuildEvents, into: fresh, using: freshReconciler, countMetrics: false, mayRebuild: false)
            index.replace(with: fresh)
            reconciler = DirectoryReconciler(scanner: scanner, index: index, rootDeviceID: rootDevice, metrics: metrics)
            rebuildEvents = []
            metrics.record("full_rebuilds")
            let restart = needsStreamRestart
            needsStreamRestart = false
            if restart {
                watcher.stop()
                inboxLock.withLock {
                    inbox = []; inboxHistoryDone = false; inboxOverflow = false; drainScheduled = false
                }
                stateLock.withLock { historyDone = false }
                setState(.replaying)
                try startWatcher(since: e0)
            } else { setState(stateLock.withLock { historyDone } ? .live : .replaying) }
            failureCount = 0
            stateLock.withLock { errorDescription = nil; recoveryReason = nil }
            if rebuildOverflow { requestRebuild(invalidated: true, reason: "rebuild_buffer_overflow") }
        } catch {
            failureCount += 1
            metrics.record("rebuild_failures")
            setState(.dirty, error: String(describing: error))
            FileHandle.standardError.write(Data("[error] Rebuild failed: \(error)\n".utf8))
            if failureCount >= configuration.maxConsecutiveRebuildFailures {
                automaticRebuildSuspended = true
                metrics.set("automatic_rebuild_suspended", to: 1)
                FileHandle.standardError.write(Data("[error] Automatic rebuild retries suspended; use :rebuild after restoring directory access.\n".utf8))
                return
            }
            requestRebuild(invalidated: true, reason: "rebuild_failure")
        }
    }

    public func flushEvents(timeout: TimeInterval = 2) -> Bool {
        guard !cancellation.isCancelled else { return false }
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { completed.signal(); return }
            self.watcher.flush()
            self.writer.async { [weak self] in self?.drain(); completed.signal() }
        }
        return completed.wait(timeout: .now() + timeout) == .success
    }

    public func verify() throws -> VerificationResult {
        let scan = try BulkScanner(root: root, workerCount: configuration.workerCount).scan(cancellation: cancellation)
        guard !scan.cancelled else { throw CocoaError(.userCancelled) }
        let actual = Set(scan.entries.map(\.path)).union([root])
        let online = index.snapshotPaths()
        return VerificationResult(missing: actual.subtracting(online).sorted(), extra: online.subtracting(actual).sorted())
    }

    public func stats() -> CoordinatorStats {
        let s = index.stats(), usage = Metrics.processUsage()
        var values: [String: Any] = metrics.snapshot()
        for key in ["fsevents_received", "fsevents_processed", "ignored_content_events", "direct_patches", "directory_reconciles",
                    "subtree_reconciles", "full_rebuilds", "dropped_invalidated_events", "event_queue_high_watermark", "last_batch_size"] {
            if values[key] == nil { values[key] = 0 }
        }
        values.merge(["entries": s.totalEntries, "live_entries": s.liveEntries, "tombstones": s.tombstones,
                      "current_generation": s.generation, "current_index_state": currentState.rawValue,
                      "process_rss_bytes": usage.residentBytes, "user_cpu_seconds": usage.userCPUSeconds,
                      "system_cpu_seconds": usage.systemCPUSeconds, "latency_ms": configuration.latencyMilliseconds,
                      "workers": configuration.workerCount, "direct_patch_batch_limit": configuration.directPatchBatchLimit,
                      "dirty_parent_limit": configuration.dirtyParentLimit,
                      "micro_batch_window_ms": configuration.microBatchWindowMilliseconds,
                      "full_rebuild_min_interval_seconds": configuration.fullRebuildMinInterval,
                      "max_consecutive_rebuild_failures": configuration.maxConsecutiveRebuildFailures,
                      "max_pending_events": configuration.maxPendingEvents,
                      "rebuild_debounce_ms": configuration.rebuildDebounceMilliseconds], uniquingKeysWith: { _, b in b })
        if let error = stateLock.withLock({ errorDescription }) { values["last_error"] = error }
        return CoordinatorStats(dictionary: values)
    }

    public func stop() {
        cancellation.cancel()
        watcher.stop()
        // Establish that no writer can enter the rebuild group after wait begins.
        writer.sync {}
        buildGroup.wait()
        writer.sync { inboxLock.withLock { inbox.removeAll() }; setState(.stopped) }
    }
}
