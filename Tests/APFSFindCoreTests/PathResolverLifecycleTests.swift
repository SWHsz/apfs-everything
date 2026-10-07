import Foundation
import XCTest
@testable import APFSFindCore

final class PathResolverLifecycleTests: XCTestCase {
  func testBoundaryMalformedRefAndBaseSwapInvalidateCacheButPinOldView() throws {
    let cache = try TemporaryTree(cache:true), identity = snapshotIdentity(), ram = sampleSnapshotIndex(), store = try SnapshotStore(directory:cache.root,identity:identity)
    ram.apply([.upsert(.init(path:identity.root+"/mount",kind:.directory,isMountPoint:true))])
    _ = try SnapshotV2Writer.write(source:.ram(ram,ram.stats().generation),identity:identity,generation:ram.stats().generation,cursor:1,store:store)
    let old = try store.reader(expectedIdentity:identity).mappedBase!, hybrid = HybridIndex(base:old)
    hybrid.apply([.upsert(.init(path:identity.root+"/mount/forbidden",kind:.file))]); XCTAssertNil(hybrid.entry(at:identity.root+"/mount/forbidden"))
    let pinned = hybrid.capture()!
    XCTAssertNotNil(hybrid.entry(at:identity.root+"/dir/deep"))
    XCTAssertNil(pinned.resolver.kind(.base(.max))); XCTAssertTrue(pinned.resolver.children(of:.base(.max)).isEmpty)
    let replacement = FileIndex(root:identity.root); replacement.apply([.upsert(.init(path:identity.root+"/new/child",kind:.file))])
    _ = try SnapshotV2Writer.write(source:.ram(replacement,replacement.stats().generation),identity:identity,generation:replacement.stats().generation,cursor:2,store:store)
    hybrid.install(base:try store.reader(expectedIdentity:identity).mappedBase!)
    XCTAssertNil(hybrid.entry(at:identity.root+"/dir/deep")); XCTAssertNotNil(hybrid.entry(at:identity.root+"/new/child"))
    XCTAssertNotNil(pinned.resolver.entry(identity.root+"/dir/deep"))
    XCTAssertEqual(hybrid.hybridStats()["directory_map_entries"] as? Int,0)
  }
  func testConcurrentComponentReadsAndReplacementRemainBounded() throws {
    let cache = try TemporaryTree(cache:true), identity = snapshotIdentity(), ram = sampleSnapshotIndex(), store = try SnapshotStore(directory:cache.root,identity:identity)
    _ = try SnapshotV2Writer.write(source:.ram(ram,ram.stats().generation),identity:identity,generation:ram.stats().generation,cursor:1,store:store)
    let hybrid = HybridIndex(base:try store.reader(expectedIdentity:identity).mappedBase!), queue = DispatchQueue(label:"path.test",attributes:.concurrent), group = DispatchGroup()
    for worker in 0..<4 {
      group.enter(); queue.async {
        defer { group.leave() }
        for i in 0..<1000 {
          if worker == 0 {
            hybrid.apply([.upsert(.init(path:identity.root+"/delta",kind:.directory)),.upsert(.init(path:identity.root+"/delta/file",kind:.file))])
            if i%3 == 0 { hybrid.apply([.remove(identity.root+"/delta")]) }
          } else {
            _ = hybrid.entry(at:identity.root+"/delta/file"); _ = hybrid.children(of:identity.root+"/dir/deep")
            let view = hybrid.capture()!; XCTAssertNotNil(view.resolver.resolveDirectory(identity.root+"/dir/deep"))
          }
        }
      }
    }
    group.wait(); XCTAssertLessThanOrEqual(hybrid.hotDirectoryCache.statistics["hot_directory_cache_entries"]!,8192)
  }
}
