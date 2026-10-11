import XCTest
import Foundation
import CoreServices
@testable import APFSFindCore

final class MetadataDirectoryCursorTests: XCTestCase {
    private struct PagedFixture {
        let tree: TemporaryTree, cache: TemporaryTree
        let identity: VolumeIdentity, base: MMapBaseIndex
        let meta: MetadataIndexCoordinator
        let metrics = Metrics()
        init() throws {
            let tree = try TemporaryTree(), cache = try TemporaryTree(cache:true)
            for i in 0..<2048 {try tree.file("file-\(i)")}
            let scan = try BulkScanner(root:tree.root).scan(), ram = FileIndex(root:tree.root)
            ram.apply(scan.entries.map(IndexMutation.upsert))
            let identity = try VolumeIdentity.discover(root:tree.root)
            let store = try SnapshotStore(directory:cache.root,identity:identity)
            _ = try SnapshotV2Writer.write(source:.ram(ram,ram.stats().generation),identity:identity,
                generation:ram.stats().generation,cursor:100,store:store)
            let base = try XCTUnwrap(store.reader(expectedIdentity:identity).mappedBase)
            let meta = MetadataIndexCoordinator()
            _ = try MetadataWriter.write(store:store,base:base.header,cursor:100,
                value:{_ in .init(logicalSize:999,modificationTimeNanoseconds:0)})
            meta.bind(namespace:base,mapped:try store.metadataReader(base:base.header));meta.advance(100,historyDone:true)
            self.tree = tree;self.cache = cache;self.identity = identity;self.base = base;self.meta = meta
        }
        func firstPage() throws -> [ScannedEntry] {
            let cursor = try MetadataDirectoryCursor(path:tree.root,device:identity.deviceID,
                excludedRoots:[],metrics:Metrics())
            defer {cursor.close()}
            return try cursor.next(cancellation:CancellationToken())
        }
    }

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
        XCTAssertGreaterThan(metrics.snapshot()["metadata_parent_compensation_paths",default:0],0)
        XCTAssertGreaterThan(metrics.snapshot()["metadata_parent_bulk_pages",default:0],1)
        XCTAssertEqual(metrics.snapshot()["metadata_inbox_scope_repairs",default:0],0)
        XCTAssertEqual(metrics.snapshot()["unexpected_bootstrap",default:0],0)
    }

    func testHotContentWritesFinishParentPassAndKeepOtherParentsCurrent() throws {
        let tree = try TemporaryTree(), cache = try TemporaryTree(cache:true)
        try tree.directory("hot");try tree.directory("quiet")
        for i in 0..<2048 {try tree.file("hot/file-\(i)")}
        try tree.file("quiet/target")
        let scan = try BulkScanner(root:tree.root).scan(), ram = FileIndex(root:tree.root)
        ram.apply(scan.entries.map(IndexMutation.upsert))
        let identity = try VolumeIdentity.discover(root:tree.root)
        let store = try SnapshotStore(directory:cache.root,identity:identity)
        _ = try SnapshotV2Writer.write(source:.ram(ram,ram.stats().generation),identity:identity,
            generation:ram.stats().generation,cursor:100,store:store)
        let base = try XCTUnwrap(store.reader(expectedIdentity:identity).mappedBase)
        let meta = MetadataIndexCoordinator(), metrics = Metrics()
        _ = try MetadataWriter.write(store:store,base:base.header,cursor:100,
            value:{_ in .init(logicalSize:999,modificationTimeNanoseconds:0)})
        meta.bind(namespace:base,mapped:try store.metadataReader(base:base.header));meta.advance(100,historyDone:true)
        let probe = try MetadataDirectoryCursor(path:tree.path("hot"),device:identity.deviceID,
            excludedRoots:[],metrics:Metrics())
        let hot = try XCTUnwrap(probe.next(cancellation:CancellationToken()).first).namespace.path
        probe.close()
        let quiet = tree.path("quiet/target")
        try Data(repeating:1,count:13).write(to:URL(fileURLWithPath:quiet))
        final class Input: @unchecked Sendable {
            let lock = NSLock()
            var enabled = true, pages = 0, size = 0
            var updater: MetadataUpdateCoordinator?
        }
        let input = Input()
        var policy = MetadataUpdatePolicy();policy.debounceSeconds = 60;policy.maxParentPagesPerSlice = 1
        let updater = MetadataUpdateCoordinator(root:tree.root,device:identity.deviceID,index:meta,
            namespace:HybridIndex(base:base),metrics:metrics,policy:policy,
            invalidated:{metrics.record("unexpected_bootstrap")},changed:{
                let pages = metrics.snapshot()["metadata_parent_bulk_pages",default:0]
                let write = input.lock.withLock { () -> Bool in
                    guard input.enabled,pages > input.pages else {return false}
                    input.pages = pages;input.size = 37 + pages;return true
                }
                guard write else {return}
                do {try Data(repeating:1,count:37+pages).write(to:URL(fileURLWithPath:hot))}
                catch {XCTFail("fixture write failed: \(error)")}
                var events = [FileSystemEvent(path:hot,flags:UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile),id:UInt64(200+pages))]
                if pages == 1 {events.append(.init(path:quiet,flags:UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile),id:101))}
                input.updater?.enqueue(events)
            })
        input.updater = updater
        defer {updater.stop();input.updater = nil}
        updater.enqueue([.init(path:hot,flags:UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile),id:101)])
        // Every completed page generates another typed content write. Refresh
        // those known paths without indefinitely restarting a full parent pass.
        for _ in 0..<30 {updater.flush()}
        XCTAssertEqual(meta.capture().value(path:quiet).logicalSize,13)
        XCTAssertGreaterThan(meta.processedCursor,100)
        XCTAssertEqual(metrics.snapshot()["metadata_parent_repeat_passes",default:0],0)
        input.lock.withLock {input.enabled = false}
        waitFor("all post-page content writes converge",timeout:5) {updater.flush();return updater.pendingCount == 0}
        XCTAssertEqual(meta.capture().value(path:hot).logicalSize,UInt64(input.lock.withLock {input.size}))
        XCTAssertEqual(meta.capture().value(path:quiet).logicalSize,13)
        XCTAssertEqual(metrics.snapshot()["unexpected_bootstrap",default:0],0)
    }

    func testLateContentBudgetFallsBackToAuthoritativeParentPass() throws {
        let f = try PagedFixture(), page = try f.firstPage()
        XCTAssertGreaterThan(page.count,26)
        let requested = Array(page.prefix(20).map { $0.namespace.path })
        let late = Array(page.dropFirst(20).prefix(6).map { $0.namespace.path })
        final class Input: @unchecked Sendable {var done = false;var updater:MetadataUpdateCoordinator?}
        let input = Input(), metrics = f.metrics
        var policy = MetadataUpdatePolicy();policy.debounceSeconds = 60
        policy.maxPendingEntries = 25;policy.smallBatchLimit = 0;policy.stormParentCollapseThreshold = 1;policy.maxParentPagesPerSlice = 1
        let updater = MetadataUpdateCoordinator(root:f.tree.root,device:f.identity.deviceID,index:f.meta,
            namespace:HybridIndex(base:f.base),metrics:f.metrics,policy:policy,
            invalidated:{metrics.record("unexpected_bootstrap")},changed:{
                guard !input.done,metrics.snapshot()["metadata_parent_bulk_pages",default:0]>0 else {return}
                input.done = true
                for (offset,path) in late.enumerated() {
                    do {try Data(repeating:1,count:37+offset).write(to:URL(fileURLWithPath:path))}
                    catch {XCTFail("fixture write failed: \(error)")}
                }
                input.updater?.enqueue(late.enumerated().map { offset,path in
                    FileSystemEvent(path:path,flags:UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile),id:UInt64(200+offset))
                })
            })
        input.updater = updater;defer {updater.stop();input.updater = nil}
        updater.enqueue(requested.enumerated().map {offset,path in
            FileSystemEvent(path:path,flags:UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile),id:UInt64(101+offset))
        })
        waitFor("bounded fallback completes",timeout:5) {updater.flush();return f.meta.processedCursor == 205}
        for (offset,path) in late.enumerated() {XCTAssertEqual(f.meta.capture().value(path:path).logicalSize,UInt64(37+offset))}
        XCTAssertGreaterThan(f.metrics.snapshot()["metadata_parent_repeat_passes",default:0],0)
        XCTAssertEqual(f.metrics.snapshot()["unexpected_bootstrap",default:0],0)
    }

    func testLateContentBudgetExpandsPartialParentPass() throws {
        let f = try PagedFixture(), page = try f.firstPage()
        XCTAssertGreaterThan(page.count,306)
        // Dense enough to enumerate, below the storm threshold: the first
        // pass must refresh only its requested paths. Late writes are outside
        // that set and precede the compensation budget fallback.
        let requested = Array(page.prefix(300).map { $0.namespace.path })
        let late = Array(page.dropFirst(300).prefix(6).map { $0.namespace.path })
        final class Input: @unchecked Sendable {var done = false;var updater:MetadataUpdateCoordinator?}
        let input = Input(), metrics = f.metrics
        var policy = MetadataUpdatePolicy();policy.debounceSeconds = 60
        policy.maxPendingEntries = 305;policy.smallBatchLimit = 0;policy.stormParentCollapseThreshold = 512;policy.maxParentPagesPerSlice = 1
        let updater = MetadataUpdateCoordinator(root:f.tree.root,device:f.identity.deviceID,index:f.meta,
            namespace:HybridIndex(base:f.base),metrics:f.metrics,policy:policy,
            invalidated:{metrics.record("unexpected_bootstrap")},changed:{
                guard !input.done,metrics.snapshot()["metadata_parent_bulk_pages",default:0]>0 else {return}
                input.done = true
                for (offset,path) in late.enumerated() {
                    do {try Data(repeating:1,count:37+offset).write(to:URL(fileURLWithPath:path))}
                    catch {XCTFail("fixture write failed: \(error)")}
                }
                input.updater?.enqueue(late.enumerated().map { offset,path in
                    FileSystemEvent(path:path,flags:UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile),id:UInt64(1000+offset))
                })
            })
        input.updater = updater;defer {updater.stop();input.updater = nil}
        updater.enqueue(requested.enumerated().map {offset,path in
            FileSystemEvent(path:path,flags:UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile),id:UInt64(101+offset))
        })
        waitFor("bounded fallback completes",timeout:5) {updater.flush();return f.meta.processedCursor == 1005}
        for (offset,path) in late.enumerated() {XCTAssertEqual(f.meta.capture().value(path:path).logicalSize,UInt64(37+offset))}
        XCTAssertGreaterThan(f.metrics.snapshot()["metadata_parent_repeat_passes",default:0],0)
        XCTAssertEqual(f.metrics.snapshot()["unexpected_bootstrap",default:0],0)
    }

    func testPublicationRetainsLateContentOutsideOriginalRequestedPaths() throws {
        let f = try PagedFixture(), page = try f.firstPage()
        XCTAssertGreaterThan(page.count,300)
        let requested = Array(page.prefix(300).map { $0.namespace.path })
        let late = page[300].namespace.path
        final class Input: @unchecked Sendable {var done = false;var updater:MetadataUpdateCoordinator?}
        let input = Input(), metrics = f.metrics
        var policy = MetadataUpdatePolicy();policy.debounceSeconds = 60
        policy.maxPendingEntries = 700;policy.maxParentPagesPerSlice = 1
        let updater = MetadataUpdateCoordinator(root:f.tree.root,device:f.identity.deviceID,index:f.meta,
            namespace:HybridIndex(base:f.base),metrics:f.metrics,policy:policy,
            invalidated:{metrics.record("unexpected_bootstrap")},changed:{
                guard !input.done,metrics.snapshot()["metadata_parent_bulk_pages",default:0]>0 else {return}
                input.done = true
                do {try Data(repeating:1,count:37).write(to:URL(fileURLWithPath:late))}
                catch {XCTFail("fixture write failed: \(error)")}
                input.updater?.enqueue([.init(path:late,flags:UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile),id:500)])
            })
        input.updater = updater;defer {updater.stop();input.updater = nil}
        updater.enqueue(requested.enumerated().map {offset,path in
            FileSystemEvent(path:path,flags:UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile),id:UInt64(101+offset))
        })
        updater.flush();updater.suspend()
        XCTAssertEqual(f.meta.processedCursor,100)
        updater.resume()
        waitFor("publication retains late content",timeout:5) {updater.flush();return f.meta.processedCursor == 500}
        XCTAssertEqual(f.meta.capture().value(path:late).logicalSize,37)
        XCTAssertEqual(f.metrics.snapshot()["unexpected_bootstrap",default:0],0)
    }

    func testDirectoryEventPreservesLateContentOutsidePartialPass() throws {
        let f = try PagedFixture(), page = try f.firstPage()
        XCTAssertGreaterThan(page.count,300)
        let requested = Array(page.prefix(300).map { $0.namespace.path })
        let late = page[300].namespace.path
        final class Input: @unchecked Sendable {var done = false;var updater:MetadataUpdateCoordinator?}
        let input = Input(), metrics = f.metrics
        var policy = MetadataUpdatePolicy();policy.debounceSeconds = 60
        policy.maxPendingEntries = 700;policy.maxParentPagesPerSlice = 1
        let updater = MetadataUpdateCoordinator(root:f.tree.root,device:f.identity.deviceID,index:f.meta,
            namespace:HybridIndex(base:f.base),metrics:f.metrics,policy:policy,
            invalidated:{metrics.record("unexpected_bootstrap")},changed:{
                guard !input.done,metrics.snapshot()["metadata_parent_bulk_pages",default:0]>0 else {return}
                input.done = true
                do {try Data(repeating:1,count:37).write(to:URL(fileURLWithPath:late))}
                catch {XCTFail("fixture write failed: \(error)")}
                input.updater?.enqueue([.init(path:late,flags:UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile),id:500)])
            })
        input.updater = updater;defer {updater.stop();input.updater = nil}
        updater.enqueue(requested.enumerated().map {offset,path in
            FileSystemEvent(path:path,flags:UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile),id:UInt64(101+offset))
        })
        updater.flush();updater.flush()
        XCTAssertEqual(f.meta.processedCursor,100)
        XCTAssertGreaterThan(updater.pendingCount,0)
        updater.enqueue([.init(path:f.tree.root,flags:UInt32(kFSEventStreamEventFlagItemInodeMetaMod | kFSEventStreamEventFlagItemIsDir),id:501)])
        waitFor("directory event retains late content",timeout:5) {updater.flush();return f.meta.processedCursor == 501}
        XCTAssertEqual(f.meta.capture().value(path:late).logicalSize,37)
        XCTAssertEqual(f.metrics.snapshot()["unexpected_bootstrap",default:0],0)
    }

    func testOrdinaryNewDirectoryUsesPagesAndRetainsCursorFence() throws {
        let tree = try TemporaryTree(),cache = try TemporaryTree(cache:true)
        try tree.file("seed")
        let original = try BulkScanner(root:tree.root).scan(),ram = FileIndex(root:tree.root)
        ram.apply(original.entries.map(IndexMutation.upsert))
        let identity = try VolumeIdentity.discover(root:tree.root),store = try SnapshotStore(directory:cache.root,identity:identity)
        _ = try SnapshotV2Writer.write(source:.ram(ram,ram.stats().generation),identity:identity,generation:ram.stats().generation,cursor:100,store:store)
        let base = try XCTUnwrap(store.reader(expectedIdentity:identity).mappedBase),ns = HybridIndex(base:base),meta = MetadataIndexCoordinator(),metrics = Metrics()
        _ = try MetadataWriter.write(store:store,base:base.header,cursor:100,value:{_ in .unknown})
        meta.bind(namespace:base,mapped:try store.metadataReader(base:base.header));meta.advance(100,historyDone:true)
        try tree.directory("incoming")
        for i in 0..<2048 {
            try Data(repeating:1,count:i % 23).write(to:URL(fileURLWithPath:tree.path("incoming/file-\(i)")))
        }
        let incoming = try BulkScanner(root:tree.root).scan().scannedEntries.filter {
            PathCanonicalizer.isWithin($0.namespace.path,root:tree.path("incoming"))
        }
        ns.apply(incoming.map { .upsert($0.namespace) })
        var policy = MetadataUpdatePolicy();policy.debounceSeconds = 60
        let updater = MetadataUpdateCoordinator(root:tree.root,device:identity.deviceID,index:meta,namespace:ns,metrics:metrics,policy:policy,invalidated:{metrics.record("unexpected_bootstrap")})
        defer {updater.stop()}
        SystemResourceSignals.shared.beginQuery()
        updater.enqueue([.init(path:tree.path("incoming"),flags:UInt32(kFSEventStreamEventFlagItemCreated|kFSEventStreamEventFlagItemIsDir),id:101)])
        updater.flush()
        SystemResourceSignals.shared.endQuery()
        XCTAssertEqual(meta.processedCursor,100,"a partial subtree must retain its replay fence")
        XCTAssertGreaterThan(updater.pendingCount,0)
        XCTAssertGreaterThan(metrics.snapshot()["metadata_subtree_bulk_pages",default:0],0)
        waitFor("ordinary directory pages converge",timeout:10) {updater.flush();return meta.processedCursor == 101}
        let snapshot = meta.capture()
        for entry in incoming where entry.namespace.kind == .file {
            XCTAssertEqual(snapshot.value(path:entry.namespace.path),entry.metadata)
        }
        XCTAssertGreaterThan(metrics.snapshot()["metadata_subtree_bulk_pages",default:0],1)
        XCTAssertLessThan(metrics.snapshot()["metadata_subtree_batch_entries_max",default:2048],2048)
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
