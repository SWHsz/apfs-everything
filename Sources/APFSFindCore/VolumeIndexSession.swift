import Foundation

public enum VolumeSessionState: Sendable, Equatable {
  case opening, queuedForInitialIndex, scanning, baseReady, catchingUp, live, rebuilding, offline, failed(String)
  public var description: String {
    switch self {
    case .opening: "Opening"
    case .queuedForInitialIndex: "Queued"
    case .scanning: "Scanning"
    case .baseReady: "Base ready"
    case .catchingUp: "Catching up"
    case .live: "Live"
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
  public let pendingReplayEvents: Int
  public init(volume: VolumeDescriptor, state: VolumeSessionState, searchAvailable: Bool, freshness: SearchFreshness,
              indexedEntries: Int, snapshotBytes: UInt64, unreadableDirectories: Int, pendingReplayEvents: Int) {
    self.volume = volume; self.state = state; self.searchAvailable = searchAvailable; self.freshness = freshness
    self.indexedEntries = indexedEntries; self.snapshotBytes = snapshotBytes
    self.unreadableDirectories = unreadableDirectories; self.pendingReplayEvents = pendingReplayEvents
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
}
public final class VolumeIndexSession: VolumeSearching, @unchecked Sendable {
  public let volume: VolumeDescriptor
  public let coordinator: PersistentIndexCoordinator
  private let lock = NSLock()
  private var state: VolumeSessionState = .opening
  private var offline = false, started = false
  private var observationTask: Task<Void, Never>?
  private let startup = DispatchGroup()
  private let observations = SnapshotObservation<VolumeSessionSnapshot>()
  public init(volume: VolumeDescriptor, cacheDirectory: String? = nil, maintenanceScheduler: MaintenanceScheduler = .shared) throws {
    self.volume = volume
    coordinator = try PersistentIndexCoordinator(root: volume.mountPath, cacheDirectory: cacheDirectory,
                                                 maintenanceScheduler: maintenanceScheduler)
  }
  public func snapshot() -> VolumeSessionSnapshot {
    let status = coordinator.readinessSnapshot()
    let current = lock.withLock { state }
    return .init(volume: volume, state: current,
                 searchAvailable: current != .offline && status.searchAvailable,
                 freshness: status.freshness, indexedEntries: status.indexedEntries,
                 snapshotBytes: coordinator.snapshotBytes,
                 unreadableDirectories: coordinator.metrics.snapshot()["scanner_unreadable_directories", default: 0],
                 pendingReplayEvents: status.replayPending)
  }
  public func changes() -> AsyncStream<VolumeSessionSnapshot> { observations.stream(initial: snapshot()) }
  public func start() {
    let begin = lock.withLock { if started || offline { return false }; started = true; state = .queuedForInitialIndex; startup.enter(); return true }
    guard begin else { return }
    observations.send(snapshot())
    observationTask = Task { [weak self] in
      guard let self else { return }
      for await value in coordinator.readinessStream() {
        if Task.isCancelled { break }
        lock.withLock {
          guard !offline else { return }
          switch value.state {
          case .opening: state = .opening
          case .scanning: state = coordinator.metrics.snapshot()["maintenance_queued", default: 0] != 0 ? .queuedForInitialIndex : .scanning
          case .baseReady: state = .baseReady
          case .catchingUp: state = .catchingUp
          case .live: state = .live
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
  private func stopSynchronously(_ policy: ShutdownPolicy) { coordinator.stop(policy: policy); startup.wait() }
  public func search(_ request: SearchRequest) -> SearchResult {
    guard !lock.withLock({ offline }) else { return .init(hits: [], latencyMilliseconds: 0, generation: 0) }
    return coordinator.search(request)
  }
  public func reconcileParent(of path: String) { coordinator.core.reconcileParent(of: path) }
}
