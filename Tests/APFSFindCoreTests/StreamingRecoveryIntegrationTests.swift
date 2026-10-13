import CoreServices
import Darwin
import Foundation
import XCTest
@testable import APFSFindCore

final class StreamingRecoveryIntegrationTests:XCTestCase {
  func testColdFenceReplaysMutationsAfterSealedEnumeration() throws {
    try requireFSEvents()
    let tree=try TemporaryTree(),cache=try TemporaryTree(cache:true),root=tree.root
    try tree.file("delete");try tree.file("rename");try tree.file("contents")
    let c=try PersistentIndexCoordinator(root:root,cacheDirectory:cache.root,maintenanceScheduler:.init(),streamingBuildFault:{point,_ in
      if point == .afterSections {
        try FileManager.default.removeItem(atPath:root+"/delete")
        try FileManager.default.moveItem(atPath:root+"/rename",toPath:root+"/renamed")
        try Data().write(to:URL(fileURLWithPath:root+"/create"))
        let fd=open(root+"/contents",O_WRONLY|O_CLOEXEC)
        guard fd>=0 else {throw SnapshotError.io("test open",errno)}
        defer {close(fd)};guard ftruncate(fd,54321)==0 else {throw SnapshotError.io("test truncate",errno)}
      }
    })
    defer {c.stop(policy:.fast)}
    try c.start();XCTAssertTrue(c.waitUntilLive())
    waitFor("streaming scan fence catches mutations",timeout:15) {
      c.index.entry(at:root+"/delete")==nil && c.index.entry(at:root+"/rename")==nil &&
      c.index.entry(at:root+"/create") != nil && c.index.entry(at:root+"/renamed") != nil &&
      c.metadata.capture().value(path:root+"/contents").logicalSize==54321
    }
    XCTAssertEqual(c.metrics.snapshot()["full_scans"],1)
    XCTAssertEqual(c.metrics.snapshot()["streaming_builds"],1)
    XCTAssertEqual(c.metrics.snapshot()["scanner_scanned_collected_entries_max",default:0],0)
    XCTAssertEqual(c.metrics.snapshot()["initial_index_entries",default:0],0)
    XCTAssertTrue(try c.verify().isConsistent)
  }
  func testRecoveryKeepsCapturedOldBaseQueryableAndRestartsWithoutScan() throws {
    try requireFSEvents()
    let tree=try TemporaryTree(),cache=try TemporaryTree(cache:true),root=tree.root,gate=StreamingRecoveryGate()
    try tree.file("kept");try tree.file("deleted")
    let c=try PersistentIndexCoordinator(root:root,configuration:.init(fullRebuildMinInterval:0),cacheDirectory:cache.root,
      maintenanceScheduler:.init(),streamingBuildFault:{point,_ in if point == .afterSections {try gate.check()}})
    try c.start();XCTAssertTrue(c.waitUntilLive())
    let old=try XCTUnwrap((c.index as? HybridIndex)?.immutableBase),uuid=old.header.snapshotUUID
    gate.arm();c.rebuild();XCTAssertEqual(gate.entered.wait(timeout:.now()+10),.success)
    XCTAssertEqual(c.currentState,.rebuilding);XCTAssertEqual(c.search("kept").hits.count,1)
    XCTAssertEqual((c.index as? HybridIndex)?.immutableBase?.header.snapshotUUID,uuid)
    try tree.file("during");try FileManager.default.removeItem(atPath:root+"/deleted")
    try FileManager.default.moveItem(atPath:root+"/kept",toPath:root+"/renamed")
    gate.resume.signal()
    waitFor("recovery replay returns live",timeout:15) {c.currentState == .live && c.metrics.snapshot()["full_rebuilds"]==1}
    // HistoryDone finishes historical replay, but recent filesystem mutations
    // can still be in FSEvents' live delivery latency window. Assert their
    // actual convergence before verifying or persisting the restart cursor.
    waitFor("recovery fence catches concurrent mutations",timeout:15) {
      c.index.entry(at:root+"/deleted")==nil && c.index.entry(at:root+"/kept")==nil &&
      c.index.entry(at:root+"/during") != nil && c.index.entry(at:root+"/renamed") != nil
    }
    XCTAssertTrue(try c.verify().isConsistent)
    XCTAssertEqual(c.metrics.snapshot()["full_scans"],2);XCTAssertEqual(c.metrics.snapshot()["streaming_builds"],2)
    XCTAssertEqual(try old.name(at:1),"deleted") // pinned inode remains valid after publication
    XCTAssertNotEqual((c.index as? HybridIndex)?.immutableBase?.header.snapshotUUID,uuid)
    XCTAssertNotNil(c.index.entry(at:root+"/during"));XCTAssertNotNil(c.index.entry(at:root+"/renamed"))
    c.stop(policy:.fast)
    let next=try PersistentIndexCoordinator(root:root,cacheDirectory:cache.root,maintenanceScheduler:.init())
    defer {next.stop(policy:.fast)}
    try next.start();XCTAssertTrue(next.waitUntilLive());XCTAssertTrue(try next.verify().isConsistent)
    XCTAssertEqual(next.metrics.snapshot()["full_scans",default:0],0)
  }
  func testYieldRetainsSameWorkspaceAndFence() throws {
    let tree=try TemporaryTree(),cache=try TemporaryTree(cache:true),root=tree.root,signals=FakeResourceSignals(),gate=StreamingRecoveryGate()
    try tree.file("kept")
    let c=try PersistentIndexCoordinator(root:root,configuration:.init(fullRebuildMinInterval:0),cacheDirectory:cache.root,
      maintenanceScheduler:MaintenanceScheduler(signals:signals),replayStarter:{id,deliver in deliver([.init(path:root,flags:UInt32(kFSEventStreamEventFlagHistoryDone),id:id)])},
      fenceProvider:{_ in 7},streamingBuildFault:{point,_ in if point == .afterSections {try gate.check()}})
    defer {gate.resume.signal();c.stop(policy:.fast)}
    try c.start();XCTAssertTrue(c.waitUntilLive());gate.arm();c.rebuild()
    XCTAssertEqual(gate.entered.wait(timeout:.now()+10),.success)
    let directories=try FileManager.default.contentsOfDirectory(atPath:cache.root).filter {$0.hasPrefix(".build-")}
    XCTAssertEqual(directories.count,1)
    signals.update(.init(activeQueries:1));gate.resume.signal()
    waitFor("builder lease yielded",timeout:5) {c.metrics.snapshot()["streaming_build_resumes",default:0]>0}
    XCTAssertEqual(c.search("kept").hits.count,1)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:cache.root).filter {$0.hasPrefix(".build-")},directories)
    signals.update(.init(cpuIdleEWMA:1))
    waitFor("same builder resumes",timeout:10) {c.currentState == .live && c.metrics.snapshot()["full_rebuilds"]==1}
    XCTAssertEqual(c.metrics.snapshot()["full_scans"],2);XCTAssertEqual(c.metrics.snapshot()["streaming_builds"],2)
    XCTAssertEqual((c.index as? HybridIndex)?.immutableBase?.header.lastProcessedEventID,7)
    XCTAssertEqual(gate.count,2)
  }
  func testCriticalPressureCancelsRecoveryKeepsOldCursorAndBase() throws {
    let tree=try TemporaryTree(),cache=try TemporaryTree(cache:true),root=tree.root,signals=FakeResourceSignals(),gate=StreamingRecoveryGate()
    try tree.file("kept")
    let c=try PersistentIndexCoordinator(root:root,configuration:.init(fullRebuildMinInterval:0,maxConsecutiveRebuildFailures:1),cacheDirectory:cache.root,
      maintenanceScheduler:MaintenanceScheduler(signals:signals),replayStarter:{id,deliver in deliver([.init(path:root,flags:UInt32(kFSEventStreamEventFlagHistoryDone),id:id)])},
      fenceProvider:{_ in 7},streamingBuildFault:{point,_ in if point == .afterSections {try gate.check()}})
    defer {gate.resume.signal();c.stop(policy:.fast)}
    try c.start();XCTAssertTrue(c.waitUntilLive());let old=try XCTUnwrap((c.index as? HybridIndex)?.immutableBase)
    gate.arm();c.rebuild();XCTAssertEqual(gate.entered.wait(timeout:.now()+10),.success)
    signals.update(.init(memoryPressure:.critical));gate.resume.signal()
    waitFor("critical recovery cancellation",timeout:10) {c.metrics.snapshot()["rebuild_failures",default:0]==1}
    XCTAssertEqual((c.index as? HybridIndex)?.immutableBase?.header.snapshotUUID,old.header.snapshotUUID)
    XCTAssertEqual(c.search("kept").hits.count,1);XCTAssertEqual(old.header.lastProcessedEventID,7)
    XCTAssertEqual(c.metrics.snapshot()["full_rebuilds",default:0],0)
  }
}
private final class StreamingRecoveryGate:@unchecked Sendable {
  private let lock=NSLock();private var armed=false,visits=0
  let entered=DispatchSemaphore(value:0),resume=DispatchSemaphore(value:0)
  var count:Int {lock.withLock {visits}}
  func arm() {lock.withLock {armed=true}}
  func check() throws {
    let block=lock.withLock {visits+=1;let result=armed;armed=false;return result}
    if block {entered.signal();guard resume.wait(timeout:.now()+15) == .success else {throw SnapshotError.cancelled}}
  }
}
