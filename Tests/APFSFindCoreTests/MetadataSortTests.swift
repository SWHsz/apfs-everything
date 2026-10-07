import Foundation
import XCTest
@testable import APFSFindCore

final class MetadataSortTests: XCTestCase {
    func testAllDirectionsUnknownLastGlobalTopKAndPagination() throws {
        let cache = try TemporaryTree(cache:true), identity = snapshotIdentity(), ram = FileIndex(root:identity.root)
        ram.apply((0..<200).map { .upsert(.init(path:identity.root+String(format:"/match-%03d",$0),kind:$0 % 11 == 0 ? .directory : .file,fileID:UInt64($0+1))) })
        let store = try SnapshotStore(directory:cache.root,identity:identity)
        _ = try SnapshotV2Writer.write(source:.ram(ram,ram.stats().generation),identity:identity,generation:ram.stats().generation,cursor:1,store:store)
        let base = try store.reader(expectedIdentity:identity).mappedBase!
        _ = try MetadataWriter.write(store:store,base:base.header,cursor:1,value:{ id in
            .init(logicalSize:base.record(at:id).kind == .file ? UInt64(1000-Int(id)) : UInt64.max,
                  modificationTimeNanoseconds:id % 7 == 0 ? nil : Int64(id)*100)
        })
        let meta = MetadataIndexCoordinator(); meta.bind(namespace:base,mapped:try store.metadataReader(base:base.header)); meta.advance(1,historyDone:true)
        let hybrid = HybridIndex(base:base); hybrid.setMetadataSource(meta)
        hybrid.apply([.upsert(.init(path:identity.root+"/match-zz-delta",kind:.file))]); meta.update(path:identity.root+"/match-zz-delta",value:.init(logicalSize:99999,modificationTimeNanoseconds:999999))
        let all = hybrid.snapshotEntries().filter { $0.path.contains("/match") }.map { e -> SearchHit in
            let v = meta.capture().value(path:e.path)
            return .init(path:e.path,kind:e.kind,matchRank:.prefix,logicalSize:v.logicalSize,modificationTimeNanoseconds:v.modificationTimeNanoseconds,metadataFreshness:.live)
        }
        for key in SearchSortKey.allCases {
            for direction in [SortDirection.ascending,.descending] {
                let order = SearchSortDescriptor(key:key,direction:direction)
                let oracle = all.sorted { SearchOrdering.less($0,$1,sort:order) }
                for limit in [1,50,100,250] {
                    let result = hybrid.search(.init(query:"MATCH",limit:limit,sort:order))
                    XCTAssertEqual(result.hits.map(\.path),oracle.prefix(limit).map(\.path),"\(key) \(direction)")
                }
                if key == .size || key == .modificationTime {
                    let result = hybrid.search(.init(query:"match",limit:250,sort:order)).hits
                    let validity = result.map { key == .size ? $0.logicalSize != nil : $0.modificationTimeNanoseconds != nil }
                    if let unknown = validity.firstIndex(of:false) { XCTAssertFalse(validity[unknown...].contains(true)) }
                }
            }
        }
        let token = SearchCancellationToken(); token.cancel()
        XCTAssertTrue(hybrid.search(.init(query:"match",cancellation:token,sort:.init(key:.size))).cancelled)
        XCTAssertEqual(hybrid.search(.init(query:"match",limit:1,sort:.init(key:.size))).hits.first?.logicalSize,99999)
    }
    func testNameUsesRawBasenameTieThenPathAndRelevancePreserved() {
        let a = SearchHit(path:"/a/NET",kind:.file,matchRank:.substring),b = SearchHit(path:"/b/net",kind:.file,matchRank:.exact)
        XCTAssertTrue(SearchOrdering.less(a,b,sort:.init(key:.name)))
        XCTAssertTrue(SearchOrdering.less(b,a,sort:.init(key:.name,direction:.descending)))
        XCTAssertTrue(SearchOrdering.less(b,a,sort:.init()))
    }
    func testMultiVolumeHasMoreMetadataCompletenessAndGlobalSort() async {
        let a = VolumeDescriptor(volumeUUID:UUID(),displayName:"A",mountPath:"/",isSystemVolume:true)
        let b = VolumeDescriptor(volumeUUID:UUID(),displayName:"B",mountPath:"/b")
        let c = MultiVolumeCoordinator(provider:FakeVolumeProvider([a,b]),selectionStore:MemoryVolumeSelection([b.volumeUUID]),maintenance:.init(), factory:{ v,_ in SortVolumeSession(v) })
        await c.start(); let result = await c.search(.init(query:"match",limit:50,sort:.init(key:.size)))
        XCTAssertTrue(result.hasMore); XCTAssertFalse(result.metadataComplete); XCTAssertEqual(result.hits.count,50)
        XCTAssertEqual(result.hits.first?.logicalSize,1099)
        XCTAssertTrue(zip(result.hits,result.hits.dropFirst()).allSatisfy { $0.logicalSize! >= $1.logicalSize! })
        await c.stop()
    }
}
private final class SortVolumeSession: VolumeSearching, @unchecked Sendable {
    let volume:VolumeDescriptor
    init(_ volume:VolumeDescriptor) { self.volume = volume }
    func start() {}
    func stop(policy:ShutdownPolicy) async {}
    func reconcileParent(of path:String) {}
    func snapshot()->VolumeSessionSnapshot { .init(volume:volume,state:.live,searchAvailable:true,freshness:.live,indexedEntries:100,snapshotBytes:0,unreadableDirectories:0,pendingReplayEvents:0,metadataAvailable:volume.isSystemVolume) }
    func changes()->AsyncStream<VolumeSessionSnapshot> { AsyncStream { $0.yield(snapshot()); $0.finish() } }
    func search(_ request:SearchRequest)->SearchResult {
        let hits = (0..<100).map { i in SearchHit(path:volume.mountPath+"/match-\(i)",kind:.file,logicalSize:UInt64((volume.isSystemVolume ? 0 : 1000)+i)) }.sorted { SearchOrdering.less($0,$1,sort:request.sort) }
        return .init(hits:Array(hits.prefix(request.limit)),latencyMilliseconds:0,generation:0)
    }
}
