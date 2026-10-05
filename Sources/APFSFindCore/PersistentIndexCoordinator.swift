import Darwin
import Foundation

public enum StartupMode: String, Sendable { case coldScan = "cold_scan", warmSnapshot = "warm_snapshot", rebuildFallback = "rebuild_fallback" }

/// Persistence owns cache/format/checkpoint I/O. UpdateCoordinator remains the
/// single writer of the runtime namespace and its matching device cursor.
public final class PersistentIndexCoordinator: @unchecked Sendable {
    public let core: UpdateCoordinator
    public var index: FileIndex { core.index }
    public var root: String { core.root }
    public var metrics: Metrics { core.metrics }
    public let persistenceEnabled: Bool
    public let cacheDirectory: String
    private let rebuildIndex: Bool
    private let identityProvider: @Sendable (String) throws -> VolumeIdentity
    private let queue = DispatchQueue(label: "apfsfind.checkpoint", qos: .utility)
    private let group = DispatchGroup()
    private let lock = NSLock()
    private let checkpointCancellation = CancellationToken()
    private var store: SnapshotStore?
    private var identity: VolumeIdentity?
    private var mode: StartupMode = .coldScan
    private var loaded = false, valid = false, active = false, shuttingDown = false
    private var automaticCheckpointNeeded = false
    private var lastCheckpointGeneration: UInt64?
    private var snapshotHeader: SnapshotHeader?
    private var stateValid = false
    private var durableCursor: UInt64 = 0
    private var snapshotLoadMS = 0.0, snapshotRestoreMS = 0.0, snapshotWriteMS = 0.0
    private var snapshotMmapMS = 0.0
    private var rssBeforeLoad: UInt64 = 0, rssAfterMmap: UInt64 = 0, rssAfterRestore: UInt64 = 0
    private var checkpointPeakRSS: UInt64 = 0
    private var replayStarted: TimeInterval = 0
    private var warmReplayMS = 0.0, warmReplayEvents = 0, replayReceivedBaseline = 0
    private var warmReplayMeasured = false
    private var progress: (@Sendable (String) -> Void)?
    private var persistenceError: String?
    private var interrupts = 0

    public init(root: String, configuration: APFSFindConfiguration = .init(),
                ephemeral: Bool = false, rebuildIndex: Bool = false, cacheDirectory: String? = nil,
                identityProvider: @escaping @Sendable (String) throws -> VolumeIdentity = { try VolumeIdentity.discover(root: $0) }) throws {
        persistenceEnabled = !ephemeral
        self.rebuildIndex = rebuildIndex
        self.identityProvider = identityProvider
        let cache = cacheDirectory ?? SnapshotStore.defaultDirectory
        self.cacheDirectory = try SnapshotStore.normalizedDirectory(cache)
        core = try UpdateCoordinator(root: root, configuration: configuration,
            excludedRoots: ephemeral ? [] : [self.cacheDirectory], identityProvider: identityProvider)
        core.setLifecycleHandlers(live: { [weak self] in self?.becameLive() },
            recovery: { [weak self] reason in self?.beganRecovery(reason) })
    }

    public func start(progress: (@Sendable (String) -> Void)? = nil) throws {
        lock.withLock { self.progress = progress }
        let volume = try identityProvider(root)
        lock.withLock { identity = volume }
        var restored: FileIndex?, cursor: UInt64?
        if persistenceEnabled {
            let cache = try SnapshotStore(directory: cacheDirectory, identity: volume)
            lock.withLock { store = cache; automaticCheckpointNeeded = true }
            if !rebuildIndex {
                do {
                    let beforeLoad = Metrics.processUsage().residentBytes
                    lock.withLock { rssBeforeLoad = beforeLoad }
                    let started = ProcessInfo.processInfo.systemUptime
                    let reader = try cache.reader(expectedIdentity: volume)
                    let loadMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
                    let restoreStart = ProcessInfo.processInfo.systemUptime
                    restored = try FileIndex.restore(from: reader, cancellation: checkpointCancellation)
                    let restoreMS = (ProcessInfo.processInfo.systemUptime - restoreStart) * 1000
                    let afterRestore = Metrics.processUsage().residentBytes
                    let state = cache.effectiveCursor(for: reader.header)
                    cursor = state.cursor
                    lock.withLock { stateValid = state.valid; durableCursor = state.cursor }
                    lock.withLock {
                        loaded = true; valid = true; snapshotHeader = reader.header
                        snapshotLoadMS = loadMS; snapshotMmapMS = reader.mmapMilliseconds
                        snapshotRestoreMS = restoreMS; rssAfterMmap = reader.residentAfterMmap
                        rssAfterRestore = afterRestore
                        mode = .warmSnapshot; automaticCheckpointNeeded = false
                    }
                    progress?("[info] Loaded snapshot: \(reader.header.recordCount) records; startup_mode=warm_snapshot")
                } catch {
                    let missing: Bool
                    if case SnapshotError.io(_, let code) = error { missing = code == ENOENT } else { missing = false }
                    lock.withLock {
                        mode = missing ? .coldScan : .rebuildFallback
                        persistenceError = missing ? nil : String(describing: error)
                    }
                    if !missing { progress?("[info] Snapshot rejected (\(error)); startup_mode=rebuild_fallback") }
                }
            }
        }
        lock.withLock {
            replayStarted = ProcessInfo.processInfo.systemUptime
            replayReceivedBaseline = metrics.snapshot()["fsevents_received", default: 0]
        }
        try core.start(restored: restored, cursor: cursor, identity: volume, progress: progress)
        if restored != nil {
            lock.withLock { lastCheckpointGeneration = core.installedSnapshotGeneration }
        } else {
            // cold timing begins at the actual replay boundary, after enumeration/build.
            lock.withLock { replayStarted = ProcessInfo.processInfo.systemUptime }
            progress?("[info] startup_mode=\(lock.withLock { mode.rawValue })")
        }
    }

