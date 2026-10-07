import CoreServices
import Foundation
import XCTest
@testable import APFSFindCore

final class MetadataCursorTests: XCTestCase {
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
