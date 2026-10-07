import Darwin
import Foundation

public enum StartupMode: String, Sendable {
  case coldScan = "cold_scan"
  case warmSnapshot = "warm_snapshot"
  case rebuildFallback = "rebuild_fallback"
  case formatMigration = "format_migration_rebuild"
}

/// Persistence owns cache/format/checkpoint I/O. UpdateCoordinator remains the
/// single writer of the runtime namespace and its matching device cursor.
public final class PersistentIndexCoordinator: @unchecked Sendable {
  public let core: UpdateCoordinator
  public var index: any NamespaceIndex { core.index }
  public var root: String { core.root }
  public var metrics: Metrics { core.metrics }
  public let persistenceEnabled: Bool
  public let cacheDirectory: String
  public let metadata = MetadataIndexCoordinator()
  private var metadataUpdater: MetadataUpdateCoordinator?
  private let metadataQueue = DispatchQueue(label:"apfsfind.metadata-maintenance",qos:.utility)
  private let metadataGroup = DispatchGroup()
  private let metadataCancellation = CancellationToken()
  private var metadataBootstrapActive = false
  private var metadataCheckpointActive = false
  private var metadataSeeds: MetadataBuildBuffer?
  private let metadataScheduler: CompactionScheduler
  private let metadataPolicy: MetadataCheckpointPolicy
  private var lastMetadataCheckpoint: Double = -.infinity
  private var metadataError: String?
  private let rebuildIndex: Bool
  private let compactionPolicy: CompactionPolicy
  private let metadataFault: (@Sendable (SnapshotFailurePoint) throws -> Void)?
  private let compactionFault: (@Sendable (SnapshotFailurePoint) throws -> Void)?
  private let compactionScheduler: CompactionScheduler
  private var startupBegan = ProcessInfo.processInfo.systemUptime
  private let maintenanceScheduler: MaintenanceScheduler
  private var compacting = false
  private var retryAfter: TimeInterval = 0
  private var consecutiveFailures = 0
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
  private var snapshotOpenMS = 0.0
  private var rssBeforeLoad: UInt64 = 0, rssAfterMmap: UInt64 = 0, rssAfterRestore: UInt64 = 0
  private var rssAfterValidation: UInt64 = 0, validationMS = 0.0
  private var checkpointPeakRSS: UInt64 = 0
  private var replayStarted: TimeInterval = 0
  private var warmReplayMS = 0.0, warmReplayEvents = 0, replayReceivedBaseline = 0
  private var warmReplayMeasured = false
  private var progress: (@Sendable (String) -> Void)?
  private var persistenceError: String?
  private var interrupts = 0