    private func beganRecovery(_ reason: String) {
        lock.withLock {
            if loaded { mode = .rebuildFallback }
            automaticCheckpointNeeded = persistenceEnabled
        }
        emit("[info] Persistent recovery: \(reason)")
    }
    private func becameLive() {
        lock.withLock {
            if loaded && !warmReplayMeasured {
                warmReplayMS = (ProcessInfo.processInfo.systemUptime - replayStarted) * 1000
                warmReplayEvents = metrics.snapshot()["fsevents_received", default: 0] - replayReceivedBaseline
                warmReplayMeasured = true
            }
        }
        // Never call writer.sync from the lifecycle hook itself.
        queue.async { [weak self] in
            guard let self else { return }
            let automatic = self.lock.withLock { self.automaticCheckpointNeeded && !self.shuttingDown }
            if automatic { _ = self.checkpoint() }
        }
    }
    private func emit(_ message: String) {
        let handler = lock.withLock { progress }
        handler?(message)
    }

    /// Returns false when disabled or already active. Completion is reported on
    /// stderr via the progress callback; failures never terminate online queries.
    @discardableResult
    public func checkpoint() -> Bool {
        let shouldStart = lock.withLock {
            if !persistenceEnabled || active || shuttingDown || checkpointCancellation.isCancelled { return false }
            active = true; group.enter(); return true
        }
        guard shouldStart else { return false }
        queue.async { [weak self] in self?.performCheckpoint() }
        return true
    }
    private func performCheckpoint() {
        defer { lock.withLock { active = false }; group.leave() }
        do {
            let capture = try core.captureCheckpoint()
            let cache = try SnapshotStore(directory: cacheDirectory, identity: capture.identity)
            if let h = lock.withLock({ snapshotHeader }), h.snapshotUUID != nil,
               h.indexGeneration == capture.metadata.generation {
                let advanced = lock.withLock { capture.cursor > durableCursor }
                if advanced {
                    try cache.writeState(header: h, cursor: capture.cursor,
                        beforePublish: { [core] in try core.validateCheckpoint(capture) })
                    lock.withLock { durableCursor = capture.cursor; stateValid = true }
                    metrics.record("state_checkpoints")
                }
                return
            }
            let result = try SnapshotWriter.write(index: index, identity: capture.identity, cursor: capture.cursor,
                store: cache, metadata: capture.metadata, cancellation: checkpointCancellation,
                beforePublish: { [core] in try core.validateCheckpoint(capture) })
            metrics.record("snapshot_checkpoints")
            lock.withLock {
                store = cache; identity = capture.identity; snapshotHeader = result.header
                lastCheckpointGeneration = capture.metadata.generation; durableCursor = capture.cursor; stateValid = false; snapshotWriteMS = result.durationMilliseconds
                checkpointPeakRSS = result.peakResidentBytes; automaticCheckpointNeeded = false
                valid = true; persistenceError = nil
            }
            if result.header.snapshotUUID != nil {
                try? cache.writeState(header: result.header, cursor: capture.cursor,
                    beforePublish: { [core] in try core.validateCheckpoint(capture) })
            }
            emit(String(format: "[info] Checkpoint saved: %llu bytes, %llu records, %.1f ms",
                result.header.fileLength, result.header.recordCount, result.durationMilliseconds))
        } catch {
            let aborted: Bool
            switch error { case SnapshotError.generationChanged, SnapshotError.cancelled: aborted = true; default: aborted = false }
            metrics.record(aborted ? "snapshot_checkpoint_aborts" : "snapshot_checkpoint_failures")
            if case SnapshotError.generationChanged = error { metrics.record("checkpoint_aborted_generation_change") }
            lock.withLock { persistenceError = String(describing: error) }
            emit("[\(aborted ? "info" : "error")] \(error)")
        }
    }

