import CoreServices
import Foundation
import XCTest
@testable import APFSFindCore

final class ShutdownTests: XCTestCase, @unchecked Sendable {
  func testFastShutdownRecordsPhasesAndDrainsDeliveredNamespace() throws {
    let tree = try TemporaryTree(), cache = try TemporaryTree(cache:true)
    try tree.file("old")
    let c = try PersistentIndexCoordinator(root:tree.root,cacheDirectory:cache.root,maintenanceScheduler:.init(),
      replayStarter:{ [root=tree.root] id,sink in sink([.init(path:root,flags:UInt32(kFSEventStreamEventFlagHistoryDone),id:id)]) },fenceProvider:{ _ in 100 })
    try c.start(); XCTAssertTrue(c.waitUntilLive()); XCTAssertTrue(c.waitForCheckpoint())
    try tree.file("delivered")
    c.core.enqueue([.init(path:tree.path("delivered"),flags:UInt32(kFSEventStreamEventFlagItemCreated|kFSEventStreamEventFlagItemIsFile),id:101)])
    c.stop(policy:.fast)
    XCTAssertNotNil(c.index.entry(at:tree.path("delivered")))
    XCTAssertEqual(c.currentState,.stopped)
    let phases=c.shutdownMetrics.snapshot
    XCTAssertEqual(phases.count,10)
    XCTAssertTrue(phases.values.allSatisfy { $0>=0 })
    XCTAssertGreaterThan(phases["shutdown_total_ms",default:0],0)
    XCTAssertGreaterThan(phases["shutdown_namespace_drain_ms",default:0],0)
    c.stop(policy:.fast)
    XCTAssertEqual(c.shutdownMetrics.snapshot,phases)
  }
}
