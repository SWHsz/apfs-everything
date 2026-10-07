import CoreServices
import Foundation
import XCTest
@testable import APFSFindCore

private final class ReplayStarts: @unchecked Sendable {
  let lock = NSLock()
  var values: [UInt64] = []
  func record(_ id: UInt64) { lock.withLock { values.append(id) } }
  var cursors: [UInt64] { lock.withLock { values } }
}
private final class MutableIdentity: @unchecked Sendable {
  let lock = NSLock()
  private var identity: VolumeIdentity
  init(_ identity: VolumeIdentity) { self.identity = identity }
  func get() -> VolumeIdentity { lock.withLock { identity } }
  func replaceHistory() {
    lock.withLock {
      identity = .init(root: identity.root, deviceID: identity.deviceID, rootFileID: identity.rootFileID,
        volumeUUID: identity.volumeUUID, historyUUID: UUID(), mountPoint: identity.mountPoint, relativeRoot: identity.relativeRoot)
    }
  }
}
final class BackgroundLifecycleTests: XCTestCase, @unchecked Sendable {
  func testPausedNewSessionDefersInitialScanUntilResume() async throws {
    let tree = try TemporaryTree(), cache = try TemporaryTree(cache: true); try tree.file("needle")
    let session = try VolumeIndexSession(volume: .init(volumeUUID: UUID(), displayName: "New", mountPath: tree.root), cacheDirectory: cache.root)
    await session.setPauseReason(.userGlobal, enabled: true); session.start()
    XCTAssertEqual(session.snapshot().state, .paused)
    XCTAssertFalse(session.snapshot().searchAvailable)
    XCTAssertEqual(session.coordinator.metrics.snapshot()["full_scans", default: 0], 0)
    await session.setPauseReason(.userGlobal, enabled: false)
    waitFor("deferred session live") { session.snapshot().state == .live }
    XCTAssertEqual(session.search(.init(query: "needle")).hits.count, 1)
    await session.stop(policy: .fast)
  }
  func testPauseDrainsDeliveredEventsAndResumesFromMemoryFence() throws {
    let tree = try TemporaryTree(); try tree.file("before"); try tree.file("delivered")
    let starts = ReplayStarts()
    let core = try UpdateCoordinator(root: tree.root, maintenanceScheduler: .init(), replayStarter: { [root = tree.root] id, sink in
      starts.record(id); sink([.init(path: root, flags: UInt32(kFSEventStreamEventFlagHistoryDone), id: id)])
    })
    defer { core.stop() }
    let ram = FileIndex(root: tree.root); ram.apply([.upsert(.init(path: tree.path("before"), kind: .file))])
    try core.start(restored: ram, cursor: 100); XCTAssertTrue(core.waitUntilLive())
    core.enqueue([.init(path: tree.path("delivered"),
      flags: UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile), id: 101)])
    core.pause()
    XCTAssertEqual(core.currentState, .paused)
    XCTAssertEqual(core.search(.init(query: "delivered")).hits.count, 1)
    XCTAssertEqual(core.search(.init(query: "delivered")).freshness, .pausedStale)
    XCTAssertEqual(core.stats().dictionary["last_processed_event_id"] as? UInt64, 101)
    try core.resume(); XCTAssertTrue(core.waitUntilLive())
    XCTAssertEqual(starts.cursors, [100, 101])
    XCTAssertEqual(core.metrics.snapshot()["full_scans", default: 0], 0)
  }
  func testPausedChangesNativeReplayAndFastExitDoNotForceCompaction() throws {
    try requireFSEvents()
    let tree = try TemporaryTree(), cache = try TemporaryTree(cache: true)
    try tree.file("old")
    let p = try PersistentIndexCoordinator(root: tree.root, cacheDirectory: cache.root, maintenanceScheduler: .init())
    defer { p.stop(policy: .fast) }
    try p.start(); XCTAssertTrue(p.waitUntilLive()); XCTAssertTrue(p.waitForCheckpoint())
    let store = try SnapshotStore(directory: cache.root, identity: VolumeIdentity.discover(root: tree.root))
    let before = try Data(contentsOf: URL(fileURLWithPath: store.path))
    p.pause()
    try FileManager.default.removeItem(atPath: tree.path("old"))
    for i in 0..<1000 { try tree.file("new-\(i)") }
    XCTAssertEqual(p.search("old").hits.count, 1); XCTAssertTrue(p.search("new").hits.isEmpty)
    XCTAssertEqual(p.search("old").freshness, .pausedStale)
    try p.resume(); XCTAssertTrue(p.waitUntilLive(timeout: 15))
    waitFor("paused changes replay") { p.index.entry(at: tree.path("new-999")) != nil && p.index.entry(at: tree.path("old")) == nil }
    XCTAssertTrue(try p.verify().isConsistent)
    p.pause(); p.stop(policy: .fast)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: store.path)), before)
    XCTAssertEqual(p.metrics.snapshot()["compactions", default: 0], 0)
  }
  func testPauseReasonsAreIndependentAndSearchRemainsAvailable() async throws {
    let tree = try TemporaryTree(), cache = try TemporaryTree(cache: true); try tree.file("needle")
    let session = try VolumeIndexSession(volume: .init(volumeUUID: UUID(), displayName: "Fixture", mountPath: tree.root), cacheDirectory: cache.root)
    session.start()
    waitFor("session live") { session.snapshot().state == .live }
    await session.setPauseReason(.userVolume, enabled: true)
    await session.setPauseReason(.userGlobal, enabled: true)
    await session.setPauseReason(.systemSleep, enabled: true)
    XCTAssertEqual(session.snapshot().pauseReasons.count, 3)
    await session.setPauseReason(.userGlobal, enabled: false)
    await session.setPauseReason(.systemSleep, enabled: false)
    XCTAssertEqual(session.snapshot().state, .paused)
    XCTAssertEqual(session.search(.init(query: "needle")).freshness, .pausedStale)
    XCTAssertEqual(session.snapshot().pauseReasons, [.userVolume])
    await session.setPauseReason(.userVolume, enabled: false)
    waitFor("resume live") { session.snapshot().state == .live }
    await session.stop(policy: .fast)
    await session.setPauseReason(.systemSleep, enabled: false)
    XCTAssertEqual(session.snapshot().state, .offline)
  }
  func testResumeChangedHistoryRebuildsFromNewFence() throws {
    let tree = try TemporaryTree(); try tree.file("needle")
    let identity = MutableIdentity(try VolumeIdentity.discover(root: tree.root)), starts = ReplayStarts()
    let core = try UpdateCoordinator(root: tree.root,
      configuration: .init(fullRebuildMinInterval: 0, rebuildDebounceMilliseconds: 1),
      identityProvider: { _ in identity.get() }, fenceProvider: { _ in 200 },
      maintenanceScheduler: .init(), replayStarter: { [root = tree.root] id, sink in starts.record(id); sink([.init(path: root, flags: UInt32(kFSEventStreamEventFlagHistoryDone), id: id)]) })
    defer { core.stop() }; try core.start(); XCTAssertTrue(core.waitUntilLive())
    core.pause(); identity.replaceHistory(); try tree.file("new")
    try core.resume()
    waitFor("new history recovery") { core.metrics.snapshot()["full_rebuilds", default: 0] == 1 && core.currentState == .live }
    XCTAssertTrue(try core.verify().isConsistent)
    XCTAssertEqual(starts.cursors, [200, 200])
    XCTAssertEqual(core.metrics.snapshot()["rebuild_requests_resume_identity_changed"], 1)
  }
  func testGlobalPauseSurvivesRemountAndDoesNotClearVolumePause() async {
    let a = VolumeDescriptor(volumeUUID: UUID(), displayName: "A", mountPath: "/fixture", isSystemVolume: true)
    let b = VolumeDescriptor(volumeUUID: UUID(), displayName: "B", mountPath: "/Volumes/B")
    let provider = FakeVolumeProvider([a, b]), store = MemoryVolumeSelection([b.volumeUUID])
    let c = MultiVolumeCoordinator(provider: provider, selectionStore: store, maintenance:.init(), factory: { v, _ in FakeVolumeSession(v) })
    await c.start(); await c.setVolumePaused(b.volumeUUID, enabled: true)
    await c.setAllPaused(.userGlobal, enabled: true); await c.setAllPaused(.systemSleep, enabled: true)
    provider.values = [a]; await c.refreshMountedVolumes()
    provider.values = [a, b]; await c.refreshMountedVolumes()
    await c.setAllPaused(.systemSleep, enabled: false); await c.setAllPaused(.userGlobal, enabled: false)
    let states = await c.sessionsSnapshot()
    XCTAssertEqual(states.first { $0.id == a.volumeUUID }?.state, .live)
    XCTAssertEqual(states.first { $0.id == b.volumeUUID }?.pauseReasons, [.userVolume])
    await c.stop()
  }
}
