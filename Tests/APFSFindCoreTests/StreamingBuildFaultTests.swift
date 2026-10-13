import Darwin
import Foundation
import XCTest
@testable import APFSFindCore

final class StreamingBuildFaultTests:XCTestCase {
  private func runFailure(_ fault:@escaping @Sendable (StreamingBuildFailurePoint,SnapshotBuildWorkspace)throws->Void) throws {
    let tree=try TemporaryTree(),cache=try TemporaryTree(cache:true),v=try VolumeIdentity.discover(root:tree.root)
    try tree.file("old");let store=try SnapshotStore(directory:cache.root,identity:v)
    let first=try DiskBackedNamespaceBuilder(identity:v,store:store).build(generation:1,cursor:7);try first.publish()
    let before=try Data(contentsOf:URL(fileURLWithPath:store.path)),meta=try Data(contentsOf:URL(fileURLWithPath:store.metadataPath))
    try tree.file("new")
    XCTAssertThrowsError(try DiskBackedNamespaceBuilder(identity:v,store:store,fault:fault).build(generation:2,cursor:9))
    XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:store.path)),before)
    XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:store.metadataPath)),meta)
    XCTAssertEqual(try store.reader(expectedIdentity:v).header.lastProcessedEventID,7)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:cache.root).filter {$0.hasPrefix(".build-")}.count,1) // first sealed result remains owned/live
  }
  func testENOSPCDoesNotPublishOrAdvanceCursor() throws {
    try runFailure {point,_ in if point == .afterSections {throw SnapshotError.io("injected section ENOSPC",ENOSPC)}}
  }
  func testCorruptedStagingIsRejected() throws {
    try runFailure {point,w in
      if point == .beforeValidation {try w.section("namespace").patch(Data([255]),at:256)}
    }
  }
  func testCancellationAndCleanup() throws {
    let tree=try TemporaryTree(),cache=try TemporaryTree(cache:true),v=try VolumeIdentity.discover(root:tree.root),token=CancellationToken()
    let store=try SnapshotStore(directory:cache.root,identity:v)
    XCTAssertThrowsError(try DiskBackedNamespaceBuilder(identity:v,store:store,source:WideBuildSource(count:20_000),cancellation:token,
      fault:{point,_ in if point == .afterSections {token.cancel()}}).build(generation:1,cursor:1))
    XCTAssertFalse(FileManager.default.fileExists(atPath:store.path))
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:cache.root).allSatisfy {$0.hasSuffix(".lock")})
  }
  func testPublicationErrorsRollBackBothImmutableFiles() throws {
    for point in [SnapshotFailurePoint.beforeRename,.afterRename,.directorySync] {
      let tree=try TemporaryTree(),cache=try TemporaryTree(cache:true),v=try VolumeIdentity.discover(root:tree.root)
      try tree.file("old");let store=try SnapshotStore(directory:cache.root,identity:v)
      let first=try DiskBackedNamespaceBuilder(identity:v,store:store).build(generation:1,cursor:7);try first.publish()
      let old=try Data(contentsOf:URL(fileURLWithPath:store.path)),meta=try Data(contentsOf:URL(fileURLWithPath:store.metadataPath))
      try tree.file("new")
      let next=try DiskBackedNamespaceBuilder(identity:v,store:store).build(generation:2,cursor:9)
      XCTAssertThrowsError(try next.publish(fault:{if $0==point {throw SnapshotError.io("injected publish error",EIO)}}))
      XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:store.path)),old)
      XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:store.metadataPath)),meta)
      XCTAssertEqual(first.namespace.count,2);XCTAssertEqual(try first.namespace.name(at:1),"old")
    }
  }
  func testStagingReplacementCannotRedirectWrites() throws {
    let tree=try TemporaryTree(),cache=try TemporaryTree(cache:true),other=try TemporaryTree(cache:true),v=try VolumeIdentity.discover(root:tree.root)
    let otherRoot=other.root
    try tree.file("item");let store=try SnapshotStore(directory:cache.root,identity:v)
    XCTAssertThrowsError(try DiskBackedNamespaceBuilder(identity:v,store:store,fault:{point,w in
      if point == .afterSections {
        XCTAssertEqual(rename(w.path,w.path+".moved"),0);XCTAssertEqual(symlink(otherRoot,w.path),0)
      }
    }).build(generation:1,cursor:1))
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:other.root).isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath:store.path))
  }
}
