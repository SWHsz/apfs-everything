import Foundation
import XCTest
@testable import APFSFindCore

final class MaintenanceClosureTests:XCTestCase,@unchecked Sendable {
  func testCancellationOfEveryQueuedAndRunningKind() async throws {
    let scheduler=MaintenanceScheduler(),volume=UUID()
    for kind in [MaintenanceKind.coldScan,.rebuild,.compaction,.metadataBootstrap,.metadataCheckpoint] {
      let runningToken=CancellationToken()
      let lease=try await scheduler.acquire(volumeID:volume,kind:kind,cancellation:runningToken)
      let queuedToken=CancellationToken()
      let queued=Task {try await scheduler.acquire(volumeID:volume,kind:kind,cancellation:queuedToken)}
      for _ in 0..<100 {if await scheduler.snapshot().count==2 {break};try await Task.sleep(for:.milliseconds(2))}
      queuedToken.cancel()
      do {_=try await queued.value;XCTFail("queued task started")} catch {}
      runningToken.cancel();XCTAssertThrowsError(try lease.checkpoint())
      lease.release()
      for _ in 0..<100 {if await scheduler.snapshot().isEmpty {break};try await Task.sleep(for:.milliseconds(2))}
      let tasks=await scheduler.snapshot();XCTAssertTrue(tasks.isEmpty)
    }
    XCTAssertEqual(scheduler.telemetry.snapshot.filter{$0["termination_reason"] as? String=="cancelled"}.count,5)
  }
  func testYieldNoProgressBackoffAndCompletedConvergence() async throws {
    var policy=MaintenancePolicy();policy.idleSeconds=0;policy.quietSeconds=0
    let signals=FakeResourceSignals(.init(timestamp:0,cpuIdleEWMA:1)),scheduler=MaintenanceScheduler(signals:signals,policy:policy),volume=UUID()
    let lease=try await scheduler.acquire(volumeID:volume,kind:.metadataBootstrap,urgency:.opportunistic,cancellation:.init())
    signals.update(.init(timestamp:1,cpuIdleEWMA:1,activeQueries:1))
    XCTAssertThrowsError(try lease.checkpoint());lease.release()
    for _ in 0..<100 {if await scheduler.snapshot().isEmpty {break};try await Task.sleep(for:.milliseconds(2))}
    let record=try XCTUnwrap(scheduler.telemetry.snapshot.last)
    XCTAssertEqual(record["no_progress"] as? Bool,true)
    XCTAssertEqual(MaintenanceTelemetry.retryDelay(attempt:1),1)
    XCTAssertEqual(MaintenanceTelemetry.retryDelay(attempt:2),2)
    XCTAssertEqual(MaintenanceTelemetry.retryDelay(attempt:30),30)
    signals.update(.init(timestamp:2,cpuIdleEWMA:1))
    let begin=ProcessInfo.processInfo.systemUptime
    let next=try await scheduler.acquire(volumeID:volume,kind:.metadataBootstrap,urgency:.opportunistic,cancellation:.init())
    XCTAssertGreaterThan(ProcessInfo.processInfo.systemUptime-begin,0.8)
    next.recordCompletion();next.release()
    for _ in 0..<100 {if await scheduler.snapshot().isEmpty {break};try await Task.sleep(for:.milliseconds(2))}
    XCTAssertFalse(signals.isSampling)
    let counters=await scheduler.metrics.snapshot()
    XCTAssertEqual(counters["maintenance_retry_timer",default:0],0)
    XCTAssertEqual(scheduler.telemetry.snapshot.last?["termination_reason"] as? String,"completed")
  }
  func testRepeatedSameAttemptWorkIsReportedAsNoProgress() {
    let telemetry=MaintenanceTelemetry(),metrics=Metrics(),volume=UUID()
    telemetry.register(volume:volume,metrics:metrics)
    for i in 0..<2 {
      let id=UUID(),now=ProcessInfo.processInfo.systemUptime
      telemetry.start(.init(id:id,volumeID:volume,kind:.metadataBootstrap,queuedAt:now,startedAt:now,urgency:.opportunistic))
      metrics.record("scanner_entries",by:10)
      telemetry.reason(id,"yield:interactive");_ = telemetry.finish(id)
      XCTAssertEqual(telemetry.snapshot.last?["no_progress"] as? Bool,i==1)
    }
  }
  func testCancelledReconcileDiscardsPartialPlan() throws {
    let tree=try TemporaryTree(),token=CancellationToken(),index=FileIndex(root:tree.root)
    let reader=CancellingReader(root:tree.root,token:token)
    let plan=DirectoryReconciler(scanner:reader,index:index,rootDeviceID:1,metrics:.init()).prepare(tree.root,subtree:true,force:true,cancellation:token)
    XCTAssertTrue(plan.cancelled);XCTAssertTrue(plan.mutations.isEmpty)
  }
}
private final class CancellingReader:DirectoryReading {
  let root:String,token:CancellationToken
  init(root:String,token:CancellationToken){self.root=root;self.token=token}
  func readDirectory(_ path:String,rootDeviceID:UInt64,cancellation:CancellationToken)throws->[NamespaceEntry] {
    token.cancel();return [.init(path:root+"/partial",kind:.directory,deviceID:1)]
  }
}
