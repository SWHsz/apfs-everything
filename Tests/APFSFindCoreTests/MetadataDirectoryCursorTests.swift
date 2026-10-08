import XCTest
import Foundation
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
    func testOrdinaryParentPagesRetainFenceAndRepairWritesToAlreadyReadPages() throws {
        let tree = try TemporaryTree(),cache = try TemporaryTree(cache:true)
        for i in 0..<2048 {try tree.file("file-\(i)")}
        let scan = try BulkScanner(root:tree.root).scan(),ram = FileIndex(root:tree.root)
        ram.apply(scan.entries.map(IndexMutation.upsert))
        let identity = try VolumeIdentity.discover(root:tree.root),store = try SnapshotStore(directory:cache.root,identity:identity)
        _ = try SnapshotV2Writer.write(source:.ram(ram,ram.stats().generation),identity:identity,generation:ram.stats().generation,cursor:100,store:store)
        let base = try XCTUnwrap(store.reader(expectedIdentity:identity).mappedBase),meta = MetadataIndexCoordinator(),metrics = Metrics()
        _ = try MetadataWriter.write(store:store,base:base.header,cursor:100,value:{_ in .init(logicalSize:999,modificationTimeNanoseconds:0)})
        meta.bind(namespace:base,mapped:try store.metadataReader(base:base.header));meta.advance(100,historyDone:true)
        let probe = try MetadataDirectoryCursor(path:tree.root,device:identity.deviceID,excludedRoots:[],metrics:Metrics())
        let first = try XCTUnwrap(probe.next(cancellation:CancellationToken()).first);probe.close()
        final class Mutation: @unchecked Sendable {
            var updater:MetadataUpdateCoordinator?
            var done = false
        }
        let mutation = Mutation(),target = first.namespace.path
        var policy = MetadataUpdatePolicy();policy.debounceSeconds = 60;policy.maxParentPagesPerSlice = 1
        let updater = MetadataUpdateCoordinator(root:tree.root,device:identity.deviceID,index:meta,namespace:HybridIndex(base:base),metrics:metrics,policy:policy,
            invalidated:{metrics.record("unexpected_bootstrap")},changed:{
                // Runs on the writer: enqueue the second event before any next
                // page can start, without depending on scheduling/test speed.
                guard metrics.snapshot()["metadata_parent_bulk_pages",default:0] > 0,!mutation.done else {return}
                mutation.done = true
                do {try Data(repeating:1,count:37).write(to:URL(fileURLWithPath:target))} catch {XCTFail("fixture write failed: \(error)")}
                mutation.updater?.enqueue([.init(path:target,flags:UInt32(kFSEventStreamEventFlagItemModified|kFSEventStreamEventFlagItemIsFile),id:102)])
            })
        mutation.updater = updater
        defer {updater.stop();mutation.updater = nil}
        // Explicit create/remove ambiguity requests a parent refresh without
        // invoking the ordinary-inbox overflow repair path.
        updater.enqueue([.init(path:target,flags:UInt32(kFSEventStreamEventFlagItemCreated|kFSEventStreamEventFlagItemRemoved|kFSEventStreamEventFlagItemIsFile),id:101)])
        updater.flush()
        XCTAssertEqual(meta.processedCursor,100)
        XCTAssertGreaterThan(updater.pendingCount,0)
        waitFor("paged ordinary parent and repeated write converge",timeout:5) {updater.flush();return meta.processedCursor == 102}
        XCTAssertEqual(meta.capture().value(path:target).logicalSize,37)
        for entry in scan.scannedEntries where entry.namespace.kind == .file && entry.namespace.path != target {
            XCTAssertEqual(meta.capture().value(path:entry.namespace.path),entry.metadata)
        }
        XCTAssertGreaterThan(metrics.snapshot()["metadata_parent_repeat_passes",default:0],0)
        XCTAssertGreaterThan(metrics.snapshot()["metadata_parent_bulk_pages",default:0],1)
        XCTAssertEqual(metrics.snapshot()["metadata_inbox_scope_repairs",default:0],0)
        XCTAssertEqual(metrics.snapshot()["unexpected_bootstrap",default:0],0)
    }

    func testCollapsedParentDoesNotRetainUnindexedSiblingMetadata() {
        let root = "/indexed-parent",ns = FileIndex(root:root),metrics = Metrics()
        let known = NamespaceEntry(path:root+"/known",kind:.file)
        ns.apply([.upsert(known)])
        let metadata = MetadataIndexCoordinator(overlayByteLimit:1024,overlayEntryLimit:4)
        let actual:[ScannedEntry] = [.init(namespace:known,metadata:.init(logicalSize:37))] + (0..<100).map {
            ScannedEntry(namespace:.init(path:root+"/unindexed-\($0)",kind:.file),metadata:.init(logicalSize:1))
        }
        let updater = MetadataUpdateCoordinator(root:root,device:0,index:metadata,namespace:ns,metrics:metrics,
            invalidated:{metrics.record("unexpected_recovery")},readDirectory:{_,_ in actual})
        defer {updater.stop()}
        updater.enqueue([.init(path:known.path,flags:UInt32(kFSEventStreamEventFlagItemCreated|kFSEventStreamEventFlagItemRemoved|kFSEventStreamEventFlagItemIsFile),id:101)])
        updater.flush()
        XCTAssertEqual(metadata.capture().value(path:known.path).logicalSize,37)
        XCTAssertEqual(metadata.resourceUsage().entries,1)
        XCTAssertFalse(metadata.requiresRecovery)
        XCTAssertEqual(metadata.capture().value(path:root+"/unindexed-0"),.unknown)
        XCTAssertEqual(metadata.processedCursor,101)
    }

}
