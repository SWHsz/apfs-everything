import Foundation

public struct VolumeSearchHit: Sendable, Identifiable {
  public var id: String { volumeUUID.uuidString + ":" + path }
  public let path: String
  public let kind: EntryKind
  public let matchRank: MatchRank
  public let volumeUUID: UUID
  public let volumeName: String
  public let volumeMountPath: String
  public let freshness: SearchFreshness
  public init(hit: SearchHit, volume: VolumeDescriptor, freshness: SearchFreshness) {
    path = hit.path; kind = hit.kind; matchRank = hit.matchRank; volumeUUID = volume.volumeUUID
    volumeName = volume.displayName; volumeMountPath = volume.mountPath; self.freshness = freshness
  }
}
public typealias MultiVolumeSearchRequest = SearchRequest
public struct MultiVolumeSearchResult: Sendable {
  public let requestID: UInt64
  public let hits: [VolumeSearchHit]
  public let searchedVolumes: Int
  public let catchingUpVolumes: Int
  public let offlineVolumes: Int
  public let failedVolumes: [UUID]
  public let latencyMilliseconds: Double
  public let cancelled: Bool
  public init(requestID: UInt64, hits: [VolumeSearchHit], searchedVolumes: Int, catchingUpVolumes: Int,
              offlineVolumes: Int, failedVolumes: [UUID], latencyMilliseconds: Double, cancelled: Bool) {
    self.requestID = requestID; self.hits = hits; self.searchedVolumes = searchedVolumes
    self.catchingUpVolumes = catchingUpVolumes; self.offlineVolumes = offlineVolumes
    self.failedVolumes = failedVolumes; self.latencyMilliseconds = latencyMilliseconds; self.cancelled = cancelled
  }
}
public actor MultiVolumeCoordinator {
  public typealias SessionFactory = @Sendable (VolumeDescriptor, MaintenanceScheduler) throws -> any VolumeSearching
  private let provider: any MountedVolumeProvider
  private let selectionStore: any VolumeSelectionStore
  public let maintenance: MaintenanceScheduler
  private let factory: SessionFactory
  private var sessions: [UUID: any VolumeSearching] = [:]
  private var observers: [UUID: Task<Void, Never>] = [:]
  private var mounted: [VolumeDescriptor] = []
  private var selected: Set<UUID>
  private var globalPauseReasons: Set<IndexPauseReason> = []
  private var individuallyPaused: Set<UUID> = []
  private var stopping = false
  private var revision: UInt64 = 0
  private let observations = SnapshotObservation<[VolumeSessionSnapshot]>()
  public init(provider: any MountedVolumeProvider = LocalMountedVolumeProvider(),
              selectionStore: any VolumeSelectionStore = DefaultsVolumeSelectionStore(),
              maintenance: MaintenanceScheduler = .init(),
              factory: @escaping SessionFactory = { try VolumeIndexSession(volume: $0, maintenanceScheduler: $1) }) {
    self.provider = provider; self.selectionStore = selectionStore; self.maintenance = maintenance
    self.factory = factory; selected = selectionStore.load()
  }
  public func start() async { await refreshMountedVolumes() }
  public func mountedVolumes() -> [VolumeDescriptor] { mounted }
  public func selectedVolumes() -> Set<UUID> { selected }
  public func sessionsSnapshot() -> [VolumeSessionSnapshot] {
    sessions.values.map { $0.snapshot() }.sorted { $0.volume.displayName < $1.volume.displayName }
  }
  public func sessionsStream() -> AsyncStream<[VolumeSessionSnapshot]> { observations.stream(initial: sessionsSnapshot()) }
  private func publish() { observations.send(sessionsSnapshot()) }
  public func refreshMountedVolumes() async {
    guard !stopping else { return }
    revision &+= 1; let expected = revision
    do { mounted = try provider.mountedVolumes() } catch { return }
    let online = Set(mounted.map(\.volumeUUID))
    // Mark offline before awaiting teardown, so concurrent searches exclude it.
    for (id, session) in sessions where !online.contains(id) && session.snapshot().state != .offline {
      await maintenance.cancelQueued(volumeID: id)
      await session.stop(policy: .fast)
    }
    guard !stopping, revision == expected else { return }
    for volume in mounted where volume.isSystemVolume || selected.contains(volume.volumeUUID) {
      let old = sessions[volume.volumeUUID]
      if let old, old.snapshot().state != .offline, old.volume.mountPath == volume.mountPath,
        old.volume.deviceID == volume.deviceID { continue }
      if let old { await old.stop(policy: .fast) }
      guard !stopping, revision == expected else { return }
      do {
        let session = try factory(volume, maintenance)
        sessions[volume.volumeUUID] = session
        observers[volume.volumeUUID]?.cancel()
        observers[volume.volumeUUID] = Task { [weak self] in
          for await _ in session.changes() { if Task.isCancelled { break }; await self?.publish() }
        }
        for reason in globalPauseReasons { await session.setPauseReason(reason, enabled: true) }
        if individuallyPaused.contains(volume.volumeUUID) { await session.setPauseReason(.userVolume, enabled: true) }
        session.start()
      } catch { /* A failed factory is represented by an unavailable session. */
        sessions[volume.volumeUUID] = UnavailableVolumeSession(volume: volume, error: String(describing: error))
      }
    }
    publish()
  }
  public func setVolumeSelected(_ id: UUID, selected enabled: Bool) async {
    if mounted.contains(where: { $0.volumeUUID == id && $0.isSystemVolume }) { return }
    if enabled { selected.insert(id) } else { selected.remove(id) }
    selectionStore.save(selected)
    if !enabled, let session = sessions.removeValue(forKey: id) {
      observers.removeValue(forKey: id)?.cancel(); await maintenance.cancelQueued(volumeID: id)
      await session.stop(policy: .fast)
    }
    await refreshMountedVolumes()
  }
  public func search(_ request: MultiVolumeSearchRequest) async -> MultiVolumeSearchResult {
    let started = ProcessInfo.processInfo.systemUptime
    let snapshots = sessionsSnapshot()
    let available = sessions.values.filter { $0.snapshot().searchAvailable }
    let groups = await withTaskGroup(of: [VolumeSearchHit].self, returning: [[VolumeSearchHit]].self) { tasks in
      if !request.query.isEmpty, request.limit > 0, !request.cancellation.isCancelled {
        for session in available {
          tasks.addTask {
            let result = await Task.detached(priority: .userInitiated) { session.search(request) }.value
            guard !result.cancelled, session.snapshot().searchAvailable else { return [] }
            return result.hits.map { VolumeSearchHit(hit: $0, volume: session.volume, freshness: result.freshness) }
          }
        }
      }
      var values: [[VolumeSearchHit]] = []; for await value in tasks { values.append(value) }; return values
    }
    let all = groups.flatMap { $0 }.sorted { a, b in
      if a.matchRank != b.matchRank { return a.matchRank.rawValue < b.matchRank.rawValue }
      let x = SearchOrdering.foldedBasename(a.path), y = SearchOrdering.foldedBasename(b.path)
      if x != y { return x < y }; if a.path != b.path { return a.path < b.path }
      if a.volumeName != b.volumeName { return a.volumeName < b.volumeName }
      return a.volumeUUID.uuidString < b.volumeUUID.uuidString
    }
    var seen = Set<String>()
    let hits = Array(all.filter { seen.insert($0.id).inserted }.prefix(max(0, request.limit)))
    return .init(requestID: request.id, hits: request.cancellation.isCancelled ? [] : hits,
                 searchedVolumes: request.query.isEmpty ? 0 : available.count,
                 catchingUpVolumes: snapshots.filter { $0.searchAvailable && $0.freshness != .live }.count,
                 offlineVolumes: snapshots.filter { $0.state == .offline }.count,
                 failedVolumes: snapshots.compactMap { if case .failed = $0.state { return $0.id }; return nil },
                 latencyMilliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000,
                 cancelled: request.cancellation.isCancelled)
  }
  public func reconcile(_ hit: VolumeSearchHit) { sessions[hit.volumeUUID]?.reconcileParent(of: hit.path) }
  public var isGloballyPausedByUser: Bool { globalPauseReasons.contains(.userGlobal) }
  public func setAllPaused(_ reason: IndexPauseReason, enabled: Bool) async {
    guard !stopping else { return }
    if enabled { globalPauseReasons.insert(reason) } else { globalPauseReasons.remove(reason) }
    for session in Array(sessions.values) {
      await session.setPauseReason(reason, enabled: globalPauseReasons.contains(reason))
    }
    publish()
  }
  public func setVolumePaused(_ id: UUID, enabled: Bool) async {
    guard !stopping else { return }
    if enabled { individuallyPaused.insert(id) } else { individuallyPaused.remove(id) }
    await sessions[id]?.setPauseReason(.userVolume, enabled: enabled); publish()
  }
  public func stop(policy: ShutdownPolicy = .fast) async {
    stopping = true
    for task in observers.values { task.cancel() }; observers = [:]
    let current = Array(sessions.values)
    await withTaskGroup(of: Void.self) { group in
      for session in current { group.addTask { await self.maintenance.cancelQueued(volumeID: session.volume.volumeUUID); await session.stop(policy: policy) } }
    }
    publish()
  }
}
private final class UnavailableVolumeSession: VolumeSearching, @unchecked Sendable {
  let volume: VolumeDescriptor
  let error: String
  private let lock = NSLock()
  private var offline = false
  init(volume: VolumeDescriptor, error: String) { self.volume = volume; self.error = error }
  func snapshot() -> VolumeSessionSnapshot { .init(volume: volume, state: lock.withLock { offline } ? .offline : .failed(error), searchAvailable: false, freshness: .baseSnapshot, indexedEntries: 0, snapshotBytes: 0, unreadableDirectories: 0, pendingReplayEvents: 0) }
  func start() {}
  func stop(policy: ShutdownPolicy) async { lock.withLock { offline = true } }
  func search(_ request: SearchRequest) -> SearchResult { .init(hits: [], latencyMilliseconds: 0, generation: 0) }
  func reconcileParent(of path: String) {}
  func changes() -> AsyncStream<VolumeSessionSnapshot> { AsyncStream { $0.yield(snapshot()); $0.finish() } }
}
public actor LatestSearchController {
  private let coordinator: MultiVolumeCoordinator
  private var current: SearchRequest?
  public init(coordinator: MultiVolumeCoordinator) { self.coordinator = coordinator }
  public func cancel() { current?.cancellation.cancel(); current = nil }
  public func submit(_ request: SearchRequest) async -> MultiVolumeSearchResult? {
    current?.cancellation.cancel(); current = request
    let result = await coordinator.search(request)
    guard current?.id == request.id, !request.cancellation.isCancelled, !result.cancelled else { return nil }
    return result
  }
}
