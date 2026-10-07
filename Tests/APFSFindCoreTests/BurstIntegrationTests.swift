import Foundation
import XCTest
@testable import APFSFindCore

final class BurstIntegrationTests: XCTestCase {
    func testThousandFileBurstAndDeletionAgreeWithFreshScan() throws {
        try requireFSEvents()
        let tree = try TemporaryTree()
        try tree.directory("burst")
        let coordinator = try UpdateCoordinator(root: tree.root, maintenanceScheduler: .init())
        defer { coordinator.stop() }
        try coordinator.start()
        XCTAssertTrue(coordinator.waitUntilLive())
        for i in 0..<1000 { try tree.file("burst/file-\(i)") }
        waitFor("1000 file burst converges", timeout: 10) { coordinator.index.stats().files == 1000 }
        XCTAssertTrue(coordinator.flushEvents())
        XCTAssertTrue(try coordinator.verify().isConsistent)
        try FileManager.default.removeItem(atPath: tree.path("burst"))
        waitFor("burst subtree deletion converges", timeout: 10) { coordinator.index.snapshotPaths() == [tree.root] }
        XCTAssertTrue(try coordinator.verify().isConsistent)
    }
}
