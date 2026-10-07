import Foundation
import XCTest
@testable import APFSFindCore

final class ResourceSchedulerTests: XCTestCase, @unchecked Sendable {
  private func settle() async { for _ in 0..<200 { await Task.yield() }; try? await Task.sleep(for:.milliseconds(20)) }
  private func waitQueue(_ scheduler:MaintenanceScheduler,count:Int) async {
    for _ in 0..<200 { if await scheduler.snapshot().count == count { return }; try? await Task.sleep(for:.milliseconds(2)) }
    XCTFail("scheduler queue did not converge")
  }
  func testNoWorkSamplerSustainedIdleAndHysteresis() async throws {
    let signals = FakeResourceSignals(.init(timestamp:0,cpuIdleEWMA:0.8)), scheduler = MaintenanceScheduler(signals:signals), volume = UUID()
    XCTAssertFalse(signals.isSampling)
    let token = CancellationToken(), job = Task { try await scheduler.acquire(volumeID:volume,kind:.metadataBootstrap,urgency:.opportunistic,cancellation:token) }
    await waitQueue(scheduler,count:1); XCTAssertTrue(signals.isSampling)
    signals.update(.init(timestamp:9,cpuIdleEWMA:0.8)); await settle()
    var queue = await scheduler.snapshot(); XCTAssertNil(queue.first?.startedAt)
    signals.update(.init(timestamp:10,cpuIdleEWMA:0.8)); let lease = try await job.value
    signals.update(.init(timestamp:11,cpuIdleEWMA:0.2)); await settle(); XCTAssertNoThrow(try lease.checkpoint())
    signals.update(.init(timestamp:13,cpuIdleEWMA:0.2)); await settle(); XCTAssertThrowsError(try lease.checkpoint()) { XCTAssertTrue($0 is MaintenanceYield) }
    lease.release(); await waitQueue(scheduler,count:0); await settle(); XCTAssertFalse(signals.isSampling)
    XCTAssertEqual(signals.metrics.snapshot()["cpu_sampler_starts"],1); XCTAssertEqual(signals.metrics.snapshot()["cpu_sampler_stops"],1)
  }
  func testInteractionMemoryThermalAndLowPowerYield() async throws {
    var policy = MaintenancePolicy(); policy.idleSeconds = 0
    let signals = FakeResourceSignals(.init(timestamp:0,cpuIdleEWMA:1)), scheduler = MaintenanceScheduler(signals:signals,policy:policy)
    let lease = try await scheduler.acquire(volumeID:UUID(),kind:.compaction,urgency:.opportunistic,cancellation:.init())
    for value in [ResourceSnapshot(timestamp:1,memoryPressure:.warning,cpuIdleEWMA:1),
      .init(timestamp:2,memoryPressure:.critical,cpuIdleEWMA:1), .init(timestamp:3,cpuIdleEWMA:1,thermalState:.serious),
      .init(timestamp:4,cpuIdleEWMA:1,lowPowerMode:true), .init(timestamp:5,cpuIdleEWMA:1,activeQueries:1),
      .init(timestamp:6,cpuIdleEWMA:1,lastInteractionAge:2)] {
      signals.update(value); await settle(); XCTAssertThrowsError(try lease.checkpoint())
    }
    signals.update(.init(timestamp:20,cpuIdleEWMA:1)); await settle(); XCTAssertNoThrow(try lease.checkpoint())
    lease.release(); await waitQueue(scheduler,count:0)
  }
  func testBusyRequiredEmergencyPriorityAndCancellation() async throws {
    let signals = FakeResourceSignals(.init(timestamp:0,cpuIdleEWMA:0.05,thermalState:.serious,lowPowerMode:true)), scheduler = MaintenanceScheduler(signals:signals), volume = UUID()
    let token = CancellationToken(), ordinary = Task { try await scheduler.acquire(volumeID:volume,kind:.compaction,urgency:.opportunistic,cancellation:token) }
    await waitQueue(scheduler,count:1)
    let required = try await scheduler.acquire(volumeID:volume,kind:.rebuild,urgency:.required,cancellation:.init())
    XCTAssertEqual(required.workerLimit,1); XCTAssertNoThrow(try required.checkpoint())
    signals.update(.init(timestamp:1,memoryPressure:.critical,cpuIdleEWMA:0.05)); await settle()
    XCTAssertThrowsError(try required.checkpoint()); required.release(); await settle()
    let emergency = try await scheduler.acquire(volumeID:volume,kind:.compaction,urgency:.emergency,cancellation:.init())
    XCTAssertNoThrow(try emergency.checkpoint()); let state = await scheduler.operatingState(volumeID:volume); XCTAssertEqual(state,.emergency)
    token.cancel(); do { _ = try await ordinary.value; XCTFail("cancelled task ran") } catch {}
    emergency.release(); await waitQueue(scheduler,count:0); await settle(); XCTAssertFalse(signals.isSampling)
  }
  func testCheckpointDiscardsStagingPreservesOldBaseAndOverlay() async throws {
    let cache = try TemporaryTree(cache:true), identity = snapshotIdentity(), ram = sampleSnapshotIndex()
    let store = try SnapshotStore(directory:cache.root,identity:identity)
    _ = try SnapshotV2Writer.write(source:.ram(ram,ram.stats().generation),identity:identity,generation:ram.stats().generation,cursor:1,store:store)
    let old = try Data(contentsOf:URL(fileURLWithPath:store.path)), hybrid = HybridIndex(base:try store.reader(expectedIdentity:identity).mappedBase!)
    hybrid.apply([.upsert(.init(path:identity.root+"/new",kind:.file))]); let capture = hybrid.capture()!
    var policy = MaintenancePolicy(); policy.idleSeconds = 0
    let signals = FakeResourceSignals(), scheduler = MaintenanceScheduler(signals:signals,policy:policy)
    let lease = try await scheduler.acquire(volumeID:identity.volumeUUID,kind:.compaction,urgency:.opportunistic,cancellation:.init())
    signals.update(.init(memoryPressure:.critical,cpuIdleEWMA:1)); await settle()
    XCTAssertThrowsError(try SnapshotV2Writer.write(source:.hybrid(capture),identity:identity,generation:capture.generation,cursor:2,store:store,checkpoint:{try lease.checkpoint()}))
    XCTAssertEqual(old,try Data(contentsOf:URL(fileURLWithPath:store.path))); XCTAssertNotNil(hybrid.entry(at:identity.root+"/new"))
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:cache.root).contains { $0.hasSuffix(".tmp") }); lease.release()
  }
  func testHardOverlayLimitCannotGrowDuringBusyCPU() throws {
    let cache = try TemporaryTree(cache:true), identity = snapshotIdentity(), ram = sampleSnapshotIndex(), store = try SnapshotStore(directory:cache.root,identity:identity)
    _ = try SnapshotV2Writer.write(source:.ram(ram,ram.stats().generation),identity:identity,generation:ram.stats().generation,cursor:1,store:store)
    let base = try store.reader(expectedIdentity:identity).mappedBase!, hybrid = HybridIndex(base:base,maximumOverlayEntries:32)
    hybrid.apply((0..<1000).map { .upsert(.init(path:identity.root+"/n\($0)",kind:.file)) })
    XCTAssertTrue(hybrid.requiresRecovery); XCTAssertEqual(hybrid.capture()?.delta.count,32)
    XCTAssertNotNil(hybrid.entry(at:identity.root+"/link")); hybrid.install(base:base); XCTAssertFalse(hybrid.requiresRecovery)
  }
  func testDynamicQueuePressureUnblocksAfterStormWithoutAnotherMutation() async throws {
    let signals = FakeResourceSignals(.init(timestamp:0,cpuIdleEWMA:1)), scheduler = MaintenanceScheduler(signals:signals), volume = UUID()
    let pressure = QueuePressureBox()
    scheduler.registerPressure(volumeID:volume) { pressure.current() }
    let token = CancellationToken(), job = Task { try await scheduler.acquire(volumeID:volume,kind:.compaction,urgency:.opportunistic,cancellation:token) }
    await waitQueue(scheduler,count:1)
    signals.update(.init(timestamp:11,cpuIdleEWMA:1)); await settle()
    let before = await scheduler.snapshot(); XCTAssertNil(before.first?.startedAt)
    pressure.clear(); signals.update(.init(timestamp:12,cpuIdleEWMA:1))
    let lease = try await job.value; XCTAssertNoThrow(try lease.checkpoint()); lease.release()
    await waitQueue(scheduler,count:0); scheduler.unregisterPressure(volumeID:volume)
  }
  func testScanResourceYieldIsNotAnUnreadableDirectory() throws {
    let tree = try TemporaryTree(); try tree.directory("x"); try tree.file("x/needle")
    let scanner = BulkScanner(root:tree.root,checkpoint:{throw MaintenanceYield(reason:"critical")})
    XCTAssertThrowsError(try scanner.scan()) { XCTAssertTrue($0 is MaintenanceYield) }
  }
}

private final class QueuePressureBox: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 1000
  func current()->InternalResourcePressure { lock.withLock { var result = InternalResourcePressure(); result.eventQueueDepth = count; return result } }
  func clear() { lock.withLock { count = 0 } }
}
