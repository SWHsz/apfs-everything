import CoreServices
import Darwin
import Foundation
import XCTest
@testable import APFSFindCore

final class CursorStateTests: XCTestCase {
    func testBindingCorruptionAndInterruptedStatePublication() throws {
        let cache = try TemporaryTree(cache: true), v = snapshotIdentity(), index = sampleSnapshotIndex()
        let store = try SnapshotStore(directory: cache.root, identity: v)
        let first = try SnapshotWriter.write(index: index, identity: v, cursor: 7, store: store).header
        try store.writeState(header: first, cursor: 99, beforePublish: {})
        XCTAssertEqual(store.effectiveCursor(for: first).cursor, 99)
        var d = try Data(contentsOf: URL(fileURLWithPath: store.statePath)); d[88] ^= 1
        try d.write(to: URL(fileURLWithPath: store.statePath))
        XCTAssertEqual(store.effectiveCursor(for: first).cursor, 7)
        try store.writeState(header: first, cursor: 100, beforePublish: {})
        let second = try SnapshotWriter.write(index: index, identity: v, cursor: 10, store: store).header
        XCTAssertEqual(store.effectiveCursor(for: second).cursor, 10, "old UUID ignored after snapshot published without state")
        for point in [SnapshotFailurePoint.beforeFileSync, .beforeRename, .afterRename, .directorySync] {
            XCTAssertThrowsError(try store.writeState(header: second, cursor: 101, beforePublish: {}, fault: {
                if $0 == point { throw SnapshotError.io("state fault", EIO) }
            }))
            XCTAssertEqual(try store.reader(expectedIdentity: v).header.snapshotUUID, second.snapshotUUID)
        }
    }
    func testContentOnlyExitUpdatesStateAndWarmUsesFence() throws {
        try requireFSEvents()
        let tree = try TemporaryTree(), cache = try TemporaryTree(cache: true)
        try tree.file("seed")
        let c = try PersistentIndexCoordinator(root: tree.root, cacheDirectory: cache.root)
        try c.start(); XCTAssertTrue(c.waitUntilLive()); XCTAssertTrue(c.waitForCheckpoint())
        let v = try VolumeIdentity.discover(root: tree.root), store = try SnapshotStore(directory: cache.root, identity: v)
        let h = try store.reader(expectedIdentity: v).header
        var before = stat(); XCTAssertEqual(lstat(store.path, &before), 0)
        let fence = try c.core.captureCheckpoint().cursor + 1
        c.core.enqueue([.init(path: tree.path("seed"), flags: UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile), id: fence)])
        XCTAssertTrue(c.core.flushEvents())
        XCTAssertEqual(c.index.stats().generation, h.indexGeneration)
        c.stop()
        var after = stat(); XCTAssertEqual(lstat(store.path, &after), 0)
        XCTAssertEqual(before.st_ino, after.st_ino); XCTAssertEqual(before.st_size, after.st_size)
        XCTAssertEqual(before.st_mtimespec.tv_sec, after.st_mtimespec.tv_sec)
        XCTAssertEqual(before.st_mtimespec.tv_nsec, after.st_mtimespec.tv_nsec)
        XCTAssertGreaterThanOrEqual(store.effectiveCursor(for: h).cursor, fence)
        let next = try PersistentIndexCoordinator(root: tree.root, cacheDirectory: cache.root)
        defer { next.stop(saveCheckpoint: false) }
        try next.start(); XCTAssertTrue(next.waitUntilLive())
        XCTAssertEqual(next.stats().dictionary["effective_cursor"] as? UInt64, store.effectiveCursor(for: h).cursor)
    }
    func testStateCannotSkipUnpublishedNamespace() throws {
        try requireFSEvents()
        let tree = try TemporaryTree(), cache = try TemporaryTree(cache: true)
        let c = try PersistentIndexCoordinator(root: tree.root, cacheDirectory: cache.root)
        try c.start(); XCTAssertTrue(c.waitUntilLive()); XCTAssertTrue(c.waitForCheckpoint())
        let store = try SnapshotStore(directory: cache.root, identity: VolumeIdentity.discover(root: tree.root))
        let h = try store.reader(expectedIdentity: VolumeIdentity.discover(root: tree.root)).header
        try tree.file("pending")
        waitFor("pending namespace") { c.index.entry(at: tree.path("pending")) != nil }
        let capture = try c.core.captureCheckpoint()
        XCTAssertThrowsError(try store.writeState(header: h, cursor: capture.cursor, beforePublish: {
            guard capture.metadata.generation == h.indexGeneration else { throw SnapshotError.generationChanged }
        }))
        XCTAssertEqual(store.effectiveCursor(for: h).cursor, h.lastProcessedEventID)
        c.stop(saveCheckpoint: false)
        let next = try PersistentIndexCoordinator(root: tree.root, cacheDirectory: cache.root)
        defer { next.stop(saveCheckpoint: false) }
        try next.start(); XCTAssertTrue(next.waitUntilLive())
        waitFor("unpublished namespace replay") { next.index.entry(at: tree.path("pending")) != nil }
        XCTAssertTrue(try next.verify().isConsistent)
    }
    func testCachePermissionsHaveNoSideEffects() throws {
        let parent = try TemporaryTree(), v = snapshotIdentity()
        XCTAssertEqual(chmod(parent.root, 0o755), 0)
        XCTAssertThrowsError(try SnapshotStore(directory: parent.root, identity: v))
        var st = stat(); XCTAssertEqual(lstat(parent.root, &st), 0); XCTAssertEqual(st.st_mode & 0o7777, 0o755)
        let store = try SnapshotStore(directory: parent.path("owned"), identity: v)
        XCTAssertEqual(lstat(store.directory, &st), 0); XCTAssertEqual(st.st_mode & 0o7777, 0o700)
        _ = try SnapshotStore(directory: store.directory, identity: v)
        XCTAssertEqual(lstat(parent.root, &st), 0); XCTAssertEqual(st.st_mode & 0o7777, 0o755)
    }
    func testInjectableCFClockAndSDKConversion() {
        let v = snapshotIdentity(device: 42)
        let id = v.currentEventID(clock: { 123 }, fence: { device, time in
            XCTAssertEqual(device, 42); XCTAssertEqual(time, 123 + kCFAbsoluteTimeIntervalSince1970)
            return 99
        })
        XCTAssertEqual(id, 99)
    }
}

