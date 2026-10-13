import Darwin
import Foundation
import XCTest
@testable import APFSFindCore

final class StreamingExternalStorageTests:XCTestCase {
  func testPReadValidationPublicationAndReconnect() throws {
    let tree=try TemporaryTree(),cache=try TemporaryTree(cache:true),v=try VolumeIdentity.discover(root:tree.root)
    try tree.file("one")
    let store=try SnapshotStore(directory:cache.root,identity:v,usePRead:true)
    let sealed=try DiskBackedNamespaceBuilder(identity:v,store:store).build(generation:1,cursor:1)
    XCTAssertTrue(sealed.namespace is PReadNamespaceIndex);XCTAssertTrue(sealed.metadata is PReadMetadataIndex)
    XCTAssertEqual(sealed.namespace.mappedBytes,0);try sealed.publish()
    let reopened=try SnapshotStore(directory:cache.root,identity:v,usePRead:true).reader(expectedIdentity:v)
    XCTAssertEqual(reopened.header.snapshotUUID,sealed.namespace.header.snapshotUUID)
    XCTAssertEqual(try reopened.immutableBase?.reconstructPath(1),tree.path("one"))
  }
  func testLatchedDisconnectAbortsBuilderBeforePublication() throws {
    let tree=try TemporaryTree(),cache=try TemporaryTree(cache:true),v=try VolumeIdentity.discover(root:tree.root),offline=CancellationToken()
    let store=try SnapshotStore(directory:cache.root,identity:v,usePRead:true,validateStorage:{if offline.isCancelled {throw SnapshotError.io("injected offline",EIO)}})
    XCTAssertThrowsError(try DiskBackedNamespaceBuilder(identity:v,store:store,source:WideBuildSource(count:10_000),fault:{point,_ in
      if point == .afterSections {offline.cancel()}
    }).build(generation:1,cursor:1))
    XCTAssertFalse(FileManager.default.fileExists(atPath:store.path))
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:cache.root).allSatisfy {$0.hasSuffix(".lock")})
  }
}
