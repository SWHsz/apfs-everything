import Foundation
import XCTest
@testable import APFSFindCore

final class StreamingBuildMaintenanceTests:XCTestCase {
  func testThermalYieldResumesSameBuild() throws {
    let signals=FakeResourceSignals(),scheduler=MaintenanceScheduler(signals:signals),metrics=Metrics(),token=CancellationToken()
    let session=try StreamingBuildMaintenance(scheduler:scheduler,volume:UUID(),kind:.rebuild,cancellation:token,metrics:metrics,identityCheck:{},changed:{_ in})
    defer {session.release()}
    signals.update(.init(thermalState:.serious))
    let done=DispatchSemaphore(value:0),failure=CancellationToken()
    DispatchQueue.global().async {do {try session.checkpoint()} catch {failure.cancel()};done.signal()}
    waitFor("thermal yield") {metrics.snapshot()["streaming_build_resumes",default:0]>0}
    XCTAssertEqual(done.wait(timeout:.now()+0.02),.timedOut)
    signals.update(.init(cpuIdleEWMA:1))
    XCTAssertEqual(done.wait(timeout:.now()+3),.success);XCTAssertFalse(failure.isCancelled)
  }
  func testOpportunisticBuildWaitsForCPUAndLowPower() throws {
    let signals=FakeResourceSignals(.init(timestamp:0,cpuIdleEWMA:0.05,lowPowerMode:true))
    var policy=MaintenancePolicy();policy.idleSeconds=0
    let scheduler=MaintenanceScheduler(signals:signals,policy:policy),token=CancellationToken(),done=DispatchSemaphore(value:0),failure=CancellationToken()
    DispatchQueue.global().async {
      do {
        let session=try StreamingBuildMaintenance(scheduler:scheduler,volume:UUID(),kind:.coldScan,cancellation:token,metrics:.init(),urgency:.opportunistic,identityCheck:{},changed:{_ in})
        session.release()
      } catch {failure.cancel()};done.signal()
    }
    waitFor("resource sampler active") {signals.isSampling}
    XCTAssertEqual(done.wait(timeout:.now()+0.02),.timedOut)
    signals.update(.init(timestamp:1,cpuIdleEWMA:1,lowPowerMode:true))
    XCTAssertEqual(done.wait(timeout:.now()+0.02),.timedOut)
    signals.update(.init(timestamp:2,cpuIdleEWMA:1))
    XCTAssertEqual(done.wait(timeout:.now()+3),.success);XCTAssertFalse(failure.isCancelled)
    waitFor("sampler stops with no work") {!signals.isSampling}
  }
}
