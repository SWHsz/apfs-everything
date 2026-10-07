import Darwin
import Foundation
import XCTest
@testable import APFSFindCore

final class StreamingMetadataTests: XCTestCase {
    private func fixture(_ count:Int) throws -> (TemporaryTree,SnapshotStore,MMapBaseIndex) {
        let cache = try TemporaryTree(cache:true),identity = snapshotIdentity(),index = FileIndex(root:identity.root)
        index.apply((0..<count-1).map { .upsert(.init(path:identity.root+"/f\($0)",kind:.file)) })
        let store = try SnapshotStore(directory:cache.root,identity:identity)
        _ = try SnapshotV2Writer.write(source:.ram(index,index.stats().generation),identity:identity,generation:index.stats().generation,cursor:1,store:store)
        return (cache,store,try store.reader(expectedIdentity:identity).mappedBase!)
    }
    func testMillionCompactValuesAndBoundedWriterChunks() throws {
        let values = try MetadataBuildBuffer(count:1_000_000)
        XCTAssertEqual(values.allocatedBytes,16_250_000)
        for start in stride(from:0,to:1_000_000,by:4096) {
            values.update((start..<min(start+4096,1_000_000)).map { ($0,.init(logicalSize:UInt64($0),modificationTimeNanoseconds:Int64($0)-500_000)) })
        }
        for id in [0,1,4095,4096,999999] { XCTAssertEqual(values.value(id).logicalSize,UInt64(id)); XCTAssertEqual(values.value(id).modificationTimeNanoseconds,Int64(id)-500_000) }
        XCTAssertLessThanOrEqual(MetadataWriter.maximumChunkBytes,65536)
    }
    func testStreamedFormatCRCAndCancelPreservePreviousFile() throws {
        let (cache,store,base) = try fixture(100_000); withExtendedLifetime(cache) {}
        let token = CancellationToken()
        let header = try MetadataWriter.write(store:store,base:base.header,cursor:1,value:{ .init(logicalSize:UInt64($0),modificationTimeNanoseconds:Int64($0)) })
        XCTAssertEqual(header.fileLength,1_625_272)
        let previous = try Data(contentsOf:URL(fileURLWithPath:store.metadataPath))
        var checks = 0
        XCTAssertThrowsError(try MetadataWriter.write(store:store,base:base.header,cursor:2,value:{ _ in .unknown },cancellation:token,checkpoint:{ checks += 1; if checks == 2 { token.cancel() } }))
        XCTAssertEqual(previous,try Data(contentsOf:URL(fileURLWithPath:store.metadataPath)))
        XCTAssertEqual(try store.metadataReader(base:base.header).value(at:99999).logicalSize,99999)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:cache.root).allSatisfy { !$0.hasSuffix(".tmp") })
    }
    func testInjectedStorageAndMappingFailuresCleanUp() throws {
        let (cache,store,base) = try fixture(100)
        _ = try MetadataWriter.write(store:store,base:base.header,cursor:1,value:{ _ in .unknown })
        let previous = try Data(contentsOf:URL(fileURLWithPath:store.metadataPath))
        XCTAssertThrowsError(try MetadataWriter.write(store:store,base:base.header,cursor:2,value:{ _ in .unknown },fault:{ if $0 == .afterHeader { throw SnapshotError.io("injected write",ENOSPC) } }))
        XCTAssertEqual(previous,try Data(contentsOf:URL(fileURLWithPath:store.metadataPath)))
        XCTAssertThrowsError(try MetadataBuildBuffer(count:100,directory:cache.root,beforeMapping:{ throw SnapshotError.io("injected mmap",ENOMEM) }))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:cache.root).allSatisfy { !$0.hasPrefix("apfsfind-real-cache-") })
        XCTAssertThrowsError(try MetadataBuildBuffer(count:0))
    }
}