private final class FenceCounter: @unchecked Sendable {
    let lock=NSLock()
    var calls=0
    func capture(_ v:VolumeIdentity)->UInt64 {lock.withLock{calls+=1};return v.currentEventID()}
    var count:Int {lock.withLock{calls}}
}
extension CursorStateTests {
    func testInjectedFenceIsUsedBeforeColdScanAndRecoveryScan() throws {
        try requireFSEvents()
        let tree=try TemporaryTree(),counter=FenceCounter()
        let c=try UpdateCoordinator(root:tree.root,configuration:.init(fullRebuildMinInterval:0,rebuildDebounceMilliseconds:0),
            fenceProvider:{counter.capture($0)})
        defer{c.stop()}
        try c.start();XCTAssertTrue(c.waitUntilLive());XCTAssertEqual(counter.count,1)
        c.rebuild()
        waitFor("recovery fence",timeout:5){counter.count>=2}
        waitFor("recovery live",timeout:5){c.currentState == .live && c.metrics.snapshot()["full_rebuilds",default:0]>0}
    }
}

extension CursorStateTests {
    func testPersistentCoordinatorForwardsFenceAndWarmUsesStoredCursor() throws {
        try requireFSEvents()
        let tree=try TemporaryTree(),cache=try TemporaryTree(cache:true),counter=FenceCounter()
        let cold=try PersistentIndexCoordinator(root:tree.root,cacheDirectory:cache.root,fenceProvider:{counter.capture($0)})
        try cold.start();XCTAssertTrue(cold.waitUntilLive());XCTAssertEqual(counter.count,1);cold.stop()
        let warm=try PersistentIndexCoordinator(root:tree.root,cacheDirectory:cache.root,fenceProvider:{counter.capture($0)})
        defer{warm.stop(saveCheckpoint:false)}
        try warm.start();XCTAssertTrue(warm.waitUntilLive());XCTAssertEqual(counter.count,1)
        XCTAssertEqual(warm.stats().dictionary["startup_mode"] as? String,"warm_snapshot")
    }
}
