import Darwin
import Foundation
import XCTest
@testable import APFSFindCore

final class StreamingBuildDifferentialTests:XCTestCase {
  func testRealMixedTreeMatchesRAMOracleAndExactMetadata() throws {
    let tree=try TemporaryTree(),cache=try TemporaryTree(cache:true),oracleCache=try TemporaryTree(cache:true)
    try tree.directory("a");try tree.directory("b");try tree.directory("z/sub")
    // NFC/NFD on distinct parents avoids APFS's canonical filename collision.
    for name in ["a/café","b/cafe\u{301}","a/ABC","a/abX","z/sub/日本語","Äpfel","empty"] {try tree.file(name)}
    var deep="deep"
    for _ in 0..<100 {try tree.directory(deep);deep+="/d"}
    try tree.file(deep.dropLast(2)+"/leaf")
    XCTAssertEqual(symlink(oracleCache.root,tree.path("link-out")),0)
    let path=tree.path("a/ABC"),fd=open(path,O_WRONLY|O_CLOEXEC)
    XCTAssertGreaterThanOrEqual(fd,0);XCTAssertEqual(ftruncate(fd,16385),0)
    var times=[timespec(tv_sec:1700000000,tv_nsec:123456789),timespec(tv_sec:1700000001,tv_nsec:987654321)]
    XCTAssertEqual(futimens(fd,&times),0);close(fd)
    let scan=try BulkScanner(root:tree.root).scan(),v=try VolumeIdentity.discover(root:tree.root)
    let ram=FileIndex(root:tree.root);ram.apply(scan.entries.map { .upsert($0) })
    let oldStore=try SnapshotStore(directory:oracleCache.root,identity:v)
    _ = try SnapshotV2Writer.write(source:.ram(ram,ram.stats().generation),identity:v,generation:1,cursor:1,store:oldStore)
    let old=try XCTUnwrap(oldStore.reader(expectedIdentity:v).mappedBase)
    let sealed=try DiskBackedNamespaceBuilder(identity:v,store:SnapshotStore(directory:cache.root,identity:v)).build(generation:1,cursor:1)
    XCTAssertEqual(old.count,sealed.namespace.count)
    let metadata=Dictionary(uniqueKeysWithValues:scan.scannedEntries.map {($0.namespace.path,$0.metadata)})
    for ordinal in 0..<old.count {
      let id=UInt32(ordinal),actual=try sealed.namespace.record(at:id),expected=old.record(at:id)
      XCTAssertEqual(try sealed.namespace.reconstructPath(id),old.reconstructPath(id))
      XCTAssertEqual(actual.encoded,expected.encoded)
      XCTAssertEqual(try sealed.namespace.name(at:id),old.name(at:id))
      XCTAssertEqual(try sealed.namespace.foldedName(at:id),old.foldedName(at:id))
      let p=old.reconstructPath(id)
      XCTAssertEqual(try sealed.metadata.value(at:id),metadata[p])
    }
    XCTAssertFalse(try sealed.namespace.reconstructPath(UInt32(old.count-1)).contains("link-out/"))
    XCTAssertEqual(sealed.namespace.files,ram.stats().files)
    try sealed.publish()
    XCTAssertEqual(try oldStore.reader(expectedIdentity:v).mappedBase?.count,old.count)
  }
  func testBoundaryPermissionAndPartialListingAreConservative() throws {
    let tree=try TemporaryTree(),cache=try TemporaryTree(cache:true),v=try VolumeIdentity.discover(root:tree.root)
    let sealed=try DiskBackedNamespaceBuilder(identity:v,store:SnapshotStore(directory:cache.root,identity:v),source:BoundaryBuildSource()).build(generation:1,cursor:1)
    XCTAssertEqual(sealed.namespace.count,4);XCTAssertEqual(sealed.unreadableDirectories,1)
    let children=try sealed.namespace.directChildren(of:0)
    XCTAssertEqual(try children.map {try sealed.namespace.name(at:$0)},["blocked","mount","sym"])
    XCTAssertEqual(try sealed.namespace.record(at:children[1]).flags,1)
  }
}
private struct BoundaryBuildSource:StreamingDirectorySource {
  func rootEntry(identity:VolumeIdentity)throws->ScannedEntry {.init(namespace:.init(path:identity.root,kind:.directory,deviceID:identity.deviceID,fileID:identity.rootFileID))}
  func pages(path:String,identity:VolumeIdentity,cancellation:CancellationToken,checkpoint:@escaping @Sendable ()throws->Void,visit:@escaping @Sendable ([ScannedEntry])throws->Void)throws {
    if path==identity.root {
      try visit([.init(namespace:.init(path:path+"/sym",kind:.symlink,deviceID:identity.deviceID)),
                 .init(namespace:.init(path:path+"/mount",kind:.directory,deviceID:identity.deviceID+1,isMountPoint:true)),
                 .init(namespace:.init(path:path+"/blocked",kind:.directory,deviceID:identity.deviceID))])
    } else if path.hasSuffix("/blocked") {
      try visit([.init(namespace:.init(path:path+"/partial",kind:.file,deviceID:identity.deviceID))])
      throw ScannerError(path:path,code:EACCES)
    } else {XCTFail("followed boundary/symlink")}
  }
}
