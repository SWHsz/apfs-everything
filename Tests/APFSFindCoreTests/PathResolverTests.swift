import Foundation
import XCTest
@testable import APFSFindCore

final class PathResolverTests: XCTestCase {
    func testImmutableComponentsAndBoundedCachePressure() throws {
        let cache = try TemporaryTree(cache:true), identity = snapshotIdentity(), ram = FileIndex(root:identity.root)
        ram.apply((0..<1100).map { .upsert(.init(path:identity.root+"/d\($0)/深/Cafe\u{301}.txt",kind:.file)) })
        let store = try SnapshotStore(directory:cache.root,identity:identity)
        _ = try SnapshotV2Writer.write(source:.ram(ram,ram.stats().generation),identity:identity,generation:ram.stats().generation,cursor:1,store:store)
        let base = try store.reader(expectedIdentity:identity).mappedBase!, hot = HotDirectoryCache(capacity:1024)
        let resolver = PathResolverSnapshot(base:base,cache:hot)
        hot.reset(version:resolver.version,root:identity.root)
        XCTAssertEqual(resolver.resolve(identity.root),.base(0))
        XCTAssertEqual(resolver.resolve(identity.root+"/d0/深/Café.txt"),resolver.resolve(identity.root+"/d0/深/Cafe\u{301}.txt"))
        XCTAssertNil(resolver.resolve("/outside")); XCTAssertNil(resolver.resolve(identity.root+"/d0/深/Cafe\u{301}.txt/child"))
        for i in 0..<1100 { XCTAssertNotNil(resolver.resolveDirectory(identity.root+"/d\(i)/深")) }
        XCTAssertLessThanOrEqual(hot.statistics["hot_directory_cache_entries"]!,1024)
        XCTAssertGreaterThan(hot.metrics.snapshot()["hot_directory_cache_evictions",default:0],0)
        let path = identity.root+"/d1099/深"
        XCTAssertNotNil(resolver.resolveDirectory(path)); XCTAssertNotNil(resolver.resolveDirectory(path))
        XCTAssertGreaterThan(hot.metrics.snapshot()["hot_directory_cache_hits",default:0],0)
        hot.invalidate(prefix:identity.root+"/d1099")
        XCTAssertNil(hot.lookup(path,version:resolver.version))
        hot.setPressure(.critical,root:identity.root)
        XCTAssertEqual(hot.statistics["hot_directory_cache_entries"],1)
        XCTAssertNotNil(resolver.resolveDirectory(path)); XCTAssertEqual(hot.statistics["hot_directory_cache_entries"],1)
        hot.setPressure(.normal,root:identity.root)
        XCTAssertEqual(hot.statistics["hot_directory_cache_capacity"],1024)
        let newer = PathResolutionVersion(baseUUID:UUID(),generation:1)
        hot.reset(version:newer,root:identity.root)
        hot.insert(path,ref:.base(1),version:resolver.version)
        XCTAssertNil(hot.lookup(path,version:newer))
    }
    func testOverlayParentReplacementAndTombstones() throws {
        let cache = try TemporaryTree(cache:true), identity = snapshotIdentity(), ram = sampleSnapshotIndex()
        let store = try SnapshotStore(directory:cache.root,identity:identity)
        _ = try SnapshotV2Writer.write(source:.ram(ram,ram.stats().generation),identity:identity,generation:ram.stats().generation,cursor:1,store:store)
        let base = try store.reader(expectedIdentity:identity).mappedBase!
        let original = PathResolverSnapshot(base:base)
        let dir = try XCTUnwrap(original.resolveDirectory(identity.root+"/dir"))
        guard case .base(let ordinal) = dir else { return XCTFail() }
        var words = [UInt64](repeating:0,count:(base.count+63)/64)
        for id in base.subtreeRange(of:ordinal) { words[Int(id)/64] |= 1 << (Int(id)%64) }
        let parent = DeltaEntry(id:0,entry:.init(path:identity.root+"/dir",kind:.directory),name:"dir",foldedName:"dir")
        let child = DeltaEntry(id:1,entry:.init(path:identity.root+"/dir/new",kind:.file),name:"new",foldedName:"new")
        let resolver = PathResolverSnapshot(base:base,tombstones:words,delta:[0:parent,1:child],overlayChildren:[.base(0):["dir":0],.delta(0):["new":1]])
        XCTAssertEqual(resolver.resolve(identity.root+"/dir/new"),.delta(1))
        XCTAssertNil(resolver.resolve(identity.root+"/dir/deep"))
        XCTAssertNil(resolver.resolveDirectory(identity.root+"/dir/new"))
        XCTAssertEqual(resolver.children(of:.delta(0)),[.delta(1)])
        XCTAssertNotNil(original.resolve(identity.root+"/dir/deep")) // pinned old capture
    }
}
