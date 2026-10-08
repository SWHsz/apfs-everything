import CAPFSShim
import CoreServices
import Darwin
import Foundation
import XCTest
@testable import APFSFindCore

final class MetadataIntegrationTests: XCTestCase {

    func testDuplicateMetadataBurstCoalescesWithoutInvalidatingButDistinctOverflowRemainsHard() throws {
        let tree = try TemporaryTree(); try tree.file("mutable")
        try Data(repeating:1,count:123).write(to:URL(fileURLWithPath:tree.path("mutable")))
        let ns = FileIndex(root:tree.root),meta = MetadataIndexCoordinator(),metrics = Metrics()
        ns.apply([.upsert(.init(path:tree.path("mutable"),kind:.file))])
        var policy = MetadataUpdatePolicy(); policy.maxPendingEntries = 32; policy.debounceSeconds = 60
        let updater = MetadataUpdateCoordinator(root:tree.root,device:try BulkScanner(root:tree.root).rootDeviceID(),index:meta,namespace:ns,metrics:metrics,policy:policy,invalidated:{metrics.record("test_invalidations")})
        defer {updater.stop()}
        let flags = UInt32(kFSEventStreamEventFlagItemModified|kFSEventStreamEventFlagItemIsFile)
        updater.enqueue((1...10_000).map {.init(path:tree.path("mutable"),flags:flags,id:UInt64($0))} + [.init(path:tree.root,flags:UInt32(kFSEventStreamEventFlagHistoryDone),id:UInt64.max)])
        updater.flush()
        XCTAssertEqual(meta.capture().value(path:tree.path("mutable")).logicalSize,123)
        XCTAssertEqual(meta.processedCursor,10_000)
        XCTAssertEqual(metrics.snapshot()["test_invalidations",default:0],0)
        XCTAssertEqual(metrics.snapshot()["metadata_inbox_events_coalesced"],9999)
        updater.enqueue([.init(path:tree.path("mutable"),flags:UInt32(kFSEventStreamEventFlagItemCreated|kFSEventStreamEventFlagItemIsFile),id:10_001),.init(path:tree.path("mutable"),flags:UInt32(kFSEventStreamEventFlagItemRemoved|kFSEventStreamEventFlagItemIsFile),id:10_002)])
        updater.flush()
        XCTAssertEqual(meta.capture().value(path:tree.path("mutable")).logicalSize,123,"merged create/remove refreshes the authoritative parent")
        updater.enqueue((1...33).map {.init(path:tree.path("distinct-\($0)"),flags:flags,id:UInt64(10_000+$0))})
        updater.flush()
        XCTAssertEqual(metrics.snapshot()["test_invalidations"],1,"distinct pending paths still have a hard cap")
        updater.enqueue([.init(path:tree.root,flags:UInt32(kFSEventStreamEventFlagHistoryDone|kFSEventStreamEventFlagKernelDropped),id:UInt64.max)]);updater.flush()
        XCTAssertEqual(metrics.snapshot()["test_invalidations"],2,"a history marker cannot hide real stream invalidation")
    }
    func testDirectoryRenameOriginCapFallsBackToScopedMetadataTraversal() throws {
        let cache = try TemporaryTree(cache:true),identity = snapshotIdentity(),ram = FileIndex(root:snapshotIdentity().root)
        let store = try SnapshotStore(directory:cache.root,identity:identity)
        let oldPaths = (1...65).map { identity.root+"/old-\($0)" },newPath = identity.root+"/new"
        ram.apply(oldPaths.enumerated().map {.upsert(.init(path:$0.element,kind:.directory,deviceID:identity.deviceID,fileID:UInt64($0.offset+1)))})
        _ = try SnapshotV2Writer.write(source:.ram(ram,ram.stats().generation),identity:identity,generation:ram.stats().generation,cursor:0,store:store)
        let base = try store.reader(expectedIdentity:identity).mappedBase!,ns = HybridIndex(base:base),meta = MetadataIndexCoordinator(),metrics = Metrics()
        _ = try MetadataWriter.write(store:store,base:base.header,cursor:0,value:{_ in .init(logicalSize:7)})
        meta.bind(namespace:base,mapped:try store.metadataReader(base:base.header));meta.advance(0,historyDone:true)
        var policy = MetadataUpdatePolicy();policy.debounceSeconds = 60
        let updater = MetadataUpdateCoordinator(root:identity.root,device:identity.deviceID,index:meta,namespace:ns,metrics:metrics,policy:policy,invalidated:{metrics.record("test_invalidations")},readDirectory:{path,_ in
            path == newPath ? [.init(namespace:.init(path:newPath+"/leaf",kind:.file,deviceID:identity.deviceID,fileID:99),metadata:.init(logicalSize:123,modificationTimeNanoseconds:456))] : []
        })
        defer {updater.stop()}
        ns.apply(oldPaths.map(IndexMutation.remove))
        updater.enqueue(oldPaths.prefix(64).enumerated().map {.init(path:$0.element,flags:UInt32(kFSEventStreamEventFlagItemRenamed|kFSEventStreamEventFlagItemIsDir),id:UInt64($0.offset+1))});updater.flush()
        updater.enqueue([.init(path:oldPaths[64],flags:UInt32(kFSEventStreamEventFlagItemRenamed|kFSEventStreamEventFlagItemIsDir),id:65)]);updater.flush()
        XCTAssertEqual(metrics.snapshot()["metadata_rename_origin_snapshots"],64)
        XCTAssertEqual(metrics.snapshot()["metadata_rename_origin_snapshot_rejected"],1)
        ns.apply([.upsert(.init(path:newPath,kind:.directory,deviceID:identity.deviceID,fileID:65)),.upsert(.init(path:newPath+"/leaf",kind:.file,deviceID:identity.deviceID,fileID:99))])
        updater.enqueue([.init(path:newPath,flags:UInt32(kFSEventStreamEventFlagItemRenamed|kFSEventStreamEventFlagItemIsDir),id:66)]);updater.flush()
        waitFor("rejected directory origin still repairs its descendants",timeout:10) {updater.flush();return updater.pendingCount == 0}
        XCTAssertEqual(meta.capture().value(path:newPath+"/leaf"),.init(logicalSize:123,modificationTimeNanoseconds:456))
        XCTAssertEqual(meta.processedCursor,66)
        XCTAssertEqual(metrics.snapshot()["test_invalidations",default:0],0)
    }
    func testUnpairedFileRenameDoesNotPinObsoleteMetadataMap() throws {
        let cache = try TemporaryTree(cache:true), identity = snapshotIdentity()
        let store = try SnapshotStore(directory:cache.root,identity:identity)
        let ram = FileIndex(root:identity.root), oldPath = identity.root+"/old", newPath = identity.root+"/new"
        ram.apply([.upsert(.init(path:oldPath,kind:.file,deviceID:identity.deviceID,fileID:17))])
        _ = try SnapshotV2Writer.write(source:.ram(ram,ram.stats().generation),identity:identity,generation:ram.stats().generation,cursor:0,store:store)
        let base = try store.reader(expectedIdentity:identity).mappedBase!, namespace = HybridIndex(base:base)
        _ = try MetadataWriter.write(store:store,base:base.header,cursor:0,value:{ _ in .init(logicalSize:7,modificationTimeNanoseconds:99) })
        let metadata = MetadataIndexCoordinator(), metrics = Metrics()
        weak var obsolete: MMapMetadataIndex?
        do {
            let mapped = try store.metadataReader(base:base.header)
            obsolete = mapped; metadata.bind(namespace:base,mapped:mapped)
        }
        metadata.advance(0,historyDone:true)
        let updater = MetadataUpdateCoordinator(root:identity.root,device:identity.deviceID,index:metadata,namespace:namespace,metrics:metrics,invalidated:{ metrics.record("unexpected_recovery") })
        defer { updater.stop() }
        namespace.apply([.remove(oldPath)])
        updater.enqueue([.init(path:oldPath,flags:UInt32(kFSEventStreamEventFlagItemRenamed|kFSEventStreamEventFlagItemIsFile),id:1)])
        updater.flush()
        // The unmatched old-name event only needs its scalar metadata. A base
        // replacement must release the obsolete map despite that pending pair.
        metadata.bind(namespace:base); metadata.advance(1,historyDone:true)
        XCTAssertNil(obsolete,"file rename origins must not retain a whole query snapshot")
        namespace.apply([.upsert(.init(path:newPath,kind:.file,deviceID:identity.deviceID,fileID:17))])
        updater.enqueue([.init(path:newPath,flags:UInt32(kFSEventStreamEventFlagItemRenamed|kFSEventStreamEventFlagItemIsFile),id:2)])
        updater.flush()
        XCTAssertEqual(metadata.capture().value(path:newPath),.init(logicalSize:7,modificationTimeNanoseconds:99))
        XCTAssertEqual(metrics.snapshot()["metadata_rename_reuses"],1)
        XCTAssertEqual(metrics.snapshot()["unexpected_recovery",default:0],0)
    }
    func testWideSubtreeYieldStopsWholeSliceAndRetainsEverySibling() {
        let root = "/metadata-wide-frontier", ns = FileIndex(root:root)
        let meta = MetadataIndexCoordinator(), metrics = Metrics()
        let directories = (0..<1000).map { NamespaceEntry(path:root+"/d-\($0)",kind:.directory) }
        ns.apply(directories.flatMap { [.upsert($0),.upsert(.init(path:$0.path+"/leaf",kind:.file))] })
        var policy = MetadataUpdatePolicy(); policy.debounceSeconds = 60
        let updater = MetadataUpdateCoordinator(root:root,device:0,index:meta,namespace:ns,metrics:metrics,policy:policy,
            invalidated:{ metrics.record("test_recoveries") },readDirectory:{ path,_ in
                if path == root { return directories.map { .init(namespace:$0) } }
                metrics.record("test_child_attempts")
                if metrics.snapshot()["test_child_attempts"] == 1 {
                    metrics.record("test_injected_yields"); throw MaintenanceYield(reason:"held wide frontier")
                }
                return [.init(namespace:.init(path:path+"/leaf",kind:.file),
                    metadata:.init(logicalSize:123,modificationTimeNanoseconds:456))]
            })
        defer { updater.stop() }
        SystemResourceSignals.shared.beginQuery()
        updater.enqueue([.init(path:root,flags:UInt32(kFSEventStreamEventFlagMustScanSubDirs),id:101)])
        updater.flush(); updater.flush(); updater.flush()
        let snapshot = metrics.snapshot()
        // One yield ends the whole budget, not each remaining sibling root.
        // This bound is independent of timer interleaving and frontier width.
        XCTAssertLessThanOrEqual(snapshot["metadata_subtree_yields",default:0],
            snapshot["metadata_subtree_bulk_enumerations",default:0]+snapshot["test_injected_yields",default:0])
        XCTAssertGreaterThan(updater.pendingCount,0); XCTAssertEqual(meta.processedCursor,0)
        SystemResourceSignals.shared.endQuery()
        waitFor("every retained sibling receives metadata",timeout:10) {
            updater.flush(); return updater.pendingCount == 0
        }
        let values = meta.capture()
        for directory in directories {
            XCTAssertEqual(values.value(path:directory.path+"/leaf"),.init(logicalSize:123,modificationTimeNanoseconds:456))
        }
        XCTAssertEqual(meta.processedCursor,101)
        XCTAssertEqual(metrics.snapshot()["test_injected_yields"],1)
        XCTAssertEqual(metrics.snapshot()["test_recoveries",default:0],0)
    }
    func testTransientAuthoritativeIORecoversLocallyBeforeBootstrapThreshold() {
        let root = "/metadata-io-retry", parent = root + "/parent", child = parent + "/child"
        let ns = FileIndex(root:root), meta = MetadataIndexCoordinator(), metrics = Metrics()
        ns.apply([.upsert(.init(path:parent,kind:.directory)), .upsert(.init(path:child,kind:.file))])
        var policy = MetadataUpdatePolicy(); policy.debounceSeconds = 60
        let updater = MetadataUpdateCoordinator(root:root,device:0,index:meta,namespace:ns,metrics:metrics,policy:policy,
            invalidated:{ metrics.record("test_recoveries") },readDirectory:{ path,_ in
                if path != parent { return [] }
                metrics.record("test_reads")
                if metrics.snapshot()["test_reads",default:0] <= 2 { throw ScannerError(path:path,code:EIO) }
                return [.init(namespace:.init(path:child,kind:.file),metadata:.init(logicalSize:456))]
            })
        defer { updater.stop() }
        updater.enqueue([.init(path:parent,flags:UInt32(kFSEventStreamEventFlagItemXattrMod),id:101)])
        for _ in 0..<2 {
            updater.flush(); XCTAssertGreaterThan(updater.pendingCount,0); XCTAssertEqual(meta.processedCursor,0)
        }
        updater.flush()
        XCTAssertEqual(updater.pendingCount,0); XCTAssertEqual(meta.processedCursor,101)
        XCTAssertEqual(meta.capture().value(path:child).logicalSize,456)
        XCTAssertEqual(metrics.snapshot()["test_recoveries",default:0],0)
    }
    func testParentPermissionAndDisappearanceDoNotRestartWholeMetadataBuild() throws {
        let root = "/metadata-error-test", parent = root+"/protected", path = parent+"/child"
        for code in [EPERM,EACCES,ENODATA,ENOENT,ENOTDIR,ELOOP,EXDEV,EIO,EOVERFLOW] {
            let ns = FileIndex(root:root), meta = MetadataIndexCoordinator(), metrics = Metrics()
            ns.apply([.upsert(.init(path:parent,kind:.directory)),.upsert(.init(path:path,kind:.file))])
            meta.update(path:path,value:.init(logicalSize:123))
            let updater = MetadataUpdateCoordinator(root:root,device:0,index:meta,namespace:ns,metrics:metrics,
                invalidated:{ metrics.record("test_recoveries") },readDirectory:{ directory,_ in
                    if directory != parent { return [] }
                    throw ScannerError(path:directory,code:code)
                })
            for id in 1...20 {
                updater.enqueue([.init(path:parent,flags:UInt32(kFSEventStreamEventFlagItemXattrMod),id:UInt64(id))]); updater.flush()
            }
            XCTAssertEqual(metrics.snapshot()["test_recoveries",default:0],code == EOVERFLOW ? 20 : (code == EIO ? 1 : 0),"errno \(code)")
            XCTAssertEqual(metrics.snapshot()["metadata_parent_errno_\(code)"],20)
            XCTAssertEqual(meta.capture().value(path:path).logicalSize,123,"unreadable metadata must survive")
            if code == EIO {
                XCTAssertGreaterThan(updater.pendingCount,0)
                XCTAssertEqual(meta.processedCursor,0,"failed local work pins metadata cursor")
            } else { XCTAssertEqual(updater.pendingCount,0) }
            updater.stop()
        }
        // Root permission exclusions are local too; stream identity invalidation is separate.
        let ns = FileIndex(root:root), meta = MetadataIndexCoordinator(), metrics = Metrics()
        let updater = MetadataUpdateCoordinator(root:root,device:0,index:meta,namespace:ns,metrics:metrics,
            invalidated:{ metrics.record("test_recoveries") },readDirectory:{ directory,_ in throw ScannerError(path:directory,code:EPERM) })
        updater.enqueue([.init(path:root+"/missing",flags:UInt32(kFSEventStreamEventFlagItemXattrMod),id:1)]); updater.flush()
        XCTAssertEqual(metrics.snapshot()["test_recoveries",default:0],0); updater.stop()
    }

