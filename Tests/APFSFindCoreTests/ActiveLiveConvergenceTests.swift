import XCTest
@testable import APFSFindCore

final class ActiveLiveConvergenceTests: XCTestCase {
    private func sample(_ events: Int, backlog: Int = 0, dirty: Int = 0, scans: Int = 0) -> ActiveLiveSample {
        .init(received: events, processed: events-backlog, eventBacklog: backlog, dirtyBacklog: dirty,
              fullScans: scans, resourceYieldRebuilds: 0, recoveryYields: 0, physicalBytes: 80*1024*1024)
    }
    func testActiveTrafficIsAllowedButGrowingBacklogAndScanAreFailures() {
        var gate = ActiveLiveConvergenceGate(baseline: sample(0))
        for i in 1...20 { gate.observe(sample(i*100, backlog: i%3, dirty: i%4)) }
        XCTAssertTrue(gate.blockers.isEmpty)
        for i in 21...35 { gate.observe(sample(i*100, backlog: i, dirty: i)) }
        XCTAssertTrue(gate.blockers.contains("monotonic backlog growth"))
        gate.observe(sample(4000, scans: 1))
        XCTAssertTrue(gate.blockers.contains("full scan during active window"))
    }
}
