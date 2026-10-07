import Foundation

public enum IndexPauseReason: String, Hashable, Sendable { case userGlobal, userVolume, systemSleep }
public enum VolumeSessionState: Sendable, Equatable {
  case opening, queuedForInitialIndex, scanning, baseReady, catchingUp, live, rebuilding, paused, offline, failed(String)
  public var description: String {
    switch self {
    case .opening: "Opening"
    case .queuedForInitialIndex: "Queued"
    case .scanning: "Scanning"
    case .baseReady: "Base ready"
    case .catchingUp: "Catching up"
    case .live: "Live"
    case .paused: "索引已暂停，结果可能不是最新"
    case .rebuilding: "Rebuilding"
    case .offline: "Offline"
    case .failed(let error): "Failed: " + error
    }
  }
}
public struct VolumeSessionSnapshot: Sendable, Identifiable {
  public var id: UUID { volume.volumeUUID }
  public let volume: VolumeDescriptor
  public let state: VolumeSessionState
  public let searchAvailable: Bool
  public let freshness: SearchFreshness
  public let indexedEntries: Int
  public let snapshotBytes: UInt64
  public let unreadableDirectories: Int
  /// Cumulative read attempts in this session, not a Full Disk Access probe.
  public let permissionDeniedReads: Int
  public let datalessSkips: Int
  public let pendingReplayEvents: Int
  public let metadataGeneration: UInt64
  public let metadataAvailable: Bool
  public let metadataFreshness: MetadataFreshness
  public let metadataError: String?
  public let pauseReasons: Set<IndexPauseReason>
  public init(volume: VolumeDescriptor, state: VolumeSessionState, searchAvailable: Bool, freshness: SearchFreshness,
              indexedEntries: Int, snapshotBytes: UInt64, unreadableDirectories: Int, pendingReplayEvents: Int,
              permissionDeniedReads: Int = 0, datalessSkips: Int = 0, pauseReasons: Set<IndexPauseReason> = [], metadataAvailable: Bool = false,
              metadataFreshness: MetadataFreshness = .unavailable, metadataError: String? = nil, metadataGeneration: UInt64 = 0) {
    self.volume = volume; self.state = state; self.searchAvailable = searchAvailable; self.freshness = freshness
    self.indexedEntries = indexedEntries; self.snapshotBytes = snapshotBytes
    self.unreadableDirectories = unreadableDirectories; self.pendingReplayEvents = pendingReplayEvents
    self.permissionDeniedReads = permissionDeniedReads; self.datalessSkips = datalessSkips
    self.pauseReasons = pauseReasons
    self.metadataGeneration = metadataGeneration
    self.metadataAvailable = metadataAvailable; self.metadataFreshness = metadataFreshness; self.metadataError = metadataError
  }
}
public protocol VolumeSearching: AnyObject, Sendable {
  var volume: VolumeDescriptor { get }
  func snapshot() -> VolumeSessionSnapshot
  func start()
  func stop(policy: ShutdownPolicy) async
  func search(_ request: SearchRequest) -> SearchResult
  func reconcileParent(of path: String)
  func changes() -> AsyncStream<VolumeSessionSnapshot>
  func setPauseReason(_ reason: IndexPauseReason, enabled: Bool) async
}
extension VolumeSearching {
  public func setPauseReason(_ reason: IndexPauseReason, enabled: Bool) async {}
}
public final class VolumeIndexSession: VolumeSearching, @unchecked Sendable {
  public let volume: VolumeDescriptor
  public let coordinator: PersistentIndexCoordinator
  private let lock = NSLock()
  private var state: VolumeSessionState = .opening
  private var offline = false, started = false
  private var observationTask: Task<Void, Never>?
  private let startup = DispatchGroup()
  private let lifecycle = DispatchQueue(label: "apfsfind.volume-lifecycle", qos: .utility)
  private var pauseReasons: Set<IndexPauseReason> = []
  private let observations = SnapshotObservation<VolumeSessionSnapshot>()
  public init(volume: VolumeDescriptor, cacheDirectory: String? = nil, maintenanceScheduler: MaintenanceScheduler = .shared) throws {
    self.volume = volume
    coordinator = try PersistentIndexCoordinator(root: volume.mountPath, cacheDirectory: cacheDirectory,
                                                 maintenanceScheduler: maintenanceScheduler)
  }
  public func snapshot() -> VolumeSessionSnapshot {
    let status = coordinator.readinessSnapshot()
    let (current, reasons) = lock.withLock { (state, pauseReasons) }
    let counts = coordinator.metrics.snapshot()
    return .init(volume: volume, state: current,
                 searchAvailable: current != .offline && status.searchAvailable,
                 freshness: current == .paused ? .pausedStale : status.freshness, indexedEntries: status.indexedEntries,
                 snapshotBytes: coordinator.snapshotBytes,
                 unreadableDirectories: counts["scanner_unreadable_directories", default: 0],
                 pendingReplayEvents: status.replayPending,
                 permissionDeniedReads: counts["scanner_permission_denied", default: 0],
                 datalessSkips: counts["scanner_dataless_skips", default: 0], pauseReasons: reasons,
                 metadataAvailable:coordinator.metadataAvailable, metadataFreshness:coordinator.metadata.capture().freshness, metadataError:coordinator.metadataFailure,
                 metadataGeneration:coordinator.metadata.capture().overlay.generation)
  }
  public func changes() -> AsyncStream<VolumeSessionSnapshot> { observations.stream(initial: snapshot()) }
  public func start() {
    let begin = lock.withLock {
      if started || offline { return false }
      if !pauseReasons.isEmpty { state = .paused; return false }
      started = true; state = .queuedForInitialIndex; startup.enter(); return true
    }
    guard begin else { return }
    observations.send(snapshot())
    observationTask = Task { [weak self] in
      guard let self else { return }
      for await value in coordinator.readinessStream() {
        if Task.isCancelled { break }
        lock.withLock {
          guard !offline else { return }
          if !pauseReasons.isEmpty { state = .paused; return }
          switch value.state {
          case .opening: state = .opening
          case .scanning: state = coordinator.metrics.snapshot()["maintenance_queued", default: 0] != 0 ? .queuedForInitialIndex : .scanning
          case .baseReady: state = .baseReady
          case .catchingUp: state = .catchingUp
          case .live: state = .live
          case .paused: state = .paused
          case .rebuildingUsingOldBase: state = .rebuilding
          case .offline, .stopped: state = .offline
          case .failed: state = .failed(value.error ?? "Index failed")
          }
        }
        observations.send(snapshot())
      }
    }
    DispatchQueue.global(qos: .utility).async { [self] in
      defer { startup.leave() }
      do { try coordinator.start() }
      catch { lock.withLock { if !offline { state = .failed(String(describing: error)) } }; observations.send(snapshot()) }
    }
  }
  public func stop(policy: ShutdownPolicy) async {
    lock.withLock { offline = true; state = .offline }
    observations.send(snapshot()); observationTask?.cancel()
    await Task.detached { [self] in stopSynchronously(policy) }.value
  }
  public func setPauseReason(_ reason: IndexPauseReason, enabled: Bool) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      lifecycle.async { [self] in
        defer { continuation.resume() }
        let transition = lock.withLock { () -> (Bool, Bool) in
          let was = !pauseReasons.isEmpty
          if enabled { pauseReasons.insert(reason) } else { pauseReasons.remove(reason) }
          return (was, !pauseReasons.isEmpty)
        }
        guard !lock.withLock({ offline }) else { observations.send(snapshot()); return }
        if !transition.0 && transition.1 { coordinator.pause() }
        else if transition.0 && !transition.1 {
          do {
            if lock.withLock({ started }) { try coordinator.resume() }
            else { try coordinator.resume(); start() }
          }
          catch { lock.withLock { state = .failed(String(describing: error)) }; observations.send(snapshot()); return }
        }
        lock.withLock {
          if transition.1 { state = .paused }
          else if state == .paused { state = .catchingUp }
        }
        observations.send(snapshot())
      }
    }
  }
  private func stopSynchronously(_ policy: ShutdownPolicy) { coordinator.stop(policy: policy); startup.wait() }
  public func search(_ request: SearchRequest) -> SearchResult {
    guard !lock.withLock({ offline }) else { return .init(hits: [], latencyMilliseconds: 0, generation: 0) }
    return coordinator.search(request)
  }
  public func reconcileParent(of path: String) { coordinator.core.reconcileParent(of: path) }
}