  public init(
    root: String, configuration: APFSFindConfiguration = .init(),
    ephemeral: Bool = false, rebuildIndex: Bool = false, cacheDirectory: String? = nil,
    compactionPolicy: CompactionPolicy = .init(),
    metadataPolicy: MetadataCheckpointPolicy = .init(), metadataUpdatePolicy: MetadataUpdatePolicy = .init(),
    metadataFault: (@Sendable (SnapshotFailurePoint) throws -> Void)? = nil,
    compactionFault: (@Sendable (SnapshotFailurePoint) throws -> Void)? = nil,
    identityProvider: @escaping @Sendable (String) throws -> VolumeIdentity = {
      try VolumeIdentity.discover(root: $0)
    },
    maintenanceScheduler: MaintenanceScheduler = .shared,
    replayStarter: (@Sendable (UInt64, @escaping @Sendable ([FileSystemEvent]) -> Void) throws -> Void)? = nil,
    fenceProvider: @escaping @Sendable (VolumeIdentity) -> UInt64 = { $0.currentEventID() }
  ) throws {
    persistenceEnabled = !ephemeral
    self.rebuildIndex = rebuildIndex
    self.compactionPolicy = compactionPolicy
    self.metadataPolicy = metadataPolicy
    self.compactionFault = compactionFault
    self.metadataFault = metadataFault
    self.identityProvider = identityProvider
    self.maintenanceScheduler = maintenanceScheduler
    let cache = cacheDirectory ?? SnapshotStore.defaultDirectory
    self.cacheDirectory = try SnapshotStore.normalizedDirectory(cache)
    let canonical = try PathCanonicalizer.canonicalRoot(root)
    let runtime: any NamespaceIndex =
      ephemeral ? FileIndex(root: canonical) : HybridIndex(root: canonical)
    core = try UpdateCoordinator(
      root: canonical, configuration: configuration,
      excludedRoots: ephemeral ? [] : [self.cacheDirectory], index: runtime,
      identityProvider: identityProvider, fenceProvider:fenceProvider, maintenanceScheduler: maintenanceScheduler, replayStarter: replayStarter)
    compactionScheduler = CompactionScheduler(metrics: core.metrics)
    metadataScheduler = CompactionScheduler(metrics: Metrics())
    (runtime as? HybridIndex)?.setMetadataSource(metadata)
    let initialIdentity = try identityProvider(canonical)
    metadataUpdater = ephemeral ? nil : MetadataUpdateCoordinator(root:canonical,device:initialIdentity.deviceID,
      index:metadata,namespace:runtime,metrics:core.metrics,policy:metadataUpdatePolicy,
      invalidated:{ [weak self] in self?.scheduleMetadataBootstrap() },
      changed:{ [weak self] in self?.metadataChanged() })
    core.setMetadataHandlers(scan:{ [weak self] entries,initial in
      guard let self, self.persistenceEnabled else { return }
      let seed = try? initial.metadataSeed(entries,directory:self.cacheDirectory)
      self.lock.withLock { self.metadataSeeds = seed }
    },events:{ [weak self] events in self?.metadataUpdater?.enqueue(events) })
    core.setLifecycleHandlers(
      live: { [weak self] in self?.becameLive() },
      recovery: { [weak self] reason in self?.beganRecovery(reason) })
    core.setMutationHandler { [weak self] in self?.namespaceChanged() }
    if !ephemeral {
      core.setBaseInstaller { [weak self] initial, cursor, identity in
        guard let self, let hybrid = self.index as? HybridIndex else { return }
        let cache = try SnapshotStore(directory: self.cacheDirectory, identity: identity)
        var staged: StagedMetadataFile?
        let result = try SnapshotV2Writer.write(
          source: .ram(initial, initial.stats().generation), identity: identity,
          generation: hybrid.stats().generation, cursor: cursor, store: cache,
          cancellation: self.checkpointCancellation,
          beforePublish:{
              guard try self.identityProvider(self.root)==identity else{throw SnapshotError.identity("root changed during initial scan")}
          },
          install: { base, map, publish in
            try publish()
            hybrid.install(base: base, directoryMap: map)
          }, prepareMetadata: { refs,header in
            let seed = self.lock.withLock { let values = self.metadataSeeds; self.metadataSeeds = nil; return values }
            staged = try? MetadataWriter.stage(store:cache,base:header,cursor:cursor,value:{ ordinal in
              if case .base(let id) = refs[Int(ordinal)], let seed, Int(id) < seed.count { return seed.value(Int(id)) }
              return .unknown
            },fault:self.metadataFault)
          }, completed: { _,header in self.installStagedMetadata(staged,cache:cache,header:header,cursor:cursor)
          }, resourceMetrics: self.metrics, resourceStage: "initial_snapshot")
        self.recordSnapshot(result, cache: cache, identity: identity)
      }
    }
  }

