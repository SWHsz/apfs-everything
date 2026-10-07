import Foundation
import XCTest
@testable import APFSFindCore

private struct RandomSequence {
  var state: UInt64 = 0x6170667366696e64
  mutating func next(_ limit:Int)->Int { state = state &* 6364136223846793005 &+ 1442695040888963407; return Int((state >> 32) % UInt64(limit)) }
}
private final class PropertyVolumeSession: VolumeSearching, @unchecked Sendable {
  let volume:VolumeDescriptor, index:HybridIndex
  init(_ volume:VolumeDescriptor,_ index:HybridIndex) { self.volume = volume; self.index = index }
  func start() {}
  func stop(policy:ShutdownPolicy) async {}
  func snapshot()->VolumeSessionSnapshot { .init(volume:volume,state:.live,searchAvailable:true,freshness:.live,indexedEntries:index.stats().liveEntries,snapshotBytes:0,unreadableDirectories:0,pendingReplayEvents:0) }
  func search(_ request:SearchRequest)->SearchResult { index.search(request) }
  func reconcileParent(of path:String) {}
  func changes()->AsyncStream<VolumeSessionSnapshot> { AsyncStream { $0.yield(snapshot()) } }
  func setPauseReason(_ reason:IndexPauseReason,enabled:Bool) async {}
}
final class ComparatorPropertyTests: XCTestCase, @unchecked Sendable {
  func testSeededCanonicalMmapFileIndexDeltaAndMultiVolumeTopK() async throws {
    let caches = try [TemporaryTree(cache:true),TemporaryTree(cache:true)]
    var random = RandomSequence(), indices:[HybridIndex] = [], references:[FileIndex] = [], allMetadata:[[String:FileMetadataValue]] = [], volumes:[VolumeDescriptor] = []
    let names = ["edge","EDGE","Edge","prefix-edge","edge-tail","Café-edge","Cafe\u{301}-edge","中edge","😀edge","Ædge-edge","Åedge","Zedge","éedge","e\u{301}edge","a!edge","a-edge"]
    for v in 0..<2 {
      let root = "/property-v\(v)", identity = snapshotIdentity(root:root), ram = FileIndex(root:root)
      var values:[String:FileMetadataValue] = [:]
      for i in 0..<350 {
        let path = root+"/d\(random.next(31))/branch\(i)/"+names[random.next(names.count)]
        ram.apply([.upsert(.init(path:path,kind:i%17 == 0 ? .symlink : .file))])
        values[path] = .init(logicalSize:i%4 == 0 ? nil : UInt64(random.next(13)),modificationTimeNanoseconds:i%5 == 0 ? nil : Int64(random.next(17)-8))
      }
      let store = try SnapshotStore(directory:caches[v].root,identity:identity)
      let ns = try SnapshotV2Writer.write(source:.ram(ram,ram.stats().generation),identity:identity,generation:ram.stats().generation,cursor:1,store:store)
      let base = try store.reader(expectedIdentity:identity).mappedBase!
      _ = try MetadataWriter.write(store:store,base:ns.header,cursor:1,value:{ values[base.reconstructPath($0)] ?? .unknown })
      let meta = MetadataIndexCoordinator(); meta.bind(namespace:base,mapped:try store.metadataReader(base:ns.header))
      let hybrid = HybridIndex(base:base); hybrid.setMetadataSource(meta)
      // Compare base implementations before introducing RAM changes.
      for sort in Self.sorts {
        let request = SearchRequest(query:"edge",limit:47,sort:sort)
        let oracle = ram.search(.init(query:"edge",limit:Int.max,sort:sort),metadata:{values[$0] ?? .unknown}).hits.sorted { SearchOrdering.less($0,$1,sort:sort) }
        let mmap = base.searchBase(Array(FileEntry.fold("edge").utf8),limit:47,sort:sort,metadata:{values[base.reconstructPath($0)] ?? .unknown},deleted:{_ in false}).map { base.reconstructPath($0.id) }
        XCTAssertEqual(mmap,Array(oracle.prefix(47)).map(\.path),"mmap \(sort)")
        XCTAssertEqual(ram.search(request,metadata:{values[$0] ?? .unknown}).hits.map(\.path),mmap)
      }
      for i in 0..<80 {
        let path = root+"/delta\(i)/"+names[random.next(names.count)], mutation = IndexMutation.upsert(.init(path:path,kind:.file))
        // Explicitly install parents into the hybrid delta.
        hybrid.apply([.upsert(.init(path:root+"/delta\(i)",kind:.directory,deviceID:identity.deviceID)),mutation]); ram.apply([mutation])
        let value = FileMetadataValue(logicalSize:i%3 == 0 ? nil : UInt64(random.next(11)),modificationTimeNanoseconds:i%7 == 0 ? nil : Int64(random.next(15)))
        meta.update(path:path,value:value); values[path] = value
      }
      for path in values.keys.sorted().prefix(50) { hybrid.apply([.remove(path)]); ram.apply([.remove(path)]); meta.update(path:path,value:nil) }
      for sort in Self.sorts {
        let request = SearchRequest(query:"edge",limit:47,sort:sort)
        XCTAssertEqual(hybrid.search(request).hits.map(\.path),ram.search(request,metadata:{values[$0] ?? .unknown}).hits.map(\.path),"hybrid \(sort)")
      }
      indices.append(hybrid); references.append(ram); allMetadata.append(values)
      volumes.append(.init(volumeUUID:UUID(),displayName:"Volume \(v)",mountPath:root,isSystemVolume:v == 0))
    }
    let sessions = zip(volumes,indices).map { PropertyVolumeSession($0,$1) }
    let coordinator = MultiVolumeCoordinator(provider:FakeVolumeProvider(volumes),selectionStore:MemoryVolumeSelection(Set(volumes.map(\.volumeUUID))),maintenance:.init(),factory:{ volume,_ in sessions.first { $0.volume.volumeUUID == volume.volumeUUID }! })
    await coordinator.start()
    for sort in Self.sorts {
      let oracle = references.enumerated().flatMap { i,ram in ram.search(.init(query:"edge",limit:Int.max,sort:sort),metadata:{allMetadata[i][$0] ?? .unknown}).hits }.sorted { SearchOrdering.less($0,$1,sort:sort) }
      let result = await coordinator.search(.init(id:1,query:"edge",limit:63,sort:sort))
      XCTAssertEqual(result.hits.map(\.path),Array(oracle.prefix(63)).map(\.path),"global \(sort)")
    }
    await coordinator.stop()
  }
  static var sorts:[SearchSortDescriptor] { [.init()]+[SearchSortKey.name,.size,.modificationTime].flatMap { key in [SortDirection.ascending,.descending].map { .init(key:key,direction:$0) } } }
}
