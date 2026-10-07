import Foundation
import CoreServices
import XCTest
@testable import APFSFindCore

final class EngineUsabilityTests: XCTestCase, @unchecked Sendable {
  private let create = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
  private let content = UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)
  private let history = UInt32(kFSEventStreamEventFlagHistoryDone)
  func testWarmReadyAndFreshnessBeforeHistoryDone() throws {
    let tree = try TemporaryTree(); try tree.file("needle")
    let volume = try VolumeIdentity.discover(root: tree.root)
    let ram = FileIndex(root: tree.root)
    ram.apply([.upsert(.init(path: tree.path("needle"), kind: .file))])
    let core = try UpdateCoordinator(root: tree.root, maintenanceScheduler: .init(), replayStarter: { _, _ in })
    defer { core.stop() }
    try core.start(restored: ram, cursor: 100, identity: volume)
    XCTAssertTrue(core.readinessSnapshot().searchAvailable)
    XCTAssertEqual(core.search(.init(query: "needle")).freshness, .catchingUp)
    XCTAssertEqual(core.search(.init(query: "needle")).hits.count, 1)
    XCTAssertFalse(core.startupStatus().historyDone)
    core.enqueue([.init(path: tree.root, flags: history, id: 101)])
    core.synchronizeWriter(); XCTAssertTrue(core.flushEvents())
    XCTAssertEqual(core.readinessSnapshot().state, .live)
    XCTAssertEqual(core.search(.init(query: "needle")).freshness, .live)
    core.stop(); XCTAssertFalse(core.readinessSnapshot().searchAvailable)
  }
  func testReplayFloorSkipsOldNamespaceButAppliesNewAndSpecial() throws {
    let tree = try TemporaryTree(); try tree.file("old"); try tree.file("new")
    let ram = FileIndex(root: tree.root)
    ram.apply([.upsert(.init(path: tree.path("old"), kind: .file))])
    let core = try UpdateCoordinator(root: tree.root, maintenanceScheduler: .init(), replayStarter: { _, _ in })
    defer { core.stop() }
    try core.start(restored: ram, cursor: 100)
    let generation = core.index.stats().generation
    core.enqueue([
      .init(path: tree.path("old"), flags: create, id: 99),
      .init(path: tree.path("old"), flags: UInt32(kFSEventStreamEventFlagItemRemoved), id: 100),
      .init(path: tree.path("old"), flags: UInt32(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsFile), id: 98)])
    XCTAssertTrue(core.flushEvents())
    XCTAssertEqual(core.index.stats().generation, generation)
    XCTAssertEqual(core.metrics.snapshot()["replay_overlap_events_skipped"], 3)
    core.enqueue([.init(path: tree.path("new"), flags: create, id: 101),
                  .init(path: tree.root, flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs), id: 1),
                  .init(path: tree.root, flags: history, id: 102)])
    XCTAssertTrue(core.flushEvents())
    XCTAssertNotNil(core.index.entry(at: tree.path("new")))
    XCTAssertTrue(try core.verify().isConsistent)
    XCTAssertGreaterThan(core.metrics.snapshot()["replay_special_events_applied", default: 0], 0)
  }
  func testSpecialOldInvalidationsNeverSkippedAndOldBaseSearchable() throws {
    for flag in [kFSEventStreamEventFlagUserDropped, kFSEventStreamEventFlagKernelDropped,
                 kFSEventStreamEventFlagEventIdsWrapped, kFSEventStreamEventFlagRootChanged] {
      let tree = try TemporaryTree(); try tree.file("old")
      let ram = FileIndex(root: tree.root); ram.apply([.upsert(.init(path: tree.path("old"), kind: .file))])
      let core = try UpdateCoordinator(root: tree.root, configuration: .init(rebuildDebounceMilliseconds: 5000), maintenanceScheduler: .init(), replayStarter: { _, _ in })
      defer { core.stop() }
      try core.start(restored: ram, cursor: 100)
      core.enqueue([.init(path: tree.root, flags: UInt32(flag), id: 1)])
      XCTAssertTrue(core.flushEvents())
      XCTAssertEqual(core.readinessSnapshot().state, .rebuildingUsingOldBase)
      XCTAssertEqual(core.search(.init(query: "old")).hits.count, 1)
      XCTAssertEqual(core.metrics.snapshot()["replay_overlap_events_skipped", default: 0], 0)
    }
  }
  func testColdInstallReadyWithoutHistoryDoneAndUnknownIDApplied() throws {
    let tree = try TemporaryTree(); let cache = try TemporaryTree(cache: true)
    try tree.file("seed")
    let p = try PersistentIndexCoordinator(root: tree.root, cacheDirectory: cache.root, maintenanceScheduler: .init(), replayStarter: { _, _ in })
    defer { p.stop(policy: .fast) }; try p.start()
    XCTAssertTrue(p.readinessSnapshot().searchAvailable)
    XCTAssertEqual(p.search("seed").hits.count, 1)
    try tree.file("unknown")
    p.core.enqueue([.init(path: tree.path("unknown"), flags: create, id: 0)])
    XCTAssertTrue(p.core.flushEvents()); XCTAssertEqual(p.search("unknown").hits.count, 1)
  }
  func testFastExitLeavesBaseAndConservativeCursorThenRestartRecovers() throws {
    try requireFSEvents()
    let tree = try TemporaryTree(); let cache = try TemporaryTree(cache: true)
    for i in 0..<100 { try tree.file("old-\(i)") }
    let p = try PersistentIndexCoordinator(root: tree.root, cacheDirectory: cache.root, maintenanceScheduler: .init())
    try p.start(); XCTAssertTrue(p.waitUntilLive()); XCTAssertTrue(p.waitForCheckpoint())
    let volume = try VolumeIdentity.discover(root: tree.root)
    let store = try SnapshotStore(directory: cache.root, identity: volume)
    let bytes = try Data(contentsOf: URL(fileURLWithPath: store.path))
    let before = try store.reader(expectedIdentity: volume).header
    for i in 0..<100 { try FileManager.default.moveItem(atPath: tree.path("old-\(i)"), toPath: tree.path("new-\(i)")) }
    try tree.file("created")
    waitFor("rename replay") { p.index.entry(at: tree.path("new-99")) != nil && p.index.entry(at: tree.path("created")) != nil }
    let started = ProcessInfo.processInfo.systemUptime; p.stop(policy: .fast)
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.5)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: store.path)), bytes)
    XCTAssertEqual(store.effectiveCursor(for: before).cursor, before.lastProcessedEventID)
    let warm = try PersistentIndexCoordinator(root: tree.root, cacheDirectory: cache.root, maintenanceScheduler: .init())
    defer { warm.stop(policy: .fast) }; try warm.start(); XCTAssertTrue(warm.waitUntilLive())
    XCTAssertTrue(try warm.verify().isConsistent)
    XCTAssertEqual(warm.metrics.snapshot()["full_scans", default: 0], 0)
  }
  func testContentCursorFastExitWritesBoundStateOnly() throws {
    let tree = try TemporaryTree(); let cache = try TemporaryTree(cache: true); try tree.file("seed")
    let p = try PersistentIndexCoordinator(root: tree.root, cacheDirectory: cache.root, maintenanceScheduler: .init(), replayStarter: { _, sink in sink([.init(path: "/", flags: UInt32(kFSEventStreamEventFlagHistoryDone))]) })
    try p.start(); XCTAssertTrue(p.waitUntilLive())
    let volume = try VolumeIdentity.discover(root: tree.root), store = try SnapshotStore(directory: cache.root, identity: volume)
    let bytes = try Data(contentsOf: URL(fileURLWithPath: store.path)), header = try store.reader(expectedIdentity: volume).header
    p.core.enqueue([.init(path: tree.path("seed"), flags: content, id: header.lastProcessedEventID + 1)])
    XCTAssertTrue(p.core.flushEvents()); p.stop(policy: .fast)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: store.path)), bytes)
    XCTAssertEqual(store.effectiveCursor(for: header).cursor, header.lastProcessedEventID + 1)
  }
  func testEventSchedulerReschedulesStopsAndHasNoIdleWork() throws {
    let metrics = Metrics(), scheduler = CompactionScheduler(metrics: Metrics())
    XCTAssertEqual(scheduler.currentState, .idle)
    XCTAssertEqual(scheduler.metrics.snapshot()["compaction_scheduler_wakeups", default: 0], 0)
    let done = expectation(description: "quiet work")
    scheduler.schedule(delay: 0.03) { metrics.record("calls") }
    scheduler.schedule(delay: 0.03) { metrics.record("calls"); done.fulfill() }
    wait(for: [done], timeout: 1)
    XCTAssertEqual(metrics.snapshot()["calls"], 1)
    scheduler.schedule(delay: 0.03, safety: true) { metrics.record("calls") }
    scheduler.stop(); Thread.sleep(forTimeInterval: 0.06)
    XCTAssertEqual(metrics.snapshot()["calls"], 1)
    XCTAssertEqual(scheduler.metrics.snapshot()["compaction_schedule_reschedules"], 1)
    XCTAssertEqual(scheduler.metrics.snapshot()["compaction_schedule_cancelled"], 1)
  }
  func testSchedulerSafetyAndRetryBackoff() {
    let scheduler = CompactionScheduler()
    let fired = expectation(description: "immediate safety work")
    scheduler.schedule(delay: 0, safety: true) { fired.fulfill() }
    wait(for: [fired], timeout: 1)
    XCTAssertEqual(scheduler.metrics.snapshot()["compaction_safety_triggered"], 1)
    scheduler.schedule(delay: 30, backoff: true) { XCTFail("cancelled retry executed") }
    XCTAssertEqual(scheduler.currentState, .backoff)
    scheduler.stop()
    XCTAssertEqual(scheduler.currentState, .stopped)
  }
  func testMaintenanceSerialFIFOAndQueuedCancellation() async throws {
    let scheduler = MaintenanceScheduler(), a = UUID(), b = UUID()
    let first = try await scheduler.acquire(volumeID: a, kind: .coldScan, cancellation: .init())
    let token = CancellationToken()
    let second = Task { try await scheduler.acquire(volumeID: b, kind: .compaction, cancellation: token) }
    for _ in 0..<100 { if await scheduler.snapshot().count == 2 { break }; await Task.yield() }
    let queued = await scheduler.snapshot()
    XCTAssertEqual(queued.count, 2)
    token.cancel()
    do { _ = try await second.value; XCTFail("cancelled queue ran") } catch {}
    first.release()
    let third = try await scheduler.acquire(volumeID: b, kind: .rebuild, cancellation: .init())
    let running = await scheduler.snapshot()
    XCTAssertEqual(running.count, 1); third.release()
  }
  func testMaintenancePriorityThenFIFO() async throws {
    let scheduler = MaintenanceScheduler()
    let first = try await scheduler.acquire(volumeID: UUID(), kind: .coldScan, cancellation: .init())
    let low = Task { try await scheduler.acquire(volumeID: UUID(), kind: .compaction, cancellation: .init()) }
    for _ in 0..<1000 { if await scheduler.snapshot().count == 2 { break }; await Task.yield() }
    let high = Task { try await scheduler.acquire(volumeID: UUID(), kind: .rebuild, priority: 1, cancellation: .init()) }
    for _ in 0..<1000 { if await scheduler.snapshot().count == 3 { break }; await Task.yield() }
    let queued = await scheduler.snapshot(); XCTAssertEqual(queued.count, 3)
    first.release()
    let priorityLease = try await high.value
    let running = await scheduler.snapshot()
    XCTAssertEqual(running.first?.kind, .rebuild); XCTAssertEqual(running.count, 2)
    priorityLease.release()
    let last = try await low.value
    let final = await scheduler.snapshot(); XCTAssertEqual(final.first?.kind, .compaction)
    last.release()
  }
  func testThresholdShutdownOnlyCompactsAtThreshold() throws {
    for reached in [false, true] {
      let tree = try TemporaryTree(), cache = try TemporaryTree(cache: true)
      var policy = CompactionPolicy(); policy.liveLimit = reached ? 1 : 1000
      policy.quietSeconds = 3600; policy.overlayRatio = 2; policy.tombstoneRatio = 2
      let p = try PersistentIndexCoordinator(root: tree.root, cacheDirectory: cache.root,
        compactionPolicy: policy, maintenanceScheduler: .init(), replayStarter: { _, sink in sink([.init(path: "/", flags: UInt32(kFSEventStreamEventFlagHistoryDone))]) })
      try p.start(); XCTAssertTrue(p.waitUntilLive())
      p.index.apply([.upsert(.init(path: tree.path("change"), kind: .file))])
      p.stop(policy: .compactIfThresholdReached)
      XCTAssertEqual(p.metrics.snapshot()["compactions", default: 0], reached ? 1 : 0)
    }
  }
  func testOverlayCancellationAndPersistentReadinessStreamMode() async throws {
    let tree = try TemporaryTree(), cache = try TemporaryTree(cache: true)
    let p = try PersistentIndexCoordinator(root: tree.root, cacheDirectory: cache.root, maintenanceScheduler: .init(), replayStarter: { _, _ in })
    defer { p.stop(policy: .fast) }; try p.start()
    var iterator = p.readinessStream().makeAsyncIterator()
    let status = await iterator.next()
    XCTAssertEqual(status?.startupMode, .coldScan); XCTAssertEqual(status?.searchAvailable, true)
    p.index.apply((0..<5000).map { .upsert(.init(path: tree.path("delta-\($0)"), kind: .file)) })
    let token = SearchCancellationToken(); token.cancel()
    XCTAssertTrue(p.search(.init(query: "delta", cancellation: token)).cancelled)
    XCTAssertEqual(p.search("delta", limit: 3).hits.count, 3)
  }
  private func awaitCount(_ values: [MaintenanceTaskSnapshot]) -> Int { values.count }
  func testMillionRecordBaseCancellationKeepsWriterAndMappingSafe() throws {
    let cache = try TemporaryTree(cache: true), v = snapshotIdentity()
    let store = try SnapshotStore(directory: cache.root, identity: v), ram = FileIndex(root: v.root)
    for batch in 0..<100 {
      ram.apply((0..<10_000).map { .upsert(.init(path: v.root + "/a-\(batch * 10_000 + $0)", kind: .file)) })
    }
    _ = try SnapshotV2Writer.write(source: .ram(ram, ram.stats().generation), identity: v,
                                   generation: ram.stats().generation, cursor: 1, store: store)
    let index = HybridIndex(base: try XCTUnwrap(store.reader(expectedIdentity: v).mappedBase))
    let token = SearchCancellationToken(), done = expectation(description: "cancelled")
    DispatchQueue.global().async {
      let result = index.search(.init(id: 1, query: "a", cancellation: token))
      XCTAssertTrue(result.cancelled); done.fulfill()
    }
    Thread.sleep(forTimeInterval: 0.001); token.cancel()
    let started = ProcessInfo.processInfo.systemUptime
    index.apply([.upsert(.init(path: v.root + "/writer", kind: .file))])
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.1)
    wait(for: [done], timeout: 1)
    XCTAssertLessThan(index.metrics.snapshot()["search_records_scanned_before_cancel", default: 1_000_000], 1_000_000)
    XCTAssertEqual(index.search("writer").hits.first?.path, v.root + "/writer")
  }
}
