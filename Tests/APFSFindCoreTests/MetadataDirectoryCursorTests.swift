import XCTest
import CoreServices
@testable import APFSFindCore

final class MetadataDirectoryCursorTests: XCTestCase {
    func testNewStreamGapCannotBeClearedByAnOlderRecoveryTicket() throws {
        let tree = try TemporaryTree();try tree.file("file")
        let scan = try BulkScanner(root:tree.root).scan(),ns = FileIndex(root:tree.root)
        ns.apply(scan.entries.map(IndexMutation.upsert))
        let meta = MetadataIndexCoordinator(),metrics = Metrics();meta.advance(100,historyDone:true)
        let updater = MetadataUpdateCoordinator(root:tree.root,device:scan.rootDeviceID,index:meta,namespace:ns,metrics:metrics,invalidated:{metrics.record("recovery")})
        defer {updater.stop()}
        updater.enqueue([.init(path:tree.root,flags:UInt32(kFSEventStreamEventFlagKernelDropped),id:101),
            .init(path:tree.path("file"),flags:UInt32(kFSEventStreamEventFlagItemModified|kFSEventStreamEventFlagItemIsFile),id:102)])
        updater.flush();let old = updater.recoveryTicket
        XCTAssertEqual(meta.processedCursor,100)
        updater.enqueue([.init(path:tree.root,flags:UInt32(kFSEventStreamEventFlagUserDropped),id:103)]);updater.flush()
        XCTAssertFalse(updater.completeRecovery(ticket:old));updater.flush();XCTAssertEqual(meta.processedCursor,100)
        XCTAssertTrue(updater.completeRecovery(ticket:updater.recoveryTicket));updater.flush()
        XCTAssertEqual(meta.processedCursor,102);XCTAssertEqual(metrics.snapshot()["recovery"],2)
    }
    func testCursorRetainsBulkPositionAcrossPagesAndCancels() throws {
        let tree = try TemporaryTree()
        for i in 0..<2048 {try tree.file("file-\(i)")}
        let device = try BulkScanner(root:tree.root).rootDeviceID(),metrics = Metrics()
        let cursor = try MetadataDirectoryCursor(path:tree.root,device:device,excludedRoots:[],metrics:metrics)
        let token = CancellationToken()
        let first = try cursor.next(cancellation:token)
        XCTAssertFalse(cursor.finished);XCTAssertGreaterThan(first.count,0);XCTAssertLessThan(first.count,2048)
        var names = Set(first.map(\.namespace.path))
        while !cursor.finished {
            for entry in try cursor.next(cancellation:token) {XCTAssertTrue(names.insert(entry.namespace.path).inserted)}
        }
        XCTAssertEqual(names.count,2048);XCTAssertGreaterThan(metrics.snapshot()["metadata_subtree_bulk_pages",default:0],1)
        let cancelled = try MetadataDirectoryCursor(path:tree.root,device:device,excludedRoots:[],metrics:metrics)
        _ = try cancelled.next(cancellation:token);token.cancel()
        XCTAssertThrowsError(try cancelled.next(cancellation:token))
    }

    func testProductionOverflowPagesConvergeWithoutBootstrap() throws {
        let tree = try TemporaryTree(),cache = try TemporaryTree(cache:true)
        for i in 0..<2048 {try tree.file("file-\(i)")}
        let scan = try BulkScanner(root:tree.root).scan(),ram = FileIndex(root:tree.root)
        ram.apply(scan.entries.map(IndexMutation.upsert))
        let identity = try VolumeIdentity.discover(root:tree.root),store = try SnapshotStore(directory:cache.root,identity:identity)
        _ = try SnapshotV2Writer.write(source:.ram(ram,ram.stats().generation),identity:identity,generation:ram.stats().generation,cursor:100,store:store)
        let base = try XCTUnwrap(store.reader(expectedIdentity:identity).mappedBase),meta = MetadataIndexCoordinator(),metrics = Metrics()
        _ = try MetadataWriter.write(store:store,base:base.header,cursor:100,value:{_ in .init(logicalSize:999,modificationTimeNanoseconds:0)})
        meta.bind(namespace:base,mapped:try store.metadataReader(base:base.header));meta.advance(100,historyDone:true)
        var policy = MetadataUpdatePolicy();policy.maxPendingEntries = 2
        let updater = MetadataUpdateCoordinator(root:tree.root,device:identity.deviceID,index:meta,namespace:HybridIndex(base:base),metrics:metrics,policy:policy,invalidated:{metrics.record("unexpected_bootstrap")})
        defer {updater.stop()}
        updater.enqueue((0..<3).map {.init(path:tree.path("file-\($0)"),flags:UInt32(kFSEventStreamEventFlagItemModified|kFSEventStreamEventFlagItemIsFile),id:UInt64(101+$0))})
        waitFor("paged repair finishes",timeout:5) {updater.flush();return meta.processedCursor == 103}
        for entry in scan.scannedEntries where entry.namespace.kind == .file {XCTAssertEqual(meta.capture().value(path:entry.namespace.path),entry.metadata)}
        XCTAssertGreaterThan(metrics.snapshot()["metadata_subtree_bulk_pages",default:0],1)
        XCTAssertEqual(metrics.snapshot()["metadata_inbox_scope_passes"],1)
        XCTAssertEqual(metrics.snapshot()["unexpected_bootstrap",default:0],0)
    }
}
