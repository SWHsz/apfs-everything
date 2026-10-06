import Foundation
import XCTest
@testable import APFSFindCore

final class FakeVolumeProvider: MountedVolumeProvider, @unchecked Sendable {
  private let lock = NSLock()
  var values: [VolumeDescriptor] { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
  private var stored: [VolumeDescriptor]
  init(_ values: [VolumeDescriptor]) { stored = values }
  func mountedVolumes() throws -> [VolumeDescriptor] { values }
}
final class MemoryVolumeSelection: VolumeSelectionStore, @unchecked Sendable {
  let lock = NSLock(); var selected: Set<UUID>
  init(_ ids: Set<UUID> = []) { selected = ids }
  func load() -> Set<UUID> { lock.withLock { selected } }
  func save(_ ids: Set<UUID>) { lock.withLock { selected = ids } }
}
final class ParallelSearchProbe: @unchecked Sendable {
  private let condition = NSCondition()
  private var arrived = 0, timedOut = false
  func enter() {
    condition.lock(); defer { condition.unlock() }
    arrived += 1; condition.broadcast()
    let deadline = Date().addingTimeInterval(3)
    while arrived < 2 {
      if !condition.wait(until: deadline) { timedOut = true; break }
    }
  }
  var overlapped: Bool {
    condition.lock(); defer { condition.unlock() }; return arrived == 2 && !timedOut
  }
}
final class FakeVolumeSession: VolumeSearching, @unchecked Sendable {
  let volume: VolumeDescriptor
  let index = FileIndex(root: "/fixture")
  let lock = NSLock(); var offline = false
  var reasons: Set<IndexPauseReason> = []
  let delay: Double
  let probe: ParallelSearchProbe?
  init(_ volume: VolumeDescriptor, delay: Double = 0, probe: ParallelSearchProbe? = nil) {
    self.volume = volume; self.delay = delay; self.probe = probe
    index.apply((0..<100).map { .upsert(.init(path: "/fixture/match-\($0)", kind: .file)) })
    index.apply([.upsert(.init(path: "/fixture/match", kind: .file))])
  }
  func start() {}
  func stop(policy: ShutdownPolicy) async { lock.withLock { offline = true } }
  func snapshot() -> VolumeSessionSnapshot {
    let (offline, reasons) = lock.withLock { (self.offline, self.reasons) }
    return .init(volume: volume, state: offline ? .offline : (reasons.isEmpty ? .live : .paused),
          searchAvailable: !offline, freshness: reasons.isEmpty ? .live : .pausedStale,
          indexedEntries: index.stats().liveEntries, snapshotBytes: 0, unreadableDirectories: 0, pendingReplayEvents: 0,
          pauseReasons: reasons)
  }
  func search(_ request: SearchRequest) -> SearchResult {
    probe?.enter()
    let end = ProcessInfo.processInfo.systemUptime + delay
    while ProcessInfo.processInfo.systemUptime < end && !request.cancellation.isCancelled { Thread.sleep(forTimeInterval: 0.001) }
    return index.search(request)
  }
  func reconcileParent(of path: String) {}
  func changes() -> AsyncStream<VolumeSessionSnapshot> { AsyncStream { $0.yield(snapshot()) } }
  func setPauseReason(_ reason: IndexPauseReason, enabled: Bool) async {
    lock.withLock { if enabled { reasons.insert(reason) } else { reasons.remove(reason) } }
  }
}
final class MultiVolumeTests: XCTestCase, @unchecked Sendable {
  func testParallelTop50RankingAndSamePathsDoNotDedupAcrossVolumes() async {
    let a = VolumeDescriptor(volumeUUID: UUID(), displayName: "A", mountPath: "/", isSystemVolume: true)
    let b = VolumeDescriptor(volumeUUID: UUID(), displayName: "B", mountPath: "/Volumes/B")
    let provider = FakeVolumeProvider([a, b]), store = MemoryVolumeSelection([b.volumeUUID])
    let probe = ParallelSearchProbe()
    let c = MultiVolumeCoordinator(provider: provider, selectionStore: store, factory: { v, _ in FakeVolumeSession(v, probe: probe) })
    await c.start()
    let result = await c.search(.init(id: 1, query: "match", limit: 50))
    XCTAssertEqual(result.hits.count, 50); XCTAssertEqual(result.searchedVolumes, 2)
    XCTAssertEqual(result.hits.prefix(2).map(\.matchRank), [.exact, .exact])
    XCTAssertEqual(Set(result.hits.prefix(2).map(\.volumeUUID)).count, 2)
    XCTAssertTrue(probe.overlapped, "Both queries must enter before either is allowed to return")
    await c.stop()
  }
  func testOfflineRemountSelectionAndPartialFailure() async {
    let a = VolumeDescriptor(volumeUUID: UUID(), displayName: "A", mountPath: "/", isSystemVolume: true)
    let b = VolumeDescriptor(volumeUUID: UUID(), displayName: "B", mountPath: "/Volumes/B")
    let bad = VolumeDescriptor(volumeUUID: UUID(), displayName: "Bad", mountPath: "/Volumes/Bad")
    let provider = FakeVolumeProvider([a, b, bad]), store = MemoryVolumeSelection([b.volumeUUID, bad.volumeUUID])
    let c = MultiVolumeCoordinator(provider: provider, selectionStore: store, factory: { v, _ in
      if v.displayName == "Bad" { throw CocoaError(.fileReadNoPermission) }; return FakeVolumeSession(v)
    })
    await c.start()
    var result = await c.search(.init(query: "match", limit: 2))
    XCTAssertEqual(result.failedVolumes, [bad.volumeUUID]); XCTAssertEqual(result.searchedVolumes, 2)
    provider.values = [a, bad]; await c.refreshMountedVolumes()
    result = await c.search(.init(query: "match")); XCTAssertEqual(result.offlineVolumes, 1); XCTAssertEqual(result.searchedVolumes, 1)
    provider.values = [a, b, bad]; await c.refreshMountedVolumes()
    result = await c.search(.init(query: "match")); XCTAssertEqual(result.searchedVolumes, 2)
    await c.setVolumeSelected(b.volumeUUID, selected: false)
    XCTAssertFalse(store.load().contains(b.volumeUUID))
    result = await c.search(.init(query: "match")); XCTAssertEqual(result.searchedVolumes, 1)
    await c.stop()
  }
  func testLatestRequestCancelsPriorAndEmptyDoesNotScan() async throws {
    let a = VolumeDescriptor(volumeUUID: UUID(), displayName: "A", mountPath: "/", isSystemVolume: true)
    let c = MultiVolumeCoordinator(provider: FakeVolumeProvider([a]), selectionStore: MemoryVolumeSelection(), factory: { v, _ in FakeVolumeSession(v, delay: 0.1) })
    await c.start(); let latest = LatestSearchController(coordinator: c)
    let token = SearchCancellationToken()
    let first = Task { await latest.submit(.init(id: 1, query: "match", cancellation: token)) }
    try await Task.sleep(for: .milliseconds(10))
    let second = await latest.submit(.init(id: 2, query: ""))
    let old = await first.value
    XCTAssertNil(old); XCTAssertTrue(token.isCancelled); XCTAssertEqual(second?.requestID, 2); XCTAssertEqual(second?.searchedVolumes, 0)
    await c.stop()
  }
  func testDefaultsUUIDPersistenceAndDiscoveryExclusions() {
    let suite = "apfsfind-tests-" + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = DefaultsVolumeSelectionStore(defaults: defaults), id = UUID()
    store.save([id]); XCTAssertEqual(store.load(), [id])
    XCTAssertFalse(LocalMountedVolumeProvider.includes(path: "/System/Volumes/Data", local: true, filesystem: "apfs"))
    XCTAssertFalse(LocalMountedVolumeProvider.includes(path: "/Volumes/net", local: false, filesystem: "smbfs"))
    XCTAssertFalse(LocalMountedVolumeProvider.includes(path: "/Volumes/Preboot", local: true, filesystem: "apfs"))
    XCTAssertTrue(LocalMountedVolumeProvider.includes(path: "/Volumes/work", local: true, filesystem: "apfs"))
  }
  func testTwoRealRootsFastRestartOfflineMutationReplayAndVerify() async throws {
    try requireFSEvents()
    let aTree = try TemporaryTree(), bTree = try TemporaryTree(), cache = try TemporaryTree(cache: true)
    try aTree.file("same"); try bTree.file("same")
    let a = VolumeDescriptor(volumeUUID: UUID(), displayName: "A", mountPath: aTree.root, isSystemVolume: true)
    let b = VolumeDescriptor(volumeUUID: UUID(), displayName: "B", mountPath: bTree.root)
    let provider = FakeVolumeProvider([a, b]), selection = MemoryVolumeSelection([b.volumeUUID])
    let cachePath = cache.root
    let factory: MultiVolumeCoordinator.SessionFactory = { v, scheduler in try VolumeIndexSession(volume: v, cacheDirectory: cachePath, maintenanceScheduler: scheduler) }
    let c = MultiVolumeCoordinator(provider: provider, selectionStore: selection, factory: factory)
    await c.start(); try await waitReady(c, count: 2)
    var result = await c.search(.init(query: "same")); XCTAssertEqual(result.hits.count, 2)
    provider.values = [a]; await c.refreshMountedVolumes()
    result = await c.search(.init(query: "same")); XCTAssertEqual(result.hits.count, 1)
    try bTree.file("offline-created")
    provider.values = [a, b]; await c.refreshMountedVolumes(); try await waitReady(c, count: 2)
    await c.stop(policy: .fast)
    let restarted = MultiVolumeCoordinator(provider: provider, selectionStore: selection, factory: factory)
    await restarted.start(); try await waitReady(restarted, count: 2)
    for _ in 0..<500 {
      result = await restarted.search(.init(query: "offline-created")); if result.hits.count == 1 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(result.hits.count, 1)
    let values = await restarted.sessionsSnapshot(); XCTAssertTrue(values.allSatisfy { $0.searchAvailable })
    await restarted.stop(policy: .fast)
    for tree in [aTree, bTree] {
      let p = try PersistentIndexCoordinator(root: tree.root, cacheDirectory: cache.root)
      try p.start(); XCTAssertTrue(p.waitUntilLive()); XCTAssertTrue(try p.verify().isConsistent)
      XCTAssertEqual(p.metrics.snapshot()["full_scans", default: 0], 0); p.stop(policy: .fast)
    }
  }
  private func waitReady(_ c: MultiVolumeCoordinator, count: Int) async throws {
    for _ in 0..<1000 {
      let values = await c.sessionsSnapshot()
      if values.filter({ $0.searchAvailable }).count == count { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("sessions not ready")
  }
}
