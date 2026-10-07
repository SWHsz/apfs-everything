import CAPFSShim
import CoreServices
import Darwin
import Foundation
import XCTest
@testable import APFSFindCore

final class MetadataFormatTests: XCTestCase {
    private func fixture(count:Int = 5) throws -> (TemporaryTree,SnapshotStore,MMapBaseIndex) {
        let cache = try TemporaryTree(cache:true), identity = snapshotIdentity()
        let store = try SnapshotStore(directory:cache.root,identity:identity), index = FileIndex(root:identity.root)
        if count > 1 { index.apply((1..<count).map { .upsert(.init(path:identity.root+"/f\($0)",kind:.file,fileID:UInt64($0))) }) }
        _ = try SnapshotV2Writer.write(source:.ram(index,index.stats().generation),identity:identity,generation:index.stats().generation,cursor:100,store:store)
        return (cache,store,try store.reader(expectedIdentity:identity).mappedBase!)
    }
    func testMinimalUnknownAndKnownColumns() throws {
        let (cache,store,base) = try fixture(); defer { withExtendedLifetime(cache) {} }
        let h = try MetadataWriter.write(store:store,base:base.header,cursor:100,value:{ $0 == 1 ? .init(logicalSize:UInt64.max,modificationTimeNanoseconds:Int64.min) : .unknown })
        XCTAssertEqual(h.fileLength,UInt64(272+5*16+2)); XCTAssertLessThan(Double(h.fileLength)/5,80)
        let map = try store.metadataReader(base:base.header)
        XCTAssertEqual(map.value(at:1),.init(logicalSize:UInt64.max,modificationTimeNanoseconds:Int64.min))
        XCTAssertEqual(map.value(at:0),.unknown); XCTAssertEqual(map.value(at:UInt32.max),.unknown)
    }
    func test100kDeterministicPayloadAndMmapLifetime() throws {
        let (cache,store,base) = try fixture(count:100_000); defer { withExtendedLifetime(cache) {} }
        let uuid = UUID()
        func write(_ offset:UInt64 = 0) throws { _ = try MetadataWriter.write(store:store,base:base.header,cursor:100,metadataUUID:uuid,createdAtUnixSeconds:1,value:{ .init(logicalSize:UInt64($0)+offset,modificationTimeNanoseconds:Int64($0)-100) }) }
        try write(); let bytes = try Data(contentsOf:URL(fileURLWithPath:store.metadataPath)), old = try store.metadataReader(base:base.header)
        try write(); XCTAssertEqual(bytes,try Data(contentsOf:URL(fileURLWithPath:store.metadataPath)))
        XCTAssertEqual(bytes.count,1_625_272); try write(42)
        XCTAssertEqual(old.value(at:99_999).logicalSize,99_999)
        XCTAssertEqual(try store.metadataReader(base:base.header).value(at:99_999).logicalSize,100_041)
    }
    func testCorruptionAndIdentityRejectionDoNotDamageNamespace() throws {
        let (cache,store,base) = try fixture(); defer { withExtendedLifetime(cache) {} }
        _ = try MetadataWriter.write(store:store,base:base.header,cursor:100,value:{_ in .unknown})
        let good = try Data(contentsOf:URL(fileURLWithPath:store.metadataPath))
        for offset in [0,8,16,24,40,48,56,80,96,120,128,136,144,152,160,176,184,188,200,256,296,336] {
            var broken = good; broken[offset] ^= 1
            try broken.write(to:URL(fileURLWithPath:store.metadataPath))
            XCTAssertThrowsError(try store.metadataReader(base:base.header),"offset \(offset)")
        }
        for length in [0,255,271,good.count-1] { try good.prefix(length).write(to:URL(fileURLWithPath:store.metadataPath)); XCTAssertThrowsError(try store.metadataReader(base:base.header)) }
        try good.write(to:URL(fileURLWithPath:store.metadataPath))
        var wrong = base.header; wrong.snapshotUUID = UUID(); XCTAssertThrowsError(try store.metadataReader(base:wrong))
        wrong = base.header; wrong.indexGeneration += 1; XCTAssertThrowsError(try store.metadataReader(base:wrong))
        wrong = base.header; wrong.historyUUID = UUID(); XCTAssertThrowsError(try store.metadataReader(base:wrong))
        XCTAssertNotNil(try store.reader(expectedIdentity:snapshotIdentity()).mappedBase)
    }
    func testBitmapPaddingAndUnknownColumnsAreValidatedEvenWithCorrectCRC() throws {
        let (cache,store,base) = try fixture(); defer { withExtendedLifetime(cache) {} }
        _ = try MetadataWriter.write(store:store,base:base.header,cursor:100,value:{_ in .unknown})
        let good = try Data(contentsOf:URL(fileURLWithPath:store.metadataPath))
        for offset in [256,337] {
            var broken = good; broken[offset] = 128
            broken.put(SnapshotFormat.crc(Data(broken[256..<(broken.count-16)])),at:184)
            broken.put(UInt32(0),at:188); broken.put(SnapshotFormat.crc(Data(broken.prefix(256))),at:188)
            try broken.write(to:URL(fileURLWithPath:store.metadataPath)); XCTAssertThrowsError(try store.metadataReader(base:base.header))
        }
    }
    func testAtomicFailureAndSymlinkRejection() throws {
        let (cache,store,base) = try fixture(); defer { withExtendedLifetime(cache) {} }
        _ = try MetadataWriter.write(store:store,base:base.header,cursor:100,value:{_ in .unknown})
        let good = try Data(contentsOf:URL(fileURLWithPath:store.metadataPath))
        for point in [SnapshotFailurePoint.afterHeader,.beforeFileSync,.beforeRename,.afterRename,.directorySync] {
            XCTAssertThrowsError(try MetadataWriter.write(store:store,base:base.header,cursor:101,value:{_ in .init(logicalSize:7)},fault:{ if $0 == point { throw SnapshotError.cancelled } }))
            XCTAssertEqual(good,try Data(contentsOf:URL(fileURLWithPath:store.metadataPath)))
        }
        try FileManager.default.removeItem(atPath:store.metadataPath)
        try FileManager.default.createSymbolicLink(atPath:store.metadataPath,withDestinationPath:store.path)
        XCTAssertThrowsError(try store.metadataReader(base:base.header))
        XCTAssertThrowsError(try MetadataWriter.write(store:store,base:base.header,cursor:100,value:{_ in .unknown}))
    }
    func testStateBindingCRCAndSeparateFloors() throws {
        let (cache,store,base) = try fixture(); defer { withExtendedLifetime(cache) {} }
        let h = try MetadataWriter.write(store:store,base:base.header,cursor:80,value:{_ in .unknown})
        XCTAssertEqual(MetadataCursorState.streamStart(namespaceCursor:100,metadataCursor:80),80)
        XCTAssertEqual(MetadataCursorState.streamStart(namespaceCursor:80,metadataCursor:100),80)
        try store.writeMetadataState(header:h,cursor:105); XCTAssertEqual(store.effectiveMetadataCursor(for:h).cursor,105)
        var d = try MetadataCursorState(header:h,cursor:105).encoded(); d[120] ^= 1; XCTAssertThrowsError(try MetadataCursorState.decode(d))
        try d.write(to:URL(fileURLWithPath:store.metadataPath+".state")); XCTAssertEqual(store.effectiveMetadataCursor(for:h).cursor,80)
        _ = try MetadataWriter.write(store:store,base:base.header,cursor:90,value:{_ in .unknown})
        XCTAssertFalse(store.effectiveMetadataCursor(for:try store.metadataReader(base:base.header).header).valid)
    }
}

