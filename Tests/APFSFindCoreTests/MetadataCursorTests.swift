import CoreServices
import Foundation
import XCTest
@testable import APFSFindCore

final class MetadataCursorTests: XCTestCase {
    func testMetadataAheadReplayRepairsNewAndRenamedNamespacePaths() throws {
        let tree = try TemporaryTree(), cache = try TemporaryTree(cache:true)
        try tree.file("old")
        let identity = try VolumeIdentity.discover(root:tree.root)
        let scan = try BulkScanner(root:tree.root).scan(), ram = FileIndex(root:tree.root)
        ram.apply(scan.entries.map(IndexMutation.upsert))
        let store = try SnapshotStore(directory:cache.root,identity:identity)
        _ = try SnapshotV2Writer.write(source:.ram(ram,ram.stats().generation),identity:identity,
            generation:ram.stats().generation,cursor:100,store:store)
        let base = try XCTUnwrap(store.reader(expectedIdentity:identity).mappedBase)
        _ = try MetadataWriter.write(store:store,base:base.header,cursor:200,
            value:{_ in .init(logicalSize:0,modificationTimeNanoseconds:0)})
        let born = tree.path("born"), renamed = tree.path("renamed"), old = tree.path("old"), root = tree.root
        try Data(repeating:1,count:37).write(to:URL(fileURLWithPath:born))
        try FileManager.default.moveItem(atPath:old,toPath:renamed)
        let actual = try BulkScanner(root:root).scan().scannedEntries
        let expected = Dictionary(uniqueKeysWithValues:actual.map {($0.namespace.path,$0.metadata)})
        let coordinator = try PersistentIndexCoordinator(root:root,cacheDirectory:cache.root,
            maintenanceScheduler:.init(),replayStarter:{_,deliver in
                // These IDs need namespace replay, but precede the independent
                // metadata floor. The old sidecar has neither destination.
                deliver([.init(path:born,flags:UInt32(kFSEventStreamEventFlagItemCreated|kFSEventStreamEventFlagItemIsFile),id:150),
                    .init(path:old,flags:UInt32(kFSEventStreamEventFlagItemRenamed|kFSEventStreamEventFlagItemIsFile),id:151),
                    .init(path:renamed,flags:UInt32(kFSEventStreamEventFlagItemRenamed|kFSEventStreamEventFlagItemIsFile),id:152),
                    .init(path:root,flags:UInt32(kFSEventStreamEventFlagHistoryDone),id:201)])
            })
        defer {coordinator.stop(policy:.fast)}
        try coordinator.start();XCTAssertTrue(coordinator.waitUntilLive());coordinator.flushMetadata()
        XCTAssertNotNil(coordinator.index.entry(at:born));XCTAssertNotNil(coordinator.index.entry(at:renamed))
        XCTAssertNil(coordinator.index.entry(at:old))
        XCTAssertEqual(coordinator.metadata.capture().value(path:born),expected[born])
        XCTAssertEqual(coordinator.metadata.capture().value(path:renamed),expected[renamed])
        XCTAssertEqual(coordinator.metadata.capture().value(path:old),.unknown)
        XCTAssertEqual(coordinator.metrics.snapshot()["full_scans",default:0],0)
        XCTAssertEqual(coordinator.metrics.snapshot()["rebuild_requests_resource_yield",default:0],0)
    }

