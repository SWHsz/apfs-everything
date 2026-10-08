import CAPFSShim
import Darwin
import Foundation
import CoreServices

public enum IndexState: String, Sendable { case scanning, replaying, live, dirty, rebuilding, paused, stopped, failed }
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
    public let rawMissing: [String]
    public let rawExtra: [String]
    public let racedPaths: [String]
    public var isConsistent: Bool { missing.isEmpty && extra.isEmpty }
    public var rawSetsAgree: Bool { rawMissing.isEmpty && rawExtra.isEmpty }

    /// A large scan is not an atomic filesystem snapshot. Re-read only the
    /// differing directories and compare their current names with the index.
    /// Keep every original difference; unknown metadata never counts as a pass.
    static func revalidated(missing: [String], extra: [String],
                            exists: (String) -> Bool?, indexed: (String) -> Bool) -> Self {
        var confirmedMissing: [String] = [], confirmedExtra: [String] = [], races: [String] = []
        let originalMissing = Set(missing)
        for path in (missing + extra).sorted() {
            guard let present = exists(path) else {
                if originalMissing.contains(path) { confirmedMissing.append(path) }
                else { confirmedExtra.append(path) }
                continue
            }
            let online = indexed(path)
            if present == online { races.append(path) }
            else if present { confirmedMissing.append(path) }
            else { confirmedExtra.append(path) }
        }
        return .init(missing: confirmedMissing, extra: confirmedExtra,
                     rawMissing: missing, rawExtra: extra, racedPaths: races)
    }
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
    public let index: any NamespaceIndex
    public let metrics = Metrics()
    public let configuration: APFSFindConfiguration
    private var scanObserver: (@Sendable ([ScannedEntry], FileIndex) -> Void)?
    private var metadataEventHandler: (@Sendable ([FileSystemEvent]) -> Void)?
    private var baseInstaller: (@Sendable (FileIndex, UInt64, VolumeIdentity) throws -> Void)?
    private var compactionID: UUID?
    private var compactionEvents: [FileSystemEvent] = []
    private var compactionOverflow = false
    private let writer = DispatchQueue(label: "apfsfind.writer")
    private let builder = DispatchQueue(label: "apfsfind.rebuild", qos: .utility)
    private let buildGroup = DispatchGroup()
    private let watcher = FSEventsWatcher()
    private let streamControl = DispatchQueue(label: "apfsfind.stream-control", qos: .utility)
    private var pauseRequested = false // streamControl-confined
    private let replayStarter: (@Sendable (UInt64, @escaping @Sendable ([FileSystemEvent]) -> Void) throws -> Void)?
    private let cancellation = CancellationToken()
    private let maintenanceCancellation = CancellationToken()
    private let exitReconciliation = CancellationToken()
    private var exitBatchIncomplete = false // single writer
    private var activeQueries: [UUID:SearchCancellationToken] = [:]
    public func cancelQueries() {
        let tokens = stateLock.withLock { Array(activeQueries.values) }
        tokens.forEach { $0.cancel() }
    }
    public func cancelStartup() {
        requestFastExit(); cancellation.cancel()
    }
    public func requestFastExit() {
        maintenanceCancellation.cancel(); exitReconciliation.cancel()
    }
    private let debugEvents = ProcessInfo.processInfo.environment["APFSFIND_DEBUG_EVENTS"] == "1"
    private let stateLock = NSLock()
    private var state: IndexState = .scanning
    private var readiness: IndexReadiness = .opening
    private var baseAvailableValue = false
    private var baseAvailable: Bool {
        get { stateLock.withLock { baseAvailableValue } }
        set { stateLock.withLock { baseAvailableValue = newValue } }
    }
    private var startupBegan = ProcessInfo.processInfo.systemUptime
    private var replayFloor: UInt64 = 0
    private let observation = SnapshotObservation<IndexReadinessSnapshot>()
    private var mutationHandler: (@Sendable () -> Void)?
    public let maintenanceScheduler: MaintenanceScheduler
    private var historyDone = false
    private var errorDescription: String?
    private var recoveryReason: String?
    private var restoredGeneration: UInt64?
    private var initialReplayStarted: TimeInterval?
    private var replayResources: ProcessResourceSample?
    private var contentProbePath: String?
    private let inboxLock = NSLock()
    private var inbox: [FileSystemEvent] = []
    private var inboxOverflow = false
    private var inboxHistoryDone = false
    private var drainScheduled = false
    private var rootDevice: UInt64 = 0
    private var deferredReconcile: DeferredReconcileQueue
    private var deferredTimer: DispatchWorkItem?
    private var deliveredCursorHighWatermark: UInt64 = 0
    private var recoveryRetryCount = 0
    private var recoveryTimer: DispatchWorkItem?
    private let reconcileReader: (any DirectoryReading)?
    private var reconciler: DirectoryReconciler?
    private var rebuildScheduled = false
    private var building = false
    private var lastRebuildStart: TimeInterval = -.infinity
    private var failureCount = 0
    private var rebuildEvents: [FileSystemEvent] = []
    private var rebuildOverflow = false
    private var needsStreamRestart = false
    private var automaticRebuildSuspended = false
    private var volumeIdentity: VolumeIdentity?
    private var activeMaintenance: MaintenanceLease?
    public func maintenanceCheckpoint() throws { try stateLock.withLock { activeMaintenance }?.checkpoint() }
    private var lastProcessedEventID: UInt64 = 0 // Writer-confined, advanced only after mutations.
    private var persistenceEpoch: UInt64 = 0
    private var exitFrozen = false
    private let excludedRoots: [String]
    private var liveHandler: (@Sendable () -> Void)?
    private var recoveryHandler: (@Sendable (String) -> Void)?
    private let identityProvider: @Sendable (String) throws -> VolumeIdentity
    private let fenceProvider: @Sendable (VolumeIdentity) -> UInt64

    public init(root: String, configuration: APFSFindConfiguration = .init(),
                excludedRoots: [String] = [], index: (any NamespaceIndex)? = nil,
                identityProvider: @escaping @Sendable (String) throws -> VolumeIdentity = { try VolumeIdentity.discover(root: $0) },
                fenceProvider: @escaping @Sendable (VolumeIdentity) -> UInt64 = { $0.currentEventID() },
                maintenanceScheduler: MaintenanceScheduler = .shared,
                reconcileReader: (any DirectoryReading)? = nil,
                replayStarter: (@Sendable (UInt64, @escaping @Sendable ([FileSystemEvent]) -> Void) throws -> Void)? = nil) throws {
        self.root = try PathCanonicalizer.canonicalRoot(root)
        self.index = index ?? FileIndex(root: self.root)
        self.configuration = configuration
        self.excludedRoots = PathCanonicalizer.minimalRoots(excludedRoots + BulkScanner.maintenanceExclusions(root: self.root))
        self.identityProvider = identityProvider
        self.fenceProvider = fenceProvider
        self.maintenanceScheduler = maintenanceScheduler
        self.replayStarter = replayStarter
        self.reconcileReader = reconcileReader
        self.deferredReconcile = .init(capacity: configuration.deferredReconcileLimit)
    }
    public var queuedEventCount:Int { inboxLock.withLock { inbox.count } }
    public var currentState: IndexState { stateLock.withLock { state } }
    public var installedSnapshotGeneration: UInt64? { stateLock.withLock { restoredGeneration } }
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
        let transitioned = stateLock.withLock {
            let changed = state != value; state = value
            if let error { errorDescription = error }
            return changed
        }
        switch value {
        case .live: setReadiness(.live)
        case .paused: setReadiness(.paused)
        case .replaying: setReadiness(.catchingUp)
        case .dirty, .rebuilding: setReadiness(baseAvailable ? .rebuildingUsingOldBase : .scanning)
        case .failed: setReadiness(.failed)
        case .stopped: setReadiness(.stopped)
        case .scanning: setReadiness(.scanning)
        }
        if value == .live, transitioned {
            metrics.set("time_to_live_ms", to: Int((ProcessInfo.processInfo.systemUptime - startupBegan) * 1000))
            if let started = initialReplayStarted, metrics.snapshot()["initial_replay_ms"] == nil {
                metrics.set("initial_replay_ms", to: Int((ProcessInfo.processInfo.systemUptime - started) * 1000))
                if let replayResources { metrics.recordResources("startup_replay", since: replayResources) }
            }
            liveHandler?()
        }
    }

    public func markOpening() { startupBegan = ProcessInfo.processInfo.systemUptime; setReadiness(.opening) }
    public func readinessSnapshot(startupMode: StartupMode? = nil) -> IndexReadinessSnapshot {
        let status = startupStatus()
        let current = stateLock.withLock { readiness }
        let available = [.baseReady, .catchingUp, .live, .rebuildingUsingOldBase, .paused].contains(current) && baseAvailable
        return .init(state: current, searchAvailable: available, resultsMayBeStale: current != .live,
                     startupMode: startupMode, indexedEntries: available ? index.stats().liveEntries : status.scannerEntries,
                     replayReceived: status.receivedEvents, replayProcessed: status.processedEvents,
                     replayPending: status.pendingEvents, error: status.lastError)
    }
    public func readinessStream() -> AsyncStream<IndexReadinessSnapshot> { observation.stream(initial: readinessSnapshot()) }
    private func setReadiness(_ value: IndexReadiness) {
        stateLock.withLock { readiness = value }
        if value == .baseReady { metrics.set("search_ready_ms", to: Int((ProcessInfo.processInfo.systemUptime - startupBegan) * 1000)) }
        observation.send(readinessSnapshot())
    }
    public func setMutationHandler(_ handler: @escaping @Sendable () -> Void) { writer.sync { mutationHandler = handler } }
    public func search(_ request: SearchRequest) -> SearchResult {
        let queryID = UUID()
        stateLock.withLock { activeQueries[queryID] = request.cancellation }
        defer { _ = stateLock.withLock { activeQueries.removeValue(forKey:queryID) } }
        if exitReconciliation.isCancelled { request.cancellation.cancel() }
        let status = readinessSnapshot()
        guard status.searchAvailable else { return .init(hits: [], latencyMilliseconds: 0, generation: index.stats().generation, freshness: status.freshness, cancelled: request.cancellation.isCancelled) }
        let result = index.search(request)
        return .init(hits: result.hits, latencyMilliseconds: result.latencyMilliseconds, generation: result.generation,
                     freshness: status.freshness, cancelled: result.cancelled)
    }
    public func reconcileParent(of path: String) {
        guard PathCanonicalizer.isWithin(path, root: root) else { return }
        writer.async { [weak self] in
            guard let self, let reconciler = self.reconciler, !self.cancellation.isCancelled else { return }
            self.repairDirectories([PathCanonicalizer.parent(of: path)], into: self.index, using: reconciler, mayRebuild: true)
            self.mutationHandler?()
        }
    }
    public func setMetadataHandlers(scan: @escaping @Sendable ([ScannedEntry], FileIndex) -> Void,
                                    events: @escaping @Sendable ([FileSystemEvent]) -> Void) {
        writer.sync { scanObserver = scan; metadataEventHandler = events }
    }
    public func notifyMetadataChanged() { observation.send(readinessSnapshot()) }
    public func setBaseInstaller(_ handler: @escaping @Sendable (FileIndex, UInt64, VolumeIdentity) throws -> Void) {
        writer.sync { baseInstaller = handler }
    }
    public func setLifecycleHandlers(live: @escaping @Sendable () -> Void,
                                     recovery: @escaping @Sendable (String) -> Void) {
        writer.sync { liveHandler = live; recoveryHandler = recovery }
    }

    public func start(restored: (any NamespaceIndex)? = nil, cursor: UInt64? = nil,
                      streamStartCursor: UInt64? = nil, identity supplied: VolumeIdentity? = nil,
                      progress: (@Sendable (String) -> Void)? = nil) throws {
        guard !cancellation.isCancelled else { throw CocoaError(.userCancelled) }
        let identity = try supplied ?? identityProvider(root)
        let e0 = cursor ?? fenceProvider(identity)
        writer.sync { volumeIdentity = identity; deliveredCursorHighWatermark = e0; lastProcessedEventID = e0; replayFloor = e0; rootDevice = identity.deviceID }
        metrics.set("replay_floor_event_id", to: Int(clamping: e0))
        if let restored {
            index.installSnapshot(restored)
            let generation = index.stats().generation
            stateLock.withLock { restoredGeneration = generation }
            // Upgrade exclusion policy without changing v2 or scanning files.
            // Removing an existing excluded subtree is an ordinary RAM delta.
            index.apply(excludedRoots.map { .remove($0) })
            reconciler = DirectoryReconciler(scanner: reconcileReader ?? makeScanner(), index: index,
                rootDeviceID: rootDevice, metrics: metrics)
            baseAvailable = true; setReadiness(.baseReady)
            setState(.replaying)
            initialReplayStarted = ProcessInfo.processInfo.systemUptime
            replayResources = .capture()
            try startWatcher(since: streamStartCursor ?? e0)
            if cancellation.isCancelled { watcher.stop(); setState(.stopped) }
            return
        }
        while !cancellation.isCancelled {
        metrics.set("maintenance_queued", to: 1)
        setReadiness(.scanning)
        let lease = try maintenanceScheduler.acquireBlocking(volumeID: identity.volumeUUID, kind: .coldScan, priority: root == "/" ? 1 : 0, cancellation: maintenanceCancellation)
        lease.validateIdentity { [self] in guard try identityProvider(root) == identity else { throw SnapshotError.identity("source identity changed") } }
        stateLock.withLock { activeMaintenance = lease }
        defer { stateLock.withLock { activeMaintenance = nil }; lease.release() }
        metrics.set("maintenance_queued", to: 0)
        setReadiness(.scanning)
        // Capture before any directory enumeration: replay closes the initial scan gap.
        progress?("[info] Initial scan: \(root) (\(min(configuration.workerCount,lease.workerLimit)) workers)")
        let progressQueue = DispatchQueue(label: "apfsfind.scan-progress")
        let timer = DispatchSource.makeTimerSource(queue: progressQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self, metrics] in
            if let self { self.observation.send(self.readinessSnapshot()) }
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
            let scanner = makeScanner(lease:lease)
            metrics.record("full_scans")
            let scanResources = ProcessResourceSample.capture()
            let result = try scanner.scan(cancellation: cancellation)
            metrics.recordResources("initial_scan", since: scanResources)
            guard !cancellation.isCancelled, !result.cancelled else { setState(.stopped); return }
            metrics.set("initial_scan_ms", to: Int(result.elapsedMilliseconds))
            metrics.set("initial_index_building", to: 1)
            let buildStart = ProcessInfo.processInfo.systemUptime
            let initial = try makePrivateIndex(result.entries, counter: "initial_index_entries")
            metrics.set("initial_index_build_ms", to: Int((ProcessInfo.processInfo.systemUptime - buildStart) * 1000))
            metrics.set("initial_index_building", to: 0)
            guard !cancellation.isCancelled else { setState(.stopped); return }
            index.replace(with: initial)
            scanObserver?(result.scannedEntries,initial)
            try baseInstaller?(initial, e0, identity)
            rootDevice = result.rootDeviceID
            reconciler = DirectoryReconciler(scanner: reconcileReader ?? scanner, index: index, rootDeviceID: rootDevice, metrics: metrics)
            let s = index.stats()
            timer.cancel()
            progressQueue.sync {}
            progress?(String(format: "[info] Scan complete: %d files, %d directories, %d unreadable; scan %.1f ms, index %.1f ms; replay from %llu",
                s.files, s.directories, result.unreadableDirectories, result.elapsedMilliseconds,
                (ProcessInfo.processInfo.systemUptime - buildStart) * 1000, e0))
            baseAvailable = true; setReadiness(.baseReady)
            setState(.replaying)
            initialReplayStarted = ProcessInfo.processInfo.systemUptime
            replayResources = .capture()
            lease.release()
            try startWatcher(since: e0)
            if cancellation.isCancelled { watcher.stop(); setState(.stopped) }
            return
        } catch is MaintenanceYield {
            metrics.record("maintenance_yields"); continue
        } catch {
            setState(.failed, error: String(describing: error))
            throw error
        }
        }
    }

    private func makeScanner(lease: MaintenanceLease? = nil) -> BulkScanner {
        BulkScanner(root: root, workerCount: min(configuration.workerCount,lease?.workerLimit ?? configuration.workerCount), metrics: metrics, excludedRoots: excludedRoots, checkpoint: { try lease?.checkpoint() })
    }

    private func makePrivateIndex(_ entries: [NamespaceEntry], counter: String) throws -> FileIndex {
        let fresh = FileIndex(root: root)
        // Bounded chunks keep cancellation responsive during million-entry setup.
        // This private index is never visible to queries before the final swap.
        for offset in stride(from: 0, to: entries.count, by: 4096) {
            try maintenanceCheckpoint()
            guard !cancellation.isCancelled else { break }
            let end = min(entries.count, offset + 4096)
            fresh.apply(entries[offset..<end].map { .upsert($0) })
            metrics.set(counter, to: end)
        }
        return fresh
    }

    private func startWatcher(since id: UInt64) throws {
      try streamControl.sync {
        guard !cancellation.isCancelled else { throw CocoaError(.userCancelled) }
        guard !pauseRequested else { setState(.paused); return }
        if let replayStarter {
            try replayStarter(id, { [weak self] in self?.enqueue($0) }); return
        }
        try watcher.start(root: root, since: id, latencyMilliseconds: configuration.latencyMilliseconds,
                          identity: volumeIdentity) { [weak self] events in
            self?.enqueue(events)
        }
      }
    }
    /// Flush the service and delivery queue, then drain before fixing the memory fence.
    /// The immutable base and dirty overlay remain searchable; no persistence here.
    public func pause() {
        streamControl.sync {
            pauseRequested = true
            watcher.flush(); watcher.stop()
        }
        writer.sync { drain(); deferredTimer?.cancel(); deferredTimer = nil; metrics.set("deferred_reconcile_timer", to: 0); setState(.paused) }
        metrics.record("pause_requests")
    }
    public func resume(additionalCursor: UInt64? = nil) throws {
        let identity = try identityProvider(root)
        streamControl.sync { pauseRequested = false }
        let cursor: UInt64? = writer.sync {
            guard !cancellation.isCancelled else { return nil }
            guard baseAvailable else { setState(.scanning); return nil }
            if volumeIdentity != identity {
                requestRebuild(invalidated: true, reason: "resume_identity_changed"); return nil
            }
            if needsStreamRestart && !building && !rebuildScheduled {
                requestRebuild(invalidated: true, reason: "resume_pending_recovery"); return nil
            }
            if building || rebuildScheduled { setState(.dirty); return nil }
            stateLock.withLock { historyDone = false }
            replayFloor = lastProcessedEventID
            setState(.replaying)
            return additionalCursor.map { min(lastProcessedEventID,$0) } ?? lastProcessedEventID
        }
        if let cursor { try startWatcher(since: cursor); metrics.record("resume_replays"); writer.async { [weak self] in self?.scheduleDeferredReconcile() } }
    }
    /// The callback copies only event information and queues it. No filesystem I/O.
    public func enqueue(_ events: [FileSystemEvent]) {
        guard !cancellation.isCancelled else { return }
        let events = events.filter { event in
            event.flags & UInt32(kFSEventStreamEventFlagHistoryDone | kFSEventStreamEventFlagKernelDropped |
                kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged) != 0 ||
            !excludedRoots.contains { PathCanonicalizer.isWithin(event.path, root: $0) }
        }
        metrics.record("fsevents_received", by: events.count)
        let schedule = inboxLock.withLock {
            let room = max(0, configuration.maxPendingEvents - inbox.count)
            if events.count > room { inboxOverflow = true }
            let retained = events.prefix(room)
            inbox.append(contentsOf: retained)
            metrics.record("inbox_estimated_bytes",by:Self.estimatedEventBytes(retained))
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
        guard !exitFrozen else { return }
        let (events, overflow, finished) = inboxLock.withLock {
            let result = (inbox, inboxOverflow, inboxHistoryDone)
            inbox = []; inboxOverflow = false; inboxHistoryDone = false; drainScheduled = false
            metrics.set("inbox_estimated_bytes",to:0)
            return result
        }
        guard !cancellation.isCancelled else { return }
        if compactionID != nil {
            let room = max(0, configuration.maxPendingEvents - compactionEvents.count)
            compactionEvents.append(contentsOf: events.prefix(room))
            metrics.record("compaction_buffer_estimated_bytes",by:Self.estimatedEventBytes(events.prefix(room)))
            if events.count > room || overflow { compactionOverflow = true }
            metrics.maximum("compaction_buffered_events", compactionEvents.count)
        }
        if !events.isEmpty { metrics.set("last_batch_size", to: events.count) }
        metrics.set("active_batch_size", to: events.count)
        defer {
            metrics.record("fsevents_processed", by: events.count)
            metrics.set("active_batch_size", to: 0)
            observation.send(readinessSnapshot())
        }
        if finished { stateLock.withLock { historyDone = true } }
        if let id = events.map(\.id).filter({ $0 != UInt64.max }).max() {
            deliveredCursorHighWatermark = max(deliveredCursorHighWatermark, id)
        }
        if building {
            let room = max(0, configuration.maxPendingEvents - rebuildEvents.count)
            rebuildEvents.append(contentsOf: events.prefix(room))
            metrics.record("rebuild_buffer_estimated_bytes",by:Self.estimatedEventBytes(events.prefix(room)))
            if events.count > room || overflow { rebuildOverflow = true }
        }
        if building || rebuildScheduled {
            // The pre-scan fence and bounded rebuild buffer cover these events.
            // Reconciling the obsolete base competes with the recovery scan and
            // can repeatedly request the same recovery. Keep its cursor pinned;
            // a replay from the new fence closes the scheduled/scan interval.
            metrics.record("namespace_events_deferred_during_recovery", by: events.count)
            if overflow { metrics.record("queue_overflows") }
            metadataEventHandler?(events + (overflow ? [.init(path:root,flags:UInt32(kFSEventStreamEventFlagUserDropped))] : []))
            return
        }
        if overflow {
            metrics.record("queue_overflows")
            requestRebuild(invalidated: true, reason: "queue_overflow")
            // This truncated batch cannot establish a correct cursor. The fresh
            // scan/replay covers it; walking its old scopes delays recovery.
            metrics.record("namespace_events_deferred_during_recovery",by:events.count)
            metadataEventHandler?([.init(path:root,flags:UInt32(kFSEventStreamEventFlagUserDropped))])
            return
        }
        let before = index.stats().generation
        let replaying = currentState == .replaying
        let filtered = events.filter { event in
            guard replaying else { return true }
            metrics.record("replay_events_received")
            let classification = EventClassifier.classify(event)
            let ordinary: Bool
            switch classification { case .simpleCreate, .simpleRemove, .contentOnly: ordinary = true
            case .ambiguous:
                let renameOnly = UInt32(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemIsSymlink)
                ordinary = event.flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 && event.flags & ~renameOnly == 0
            default: ordinary = false }
            if ordinary, event.id > 0, event.id != UInt64.max, event.id <= replayFloor {
                metrics.record("replay_overlap_events_skipped"); return false
            }
            metrics.record(ordinary ? "replay_events_applied" : "replay_special_events_applied")
            return true
        }
        let counters = metrics.snapshot()
        if let reconciler { process(filtered, into: index, using: reconciler, countMetrics: true, mayRebuild: true) }
        if replaying {
            let after = metrics.snapshot()
            for (target, source) in [("replay_metadata_lookups", "namespace_metadata_lookups"), ("replay_directory_reconciles", "directory_reconciles"), ("replay_subtree_reconciles", "subtree_reconciles")] {
                metrics.record(target, by: after[source, default: 0] - counters[source, default: 0])
            }
        }
        metadataEventHandler?(events + (overflow ? [.init(path:root,flags:UInt32(kFSEventStreamEventFlagUserDropped))] : []))
        if before != index.stats().generation { mutationHandler?() }
        // Include content-only IDs, but never advance a durable cursor ahead of
        // the namespace mutations corresponding to this batch.
        if deferredReconcile.count == 0, !exitBatchIncomplete, currentState != .dirty && currentState != .rebuilding, let completedID = events.lazy.map(\.id).filter({ $0 != UInt64.max }).max() {
            lastProcessedEventID = max(lastProcessedEventID, completedID)
        }
        if deferredReconcile.count == 0, stateLock.withLock({ historyDone }), currentState == .replaying,
           inboxLock.withLock({ !inboxOverflow }) {
            // HistoryDone is ordered after historical callbacks. Events queued
            // after this completed batch are live traffic; requiring an empty
            // inbox can leave an active system permanently "catching up".
            setState(.live)
        }
    }

    /// FileEvents/FullHistory can repeat Created even when the durable base
    /// already contains it. Validate metadata before excluding it from storms;
    /// neither the event's hint nor basename/type equality is authoritative.
    private func isAuthoritativeDuplicateCreate(_ path:String, kind:EntryKind, in target:any NamespaceIndex)->Bool {
        guard let existing=target.entry(at:path),existing.kind==kind else{return false}
        metrics.record("namespace_metadata_lookups")
        if path==root,kind == .directory,let identity=volumeIdentity {
            var info=APFSDirectoryInfo()
            return apfs_directory_info(path,rootDevice,1,&info)==0 && info.file_id==identity.rootFileID
        }
        var info=APFSDirectoryEntry()
        guard apfs_entry_info(path,rootDevice,&info)==0 else{return false}
        let actualKind:EntryKind = info.object_type==1 ? .file:info.object_type==2 ? .directory:info.object_type==3 ? .symlink:.other
        return existing == NamespaceEntry(path:path,kind:actualKind,deviceID:info.device_id,fileID:info.file_id,isMountPoint:info.is_mount_point != 0)
    }
    private func authoritativePatch(_ path:String, into patches:inout [IndexMutation], dirty:(String)->Void) {
        metrics.record("namespace_metadata_lookups")
        var info=APFSDirectoryEntry()
        if apfs_entry_info(path,rootDevice,&info)==0 {
            let kind:EntryKind = info.object_type==1 ? .file : info.object_type==2 ? .directory : info.object_type==3 ? .symlink : .other
            if kind == .directory {dirty(PathCanonicalizer.parent(of:path));return}
            patches.append(.upsert(.init(path:path,kind:kind,deviceID:info.device_id,fileID:info.file_id,isMountPoint:info.is_mount_point != 0)))
        } else if errno == ENOENT {patches.append(.remove(path))}
        else {dirty(PathCanonicalizer.parent(of:path))}
    }
    private func nearestIndexedParent(_ path: String, in target: any NamespaceIndex) -> String {
        if path == root { return root }
        var parent = PathCanonicalizer.parent(of: path)
        while parent != root && target.entry(at: parent)?.kind != .directory {
            guard PathCanonicalizer.isWithin(parent, root: root), parent != "/" else { return root }
            parent = PathCanonicalizer.parent(of: parent)
        }
        return parent
    }

    internal func process(_ events: [FileSystemEvent], into target: any NamespaceIndex, using reconciler: DirectoryReconciler,
                         countMetrics: Bool, mayRebuild: Bool) {
        let resources=ProcessResourceSample.capture()
        defer {metrics.recordResources("namespace_event_processing",since:resources)}
        var namespace: [(FileSystemEvent, EventClassification)] = []
        for event in events {
            let classification = EventClassifier.classify(event)
            let contentFlags = UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemInodeMetaMod |
                kFSEventStreamEventFlagItemXattrMod | kFSEventStreamEventFlagItemFinderInfoMod | kFSEventStreamEventFlagItemChangeOwner)
            if countMetrics, let contentProbePath, event.path == contentProbePath, event.flags & contentFlags != 0 {
                metrics.record("content_probe_events")
            }
            if debugEvents && countMetrics {
                FileHandle.standardError.write(Data("[debug] flags=0x\(String(event.flags, radix: 16)) \(classification) \(event.path)\n".utf8))
            }
            switch classification {
            case .historyDone: continue
            case .contentOnly:
                if countMetrics { metrics.record("ignored_content_events") }
            case .invalidated:
                if countMetrics { metrics.record("dropped_invalidated_events") }
                if mayRebuild { requestRebuild(invalidated: true, reason: "stream_invalidated"); return }
            case .simpleCreate(let kind):
                if target is HybridIndex, let path=PathCanonicalizer.normalize(event.path),
                   isAuthoritativeDuplicateCreate(path, kind:kind, in:target) {
                    if countMetrics {
                        metrics.record("duplicate_create_events")
                        let content=UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemXattrMod | kFSEventStreamEventFlagItemFinderInfoMod | kFSEventStreamEventFlagItemChangeOwner)
                        if event.flags & content != 0 {metrics.record("ignored_content_events")}
                    }
                    continue
                }
                // Remove harmless overlapping history before storm accounting.
                // FullHistory can repeat an entire chunk on warm startup.
                if !(target is HybridIndex), let path = PathCanonicalizer.normalize(event.path),
                   let existing = target.entry(at: path), existing.kind == kind,
                   kind != .directory || path == root {
                    if countMetrics {
                        metrics.record("duplicate_create_events")
                        let content = UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemInodeMetaMod |
                            kFSEventStreamEventFlagItemXattrMod | kFSEventStreamEventFlagItemFinderInfoMod | kFSEventStreamEventFlagItemChangeOwner)
                        if event.flags & content != 0 { metrics.record("ignored_content_events") }
                    }
                } else { namespace.append((event, classification)) }
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
                mark(root, subtree: true)
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
                if !(target is HybridIndex), let existing = target.entry(at: path), existing.kind == kind,
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
                    if target is HybridIndex { authoritativePatch(path, into: &direct, dirty: { mark($0) }) }
                    else { direct.append(.upsert(NamespaceEntry(path: path, kind: kind, deviceID: rootDevice))) }
                } else { mark(parent) }
            case .simpleRemove:
                if path == root { if mayRebuild { requestRebuild(invalidated: true, reason: "root_removed") } }
                else if target is HybridIndex { authoritativePatch(path, into: &direct, dirty: { mark($0) }) }
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
        // Include duplicate creates discarded above: create+remove for one path
        // still needs an authoritative diff, independent of arrival order.
        for event in events {
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
        let roots = PathCanonicalizer.minimalRoots(Array(dirty.keys))
        // Soft dirty-parent pressure changes scheduling, not index validity.
        // Only the bounded deferred queue's hard overflow requests recovery.
        if countMetrics { metrics.record("dirty_directories", by: roots.count); metrics.set("active_dirty_directories",to:roots.count) }
        defer { if countMetrics { metrics.set("active_dirty_directories",to:0) } }
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
        let rootSet = Set(roots)
        var absorbedRoots = Set<String>(), nestedPatchRoots = Set<String>()
        func coveringRoot(_ path: String) -> String? {
            var parent = PathCanonicalizer.parent(of: path)
            while PathCanonicalizer.isWithin(parent, root: root) {
                if rootSet.contains(parent) { return parent }
                if parent == root || parent == "/" { break }
                parent = PathCanonicalizer.parent(of: parent)
            }
            return nil
        }
        for path in dirty.keys where !rootSet.contains(path) {
            if let ancestor = coveringRoot(path) { absorbedRoots.insert(ancestor) }
        }
        for patch in direct {
            let path = mutationPath(patch)
            if let ancestor = coveringRoot(path), PathCanonicalizer.parent(of: path) != ancestor {
                nestedPatchRoots.insert(ancestor)
            }
        }
        let sliceStart = ProcessInfo.processInfo.systemUptime
        var attempted = 0
        for directory in roots {
            let absorbed = absorbedRoots.contains(directory)
            let nestedPatch = nestedPatchRoots.contains(directory)
            let options = dirty[directory] ?? (true, true)
            let subtree = options.subtree || absorbed || nestedPatch
            if mayRebuild && (attempted >= 32 || ProcessInfo.processInfo.systemUptime-sliceStart >= 0.02) {
                deferReconcile(.init(root: directory, reason: .event, minimumCursor: lastProcessedEventID,
                    generation: target.stats().generation, subtree: subtree)); continue
            }
            attempted += 1
            let plan = reconciler.prepare(directory, subtree: subtree, force: true,
                cancellation: exitReconciliation, directoryLimit: mayRebuild ? 32 : nil)
            if plan.cancelled { exitBatchIncomplete = true; continue }
            if case .invalidated = plan.result, mayRebuild {
                requestRebuild(invalidated: true, reason: "reconcile_hard_limit")
                metrics.record("reconcile_deferred_to_rebuild"); return
            }
            if case .locallyFailed = plan.result, mayRebuild {
                var work = DeferredReconcileWork(root: directory, reason: .retry, minimumCursor: lastProcessedEventID,
                    generation: target.stats().generation, subtree: subtree)
                work.retryCount = 1; work.nextAttempt = ProcessInfo.processInfo.systemUptime + 0.05
                deferReconcile(work); continue
            }
            mutations += plan.mutations
            retryParents.formUnion(plan.retryParents)
            if !plan.frontier.isEmpty, mayRebuild {
                deferReconcile(.init(root: directory, reason: .event, minimumCursor: lastProcessedEventID,
                    generation: target.stats().generation, subtree: subtree, frontier: plan.frontier))
            }
        }
        target.apply(mutations)
        if mayRebuild, (target as? HybridIndex)?.requiresRecovery == true { requestRebuild(invalidated:true,reason:"overlay_safety_limit") } // One short write lock for the entire event microbatch.
        // A vanished directory cannot be treated as an empty successful read.
        // Its surviving parent determines removal/type replacement authoritatively.
        repairDirectories(Array(retryParents), into: target, using: reconciler, mayRebuild: mayRebuild)
        if countMetrics { metrics.record("direct_patches", by: patches.count) }
    }

    @discardableResult private func repairDirectories(_ paths: [String], into target: any NamespaceIndex,
                                   using reconciler: DirectoryReconciler, mayRebuild: Bool) -> ReconcileResult {
        var pending = PathCanonicalizer.minimalRoots(paths)
        var seen = Set<String>()
        while !pending.isEmpty, !cancellation.isCancelled {
            var parents = Set<String>()
            for directory in pending where seen.insert(directory).inserted {
                let plan = reconciler.prepare(directory, force: true, cancellation: exitReconciliation,
                    directoryLimit: mayRebuild ? 32 : nil)
                if plan.cancelled { exitBatchIncomplete = true; return .deferred([.init(path: directory)]) }
                switch plan.result {
                case .invalidated(let reason):
                    if mayRebuild { requestRebuild(invalidated: true, reason: "reconcile_hard_limit") }
                    return .invalidated(reason)
                case .locallyFailed(let failures):
                    if mayRebuild {
                        var work = DeferredReconcileWork(root: directory, reason: .parentRepair,
                            minimumCursor: lastProcessedEventID, generation: target.stats().generation)
                        work.retryCount = 1; work.nextAttempt = ProcessInfo.processInfo.systemUptime + 0.05
                        deferReconcile(work)
                    }
                    metrics.record("reconcile_local_io_failures", by: failures.count)
                case .deferred(let frontier):
                    target.apply(plan.mutations)
                    if mayRebuild { deferReconcile(.init(root: directory, reason: .parentRepair,
                        minimumCursor: lastProcessedEventID, generation: target.stats().generation, frontier: frontier)) }
                case .completed: target.apply(plan.mutations)
                }
                parents.formUnion(plan.retryParents)
            }
            pending = PathCanonicalizer.minimalRoots(Array(parents)).filter { !seen.contains($0) }
        }
        return deferredReconcile.count == 0 ? .completed : .deferred([])
    }

    private func updateDeferredMetrics() {
        metrics.set("deferred_reconcile_roots", to: deferredReconcile.count)
        metrics.set("deferred_reconcile_frontier", to: deferredReconcile.frontierCount)
        metrics.set("deferred_reconcile_bytes", to: deferredReconcile.estimatedBytes)
        metrics.maximum("deferred_reconcile_high_watermark", deferredReconcile.count)
    }
    private func deferReconcile(_ work: DeferredReconcileWork) {
        guard !exitReconciliation.isCancelled else { exitBatchIncomplete = true; return }
        guard deferredReconcile.insert(work) else {
            metrics.record("deferred_reconcile_overflows")
            requestRebuild(invalidated: true, reason: "reconcile_queue_overflow"); return
        }
        updateDeferredMetrics()
        if currentState == .live { setState(.replaying) }
        scheduleDeferredReconcile()
    }
    private func scheduleDeferredReconcile() {
        guard deferredTimer == nil, reconciler != nil, deferredReconcile.count > 0,
            !exitFrozen, !exitReconciliation.isCancelled, !building, !rebuildScheduled,
            currentState != .paused else { return }
        let delay = max(0.005, (deferredReconcile.nextAttempt ?? 0)-ProcessInfo.processInfo.systemUptime)
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.deferredTimer = nil; self.metrics.set("deferred_reconcile_timer", to: 0)
            self.drainDeferredReconcile()
        }
        deferredTimer = item; metrics.set("deferred_reconcile_timer", to: 1)
        writer.asyncAfter(deadline: .now()+delay, execute: item)
    }
    private func drainDeferredReconcile() {
        guard !exitFrozen, !exitReconciliation.isCancelled, !building, !rebuildScheduled,
            currentState != .paused, let reconciler else { return }
        let before = index.stats().generation, started = ProcessInfo.processInfo.systemUptime
        var batch: [(DeferredReconcileWork, ReconciliationPlan)] = []
        var mutations: [IndexMutation] = [], directories = 0
        // Queue roots are disjoint. Prepare their authoritative diffs together,
        // then publish one batch: query captures copy the bitmap/overlay once,
        // and a burst does not pay a one-shot timer for every tiny parent.
        while batch.count < 32 && directories < 32,
              batch.isEmpty || ProcessInfo.processInfo.systemUptime-started < 0.02,
              let work = deferredReconcile.popReady(now: ProcessInfo.processInfo.systemUptime) {
            let plan = reconciler.prepare(work.root, subtree: work.subtree, force: true,
                cancellation: exitReconciliation, frontier: work.frontier, directoryLimit: max(1,32-directories))
            if plan.cancelled {
                exitBatchIncomplete = true
                for old in batch.map({$0.0}) + [work] { _ = deferredReconcile.insert(old) }
                updateDeferredMetrics(); return
            }
            if case .invalidated = plan.result {
                requestRebuild(invalidated: true, reason: "reconcile_hard_limit"); return
            }
            if case .locallyFailed = plan.result {
                // Prefix diffs from an unexpectedly failed scope stay private.
            } else {
                // Bound aggregate retained mutations in addition to the atomic
                // per-parent cap. Roots remain disjoint across these flushes.
                if mutations.count + plan.mutations.count > 4096 {
                    index.apply(mutations); mutations.removeAll(keepingCapacity:false)
                    if (index as? HybridIndex)?.requiresRecovery == true {
                        requestRebuild(invalidated:true,reason:"overlay_safety_limit"); return
                    }
                }
                mutations += plan.mutations
            }
            directories += max(1,plan.completedDirectories.count)
            batch.append((work,plan))
        }
        index.apply(mutations)
        if (index as? HybridIndex)?.requiresRecovery == true {
            requestRebuild(invalidated:true,reason:"overlay_safety_limit"); return
        }
        for (original,plan) in batch {
            var work = original
            switch plan.result {
            case .invalidated: break // Handled before publication above.
            case .locallyFailed:
                work.retryCount += 1
                if work.retryCount >= 3 {
                    requestRebuild(invalidated: true, reason: "reconcile_repeated_io"); return
                }
                work.nextAttempt = ProcessInfo.processInfo.systemUptime + min(1,0.05 * pow(2,Double(work.retryCount)))
                deferReconcile(work)
                if rebuildScheduled || building { return }
            case .deferred(let frontier):
                work.frontier = frontier; work.nextAttempt = ProcessInfo.processInfo.systemUptime + 0.005
                metrics.record("deferred_reconcile_yields"); deferReconcile(work)
                if rebuildScheduled || building { return }
            case .completed: metrics.record("deferred_reconcile_completed")
            }
            for parent in plan.retryParents {
                deferReconcile(.init(root:parent,reason:.parentRepair,minimumCursor:work.minimumCursor,
                    generation:index.stats().generation))
                if rebuildScheduled || building { return }
            }
            // Metadata may have handled the original event before namespace
            // discovery. ID 0 hints bypass overlap without inventing a cursor.
            metadataEventHandler?(plan.completedDirectories.map {
                .init(path:$0,flags:UInt32(kFSEventStreamEventFlagItemXattrMod),id:0)
            })
        }
        updateDeferredMetrics()
        if before != index.stats().generation { mutationHandler?() }
        if deferredReconcile.count == 0 {
            if !exitBatchIncomplete { lastProcessedEventID = max(lastProcessedEventID,deliveredCursorHighWatermark) }
            if stateLock.withLock({historyDone}) { setState(.live) }
        } else { scheduleDeferredReconcile() }
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
        guard !maintenanceCancellation.isCancelled, !cancellation.isCancelled else { return }
        guard !building, !rebuildScheduled else { metrics.record("rebuild_requests_coalesced"); return }
        deferredTimer?.cancel(); deferredTimer = nil; deferredReconcile.removeAll()
        metrics.set("deferred_reconcile_timer", to: 0); updateDeferredMetrics()
        metrics.record("rebuild_requests_" + reason)
        stateLock.withLock { recoveryReason = reason }
        persistenceEpoch &+= 1
        recoveryHandler?(reason)
        // Every full rebuild establishes a new pre-scan fence and replays it.
        needsStreamRestart = true
        if !building { setState(.dirty) }
        guard !automaticRebuildSuspended else { return }
        guard !building, !rebuildScheduled else { return }
        rebuildScheduled = true
        let backoff = failureCount == 0 ? 0 : min(300, pow(2, Double(min(failureCount, 8))))
        let remaining = max(0, configuration.fullRebuildMinInterval - (Date.timeIntervalSinceReferenceDate - lastRebuildStart))
        let delay = max(configuration.rebuildDebounceMilliseconds / 1000, remaining, backoff)
        let item = DispatchWorkItem { [weak self] in self?.recoveryTimer = nil; self?.beginRebuild() }
        recoveryTimer = item; writer.asyncAfter(deadline: .now() + delay, execute: item)
    }
    private func beginRebuild() {
        rebuildScheduled = false
        guard !building, !cancellation.isCancelled, !maintenanceCancellation.isCancelled else { return }
        guard currentState != .paused else { needsStreamRestart = true; return }
        building = true; rebuildEvents = []; rebuildOverflow = false
        metrics.set("rebuild_buffer_estimated_bytes",to:0)
        lastRebuildStart = Date.timeIntervalSinceReferenceDate
        setState(.rebuilding)
        buildGroup.enter()
        builder.async { [weak self] in
            guard let self else { return }
            let result = Result {
                let identity = try self.identityProvider(self.root)
                let lease = try self.maintenanceScheduler.acquireBlocking(volumeID: identity.volumeUUID, kind: .rebuild, urgency:(self.index as? HybridIndex)?.requiresRecovery == true ? .emergency : .required, cancellation: self.maintenanceCancellation)
                lease.validateIdentity { guard try self.identityProvider(self.root) == identity else { throw SnapshotError.identity("source identity changed") } }
                self.stateLock.withLock { self.activeMaintenance = lease }
                var transferred = false
                defer { if !transferred { self.stateLock.withLock { self.activeMaintenance = nil }; lease.release() } }
                let e0 = self.fenceProvider(identity)
                self.metrics.record("full_scans")
                let scan = try self.makeScanner(lease:lease).scan(cancellation: self.cancellation)
                self.metrics.set("rebuild_index_entries", to: 0)
                let fresh = try self.makePrivateIndex(scan.entries, counter: "rebuild_index_entries")
                guard try self.identityProvider(self.root)==identity else{throw SnapshotError.identity("root changed during recovery scan")}
                guard !self.cancellation.isCancelled else { throw SnapshotError.cancelled }
                self.scanObserver?(scan.scannedEntries,fresh)
                transferred = true
                return PreparedIndex(index: fresh, rootDeviceID: scan.rootDeviceID, cancelled: scan.cancelled,
                    identity: identity, fence: e0, lease:lease)
            }
            self.writer.async { [weak self] in self?.completeRebuild(result) }
            self.buildGroup.leave()
        }
    }
    private struct PreparedIndex: Sendable {
        let index: FileIndex
        let rootDeviceID: UInt64
        let cancelled: Bool
        let identity: VolumeIdentity
        let fence: UInt64
        let lease: MaintenanceLease
    }
    private func completeRebuild(_ result: Result<PreparedIndex, Error>) {
        building = false
        defer {
            stateLock.withLock { activeMaintenance = nil }
            if case .success(let scan) = result { scan.lease.release() }
        }
        guard !cancellation.isCancelled else { return }
        do {
            let scan = try result.get()
            guard !scan.cancelled else { return }
            let fresh = scan.index
            rootDevice = scan.rootDeviceID
            let scanner = makeScanner()
            let freshReconciler = DirectoryReconciler(scanner: scanner, index: fresh, rootDeviceID: rootDevice, metrics: metrics)
            let restart = needsStreamRestart
            // A fresh stream replays every change since the pre-scan fence.
            // Applying historical buffered hints to a newer scan can resurrect
            // already vanished paths and needlessly re-walk large old scopes.
            if !restart {
                process(rebuildEvents, into: fresh, using: freshReconciler, countMetrics: false, mayRebuild: false)
            }
            if restart, let baseInstaller {
                // Publish the validated scan under its existing maintenance
                // lease before replay. Large recovery graphs must not become
                // the searchable warm runtime while HistoryDone is pending.
                try baseInstaller(fresh,scan.fence,scan.identity)
            } else { index.replace(with: fresh) }
            reconciler = DirectoryReconciler(scanner: reconcileReader ?? scanner, index: index, rootDeviceID: rootDevice, metrics: metrics)
            rebuildEvents = []
            metrics.set("rebuild_buffer_estimated_bytes",to:0)
            metrics.record("full_rebuilds")
            needsStreamRestart = false
            if restart {
                watcher.stop()
                inboxLock.withLock {
                    inbox = []; inboxHistoryDone = false; inboxOverflow = false; drainScheduled = false
                    metrics.set("inbox_estimated_bytes",to:0)
                }
                stateLock.withLock { historyDone = false }
                volumeIdentity = scan.identity
                lastProcessedEventID = scan.fence
                deliveredCursorHighWatermark = scan.fence
                replayFloor = scan.fence
                setState(.replaying)
                try startWatcher(since: scan.fence)
            } else { setState(stateLock.withLock { historyDone } ? .live : .replaying) }
            failureCount = 0; recoveryRetryCount = 0
            stateLock.withLock { errorDescription = nil; recoveryReason = nil }
            if rebuildOverflow && !restart { requestRebuild(invalidated: true, reason: "rebuild_buffer_overflow") }
            writer.async { [weak self] in self?.metrics.record("rebuild_allocator_released_bytes",by:Int(apfs_release_allocator_pages())) }
        } catch is MaintenanceYield {
            metrics.record("maintenance_yields"); metrics.record("recovery_epoch_yields")
            setState(.dirty)
            // Keep this recovery epoch/fence invalidation, not a new request.
            recoveryRetryCount += 1; rebuildScheduled = true
            let delay = min(30, 0.1 * pow(2, Double(min(recoveryRetryCount, 8))))
            let item = DispatchWorkItem { [weak self] in self?.recoveryTimer = nil; self?.beginRebuild() }
            recoveryTimer = item; writer.asyncAfter(deadline: .now()+delay, execute: item)
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
        let identity = try identityProvider(root)
        let lease = try maintenanceScheduler.acquireBlocking(volumeID:identity.volumeUUID,kind:.rebuild,urgency:.required,cancellation:maintenanceCancellation)
        defer { lease.release() }
        let scanner = makeScanner(lease:lease)
        let scan = try scanner.scan(cancellation: cancellation)
        guard !scan.cancelled else { throw CocoaError(.userCancelled) }
        guard flushEvents(timeout: 120) else { throw SnapshotError.invalid("verification event flush timed out") }
        let actual = Set(scan.entries.map(\.path)).union([root])
        let online = index.snapshotPaths()
        let missing = actual.subtracting(online).sorted(), extra = online.subtracting(actual).sorted()
        // A mass discrepancy stays a hard failure; do not turn verification
        // into millions of metadata probes or silently hide unreadable paths.
        guard missing.count + extra.count <= 10_000 else {
            return .init(missing: missing, extra: extra, rawMissing: missing, rawExtra: extra, racedPaths: [])
        }
        var refreshed: [String: Set<String>] = [:], unknown = Set<String>()
        return .revalidated(missing: missing, extra: extra, exists: { path in
            if path == root { return true }
            let parent = PathCanonicalizer.parent(of: path)
            if unknown.contains(parent) { return nil }
            if refreshed[parent] == nil {
                do {
                    refreshed[parent] = Set(try scanner.readDirectory(parent, rootDeviceID: scan.rootDeviceID,
                                                                     cancellation: cancellation).map(\.path))
                } catch let error as ScannerError where [ENOENT, ENOTDIR, ELOOP, EXDEV].contains(error.code) {
                    refreshed[parent] = []
                } catch { unknown.insert(parent); return nil }
            }
            return refreshed[parent]!.contains(path)
        }, indexed: { index.entry(at: $0) != nil })
    }

    public func synchronizeWriter() { writer.sync {} }
    private static func estimatedEventBytes(_ events:ArraySlice<FileSystemEvent>) -> Int {
        events.reduce(0) { $0 + MemoryLayout<FileSystemEvent>.stride + $1.path.utf8.count }
    }
    /// On-demand estimates, not allocation ledgers. Core retains no query cache.
    public func eventBufferEstimates() -> [String:Int] {
        let counters = metrics.snapshot()
        return ["pending_event_estimated_bytes":counters["inbox_estimated_bytes",default:0]+counters["rebuild_buffer_estimated_bytes",default:0]+counters["compaction_buffer_estimated_bytes",default:0],"core_query_cache_bytes":0]
    }
    /// Opt-in benchmark counter for one owned fixture; no paths are logged.
    public func measureContentEvents(at path: String?) {
        writer.sync {
            contentProbePath = path.flatMap { PathCanonicalizer.isWithin($0, root: root) ? PathCanonicalizer.normalize($0) : nil }
        }
    }

    public func stats() -> CoordinatorStats {
        let s = index.stats(), usage = Metrics.processUsage()
        var values: [String: Any] = metrics.snapshot()
        values["excluded_roots"] = excludedRoots
        for key in ["fsevents_received", "fsevents_processed", "ignored_content_events", "direct_patches", "directory_reconciles",
                    "subtree_reconciles", "full_rebuilds", "full_scans", "dropped_invalidated_events", "event_queue_high_watermark", "last_batch_size"] {
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
        values["last_processed_event_id"] = writer.sync { lastProcessedEventID }
        return CoordinatorStats(dictionary: values)
    }

    public func captureCheckpoint() throws -> CheckpointCapture {
        try writer.sync {
            guard currentState == .live, deferredReconcile.count == 0, !building, !rebuildScheduled, let volumeIdentity else {
                throw SnapshotError.invalid("checkpoint requires a live, recovered index")
            }
            return .init(metadata: index.captureSnapshotMetadata(), cursor: lastProcessedEventID,
                         identity: volumeIdentity, epoch: persistenceEpoch)
        }
    }
    public func validateCheckpoint(_ capture: CheckpointCapture) throws {
        try writer.sync {
            guard currentState == .live, persistenceEpoch == capture.epoch,
                  volumeIdentity == capture.identity,
                  index.captureSnapshotMetadata().generation == capture.metadata.generation else {
                throw SnapshotError.generationChanged
            }
        }
    }
    public func installRecoveredBase(_ capture:CheckpointCapture,base:MMapBaseIndex,map:[String:EntryRef],publish:()throws->Void) throws {
        try writer.sync {
            guard currentState == .live,persistenceEpoch==capture.epoch,volumeIdentity==capture.identity,
                  try identityProvider(root)==capture.identity,
                  index.stats().generation==capture.metadata.generation,let h=index as? HybridIndex else{throw SnapshotError.generationChanged}
            try publish();h.install(base:base,directoryMap:map)
        }
    }
    public func beginCompaction() throws -> CompactionTicket {
        try writer.sync {
            guard currentState == .live, deferredReconcile.count == 0, !building, !rebuildScheduled, compactionID == nil,
                  let volumeIdentity, let hybrid = index as? HybridIndex, let snapshot = hybrid.capture() else {
                throw SnapshotError.busy
            }
            let id = UUID(); compactionID = id; compactionEvents = []; compactionOverflow = false
            metrics.set("compaction_buffer_estimated_bytes",to:0)
            metrics.set("compaction_buffered_events", to: 0)
            metrics.set("compaction_replayed_events", to: 0)
            return .init(id:id, snapshot:snapshot, checkpoint:.init(metadata:index.captureSnapshotMetadata(),
                cursor:lastProcessedEventID, identity:volumeIdentity, epoch:persistenceEpoch))
        }
    }
    public func abortCompaction(_ ticket:CompactionTicket) {
        writer.sync { if compactionID == ticket.id { compactionID=nil; compactionEvents=[]; compactionOverflow=false; metrics.set("compaction_buffer_estimated_bytes",to:0) } }
    }
    public func finishCompaction(_ ticket:CompactionTicket, base:MMapBaseIndex, directories:[String:EntryRef],
                                 publish:()throws->Void) throws {
        try writer.sync {
            guard compactionID == ticket.id, !compactionOverflow, !cancellation.isCancelled,
                  currentState == .live, persistenceEpoch == ticket.checkpoint.epoch,
                  volumeIdentity == ticket.checkpoint.identity,
                  try identityProvider(root) == ticket.checkpoint.identity,
                  let hybrid=index as? HybridIndex, let reconciler else { throw SnapshotError.generationChanged }
            let visibleGeneration=index.stats().generation
            try publish()
            hybrid.install(base:base,directoryMap:directories,generation:ticket.snapshot.generation)
            let buffered=compactionEvents
            compactionID=nil;compactionEvents=[];compactionOverflow=false
            metrics.set("compaction_buffer_estimated_bytes",to:0)
            process(buffered,into:index,using:reconciler,countMetrics:false,mayRebuild:true)
            hybrid.ensureGeneration(atLeast:visibleGeneration)
            metrics.set("compaction_replayed_events",to:buffered.count)
        }
    }
    /// Stop delivery, then finish every received batch before an exit checkpoint.
    /// Filesystem changes after this fence are recovered from the saved cursor.
    public func quiesceForExit(timings: ShutdownMetrics = .init()) {
        timings.measure("shutdown_stop_watcher_ms") { streamControl.sync { pauseRequested = true; watcher.stop() } }
        timings.measure("shutdown_namespace_drain_ms") { writer.sync { drain(); exitFrozen = true; deferredTimer?.cancel(); deferredTimer = nil; recoveryTimer?.cancel(); recoveryTimer = nil; metrics.set("deferred_reconcile_timer", to: 0) } }
    }

    public func stop() {
        requestFastExit(); cancelQueries(); cancellation.cancel()
        streamControl.sync { pauseRequested = true; watcher.stop() }
        // Establish that no writer can enter the rebuild group after wait begins.
        writer.sync { deferredTimer?.cancel(); deferredTimer = nil; recoveryTimer?.cancel(); recoveryTimer = nil; metrics.set("deferred_reconcile_timer", to: 0) }
        buildGroup.wait()
        writer.sync { inboxLock.withLock { inbox.removeAll(); metrics.set("inbox_estimated_bytes",to:0) }; setState(.stopped) }
    }
}