final class BulkMetadataTests: XCTestCase {
    func testCheckedUnixTimeMissingAndTypes() throws {
        XCTAssertEqual(FileMetadataValue.unixNanoseconds(seconds:1,nanoseconds:2),1_000_000_002)
        XCTAssertEqual(FileMetadataValue.unixNanoseconds(seconds:-1,nanoseconds:2),-999_999_998)
        for (s,n) in [(Int64.max,Int64(0)),(Int64.min,0),(1,-1),(1,1_000_000_000)] { XCTAssertNil(FileMetadataValue.unixNanoseconds(seconds:s,nanoseconds:n)) }
        XCTAssertEqual(FileMetadataValue(APFSDirectoryEntry()),.unknown)
        let tree = try TemporaryTree(); try tree.directory("dir"); try Data(repeating:1,count:123).write(to:URL(fileURLWithPath:tree.path("Café")))
        try FileManager.default.createSymbolicLink(atPath:tree.path("link"),withDestinationPath:tree.path("Café"))
        XCTAssertEqual(mkfifo(tree.path("fifo"),0o600),0)
        let scanner = BulkScanner(root:tree.root)
        let entries = try scanner.scan().scannedEntries
        for name in ["Café","dir","link","fifo"] {
            let e = try XCTUnwrap(entries.first { $0.namespace.path == tree.path(name) })
            XCTAssertEqual(e.metadata.logicalSize,name == "Café" ? 123 : nil)
            var record = APFSDirectoryEntry(); XCTAssertEqual(apfs_entry_info(e.namespace.path,try scanner.rootDeviceID(),&record),0)
            XCTAssertEqual(e.metadata,FileMetadataValue(record)); XCTAssertNotNil(e.metadata.modificationTimeNanoseconds)
        }
    }
}

final class MetadataEventImpactTests: XCTestCase {
    func testIndependentContentNamespaceAndSpecialImpacts() {
        func impact(_ flags:UInt32)->MetadataEventImpact { .classify(.init(path:"/fixture/item",flags:flags,id:1)) }
        let file = UInt32(kFSEventStreamEventFlagItemIsFile),dir = UInt32(kFSEventStreamEventFlagItemIsDir)
        XCTAssertEqual(impact(file | UInt32(kFSEventStreamEventFlagItemModified)),.refreshSizeAndTime)
        XCTAssertEqual(impact(dir | UInt32(kFSEventStreamEventFlagItemInodeMetaMod)),.refreshTime)
        XCTAssertEqual(impact(file | UInt32(kFSEventStreamEventFlagItemCreated)),.refreshSizeAndTime)
        XCTAssertEqual(impact(file | UInt32(kFSEventStreamEventFlagItemRemoved)),.remove)
        XCTAssertEqual(impact(file | UInt32(kFSEventStreamEventFlagItemRenamed)),.refreshSizeAndTime)
        for flag in [kFSEventStreamEventFlagItemXattrMod,kFSEventStreamEventFlagItemFinderInfoMod,kFSEventStreamEventFlagItemChangeOwner] {
            XCTAssertEqual(impact(file | UInt32(flag)),.none)
        }
        XCTAssertEqual(impact(UInt32(kFSEventStreamEventFlagItemXattrMod)),.reconcileParent)
        XCTAssertEqual(impact(UInt32(kFSEventStreamEventFlagMustScanSubDirs)),.reconcileParent)
        XCTAssertEqual(impact(UInt32(kFSEventStreamEventFlagUserDropped)),.invalidated)
        XCTAssertEqual(impact(UInt32(kFSEventStreamEventFlagMount)),.invalidated)
        XCTAssertEqual(impact(1<<31),.reconcileParent)
        XCTAssertEqual(impact(UInt32(kFSEventStreamEventFlagHistoryDone)),.none)
    }
}
