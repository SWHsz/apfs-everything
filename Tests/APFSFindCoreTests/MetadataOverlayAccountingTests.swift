import Foundation
import XCTest
@testable import APFSFindCore

final class MetadataOverlayAccountingTests:XCTestCase {
    func testDeltaCreateDeleteChurnReleasesItsBudget() {
        let meta = MetadataIndexCoordinator(overlayByteLimit:512,overlayEntryLimit:4)
        let path = "/churn"
        for i in 0..<10_000 {
            meta.update(path:path,value:.init(logicalSize:UInt64(i)))
            XCTAssertFalse(meta.requiresRecovery)
            meta.update(path:path,value:nil)
        }
        XCTAssertEqual(meta.resourceUsage().entries,0)
        XCTAssertEqual(meta.resourceUsage().bytes,0)
        XCTAssertFalse(meta.requiresRecovery,"the budget measures retained memory, not cumulative allocation")
    }
    func testMappedDeleteRecreateCountsEachLiveAllocationOnce() throws {
        let cache = try TemporaryTree(cache:true),identity = snapshotIdentity(),ram = FileIndex(root:identity.root)
        let path = identity.root+"/churn"
        ram.apply([.upsert(.init(path:path,kind:.file))])
        let store = try SnapshotStore(directory:cache.root,identity:identity)
        _ = try SnapshotV2Writer.write(source:.ram(ram,ram.stats().generation),identity:identity,generation:ram.stats().generation,cursor:1,store:store)
        let base = try XCTUnwrap(store.reader(expectedIdentity:identity).mappedBase)
        _ = try MetadataWriter.write(store:store,base:base.header,cursor:1,value:{_ in .init(logicalSize:1)})
        let meta = MetadataIndexCoordinator(overlayByteLimit:512,overlayEntryLimit:4)
        meta.bind(namespace:base,mapped:try store.metadataReader(base:base.header))
        for i in 0..<1000 {
            meta.update(path:path,value:nil)
            XCTAssertEqual(meta.resourceUsage().bytes,64+48+path.utf8.count)
            meta.update(path:path,value:.init(logicalSize:UInt64(i+2)))
            XCTAssertEqual(meta.resourceUsage().bytes,64)
        }
        XCTAssertFalse(meta.requiresRecovery)
        XCTAssertEqual(meta.resourceUsage().entries,1)
        XCTAssertEqual(meta.capture().value(path:path).logicalSize,1001)
    }
    func testHardCapRejectsOnlyGrowthAndPinsCursor() {
        let meta = MetadataIndexCoordinator(overlayByteLimit:1024,overlayEntryLimit:2)
        meta.update(path:"/a",value:.init(logicalSize:1));meta.update(path:"/b",value:.init(logicalSize:2))
        meta.advance(10)
        meta.update(path:"/a",value:.init(logicalSize:3))
        XCTAssertFalse(meta.requiresRecovery,"an update at capacity does not allocate another entry")
        meta.update(path:"/c",value:.init(logicalSize:4))
        XCTAssertTrue(meta.requiresRecovery)
        meta.advance(20)
        XCTAssertEqual(meta.processedCursor,10)
        XCTAssertEqual(meta.resourceUsage().entries,2)
        XCTAssertEqual(meta.capture().value(path:"/a").logicalSize,3)
        XCTAssertEqual(meta.capture().value(path:"/c"),.unknown)
    }
}
