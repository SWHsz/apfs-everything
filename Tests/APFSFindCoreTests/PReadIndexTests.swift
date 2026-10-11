import Darwin
import Foundation
import XCTest
@testable import APFSFindCore

final class PReadIndexTests: XCTestCase {
  private func fixture(_ count:Int = 100) throws -> (TemporaryTree,SnapshotStore,MMapBaseIndex) {
    let cache = try TemporaryTree(cache:true), identity = snapshotIdentity()
    let store = try SnapshotStore(directory:cache.root,identity:identity), index = FileIndex(root:identity.root)
    index.apply((0..<count).map { .upsert(.init(path:identity.root+"/d\($0%7)/file-\($0)-É",kind:.file,fileID:UInt64($0+10))) })
    _ = try SnapshotV2Writer.write(source:.ram(index,index.stats().generation),identity:identity,
      generation:index.stats().generation,cursor:100,store:store)
    let base = try XCTUnwrap(store.reader(expectedIdentity:identity).mappedBase)
    _ = try MetadataWriter.write(store:store,base:base.header,cursor:100,value:{
      $0%11 == 0 ? .unknown : .init(logicalSize:UInt64($0%13),modificationTimeNanoseconds:Int64($0)-120)
    })
    return (cache,store,base)
  }
  private func namespace(_ store:SnapshotStore,checkpoint:()throws->Void = {}) throws -> PReadNamespaceIndex {
    try PReadNamespaceIndex(fileDescriptor:open(store.path,O_RDONLY|O_CLOEXEC|O_NOFOLLOW),identity:snapshotIdentity(),checkpoint:checkpoint)
  }
  private func metadata(_ store:SnapshotStore,_ header:SnapshotHeader) throws -> PReadMetadataIndex {
    try PReadMetadataIndex(fileDescriptor:open(store.metadataPath,O_RDONLY|O_CLOEXEC|O_NOFOLLOW),base:header)
  }
  func testEveryRecordLookupAndColumnMatchesMMapAcrossPages() throws {
    let (cache,store,map) = try fixture(9000); defer { withExtendedLifetime(cache) {} }
    let safe = try namespace(store), meta = try metadata(store,map.header), mappedMeta = try store.metadataReader(base:map.header)
    XCTAssertEqual(safe.count,map.count); XCTAssertEqual(safe.files,map.files); XCTAssertEqual(safe.directories,map.directories)
    XCTAssertEqual(safe.mappedBytes,0)
    for i in 0..<map.count {
      let id = UInt32(i)
      XCTAssertEqual(try safe.record(at:id).encoded,map.record(at:id).encoded)
      XCTAssertEqual(try safe.name(at:id),map.name(at:id))
      XCTAssertEqual(try safe.reconstructPath(id),map.reconstructPath(id))
      XCTAssertEqual(try meta.value(at:id),mappedMeta.value(at:id))
    }
    XCTAssertLessThanOrEqual(safe.cachedBytes,4*1024*1024); XCTAssertLessThanOrEqual(meta.cachedBytes,4*1024*1024)
    safe.reclaimPages(); meta.reclaimPages(); XCTAssertEqual(safe.cachedBytes,0); XCTAssertEqual(meta.cachedBytes,0)
    let d = try safe.lookupChild(parent:0,name:"d3")
    XCTAssertEqual(d,map.lookupChild(parent:0,name:"d3"))
    let directory = try XCTUnwrap(d)
    XCTAssertEqual(try safe.directChildren(of:directory),map.directChildren(of:directory))
  }
  func testAllSortsAndDirectionsMatchReferenceTopK() throws {
    let (cache,store,map) = try fixture(300); defer { withExtendedLifetime(cache) {} }
    let safe = try namespace(store), meta = try metadata(store,map.header), mappedMeta = try store.metadataReader(base:map.header)
    for key in SearchSortKey.allCases {
      for direction in [SortDirection.ascending,.descending] {
        let sort = SearchSortDescriptor(key:key,direction:direction)
        for query in ["f","file-2","é","absent"] {
          let a = map.searchBase(Array(FileEntry.fold(query).utf8),limit:51,sort:sort,metadata:{mappedMeta.value(at:$0)},deleted:{ $0%17 == 0 })
          let b = try safe.searchBase(Array(FileEntry.fold(query).utf8),limit:51,cancellation:nil,scanned:nil,sort:sort,metadata:{try meta.value(at:$0)},deleted:{ $0%17 == 0 })
          XCTAssertEqual(a.map(\.id),b.map(\.id),"\(key) \(direction) \(query)")
          XCTAssertEqual(a.map(\.rank),b.map(\.rank))
        }
      }
    }
  }
  func testDuplicateBasenamePathTiesMatchMMapAcrossDeepAndUnicodeParents() throws {
    let cache = try TemporaryTree(cache:true),id = snapshotIdentity(),store = try SnapshotStore(directory:cache.root,identity:id)
    let index = FileIndex(root:id.root)
    for prefix in ["A","a","a-","a.","É","e\u{301}","目录",".cache"] {
      for j in 0..<40 {index.apply([.upsert(.init(path:id.root+"/"+prefix+"/deep-\(j)/a",kind:.file))])}
    }
    _ = try SnapshotV2Writer.write(source:.ram(index,index.stats().generation),identity:id,generation:1,cursor:100,store:store)
    let mapped = try XCTUnwrap(store.reader(expectedIdentity:id).mappedBase),safe = try namespace(store)
    for key in SearchSortKey.allCases {
      for direction in [SortDirection.ascending,.descending] {
        let sort = SearchSortDescriptor(key:key,direction:direction)
        let x = mapped.searchBase([97],limit:51,sort:sort,metadata:{_ in .unknown},deleted:{_ in false})
        let y = try safe.searchBase([97],limit:51,cancellation:nil,scanned:nil,sort:sort,metadata:{_ in .unknown},deleted:{_ in false})
        XCTAssertEqual(x.map(\.id),y.map(\.id),"\(key) \(direction)")
      }
    }
  }
  func testProductionHybridBatchMetadataMatchesMMapWithOverrides() throws {
    let (cache,store,map) = try fixture(9000); defer {withExtendedLifetime(cache) {}}
    let safe = try namespace(store),preadMeta = try metadata(store,map.header),mappedMeta = try store.metadataReader(base:map.header)
    let reference = HybridIndex(base:map),external = HybridIndex(base:safe)
    let a = MetadataIndexCoordinator(),b = MetadataIndexCoordinator()
    a.bind(namespace:map,mapped:mappedMeta,cursor:100);b.bind(namespace:safe,mapped:preadMeta,cursor:100)
    reference.setMetadataSource(a);external.setMetadataSource(b)
    for coordinator in [a,b] {coordinator.update(path:map.reconstructPath(4100),value:.init(logicalSize:999999,modificationTimeNanoseconds:999999))}
    for key in SearchSortKey.allCases {
      for direction in [SortDirection.ascending,.descending] {
        let request = SearchRequest(query:"file",limit:51,sort:.init(key:key,direction:direction))
        let x = reference.search(request),y = external.search(request)
        XCTAssertNil(y.storageError);XCTAssertEqual(x.hits.map(\.path),y.hits.map(\.path))
        XCTAssertEqual(x.hits.map(\.logicalSize),y.hits.map(\.logicalSize))
        XCTAssertEqual(x.hits.map(\.modificationTimeNanoseconds),y.hits.map(\.modificationTimeNanoseconds))
      }
    }
  }
  func testIOFailureAndCancellationNeverReturnPartialHits() throws {
    let (cache,store,map) = try fixture(); defer { withExtendedLifetime(cache) {} }
    let safe = try namespace(store), meta = try metadata(store,map.header)
    let token = SearchCancellationToken(); token.cancel()
    XCTAssertThrowsError(try safe.searchBase([102],limit:51,cancellation:token,scanned:nil,sort:.init(),metadata:{_ in .unknown},deleted:{_ in false})) { XCTAssertEqual($0 as? IndexBackingError,.cancelled) }
    meta.close()
    XCTAssertThrowsError(try safe.searchBase([102],limit:51,cancellation:nil,scanned:nil,sort:.init(key:.size),metadata:{try meta.value(at:$0)},deleted:{_ in false})) { XCTAssertEqual($0 as? IndexBackingError,.closed) }
    safe.close()
    XCTAssertThrowsError(try safe.lookupChild(parent:0,name:"d0")) { XCTAssertEqual($0 as? IndexBackingError,.closed) }
  }
  func testValidationCancelClosesOwnedDescriptor() throws {
    let (cache,store,_) = try fixture(); defer { withExtendedLifetime(cache) {} }
    let fd = open(store.path,O_RDONLY|O_CLOEXEC|O_NOFOLLOW)
    XCTAssertThrowsError(try PReadNamespaceIndex(fileDescriptor:fd,identity:snapshotIdentity(),checkpoint:{throw SnapshotError.cancelled}))
    XCTAssertEqual(fcntl(fd,F_GETFD),-1); XCTAssertEqual(errno,EBADF)
    XCTAssertNoThrow(try namespace(store))
  }
  func testNamespaceAndMetadataCorruptionRejected() throws {
    let (cache,store,map) = try fixture(); defer { withExtendedLifetime(cache) {} }
    let good = try Data(contentsOf:URL(fileURLWithPath:store.path))
    for offset in [0,8,24,112,148,256,Int(map.header.recordTableOffset),good.count-8] {
      var broken = good; broken[offset] ^= 1; try broken.write(to:URL(fileURLWithPath:store.path))
      XCTAssertThrowsError(try namespace(store),"namespace offset \(offset)")
    }
    try good.write(to:URL(fileURLWithPath:store.path))
    let goodMeta = try Data(contentsOf:URL(fileURLWithPath:store.metadataPath))
    for offset in [0,8,24,56,184,188,256,goodMeta.count-17,goodMeta.count-8] {
      var broken = goodMeta; broken[offset] ^= 1; try broken.write(to:URL(fileURLWithPath:store.metadataPath))
      XCTAssertThrowsError(try metadata(store,map.header),"metadata offset \(offset)")
    }
  }
  func testUnknownColumnsRejectedWithRepairedCRC() throws {
    let (cache,store,map) = try fixture(); defer { withExtendedLifetime(cache) {} }
    var broken = try Data(contentsOf:URL(fileURLWithPath:store.metadataPath))
    broken[256] = 99
    broken.put(SnapshotFormat.crc(Data(broken[256..<(broken.count-16)])),at:184)
    broken.put(UInt32(0),at:188); broken.put(SnapshotFormat.crc(Data(broken.prefix(256))),at:188)
    try broken.write(to:URL(fileURLWithPath:store.metadataPath))
    XCTAssertThrowsError(try metadata(store,map.header))
  }
}
