import Darwin
import Foundation
import XCTest
@testable import APFSFindCore

final class DiskBackedNamespaceBuilderTests:XCTestCase {
  func testEmptyRootAndOwnedSections() throws {
    let tree=try TemporaryTree(),cache=try TemporaryTree(cache:true),v=try VolumeIdentity.discover(root:tree.root)
    let store=try SnapshotStore(directory:cache.root,identity:v),w=try store.createBuildWorkspace()
    var st=stat();XCTAssertEqual(lstat(w.path,&st),0);XCTAssertEqual(st.st_mode & 0o7777,0o700)
    for name in SnapshotBuildWorkspace.sectionNames {XCTAssertEqual(lstat(w.path+"/"+name,&st),0);XCTAssertEqual(st.st_mode & 0o7777,0o600)}
    let sealed=try DiskBackedNamespaceBuilder(identity:v,store:store).build(generation:1,cursor:1)
    XCTAssertEqual(sealed.namespace.count,1);XCTAssertEqual(try sealed.namespace.record(at:0).subtreeEnd,1)
    try sealed.publish();XCTAssertEqual(try store.reader(expectedIdentity:v).formatVersion,2)
    XCTAssertTrue(try store.immutableMetadataReader(base:sealed.namespace.header).header.matches(sealed.namespace.header))
  }
  func testAbandonedWorkspaceCleanupPreservesActiveAndUnknownFiles() throws {
    let tree=try TemporaryTree(),cache=try TemporaryTree(cache:true),v=try VolumeIdentity.discover(root:tree.root)
    let store=try SnapshotStore(directory:cache.root,identity:v),active=try store.createBuildWorkspace()
    let stale=cache.root+"/.build-"+UUID().uuidString.lowercased()
    XCTAssertEqual(mkdir(stale,0o700),0)
    for name in ["owner-lock","records","keep-user-file"] {
      let fd=open(stale+"/"+name,O_CREAT|O_EXCL|O_RDWR|O_CLOEXEC|O_NOFOLLOW,0o600)
      XCTAssertGreaterThanOrEqual(fd,0);close(fd)
    }
    _ = try SnapshotStore(directory:cache.root,identity:v)
    XCTAssertTrue(FileManager.default.fileExists(atPath:active.path+"/records"))
    XCTAssertTrue(FileManager.default.fileExists(atPath:stale+"/keep-user-file"))
    XCTAssertFalse(FileManager.default.fileExists(atPath:stale+"/records"))
    try active.checkIdentity()
  }
  func testWideDirectoryUsesBoundedRuns() throws {
    let tree=try TemporaryTree(),cache=try TemporaryTree(cache:true),v=try VolumeIdentity.discover(root:tree.root),metrics=Metrics()
    let store=try SnapshotStore(directory:cache.root,identity:v)
    let sealed=try DiskBackedNamespaceBuilder(identity:v,store:store,source:WideBuildSource(count:100_000),metrics:metrics).build(generation:1,cursor:1)
    XCTAssertEqual(sealed.namespace.count,100_001)
    XCTAssertLessThanOrEqual(metrics.snapshot()["streaming_listing_entries_max",default:0],257)
    XCTAssertEqual(metrics.snapshot()["streaming_dfs_depth_max"],1)
    XCTAssertEqual(try sealed.namespace.name(at:1),"item-000000")
    XCTAssertEqual(try sealed.namespace.name(at:100_000),"item-099999")
    XCTAssertEqual(try sealed.metadata.value(at:100_000).logicalSize,99_999)
    XCTAssertEqual(try sealed.namespace.record(at:0).childCount,100_000)
    XCTAssertGreaterThan(sealed.temporaryPeakBytes,sealed.result.header.fileLength)
  }
}
struct WideBuildSource:StreamingDirectorySource {
  let count:Int
  func rootEntry(identity:VolumeIdentity)throws->ScannedEntry {.init(namespace:.init(path:identity.root,kind:.directory,deviceID:identity.deviceID,fileID:identity.rootFileID))}
  func pages(path:String,identity:VolumeIdentity,cancellation:CancellationToken,checkpoint:@escaping @Sendable ()throws->Void,visit:@escaping @Sendable ([ScannedEntry])throws->Void)throws {
    guard path==identity.root else {return}
    for start in stride(from:0,to:count,by:257) {
      try checkpoint()
      try visit((start..<min(start+257,count)).map {n in
        let id=count-1-n
        return .init(namespace:.init(path:path+String(format:"/item-%06d",id),kind:.file,deviceID:identity.deviceID,fileID:UInt64(id+1)),
                     metadata:.init(logicalSize:UInt64(id),modificationTimeNanoseconds:Int64(id)*1000000000+123456789))
      })
    }
  }
}