    func testParentQueryYieldRetriesWithoutMetadataBootstrapOrCursorAdvance() {
        let root = "/metadata-yield-test", parent = root+"/incoming", path = parent+"/child"
        let ns = FileIndex(root:root), meta = MetadataIndexCoordinator(), metrics = Metrics()
        ns.apply([.upsert(.init(path:parent,kind:.directory)),.upsert(.init(path:path,kind:.file))])
        var policy = MetadataUpdatePolicy(); policy.debounceSeconds = 60
        let updater = MetadataUpdateCoordinator(root:root,device:0,index:meta,namespace:ns,metrics:metrics,policy:policy,
            invalidated:{ metrics.record("test_recoveries") },readDirectory:{ _,_ in
                metrics.record("test_reads")
                if metrics.snapshot()["test_reads"] == 1 { throw MaintenanceYield(reason:"active query") }
                return [.init(namespace:.init(path:path,kind:.file),metadata:.init(logicalSize:456))]
            })
        updater.enqueue([.init(path:parent,flags:UInt32(kFSEventStreamEventFlagItemXattrMod),id:101)]); updater.flush()
        XCTAssertEqual(metrics.snapshot()["metadata_parent_yields"],1)
        XCTAssertEqual(metrics.snapshot()["test_recoveries",default:0],0)
        XCTAssertGreaterThan(updater.pendingCount,0); XCTAssertEqual(meta.processedCursor,0)
        updater.flush()
        XCTAssertEqual(meta.capture().value(path:path).logicalSize,456)
        XCTAssertEqual(meta.processedCursor,101); XCTAssertEqual(updater.pendingCount,0)
        updater.stop()
    }