  public func start(progress: (@Sendable (String) -> Void)? = nil) throws {
    startupBegan = ProcessInfo.processInfo.systemUptime
    core.markOpening()
    lock.withLock { self.progress = progress }
    let volume = try identityProvider(root)
    lock.withLock { identity = volume }
    var restored: (any NamespaceIndex)?
    var cursor: UInt64?
    var streamCursor: UInt64?
    if persistenceEnabled {
      let cache = try SnapshotStore(directory: cacheDirectory, identity: volume)
      lock.withLock {
        store = cache
        automaticCheckpointNeeded = true
      }
      if !rebuildIndex {
        do {
          let beforeLoad = Metrics.processUsage().residentBytes
          lock.withLock { rssBeforeLoad = beforeLoad }
          let started = ProcessInfo.processInfo.systemUptime
          let reader = try cache.reader(expectedIdentity: volume)
          let loadMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
          let restoreStart = ProcessInfo.processInfo.systemUptime
          guard let base = reader.mappedBase else { throw SnapshotError.formatMigration }
          restored = HybridIndex(base: base)
          let restoreMS = (ProcessInfo.processInfo.systemUptime - restoreStart) * 1000
          let afterRestore = Metrics.processUsage().residentBytes
          let state = cache.effectiveCursor(for: reader.header)
          cursor = state.cursor
          if let mapped = try? cache.metadataReader(base:reader.header) {
            let fence = cache.effectiveMetadataCursor(for:mapped.header)
            metadata.bind(namespace:base,mapped:mapped,cursor:fence.cursor)
            streamCursor = min(state.cursor,fence.cursor)
          } else { metadata.bind(namespace:base) }
          lock.withLock {
            stateValid = state.valid
            durableCursor = state.cursor
          }
          lock.withLock {
            loaded = true
            valid = true
            snapshotHeader = reader.header
            snapshotLoadMS = loadMS
            snapshotMmapMS = reader.mmapMilliseconds
            snapshotOpenMS = reader.openMilliseconds
            snapshotRestoreMS = restoreMS
            rssAfterMmap = reader.residentAfterMmap
            rssAfterValidation = base.residentAfterValidation
            validationMS = base.validationMilliseconds
            rssAfterRestore = afterRestore
            mode = .warmSnapshot
            automaticCheckpointNeeded = false
          }
          progress?(
            "[info] Loaded snapshot: \(reader.header.recordCount) records; startup_mode=warm_snapshot"
          )
        } catch {
          let missing: Bool
          if case SnapshotError.io(_, let code) = error {
            missing = code == ENOENT
          } else {
            missing = false
          }
          lock.withLock {
            mode =
              missing
              ? .coldScan
              : ((error as? SnapshotError).map {
                if case .formatMigration = $0 { return true }
                return false
              } == true ? .formatMigration : .rebuildFallback)
            persistenceError = missing ? nil : String(describing: error)
          }
          if !missing {
            progress?(
              "[info] Snapshot load: \(error); startup_mode=\(lock.withLock { mode.rawValue })")
          }
        }
      }
    }
    lock.withLock {
      replayStarted = ProcessInfo.processInfo.systemUptime
      replayReceivedBaseline = metrics.snapshot()["fsevents_received", default: 0]
    }
    try core.start(restored: restored, cursor: cursor, streamStartCursor: streamCursor, identity: volume, progress: progress)
    if restored != nil {
      lock.withLock { lastCheckpointGeneration = core.installedSnapshotGeneration }
      if !metadata.capture().available { scheduleMetadataBootstrap() }
    } else {
      // cold timing begins at the actual replay boundary, after enumeration/build.
      lock.withLock { replayStarted = ProcessInfo.processInfo.systemUptime }
      progress?("[info] startup_mode=\(lock.withLock { mode.rawValue })")
    }
  }
  private func namespaceChanged() {
    guard persistenceEnabled, currentState == .live, let hybrid = index as? HybridIndex else { return }
    let trigger = hybrid.compactionTrigger(compactionPolicy)
    guard trigger.threshold else { return }
    let retry = lock.withLock { retryAfter - ProcessInfo.processInfo.systemUptime }
    let delay = max(trigger.safety ? 0 : compactionPolicy.quietSeconds, retry)
    compactionScheduler.schedule(delay: delay, safety: trigger.safety, backoff: retry > 0) { [weak self] in
      guard let self, !self.lock.withLock({ self.shuttingDown }) else { return }
      if self.compact() { _ = self.group.wait(timeout: .now() + 3600) }
    }
  }
  public var metadataAvailable: Bool { let captured = metadata.capture(); return captured.available && captured.namespace?.header.snapshotUUID == (index as? HybridIndex)?.mappedBase?.header.snapshotUUID }
  public var metadataFailure: String? { lock.withLock { metadataError } }
  public var snapshotBytes: UInt64 { lock.withLock { snapshotHeader?.fileLength ?? 0 } }
  public func readinessSnapshot() -> IndexReadinessSnapshot { core.readinessSnapshot(startupMode: lock.withLock { mode }) }
  public func readinessStream() -> AsyncStream<IndexReadinessSnapshot> {
    let source = core.readinessStream()
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let task = Task { [weak self] in
        for await value in source {
          guard let self, !Task.isCancelled else { break }
          continuation.yield(.init(state: value.state, searchAvailable: value.searchAvailable,
            resultsMayBeStale: value.resultsMayBeStale, startupMode: self.lock.withLock { self.mode },
            indexedEntries: value.indexedEntries, replayReceived: value.replayReceived,
            replayProcessed: value.replayProcessed, replayPending: value.replayPending, error: value.error))
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
  public func search(_ request: SearchRequest) -> SearchResult { core.search(request) }
  public func search(_ query: String, limit: Int = 50) -> SearchResult { search(.init(query: query, limit: limit)) }
  public func pause() { compactionScheduler.cancelPending(); metadataScheduler.cancelPending(); core.pause(); metadataUpdater?.flush(); metadata.pause(true) }
  public func resume() throws { metadata.pause(false); metadataUpdater?.resetReplay(); try core.resume(additionalCursor:metadata.capture().available ? metadata.processedCursor : nil); namespaceChanged(); if !metadata.capture().available { scheduleMetadataBootstrap() } }

  private func recordSnapshot(
    _ result: SnapshotWriteResult, cache: SnapshotStore, identity: VolumeIdentity
  ) {
    metrics.record("snapshot_checkpoints")
    lock.withLock {
      store = cache
      self.identity = identity
      snapshotHeader = result.header
      lastCheckpointGeneration = result.header.indexGeneration
      durableCursor = result.header.lastProcessedEventID
      stateValid = false
      snapshotWriteMS = result.durationMilliseconds
      checkpointPeakRSS = result.peakResidentBytes
      automaticCheckpointNeeded = false
      valid = true
      persistenceError = nil
      retryAfter = 0
      consecutiveFailures = 0
    }
  }
  private func beganRecovery(_ reason: String) {
    metadata.fail()
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
        warmReplayEvents =
          metrics.snapshot()["fsevents_received", default: 0] - replayReceivedBaseline
        warmReplayMeasured = true
      }
    }
    namespaceChanged()
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
  public func checkpoint(forceCompact: Bool = false) -> Bool {
    let shouldStart = lock.withLock {
      if !persistenceEnabled || active || shuttingDown || checkpointCancellation.isCancelled {
        return false
      }
      active = true
      group.enter()
      return true
    }
    guard shouldStart else { return false }
    queue.async { [weak self] in self?.performCheckpoint(forceCompact: forceCompact) }
    return true
  }
  private func performCheckpoint(forceCompact: Bool = false) {
    defer {
      lock.withLock { active = false }
      group.leave()
      namespaceChanged()
    }
    do {
      let capture = try core.captureCheckpoint()
      let cache = try SnapshotStore(directory: cacheDirectory, identity: capture.identity)
      if let h = lock.withLock({ snapshotHeader }), h.snapshotUUID != nil,
        h.indexGeneration == capture.metadata.generation, !forceCompact
      {
        let advanced = lock.withLock { capture.cursor > durableCursor }
        if advanced {
          let stateResources = ProcessResourceSample.capture()
          try cache.writeState(
            header: h, cursor: capture.cursor,
            beforePublish: { [core] in try core.validateCheckpoint(capture) })
          lock.withLock {
            durableCursor = capture.cursor
            stateValid = true
          }
          metrics.record("state_checkpoints")
          metrics.recordResources("state_checkpoint", since: stateResources)
        }
        return
      }
      let lease = try maintenanceScheduler.acquireBlocking(volumeID: capture.identity.volumeUUID, kind: .compaction, cancellation: checkpointCancellation)
      defer { lease.release() }
      let result: SnapshotWriteResult
      if let hybrid = index as? HybridIndex, hybrid.mappedBase != nil {
        let ticket = try core.beginCompaction()
        lock.withLock { compacting = true }
        defer {
          core.abortCompaction(ticket)
          lock.withLock { compacting = false }
        }
        metadataUpdater?.suspend()
        defer { metadataUpdater?.resume() }
        let metadataCapture = metadata.capture()
        var staged: StagedMetadataFile?
        result = try SnapshotV2Writer.write(
          source: .hybrid(ticket.snapshot), identity: ticket.checkpoint.identity,
          generation: ticket.snapshot.generation, cursor: ticket.checkpoint.cursor, store: cache,
          cancellation: checkpointCancellation,
          fault: compactionFault,
          install: { [core] base, map, publish in
            try core.finishCompaction(ticket, base: base, directories: map, publish: publish)
          }, prepareMetadata:{ refs,header in
            guard metadataCapture.available else { return }
            staged = try? MetadataWriter.stage(store:cache,base:header,cursor:min(self.metadata.processedCursor,ticket.checkpoint.cursor),value:{ ordinal in
              switch refs[Int(ordinal)] {
              case .base(let id): return metadataCapture.value(at:id)
              case .delta(let id): return ticket.snapshot.delta[id].map { metadataCapture.value(path:$0.entry.path) } ?? .unknown
              }
            },fault:self.metadataFault)
          }, completed:{ _,header in self.installStagedMetadata(staged,cache:cache,header:header,cursor:header.lastProcessedEventID)
          }, resourceMetrics: metrics, resourceStage: "full_compaction")
        metrics.record("compactions")
        metrics.set("compaction_ms", to: Int(result.durationMilliseconds))
        metrics.set("compaction_bytes_written", to: Int(result.header.fileLength))
      } else if let hybrid = index as? HybridIndex, let ram = hybrid.transientIndex {
        result = try SnapshotV2Writer.write(
          source: .ram(ram, ram.stats().generation), identity: capture.identity,
          generation: capture.metadata.generation, cursor: capture.cursor, store: cache,
          cancellation: checkpointCancellation,
          install: { [core] base, map, publish in
            try core.installRecoveredBase(capture, base: base, map: map, publish: publish)
          }, resourceMetrics: metrics, resourceStage: "recovery_snapshot")
      } else {
        throw SnapshotError.invalid("persistent runtime is not hybrid")
      }
      recordSnapshot(result, cache: cache, identity: capture.identity)
      if !metadata.capture().available { scheduleMetadataBootstrap() }
      // Buffered content events can safely advance the new base fence. Any
      // buffered namespace change leaves G different and keeps the conservative
      // header cursor until the next compaction.
      if let current=try? core.captureCheckpoint(),current.metadata.generation==result.header.indexGeneration {
          do {
              try cache.writeState(header:result.header,cursor:current.cursor,
                  beforePublish:{[core] in try core.validateCheckpoint(current)})
              lock.withLock{stateValid=true;durableCursor=current.cursor}
              metrics.record("state_checkpoints")
          } catch {metrics.record("state_checkpoint_failures")}
      }
      emit(
        String(
          format: "[info] Checkpoint saved: %llu bytes, %llu records, %.1f ms",
          result.header.fileLength, result.header.recordCount, result.durationMilliseconds))
    } catch {
      let aborted: Bool
      switch error {
      case SnapshotError.generationChanged, SnapshotError.cancelled: aborted = true
      default: aborted = false
      }
      metrics.record(aborted ? "snapshot_checkpoint_aborts" : "snapshot_checkpoint_failures")
      metrics.record(aborted ? "compaction_aborts" : "compaction_failures")
      if case SnapshotError.generationChanged = error {
        metrics.record("checkpoint_aborted_generation_change")
      }
      lock.withLock {
        persistenceError = String(describing: error)
        consecutiveFailures += 1
        retryAfter =
          ProcessInfo.processInfo.systemUptime
          + min(30, pow(2, Double(min(5, consecutiveFailures))))
      }
      emit("[\(aborted ? "info" : "error")] \(error)")
    }
  }

  @discardableResult public func compact() -> Bool { checkpoint(forceCompact: true) }

  public func waitForCheckpoint(timeout: TimeInterval = 30) -> Bool {
    core.synchronizeWriter()
    // Wait for any queued lifecycle notification to schedule its checkpoint.
    let dispatched = DispatchSemaphore(value: 0)
    queue.async { dispatched.signal() }
    guard dispatched.wait(timeout: .now() + timeout) == .success else { return false }
    return group.wait(timeout: .now() + timeout) == .success
  }
  public func waitUntilLive(timeout: TimeInterval = 10) -> Bool {
    core.waitUntilLive(timeout: timeout)
  }
  public func startupStatus() -> StartupStatus { core.startupStatus() }
  public func verify() throws -> VerificationResult { try core.verify() }
  public func rebuild() { core.rebuild() }
  public var currentState: IndexState { core.currentState }

  /// First Ctrl+C requests a graceful live exit; during startup it cancels
  /// scanning. A second Ctrl+C cancels an exit checkpoint without touching the
  /// previous final snapshot.
  public func interrupt() {
    let count = lock.withLock {
      interrupts += 1
      return interrupts
    }
    if count > 1 || currentState != .live {
      checkpointCancellation.cancel()
      core.stop()
    }
  }
  // Legacy explicit persistence callers retain their full checkpoint behavior.
  public func stop(saveCheckpoint: Bool = true) { stop(policy: saveCheckpoint ? .forceCompact : .fast, saveCheckpoint: saveCheckpoint) }
  public func stop(policy: ShutdownPolicy) { stop(policy: policy, saveCheckpoint: true) }
  private func stop(policy: ShutdownPolicy, saveCheckpoint: Bool) {
    let first = lock.withLock {
      if shuttingDown { return false }
      shuttingDown = true
      return true
    }
    guard first else { return }
    compactionScheduler.stop()
    metadataScheduler.stop()
    metadataCancellation.cancel()
    if policy == .fast { checkpointCancellation.cancel() }
    if saveCheckpoint && persistenceEnabled {
      core.quiesceForExit()
      group.wait()
      let capture = try? core.captureCheckpoint()
      let changed = lock.withLock {
        lastCheckpointGeneration != index.stats().generation
          || (capture?.cursor ?? 0) > durableCursor
      }
      let sameBase = lock.withLock { snapshotHeader?.indexGeneration == index.stats().generation }
      let threshold = (index as? HybridIndex)?.compactionTrigger(compactionPolicy).threshold ?? false
      let mayCompact = policy == .forceCompact || (policy == .compactIfThresholdReached && threshold)
      if currentState == .live && changed && (sameBase || mayCompact) {
        emit("[info] Saving index snapshot...")
        // An exit is quiesced, so the writer cannot change G during export.
        lock.withLock {
          active = true
          group.enter()
        }
        performCheckpoint()
      } else if changed { metrics.record("fast_exit_unpersisted_namespace") }
    } else {
      checkpointCancellation.cancel()
    }
    core.stop()
    metadataUpdater?.stop()
    metadataGroup.wait()
    saveMetadataStateIfClean()
    group.wait()
  }

  private func installStagedMetadata(_ staged:StagedMetadataFile?,cache:SnapshotStore,header:SnapshotHeader,cursor:UInt64) {
    guard let base = (index as? HybridIndex)?.mappedBase, base.header.snapshotUUID == header.snapshotUUID else { return }
    metadata.bind(namespace:base,cursor:staged?.header.cursor ?? cursor)
    do {
      guard let staged else { throw SnapshotError.invalid("metadata staging unavailable") }
      try staged.publish(beforePublish:{
        let actual = try self.identityProvider(self.root)
        guard actual.volumeUUID == header.volumeUUID, actual.historyUUID == header.historyUUID, actual.deviceID == header.rootDeviceID, actual.rootFileID == header.rootFileID else { throw SnapshotError.identity("root changed before metadata publication") }
        guard (self.index as? HybridIndex)?.mappedBase?.header.snapshotUUID == header.snapshotUUID else { throw SnapshotError.generationChanged }
      })
      try metadata.install(cache.metadataReader(base:header))
      lock.withLock { metadataError = nil; lastMetadataCheckpoint = ProcessInfo.processInfo.systemUptime }
      metrics.record("metadata_checkpoints")
    } catch {
      metadata.fail(); lock.withLock { metadataError = String(describing:error) }
      metrics.record("metadata_publish_failures"); scheduleMetadataBootstrap()
    }
  }
  private func scheduleMetadataBootstrap() {
    guard persistenceEnabled else { return }
    let allowed = lock.withLock {
      guard !shuttingDown, !metadataBootstrapActive else { return false }
      metadataBootstrapActive = true; metadataGroup.enter(); return true
    }
    guard allowed else { return }
    metadataQueue.async { [weak self] in
      guard let self else { return }
      defer { self.lock.withLock { self.metadataBootstrapActive = false }; self.metadataGroup.leave() }
      guard self.currentState != .paused, !self.metadataCancellation.isCancelled,
            let base = (self.index as? HybridIndex)?.mappedBase else { return }
      do {
        let identity = try self.identityProvider(self.root)
        guard identity.volumeUUID == base.header.volumeUUID, identity.historyUUID == base.header.historyUUID,
              identity.deviceID == base.header.rootDeviceID, identity.rootFileID == base.header.rootFileID else {
          throw SnapshotError.identity("metadata awaits matching namespace identity")
        }
        let lease = try self.maintenanceScheduler.acquireBlocking(volumeID:identity.volumeUUID,kind:.metadataBootstrap,cancellation:self.metadataCancellation)
        defer { lease.release() }
        guard self.currentState != .paused else { return }
        guard (self.index as? HybridIndex)?.mappedBase?.header.snapshotUUID == base.header.snapshotUUID else { throw SnapshotError.generationChanged }
        let resources = ProcessResourceSample.capture()
        self.metadataUpdater?.suspend()
        let fence = identity.currentEventID()
        self.metadata.bind(namespace:base)
        self.metadata.beginBootstrap(fence:fence)
        self.metadataUpdater?.resume()
        self.core.notifyMetadataChanged()
        let lookup = self.metadata.capture()
        let values = try MetadataBuildBuffer(count:base.count,directory:self.cacheDirectory)
        let scan = try BulkScanner(root:self.root,workerCount:self.core.configuration.workerCount,metrics:self.metrics,
          excludedRoots:[self.cacheDirectory]).scan(cancellation:self.metadataCancellation,collectEntries:false,visit:{ entries in
            var pairs:[(Int,FileMetadataValue)] = []
            for entry in entries {
              if let ordinal = lookup.ordinal(entry.namespace.path) {
                let record = base.record(at:ordinal)
                if record.kind == entry.namespace.kind, record.fileID == (entry.namespace.fileID ?? 0) {
                  pairs.append((Int(ordinal),entry.metadata)); continue
                }
              }
              if self.index.entry(at:entry.namespace.path) == entry.namespace {
                self.metadata.update(path:entry.namespace.path,value:entry.metadata)
              }
            }
            values.update(pairs)
          })
        guard !scan.cancelled else { throw SnapshotError.cancelled }
        let cache = try SnapshotStore(directory:self.cacheDirectory,identity:identity)
        let safeCursor = self.index.stats().generation == base.header.indexGeneration ? fence : min(fence,self.lock.withLock { self.durableCursor })
        _ = try MetadataWriter.write(store:cache,base:base.header,cursor:safeCursor,value:{values.value(Int($0))},beforePublish:{
          guard !self.metadataCancellation.isCancelled else { throw SnapshotError.cancelled }
          guard try self.identityProvider(self.root) == identity else { throw SnapshotError.identity("root changed during metadata maintenance") }
          guard (self.index as? HybridIndex)?.mappedBase?.header.snapshotUUID == base.header.snapshotUUID else { throw SnapshotError.generationChanged }
        },fault:self.metadataFault)
        try self.metadata.install(cache.metadataReader(base:base.header))
        self.metadataUpdater?.flush()
        self.metrics.record("metadata_bootstraps")
        self.metrics.recordResources("metadata_bootstrap",since:resources)
        self.lock.withLock { self.metadataError = nil; self.lastMetadataCheckpoint = ProcessInfo.processInfo.systemUptime }
        self.core.notifyMetadataChanged()
      } catch {
        if !self.metadataCancellation.isCancelled {
          self.metadata.fail(); self.lock.withLock { self.metadataError = String(describing:error) }
          self.metrics.record("metadata_bootstrap_failures"); self.core.notifyMetadataChanged()
        }
      }
      if !self.metadataCancellation.isCancelled,
         self.metadata.capture().namespace?.header.snapshotUUID != (self.index as? HybridIndex)?.mappedBase?.header.snapshotUUID {
        self.lock.withLock { self.metadataBootstrapActive = false }; self.scheduleMetadataBootstrap()
      }
    }
  }
  private func metadataChanged() {
    core.notifyMetadataChanged()
    let capture = metadata.capture()
    guard capture.available, capture.overlay.entryCount > 0, currentState != .paused else { return }
    let safety = capture.overlay.estimatedBytes >= metadataPolicy.safetyBytes
    if safety && metadata.hasUnpersistedPaths { _ = compact(); return }
    guard safety || capture.overlay.entryCount >= metadataPolicy.entryLimit || capture.overlay.estimatedBytes >= metadataPolicy.byteLimit else { return }
    let interval = lock.withLock { lastMetadataCheckpoint + metadataPolicy.minimumInterval - ProcessInfo.processInfo.systemUptime }
    metadataScheduler.schedule(delay:safety ? 0 : max(metadataPolicy.quietSeconds,interval),safety:safety) { [weak self] in self?.checkpointMetadata() }
  }
  public func waitForMetadata(timeout: Double = 30) -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while ProcessInfo.processInfo.systemUptime < deadline {
      metadataUpdater?.flush()
      if metadata.capture().available { return true }
      Thread.sleep(forTimeInterval:0.01)
    }
    return false
  }
  public func rebuildMetadata() { scheduleMetadataBootstrap() }
  public func flushMetadata() { metadataUpdater?.flush() }
  public func checkpointMetadata() {
    let allowed = lock.withLock {
      guard !shuttingDown, !metadataCheckpointActive else { return false }
      metadataCheckpointActive = true; metadataGroup.enter(); return true
    }
    guard allowed else { return }
    metadataQueue.async { [weak self] in
      guard let self else { return }
      defer { self.lock.withLock { self.metadataCheckpointActive = false }; self.metadataGroup.leave() }
      do {
        let identity = try self.identityProvider(self.root)
        let lease = try self.maintenanceScheduler.acquireBlocking(volumeID:identity.volumeUUID,kind:.metadataCheckpoint,cancellation:self.metadataCancellation)
        defer { lease.release() }
        guard self.currentState != .paused else { return }
        self.metadataUpdater?.suspend(); defer { self.metadataUpdater?.resume() }
        let captured = self.metadata.capture()
        let cursor = !self.metadata.hasUnpersistedPaths ? self.metadata.processedCursor : (captured.base?.header.cursor ?? 0)
        guard captured.available, let base = captured.namespace else { return }
        guard identity.volumeUUID == base.header.volumeUUID, identity.historyUUID == base.header.historyUUID,
              identity.deviceID == base.header.rootDeviceID, identity.rootFileID == base.header.rootFileID else {
          throw SnapshotError.identity("metadata checkpoint namespace identity")
        }
        let cache = try SnapshotStore(directory:self.cacheDirectory,identity:identity)
        let resources = ProcessResourceSample.capture()
        _ = try MetadataWriter.write(store:cache,base:base.header,cursor:cursor,value:{captured.value(at:$0)},beforePublish:{
          guard !self.metadataCancellation.isCancelled else { throw SnapshotError.cancelled }
          guard try self.identityProvider(self.root) == identity else { throw SnapshotError.identity("root changed during metadata maintenance") }
          guard (self.index as? HybridIndex)?.mappedBase?.header.snapshotUUID == base.header.snapshotUUID else { throw SnapshotError.generationChanged }
        },fault:self.metadataFault)
        try self.metadata.install(cache.metadataReader(base:base.header),expectedGeneration:captured.overlay.generation)
        // Delta entries have no ordinal until namespace compaction. They remain dirty and keep a conservative fence.
        self.lock.withLock { self.lastMetadataCheckpoint = ProcessInfo.processInfo.systemUptime }
        self.metrics.record("metadata_checkpoints"); self.metrics.recordResources("metadata_checkpoint",since:resources)
      } catch { self.metrics.record("metadata_checkpoint_failures"); self.lock.withLock { self.metadataError = String(describing:error) } }
    }
  }
  private func saveMetadataStateIfClean() {
    guard !metadata.isDirty, let header = metadata.capture().base?.header,
      let cache = lock.withLock({store}), metadata.processedCursor > header.cursor else { return }
    do { try cache.writeMetadataState(header:header,cursor:metadata.processedCursor); metrics.record("metadata_state_checkpoints") }
    catch { metrics.record("metadata_state_failures") }
  }

  public func stats() -> CoordinatorStats {
    var values = core.stats().dictionary
    let snapshot = lock.withLock {
      var v: [String: Any] = [
        "persistence_enabled": persistenceEnabled, "snapshot_path": store?.path ?? "",
        "snapshot_loaded": loaded, "snapshot_valid": valid,
        "snapshot_records": snapshotHeader?.recordCount ?? 0,
        "snapshot_bytes": snapshotHeader?.fileLength ?? 0,
        "snapshot_bytes_per_entry": snapshotHeader.map {
          Double($0.fileLength) / Double($0.recordCount)
        } ?? 0,
        "snapshot_format_version": snapshotHeader == nil ? 0 : 2,
        "snapshot_load_ms": snapshotLoadMS,
        "snapshot_mmap_ms": snapshotMmapMS, "snapshot_restore_ms": snapshotRestoreMS,
        "snapshot_open_ms": snapshotOpenMS,
        "snapshot_validation_ms": validationMS, "rss_after_validation": rssAfterValidation,
        "snapshot_write_ms": snapshotWriteMS,
        "last_checkpoint_generation": lastCheckpointGeneration ?? 0,
        "volume_uuid": identity?.volumeUUID.uuidString ?? "",
        "fsevents_history_uuid": identity?.historyUUID.uuidString ?? "",
        "startup_mode": mode.rawValue, "warm_replay_events": warmReplayEvents,
        "warm_replay_ms": warmReplayMS,
        "rss_before_snapshot_load": rssBeforeLoad, "rss_after_mmap": rssAfterMmap,
        "rss_after_restore": rssAfterRestore, "checkpoint_peak_rss_bytes": checkpointPeakRSS,
        "checkpoint_running": active, "compaction_running": compacting,
        "state_path": store?.statePath ?? "",
        "state_valid": stateValid, "snapshot_uuid": snapshotHeader?.snapshotUUID?.uuidString ?? "",
        "base_cursor": snapshotHeader?.lastProcessedEventID ?? 0, "effective_cursor": durableCursor,
      ]
      if let persistenceError { v["persistence_error"] = persistenceError }
      return v
    }
    values.merge(snapshot, uniquingKeysWith: { _, new in new })
    let meta = metadata.capture()
    values["metadata_available"] = meta.available
    values["metadata_freshness"] = meta.freshness.rawValue
    values["metadata_bytes"] = meta.base?.header.fileLength ?? 0
    values["metadata_bytes_per_entry"] = meta.base.map { Double($0.header.fileLength)/Double($0.header.count) } ?? 0
    values["metadata_overlay_entries"] = meta.overlay.entryCount
    values["metadata_overlay_bytes"] = meta.overlay.estimatedBytes
    values["metadata_cursor"] = metadata.processedCursor
    values["metadata_replay_floor"] = metadata.replayFloor
    values["metadata_error"] = lock.withLock { metadataError } ?? ""
    values["metadata_periodic_wakeups"] = 0
    values["resource_stages"] = metrics.resourceSnapshot()
    values["search_ready_ms"] = metrics.snapshot()["search_ready_ms", default: 0]
    values["compaction_scheduler_state"] = compactionScheduler.currentState.rawValue
    values["compaction_timer_wakeups"] = 0
    if let hybrid = index as? HybridIndex {
      values.merge(hybrid.hybridStats(), uniquingKeysWith: { _, new in new })
    }
    for name in [
      "snapshot_checkpoints", "snapshot_checkpoint_failures", "snapshot_checkpoint_aborts",
      "compactions", "compaction_aborts", "compaction_failures", "state_checkpoints",
      "query_base_scan_us", "query_overlay_scan_us", "query_path_reconstruction_us",
      "query_retries", "writer_lock_wait_us", "tombstone_cow_copies",
    ] {
      if values[name] == nil { values[name] = 0 }
    }
    return .init(dictionary: values)
  }
}