    public func waitForCheckpoint(timeout: TimeInterval = 30) -> Bool {
        core.synchronizeWriter()
        // Wait for any queued lifecycle notification to schedule its checkpoint.
        let dispatched = DispatchSemaphore(value: 0)
        queue.async { dispatched.signal() }
        guard dispatched.wait(timeout: .now() + timeout) == .success else { return false }
        return group.wait(timeout: .now() + timeout) == .success
    }
    public func waitUntilLive(timeout: TimeInterval = 10) -> Bool { core.waitUntilLive(timeout: timeout) }
    public func startupStatus() -> StartupStatus { core.startupStatus() }
    public func verify() throws -> VerificationResult { try core.verify() }
    public func rebuild() { core.rebuild() }
    public var currentState: IndexState { core.currentState }

    /// First Ctrl+C requests a graceful live exit; during startup it cancels
    /// scanning. A second Ctrl+C cancels an exit checkpoint without touching the
    /// previous final snapshot.
    public func interrupt() {
        let count = lock.withLock { interrupts += 1; return interrupts }
        if count > 1 || currentState != .live {
            checkpointCancellation.cancel(); core.stop()
        }
    }
    public func stop(saveCheckpoint: Bool = true) {
        let first = lock.withLock { if shuttingDown { return false }; shuttingDown = true; return true }
        guard first else { return }
        if saveCheckpoint && persistenceEnabled && !checkpointCancellation.isCancelled {
            core.quiesceForExit()
            group.wait()
            let capture = try? core.captureCheckpoint()
            let changed = lock.withLock { lastCheckpointGeneration != index.stats().generation || (capture?.cursor ?? 0) > durableCursor }
            if currentState == .live && changed {
                emit("[info] Saving index snapshot...")
                // An exit is quiesced, so the writer cannot change G during export.
                lock.withLock { active = true; group.enter() }
                performCheckpoint()
            }
        } else { checkpointCancellation.cancel() }
        core.stop()
        group.wait()
    }

    public func stats() -> CoordinatorStats {
        var values = core.stats().dictionary
        let snapshot = lock.withLock {
            var v: [String: Any] = [
                "persistence_enabled": persistenceEnabled, "snapshot_path": store?.path ?? "",
                "snapshot_loaded": loaded, "snapshot_valid": valid,
                "snapshot_records": snapshotHeader?.recordCount ?? 0, "snapshot_bytes": snapshotHeader?.fileLength ?? 0,
                "snapshot_bytes_per_entry": snapshotHeader.map { Double($0.fileLength) / Double($0.recordCount) } ?? 0,
                "snapshot_format_version": SnapshotFormat.version, "snapshot_load_ms": snapshotLoadMS,
                "snapshot_mmap_ms": snapshotMmapMS, "snapshot_restore_ms": snapshotRestoreMS,
                "snapshot_write_ms": snapshotWriteMS, "last_checkpoint_generation": lastCheckpointGeneration ?? 0,
                "volume_uuid": identity?.volumeUUID.uuidString ?? "", "fsevents_history_uuid": identity?.historyUUID.uuidString ?? "",
                "startup_mode": mode.rawValue, "warm_replay_events": warmReplayEvents, "warm_replay_ms": warmReplayMS,
                "rss_before_snapshot_load": rssBeforeLoad, "rss_after_mmap": rssAfterMmap,
                "rss_after_restore": rssAfterRestore, "checkpoint_peak_rss_bytes": checkpointPeakRSS,
                "checkpoint_running": active, "state_path": store?.statePath ?? "",
                "state_valid": stateValid, "snapshot_uuid": snapshotHeader?.snapshotUUID?.uuidString ?? "",
                "base_cursor": snapshotHeader?.lastProcessedEventID ?? 0, "effective_cursor": durableCursor
            ]
            if let persistenceError { v["persistence_error"] = persistenceError }
            return v
        }
        values.merge(snapshot, uniquingKeysWith: { _, new in new })
        for name in ["snapshot_checkpoints", "snapshot_checkpoint_failures", "snapshot_checkpoint_aborts"] {
            if values[name] == nil { values[name] = 0 }
        }
        return .init(dictionary: values)
    }
}