    private func coordinator(_ tree:TemporaryTree,_ cache:TemporaryTree) throws -> PersistentIndexCoordinator {
        var policy = CompactionPolicy(); policy.liveLimit = 1_000_000; policy.overlayRatio = 10_000; policy.tombstoneRatio = 10_000
        return try .init(root:tree.root,cacheDirectory:cache.root,compactionPolicy:policy,maintenanceScheduler:.init())
    }
    private func ready(_ c:PersistentIndexCoordinator) throws {
        try c.start(); XCTAssertTrue(c.waitUntilLive(timeout:30)); XCTAssertTrue(c.waitForMetadata(timeout:30))
    }
    func testColdContentDebouncePauseAndFastRestart() throws {
        try requireFSEvents()
        let tree = try TemporaryTree(), cache = try TemporaryTree(cache:true); try tree.file("target")
        let c = try coordinator(tree,cache); try ready(c)
        let identity = try VolumeIdentity.discover(root:tree.root), store = try SnapshotStore(directory:cache.root,identity:identity)
        let original = try Data(contentsOf:URL(fileURLWithPath:store.path)), oldMeta = try Data(contentsOf:URL(fileURLWithPath:store.metadataPath))
        let generation = c.index.stats().generation, before = c.metrics.snapshot()
        let contentStarted = ProcessInfo.processInfo.systemUptime
        for i in 1...10_000 { try Data(repeating:1,count:(i%100)+1).write(to:URL(fileURLWithPath:tree.path("target"))) }
        waitFor("metadata content convergence",timeout:10) { c.metadata.capture().value(path:tree.path("target")).logicalSize == 1 }
        XCTAssertEqual(c.index.stats().generation,generation)
        // Continuous input now makes bounded progress instead of moving a
        // trailing deadline forever. Bound lookups by the existing 0.2s batch
        // interval, including the final converged lookup, rather than host I/O speed.
        let allowed = Int(ceil((ProcessInfo.processInfo.systemUptime-contentStarted)/MetadataUpdatePolicy().debounceSeconds))+2
        XCTAssertLessThanOrEqual(c.metrics.snapshot()["metadata_lookups",default:0]-before["metadata_lookups",default:0],allowed)
        c.pause(); let old = c.metadata.capture().value(path:tree.path("target"))
        try Data(repeating:2,count:200).write(to:URL(fileURLWithPath:tree.path("target")))
        XCTAssertEqual(c.metadata.capture().value(path:tree.path("target")),old); XCTAssertEqual(c.metadata.capture().freshness,.pausedStale)
        try c.resume(); XCTAssertTrue(c.waitUntilLive(timeout:30))
        waitFor("resume metadata",timeout:10) { c.metadata.capture().value(path:tree.path("target")).logicalSize == 200 }
        c.stop(policy:.fast)
        XCTAssertEqual(original,try Data(contentsOf:URL(fileURLWithPath:store.path)))
        XCTAssertEqual(oldMeta,try Data(contentsOf:URL(fileURLWithPath:store.metadataPath)))
        try Data(repeating:3,count:333).write(to:URL(fileURLWithPath:tree.path("target")))
        let next = try coordinator(tree,cache); defer { next.stop(policy:.fast) }; try ready(next)
        waitFor("restart metadata replay",timeout:10) { next.metadata.capture().value(path:tree.path("target")).logicalSize == 333 }
        XCTAssertEqual(next.metrics.snapshot()["full_scans",default:0],0)
        let scanned = try BulkScanner(root:tree.root).scan().scannedEntries.first { $0.namespace.path == tree.path("target") }
        XCTAssertEqual(next.metadata.capture().value(path:tree.path("target")),scanned?.metadata)
    }
    func testMissingCorruptMetadataBootstrapLeavesNamespaceBytesUnchanged() throws {
        try requireFSEvents()
        let tree = try TemporaryTree(),cache = try TemporaryTree(cache:true); try tree.file("target")
        let first = try coordinator(tree,cache); try ready(first); first.stop(policy:.fast)
        let identity = try VolumeIdentity.discover(root:tree.root),store = try SnapshotStore(directory:cache.root,identity:identity)
        let bytes = try Data(contentsOf:URL(fileURLWithPath:store.path))
        for missing in [true,false] {
            if missing { try FileManager.default.removeItem(atPath:store.metadataPath) }
            else { try Data(repeating:0,count:300).write(to:URL(fileURLWithPath:store.metadataPath)) }
            let next = try coordinator(tree,cache); try next.start()
            XCTAssertTrue(next.readinessSnapshot().searchAvailable); XCTAssertEqual(next.search("target").hits.count,1)
            XCTAssertTrue(next.waitUntilLive(timeout:30)); XCTAssertTrue(next.waitForMetadata(timeout:30))
            XCTAssertEqual(next.metadata.capture().value(path:tree.path("target")).logicalSize,0)
            XCTAssertEqual(next.metrics.snapshot()["full_scans",default:0],0)
            XCTAssertEqual(bytes,try Data(contentsOf:URL(fileURLWithPath:store.path))); next.stop(policy:.fast)
        }
    }
    func testCreateDeleteRenameCompactionOrdinalAndMetadataOnlyCheckpoint() throws {
        try requireFSEvents()
        let tree = try TemporaryTree(),cache = try TemporaryTree(cache:true)
        try Data(repeating:1,count:7).write(to:URL(fileURLWithPath:tree.path("old")))
        let c = try coordinator(tree,cache); defer { c.stop(policy:.fast) }; try ready(c)
        try FileManager.default.moveItem(atPath:tree.path("old"),toPath:tree.path("renamed"))
        try Data(repeating:1,count:999).write(to:URL(fileURLWithPath:tree.path("added")))
        waitFor("new delta metadata",timeout:10) { c.metadata.capture().value(path:tree.path("added")).logicalSize == 999 && c.metadata.capture().value(path:tree.path("renamed")).logicalSize == 7 }
        XCTAssertTrue(c.compact()); XCTAssertTrue(c.waitForCheckpoint(timeout:30))
        let capture = c.metadata.capture(); XCTAssertTrue(capture.available)
        XCTAssertEqual(capture.base?.header.baseUUID,(c.index as? HybridIndex)?.mappedBase?.header.snapshotUUID)
        XCTAssertEqual(capture.value(path:tree.path("added")).logicalSize,999)
        XCTAssertEqual(capture.value(path:tree.path("renamed")).logicalSize,7)
        let identity = try VolumeIdentity.discover(root:tree.root),store = try SnapshotStore(directory:cache.root,identity:identity)
        let ns = try Data(contentsOf:URL(fileURLWithPath:store.path))
        try Data(repeating:2,count:888).write(to:URL(fileURLWithPath:tree.path("added")))
        waitFor("base override",timeout:10) { c.metadata.capture().value(path:tree.path("added")).logicalSize == 888 }
        c.checkpointMetadata()
        waitFor("metadata checkpoint",timeout:10) { c.metadata.capture().base?.value(at:c.metadata.capture().ordinal(tree.path("added"))!).logicalSize == 888 }
        XCTAssertEqual(ns,try Data(contentsOf:URL(fileURLWithPath:store.path)))
        try FileManager.default.removeItem(atPath:tree.path("added"))
        waitFor("metadata removal",timeout:10) { c.index.entry(at:tree.path("added")) == nil && c.metadata.capture().value(path:tree.path("added")) == .unknown }
    }
    func testDirectoryRenamePreservesDescendantMetadataAndReuse() throws {
        try requireFSEvents()
        let tree = try TemporaryTree(), cache = try TemporaryTree(cache:true); try tree.directory("old/sub")
        try Data(repeating:1,count:456).write(to:URL(fileURLWithPath:tree.path("old/sub/child")))
        let c = try coordinator(tree,cache); defer { c.stop(policy:.fast) }; try ready(c)
        try FileManager.default.moveItem(atPath:tree.path("old"),toPath:tree.path("new"))
        waitFor("renamed directory metadata",timeout:10) {
            c.index.entry(at:tree.path("new/sub/child")) != nil && c.metadata.capture().value(path:tree.path("new/sub/child")).logicalSize == 456
        }
        XCTAssertEqual(c.search(.init(query:"child",sort:.init(key:.size))).hits.first?.logicalSize,456)
        XCTAssertTrue(c.compact()); XCTAssertTrue(c.waitForCheckpoint())
        XCTAssertEqual(c.metadata.capture().value(path:tree.path("new/sub/child")).logicalSize,456)
    }
    func testMetadataPublishFailureKeepsPublishedNamespaceAndRecoversSeparately() throws {
        try requireFSEvents()
        let tree = try TemporaryTree(),cache = try TemporaryTree(cache:true); try tree.file("old")
        let fault = MetadataFaultSwitch()
        let c = try PersistentIndexCoordinator(root:tree.root,cacheDirectory:cache.root,metadataFault:{ point in
            if fault.enabled && point == .beforeRename { throw SnapshotError.cancelled }
        }, maintenanceScheduler: .init())
        defer { c.stop(policy:.fast) }; try ready(c)
        let oldUUID = (c.index as? HybridIndex)?.mappedBase?.header.snapshotUUID
        try tree.file("added")
        waitFor("namespace new file",timeout:10) { c.index.entry(at:tree.path("added")) != nil }
        fault.enabled = true
        XCTAssertTrue(c.compact()); XCTAssertTrue(c.waitForCheckpoint())
        XCTAssertNotEqual(oldUUID,(c.index as? HybridIndex)?.mappedBase?.header.snapshotUUID)
        XCTAssertEqual(c.search("added").hits.count,1)
        fault.enabled = false; c.rebuildMetadata(); XCTAssertTrue(c.waitForMetadata(timeout:30))
        XCTAssertEqual(c.metadata.capture().value(path:tree.path("added")).logicalSize,0)
        XCTAssertEqual(c.metrics.snapshot()["full_scans"],1)
    }
    func testDirectoryMovedIntoRootPopulatesDescendantMetadata() throws {
        try requireFSEvents()
        let tree = try TemporaryTree(),outside = try TemporaryTree(),cache = try TemporaryTree(cache:true)
        try tree.file("seed"); try outside.directory("incoming/sub")
        try Data(repeating:1,count:1234).write(to:URL(fileURLWithPath:outside.path("incoming/sub/child")))
        let c = try coordinator(tree,cache); defer { c.stop(policy:.fast) }; try ready(c)
        try FileManager.default.moveItem(atPath:outside.path("incoming"),toPath:tree.path("incoming"))
        waitFor("incoming subtree metadata",timeout:10) {
            c.index.entry(at:tree.path("incoming/sub/child")) != nil && c.metadata.capture().value(path:tree.path("incoming/sub/child")).logicalSize == 1234
        }
        XCTAssertEqual(c.search(.init(query:"child",sort:.init(key:.size))).hits.first?.logicalSize,1234)
        XCTAssertGreaterThan(c.metrics.snapshot()["metadata_subtree_bulk_enumerations",default:0],0)
    }
    func testSparseMicrobatchUsesOneParentOpenAndMetadataOnlyLookups() throws {
        let tree = try TemporaryTree(),cache = try TemporaryTree(cache:true)
        for i in 0..<1000 { try tree.file("f\(i)") }
        let scan = try BulkScanner(root:tree.root).scan(),identity = try VolumeIdentity.discover(root:tree.root)
        let ram = FileIndex(root:tree.root); ram.apply(scan.entries.map(IndexMutation.upsert))
        let store = try SnapshotStore(directory:cache.root,identity:identity)
        _ = try SnapshotV2Writer.write(source:.ram(ram,ram.stats().generation),identity:identity,generation:ram.stats().generation,cursor:0,store:store)
        let base = try store.reader(expectedIdentity:identity).mappedBase!,ns = HybridIndex(base:base),meta = MetadataIndexCoordinator(),metrics = Metrics()
        meta.bind(namespace:base); meta.advance(0,historyDone:true)
        let updater = MetadataUpdateCoordinator(root:tree.root,device:identity.deviceID,index:meta,namespace:ns,metrics:metrics,invalidated:{})
        defer { updater.stop() }
        for i in 0..<100 { try Data(repeating:1,count:5).write(to:URL(fileURLWithPath:tree.path("f\(i)"))) }
        updater.enqueue((0..<100).map { .init(path:tree.path("f\($0)"),flags:UInt32(kFSEventStreamEventFlagItemModified|kFSEventStreamEventFlagItemIsFile),id:UInt64($0+1)) }); updater.flush()
        XCTAssertEqual(metrics.snapshot()["metadata_parent_microbatches"],2)
        XCTAssertEqual(metrics.snapshot()["metadata_lookups"],100)
        XCTAssertEqual(metrics.snapshot()["metadata_parent_bulk_enumerations",default:0],0)
        XCTAssertEqual(meta.capture().value(path:tree.path("f99")).logicalSize,5)
    }
    func testBootstrapWithNamespaceDeltaRetainsConservativeDurableCursor() throws {
        try requireFSEvents()
        let tree = try TemporaryTree(),cache = try TemporaryTree(cache:true); try tree.file("old")
        let c = try coordinator(tree,cache); try ready(c)
        try Data(repeating:1,count:777).write(to:URL(fileURLWithPath:tree.path("new")))
        waitFor("namespace delta",timeout:10) { c.index.entry(at:tree.path("new")) != nil }
        c.rebuildMetadata()
        waitFor("bootstrap finished",timeout:30) { c.metrics.snapshot()["metadata_bootstraps",default:0] > 0 && c.metadata.capture().value(path:tree.path("new")).logicalSize == 777 }
        c.stop(policy:.fast)
        let next = try coordinator(tree,cache); defer { next.stop(policy:.fast) }; try ready(next)
        waitFor("bootstrap delta replay",timeout:10) { next.index.entry(at:tree.path("new")) != nil && next.metadata.capture().value(path:tree.path("new")).logicalSize == 777 }
        XCTAssertEqual(next.metrics.snapshot()["full_scans",default:0],0)
    }
    func testParentBulkStormAndSeparateReplayFloors() throws {
        let tree = try TemporaryTree(); for i in 0..<100 { try tree.file("f\(i)") }
        let ns = FileIndex(root:tree.root); ns.apply(try BulkScanner(root:tree.root).scan().entries.map(IndexMutation.upsert))
        let meta = MetadataIndexCoordinator(), metrics = Metrics()
        var policy = MetadataUpdatePolicy(); policy.smallBatchLimit = 5; policy.stormParentCollapseThreshold = 10
        let updater = MetadataUpdateCoordinator(root:tree.root,device:try BulkScanner(root:tree.root).rootDeviceID(),index:meta,namespace:ns,metrics:metrics,policy:policy,invalidated:{})
        defer { updater.stop() }
        updater.enqueue((0..<100).map { .init(path:tree.path("f\($0)"),flags:UInt32(kFSEventStreamEventFlagItemModified|kFSEventStreamEventFlagItemIsFile),id:UInt64($0+1)) }); updater.flush()
        XCTAssertEqual(metrics.snapshot()["metadata_parent_bulk_enumerations"],1)
        XCTAssertEqual(metrics.snapshot()["metadata_lookups",default:0],0)
        XCTAssertEqual(meta.capture().value(path:tree.path("f99")).logicalSize,0)
        let g = ns.stats().generation
        meta.beginBootstrap(fence:200)
        updater.enqueue([.init(path:tree.path("f99"),flags:UInt32(kFSEventStreamEventFlagItemModified|kFSEventStreamEventFlagItemIsFile),id:199)]); updater.flush()
        XCTAssertEqual(ns.stats().generation,g); XCTAssertEqual(metrics.snapshot()["metadata_overlap_skipped"],1)
        updater.enqueue([.init(path:tree.path("f98"),flags:UInt32(kFSEventStreamEventFlagItemXattrMod),id:198)]); updater.flush()
        XCTAssertEqual(meta.capture().value(path:tree.path("f98")).logicalSize,0,"ambiguous old-ID xattr can conceal creation and must be refreshed")
        XCTAssertEqual(metrics.snapshot()["metadata_overlap_skipped"],1)
        meta.advance(200,historyDone:true)
        updater.enqueue([.init(path:tree.path("f99"),flags:UInt32(kFSEventStreamEventFlagItemModified|kFSEventStreamEventFlagItemIsFile),id:199)]); updater.flush()
        XCTAssertEqual(meta.capture().value(path:tree.path("f99")).logicalSize,0)
        XCTAssertEqual(metrics.snapshot()["metadata_overlap_skipped"],1,"live delivery must not be filtered by an old replay floor")
    }
}

