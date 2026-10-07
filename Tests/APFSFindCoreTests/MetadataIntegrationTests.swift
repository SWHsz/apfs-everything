import CAPFSShim
import CoreServices
import Foundation
import XCTest
@testable import APFSFindCore

final class MetadataIntegrationTests: XCTestCase {
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
        for i in 1...10_000 { try Data(repeating:1,count:(i%100)+1).write(to:URL(fileURLWithPath:tree.path("target"))) }
        waitFor("metadata content convergence",timeout:10) { c.metadata.capture().value(path:tree.path("target")).logicalSize == 1 }
        XCTAssertEqual(c.index.stats().generation,generation)
        XCTAssertLessThanOrEqual(c.metrics.snapshot()["metadata_lookups",default:0]-before["metadata_lookups",default:0],5)
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