    func testNamespaceAheadAndMetadataAheadUseIndependentFloors() throws {
        for (namespaceCursor,metadataCursor) in [(UInt64(100),UInt64(80)),(80,100)] {
            let tree = try TemporaryTree(),cache = try TemporaryTree(cache:true); try tree.file("target")
            let identity = try VolumeIdentity.discover(root:tree.root), scan = try BulkScanner(root:tree.root).scan(), ram = FileIndex(root:tree.root)
            ram.apply(scan.entries.map(IndexMutation.upsert))
            let store = try SnapshotStore(directory:cache.root,identity:identity)
            _ = try SnapshotV2Writer.write(source:.ram(ram,ram.stats().generation),identity:identity,generation:ram.stats().generation,cursor:namespaceCursor,store:store)
            let base = try store.reader(expectedIdentity:identity).mappedBase!
            _ = try MetadataWriter.write(store:store,base:base.header,cursor:metadataCursor,value:{ id in
                .init(logicalSize:base.record(at:id).kind == .file ? (metadataCursor == 100 ? 5 : 0) : nil)
            })
            try Data(repeating:1,count:5).write(to:URL(fileURLWithPath:tree.path("target")))
            let probe = MetadataReplayProbe(), path = tree.path("target")
            let c = try PersistentIndexCoordinator(root:tree.root,cacheDirectory:cache.root,maintenanceScheduler: .init(), replayStarter:{ id,deliver in
                probe.set(id); deliver([.init(path:path,flags:UInt32(kFSEventStreamEventFlagItemModified|kFSEventStreamEventFlagItemIsFile),id:90),
                    .init(path:path,flags:UInt32(kFSEventStreamEventFlagHistoryDone),id:110)])
            })
            defer { c.stop(policy:.fast) }
            try c.start(); XCTAssertTrue(c.waitUntilLive()); c.flushMetadata()
            XCTAssertEqual(probe.value,80)
            XCTAssertEqual(c.metadata.capture().value(path:path).logicalSize,5)
            XCTAssertEqual(c.index.stats().generation,base.header.indexGeneration)
            if metadataCursor == 80 { XCTAssertEqual(c.metrics.snapshot()["metadata_lookups"],1) }
            else { XCTAssertEqual(c.metrics.snapshot()["metadata_lookups",default:0],0); XCTAssertEqual(c.metrics.snapshot()["metadata_overlap_skipped"],1) }
        }
    }
    func testFastExitWithDebouncedRefreshKeepsOldFenceAndReplays() throws {
        let tree = try TemporaryTree(),cache = try TemporaryTree(cache:true); try tree.file("target")
        let path = tree.path("target")
        var policy = MetadataUpdatePolicy(); policy.debounceSeconds = 60
        let c = try PersistentIndexCoordinator(root:tree.root,cacheDirectory:cache.root,metadataUpdatePolicy:policy,maintenanceScheduler: .init(), replayStarter:{ id,deliver in
            deliver([.init(path:path,flags:UInt32(kFSEventStreamEventFlagHistoryDone),id:id)])
        },fenceProvider:{_ in 100})
        try c.start(); XCTAssertTrue(c.waitUntilLive()); c.flushMetadata()
        let identity = try VolumeIdentity.discover(root:tree.root),store = try SnapshotStore(directory:cache.root,identity:identity)
        let bytes = try Data(contentsOf:URL(fileURLWithPath:store.metadataPath))
        try Data(repeating:1,count:333).write(to:URL(fileURLWithPath:path))
        c.core.enqueue([.init(path:path,flags:UInt32(kFSEventStreamEventFlagItemModified|kFSEventStreamEventFlagItemIsFile),id:110)])
        _ = c.core.flushEvents(); c.stop(policy:.fast)
        let header = try store.metadataReader(base:try store.reader(expectedIdentity:identity).header).header
        XCTAssertEqual(bytes,try Data(contentsOf:URL(fileURLWithPath:store.metadataPath)))
        XCTAssertEqual(store.effectiveMetadataCursor(for:header).cursor,100)
        XCTAssertEqual(c.metrics.snapshot()["metadata_lookups",default:0],0)
        let probe = MetadataReplayProbe()
        let next = try PersistentIndexCoordinator(root:tree.root,cacheDirectory:cache.root,maintenanceScheduler: .init(), replayStarter:{ id,deliver in
            probe.set(id); deliver([.init(path:path,flags:UInt32(kFSEventStreamEventFlagItemModified|kFSEventStreamEventFlagItemIsFile),id:110),
                .init(path:path,flags:UInt32(kFSEventStreamEventFlagHistoryDone),id:111)])
        })
        defer { next.stop(policy:.fast) }; try next.start(); XCTAssertTrue(next.waitUntilLive()); next.flushMetadata()
        XCTAssertEqual(probe.value,100)
        XCTAssertEqual(next.metadata.capture().value(path:path).logicalSize,333)
        XCTAssertEqual(next.metrics.snapshot()["full_scans",default:0],0)
    }
    func testMetadataBootstrapRejectsChangedNamespaceIdentity() throws {
        let tree = try TemporaryTree(),cache = try TemporaryTree(cache:true); try tree.file("target")
        let original = try VolumeIdentity.discover(root:tree.root),identity = MetadataIdentityProbe(original)
        let path = tree.path("target")
        let c = try PersistentIndexCoordinator(root:tree.root,cacheDirectory:cache.root,identityProvider:{_ in identity.value},maintenanceScheduler: .init(), replayStarter:{ id,deliver in
            deliver([.init(path:path,flags:UInt32(kFSEventStreamEventFlagHistoryDone),id:id)])
        },fenceProvider:{_ in 100})
        defer { c.stop(policy:.fast) }; try c.start(); XCTAssertTrue(c.waitUntilLive()); c.flushMetadata()
        let store = try SnapshotStore(directory:cache.root,identity:original)
        let namespaceBytes = try Data(contentsOf:URL(fileURLWithPath:store.path))
        let metadataBytes = try Data(contentsOf:URL(fileURLWithPath:store.metadataPath))
        identity.set(.init(root:original.root,deviceID:original.deviceID,rootFileID:original.rootFileID,
            volumeUUID:UUID(),historyUUID:UUID(),mountPoint:original.mountPoint,relativeRoot:original.relativeRoot))
        c.rebuildMetadata()
        waitFor("metadata identity rejection",timeout:10) { c.metrics.snapshot()["metadata_bootstrap_failures",default:0] == 1 }
        XCTAssertEqual(namespaceBytes,try Data(contentsOf:URL(fileURLWithPath:store.path)))
        XCTAssertEqual(metadataBytes,try Data(contentsOf:URL(fileURLWithPath:store.metadataPath)))
        XCTAssertEqual(c.search("target").hits.count,1)
        XCTAssertFalse(c.metadataAvailable); XCTAssertNotNil(c.metadataFailure)
    }
    func testPureCursorFastExitWritesMetadataStateOnly() throws {
        let tree = try TemporaryTree(),cache = try TemporaryTree(cache:true); try tree.file("target")
        let path = tree.path("target")
        let c = try PersistentIndexCoordinator(root:tree.root,cacheDirectory:cache.root,maintenanceScheduler: .init(), replayStarter:{ id,deliver in
            deliver([.init(path:path,flags:UInt32(kFSEventStreamEventFlagHistoryDone),id:id)])
        },fenceProvider:{_ in 100})
        try c.start(); XCTAssertTrue(c.waitUntilLive()); c.flushMetadata()
        let identity = try VolumeIdentity.discover(root:tree.root),store = try SnapshotStore(directory:cache.root,identity:identity)
        let bytes = try Data(contentsOf:URL(fileURLWithPath:store.metadataPath))
        c.core.enqueue([.init(path:path,flags:UInt32(kFSEventStreamEventFlagItemXattrMod|kFSEventStreamEventFlagItemIsFile),id:110)])
        _ = c.core.flushEvents(); c.flushMetadata(); XCTAssertFalse(c.metadata.isDirty)
        c.stop(policy:.fast)
        let header = try store.metadataReader(base:try store.reader(expectedIdentity:identity).header).header
        XCTAssertEqual(bytes,try Data(contentsOf:URL(fileURLWithPath:store.metadataPath)))
        XCTAssertEqual(store.effectiveMetadataCursor(for:header).cursor,110)
        XCTAssertTrue(store.effectiveMetadataCursor(for:header).valid)
    }
}
private final class MetadataReplayProbe: @unchecked Sendable {
    private let lock = NSLock(); private var id:UInt64 = 0
    var value:UInt64 { lock.withLock { id } }
    func set(_ id:UInt64) { lock.withLock { self.id = id } }
}

private final class MetadataIdentityProbe: @unchecked Sendable {
    private let lock = NSLock(); private var identity:VolumeIdentity
    init(_ identity:VolumeIdentity) { self.identity = identity }
    var value:VolumeIdentity { lock.withLock { identity } }
    func set(_ value:VolumeIdentity) { lock.withLock { identity = value } }
}