private final class MetadataFaultSwitch: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    var enabled:Bool { get { lock.withLock { value } } set { lock.withLock { value = newValue } } }
}

extension MetadataIntegrationTests {
    func testContinuousInputCannotPostponeMetadataBatchForever() throws {
        let tree = try TemporaryTree(); try tree.file("mutable")
        let ns = FileIndex(root: tree.root), meta = MetadataIndexCoordinator(), metrics = Metrics()
        var policy = MetadataUpdatePolicy(); policy.debounceSeconds = 0.05
        let updater = MetadataUpdateCoordinator(root: tree.root, device: try BulkScanner(root: tree.root).rootDeviceID(),
            index: meta, namespace: ns, metrics: metrics, policy: policy, invalidated: { metrics.record("unexpected_invalidation") })
        defer { updater.stop() }
        let token = CancellationToken(), finished = DispatchSemaphore(value: 0), path = tree.path("mutable")
        DispatchQueue.global().async {
            var id: UInt64 = 1
            while !token.isCancelled {
                updater.enqueue([.init(path: path, flags: UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile), id: id)])
                id += 1; Thread.sleep(forTimeInterval: 0.005)
            }
            finished.signal()
        }
        defer { token.cancel(); XCTAssertEqual(finished.wait(timeout: .now()+2), .success) }
        waitFor("metadata runs before continuous input stops", timeout: 2) {
            metrics.snapshot()["metadata_lookups", default: 0] >= 3
        }
        XCTAssertEqual(metrics.snapshot()["unexpected_invalidation", default: 0], 0)
    }
}
