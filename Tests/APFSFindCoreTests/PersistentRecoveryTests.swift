import CoreServices
import Darwin
import Foundation
import XCTest
@testable import APFSFindCore

final class PersistentRecoveryTests: XCTestCase {
    private func make(_ tree: TemporaryTree, _ cache: TemporaryTree, ephemeral: Bool = false,
                      rebuild: Bool = false) throws -> PersistentIndexCoordinator {
        try .init(root: tree.root, configuration: .init(fullRebuildMinInterval: 0),
                  ephemeral: ephemeral, rebuildIndex: rebuild, cacheDirectory: cache.root)
    }
    private func cold(_ tree: TemporaryTree, _ cache: TemporaryTree) throws {
        let c = try make(tree, cache)
        defer { c.stop(saveCheckpoint: false) }
        try c.start()
        XCTAssertTrue(c.waitUntilLive())
        XCTAssertTrue(c.waitForCheckpoint())
        XCTAssertEqual(c.metrics.snapshot()["snapshot_checkpoints"], 1)
    }
    private func assertWarm(_ c: PersistentIndexCoordinator) {
        XCTAssertEqual(c.stats().dictionary["startup_mode"] as? String, "warm_snapshot")
        XCTAssertTrue(c.stats().dictionary["snapshot_loaded"] as? Bool == true)
        XCTAssertEqual(c.metrics.snapshot()["full_scans", default: 0], 0)
    }

    func testOfflineMutationsWarmReplayWithoutFullScan() throws {
        try requireFSEvents()
        let tree = try TemporaryTree(), cache = try TemporaryTree()
        try tree.directory("a"); try tree.directory("b")
        for name in ["deleted", "same", "cross"] { try tree.file("a/" + name) }
        try cold(tree, cache)
        try FileManager.default.removeItem(atPath: tree.path("a/deleted"))
        try FileManager.default.moveItem(atPath: tree.path("a/same"), toPath: tree.path("a/renamed"))
        try FileManager.default.moveItem(atPath: tree.path("a/cross"), toPath: tree.path("b/moved"))
        try tree.directory("new/deep"); try tree.file("new/deep/child"); try tree.file("offline")
        let c = try make(tree, cache)
        defer { c.stop(saveCheckpoint: false) }
        try c.start()
        XCTAssertTrue(c.waitUntilLive())
        waitFor("offline replay converges", timeout: 5) {
            c.index.entry(at: tree.path("offline")) != nil && c.index.entry(at: tree.path("new/deep/child")) != nil &&
            c.index.entry(at: tree.path("a/deleted")) == nil && c.index.entry(at: tree.path("a/same")) == nil &&
            c.index.entry(at: tree.path("a/cross")) == nil && c.index.entry(at: tree.path("b/moved")) != nil
        }
        assertWarm(c)
        XCTAssertTrue(try c.verify().isConsistent)
    }

    func testCrashLikeOldCursorReplayAndExitCheckpoint() throws {
        try requireFSEvents()
        let tree = try TemporaryTree(), cache = try TemporaryTree()
        try tree.file("seed"); try cold(tree, cache)
        let c = try make(tree, cache)
        try c.start(); XCTAssertTrue(c.waitUntilLive())
        let checkpointG = c.stats().dictionary["last_checkpoint_generation"] as? UInt64
        try tree.file("uncheckpointed")
        waitFor("live create") { c.index.entry(at: tree.path("uncheckpointed")) != nil }
        XCTAssertNotEqual(c.index.stats().generation, checkpointG)
        c.stop(saveCheckpoint: false)
        let recovered = try make(tree, cache)
        try recovered.start(); XCTAssertTrue(recovered.waitUntilLive())
        waitFor("old cursor restores live mutation") { recovered.index.entry(at: tree.path("uncheckpointed")) != nil }
        assertWarm(recovered)
        XCTAssertTrue(try recovered.verify().isConsistent)
        recovered.stop()
        XCTAssertEqual(recovered.metrics.snapshot()["snapshot_checkpoints"], 1)
        let next = try make(tree, cache)
        defer { next.stop(saveCheckpoint: false) }
        try next.start(); XCTAssertTrue(next.waitUntilLive())
        assertWarm(next)
        XCTAssertNotNil(next.index.entry(at: tree.path("uncheckpointed")))
    }

    func testWrappedDroppedAndRootMustScanPublishRebuiltSnapshot() throws {
        try requireFSEvents()
        for flag in [kFSEventStreamEventFlagEventIdsWrapped, kFSEventStreamEventFlagKernelDropped,
                     kFSEventStreamEventFlagMustScanSubDirs] {
            let tree = try TemporaryTree(), cache = try TemporaryTree()
            try tree.file("seed"); try cold(tree, cache)
            let c = try make(tree, cache)
            defer { c.stop(saveCheckpoint: false) }
            try c.start(); XCTAssertTrue(c.waitUntilLive()); assertWarm(c)
            c.index.apply([.upsert(.init(path: tree.path("ghost"), kind: .file))])
            c.core.enqueue([.init(path: tree.root, flags: UInt32(flag))])
            waitFor("fallback rebuilt and checkpointed", timeout: 10) {
                c.metrics.snapshot()["full_rebuilds", default: 0] > 0 &&
                c.metrics.snapshot()["snapshot_checkpoints", default: 0] > 0 && c.currentState == .live
            }
            XCTAssertNil(c.index.entry(at: tree.path("ghost")))
            XCTAssertEqual(c.stats().dictionary["startup_mode"] as? String, "rebuild_fallback")
            XCTAssertTrue(try c.verify().isConsistent)
        }
    }

    func testHistoryIdentityChangeAndCorruptionFallback() throws {
        try requireFSEvents()
        let tree = try TemporaryTree(), cache = try TemporaryTree()
        try tree.file("seed"); try cold(tree, cache)
        let real = try VolumeIdentity.discover(root: tree.root)
        let changed = VolumeIdentity(root: real.root, deviceID: real.deviceID, rootFileID: real.rootFileID,
            volumeUUID: real.volumeUUID, historyUUID: UUID(), mountPoint: real.mountPoint, relativeRoot: real.relativeRoot)
        let c = try PersistentIndexCoordinator(root: tree.root, cacheDirectory: cache.root, identityProvider: { _ in changed })
        try c.start(); XCTAssertTrue(c.waitUntilLive()); XCTAssertTrue(c.waitForCheckpoint())
        XCTAssertEqual(c.stats().dictionary["startup_mode"] as? String, "rebuild_fallback")
        XCTAssertEqual(c.metrics.snapshot()["full_scans"], 1)
        c.stop(saveCheckpoint: false)
        let store = try SnapshotStore(directory: cache.root, identity: real)
        let fd = open(store.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var byte: UInt8 = 0
        XCTAssertEqual(pwrite(fd, &byte, 1, 0), 1); close(fd)
        let fallback = try make(tree, cache)
        defer { fallback.stop(saveCheckpoint: false) }
        try fallback.start(); XCTAssertTrue(fallback.waitUntilLive()); XCTAssertTrue(fallback.waitForCheckpoint())
        XCTAssertEqual(fallback.stats().dictionary["startup_mode"] as? String, "rebuild_fallback")
        XCTAssertEqual(fallback.metrics.snapshot()["full_scans"], 1)
        XCTAssertTrue(try fallback.verify().isConsistent)
        XCTAssertNoThrow(try store.reader(expectedIdentity: real))
    }

    func testEphemeralAndForcedRebuildAndOwnCacheExclusion() throws {
        try requireFSEvents()
        let tree = try TemporaryTree(), cache = try TemporaryTree()
        try tree.file("seed")
        let ephemeral = try make(tree, cache, ephemeral: true)
        try ephemeral.start(); XCTAssertTrue(ephemeral.waitUntilLive())
        XCTAssertFalse(ephemeral.checkpoint()); ephemeral.stop()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: cache.root).isEmpty)
        try cold(tree, cache)
        let forced = try make(tree, cache, rebuild: true)
        try forced.start(); XCTAssertTrue(forced.waitUntilLive()); XCTAssertTrue(forced.waitForCheckpoint())
        XCTAssertEqual(forced.metrics.snapshot()["full_scans"], 1)
        XCTAssertFalse(forced.stats().dictionary["snapshot_loaded"] as? Bool ?? true)
        forced.stop(saveCheckpoint: false)
        let inside = try PersistentIndexCoordinator(root: tree.root, cacheDirectory: tree.path("private-cache"))
        defer { inside.stop(saveCheckpoint: false) }
        try inside.start(); XCTAssertTrue(inside.waitUntilLive()); XCTAssertTrue(inside.waitForCheckpoint())
        XCTAssertNil(inside.index.entry(at: tree.path("private-cache")))
        XCTAssertTrue(try inside.verify().isConsistent)
    }

    func testNoOnlineSnapshotWritesDuringStormsAndContent() throws {
        try requireFSEvents()
        let tree = try TemporaryTree(), cache = try TemporaryTree()
        try tree.directory("storm"); try tree.file("content"); try cold(tree, cache)
        let c = try make(tree, cache)
        defer { c.stop(saveCheckpoint: false) }
        try c.start(); XCTAssertTrue(c.waitUntilLive())
        let store = try SnapshotStore(directory: cache.root, identity: VolumeIdentity.discover(root: tree.root))
        let before = try stamp(store.path)
        for i in 0..<1000 { try tree.file("storm/f\(i)") }
        waitFor("1000 created", timeout: 5) { c.index.stats().liveEntries == 1003 }
        for i in 0..<1000 {
            try FileManager.default.moveItem(atPath: tree.path("storm/f\(i)"), toPath: tree.path("storm/r\(i)"))
        }
        waitFor("rename storm converges", timeout: 5) {
            c.index.entry(at: tree.path("storm/r999")) != nil && c.index.entry(at: tree.path("storm/f0")) == nil
        }
        for i in 0..<1000 { try FileManager.default.removeItem(atPath: tree.path("storm/r\(i)")) }
        waitFor("1000 deleted", timeout: 5) { c.index.stats().liveEntries == 3 }
        XCTAssertTrue(c.core.flushEvents())
        let generation = c.index.stats().generation, metrics = c.metrics.snapshot()
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: tree.path("content")))
        for _ in 0..<10_000 { try handle.seek(toOffset: 0); try handle.write(contentsOf: Data([1])) }
        try handle.close()
        waitFor("content event processed", timeout: 5) {
            c.metrics.snapshot()["ignored_content_events", default: 0] > metrics["ignored_content_events", default: 0]
        }
        XCTAssertTrue(c.core.flushEvents())
        XCTAssertEqual(c.index.stats().generation, generation)
        XCTAssertEqual(try stamp(store.path), before)
        XCTAssertEqual(c.metrics.snapshot()["snapshot_checkpoints", default: 0], 0)
        XCTAssertTrue(try c.verify().isConsistent)
        XCTAssertTrue(c.checkpoint()); XCTAssertTrue(c.waitForCheckpoint())
        XCTAssertNotEqual(try stamp(store.path), before)
    }

    func testContentCursorAndCheckpointCaptureFollowCompletedMutations() throws {
        try requireFSEvents()
        let tree = try TemporaryTree()
        try tree.file("seed")
        let c = try UpdateCoordinator(root: tree.root)
        defer { c.stop() }
        try c.start(); XCTAssertTrue(c.waitUntilLive()); XCTAssertTrue(c.flushEvents())
        let before = try c.captureCheckpoint()
        let id = before.cursor + 1_000_000
        c.enqueue([.init(path: tree.path("seed"), flags: UInt32(kFSEventStreamEventFlagItemModified |
            kFSEventStreamEventFlagItemIsFile), id: id)])
        XCTAssertTrue(c.flushEvents())
        let content = try c.captureCheckpoint()
        XCTAssertGreaterThanOrEqual(content.cursor, id)
        XCTAssertEqual(content.metadata.generation, before.metadata.generation)
        c.enqueue([.init(path: tree.path("patched"), flags: UInt32(kFSEventStreamEventFlagItemCreated |
            kFSEventStreamEventFlagItemIsFile), id: id + 1)])
        XCTAssertTrue(c.flushEvents())
        let patched = try c.captureCheckpoint()
        XCTAssertGreaterThanOrEqual(patched.cursor, id + 1)
        XCTAssertNotNil(c.index.entry(at: tree.path("patched")))
        XCTAssertGreaterThan(patched.metadata.generation, content.metadata.generation)
    }

    func testUnchangedWarmExitDoesNotRewriteSnapshotOrAdvanceGeneration() throws {
        try requireFSEvents()
        let tree = try TemporaryTree(), cache = try TemporaryTree()
        try tree.file("seed"); try cold(tree, cache)
        let identity = try VolumeIdentity.discover(root: tree.root)
        let store = try SnapshotStore(directory: cache.root, identity: identity)
        let header = try store.reader(expectedIdentity: identity).header
        let before = try stamp(store.path)
        let c = try make(tree, cache)
        try c.start(); XCTAssertTrue(c.waitUntilLive())
        XCTAssertEqual(c.index.stats().generation, header.indexGeneration)
        XCTAssertEqual(c.stats().dictionary["last_checkpoint_generation"] as? UInt64, header.indexGeneration)
        c.stop()
        XCTAssertEqual(try stamp(store.path), before)
        XCTAssertEqual(c.metrics.snapshot()["snapshot_checkpoints", default: 0], 0)
    }

    func testWarmReplayManyDirtyParentsDoesNotLoopFullRebuild() throws {
        try requireFSEvents()
        let tree = try TemporaryTree(), cache = try TemporaryTree()
        for i in 0..<80 { try tree.directory("d\(i)"); try tree.file("d\(i)/seed") }
        try cold(tree, cache)
        for i in 0..<80 {
            try FileManager.default.moveItem(atPath: tree.path("d\(i)/seed"), toPath: tree.path("d\(i)/renamed"))
        }
        let c = try make(tree, cache)
        defer { c.stop(saveCheckpoint: false) }
        try c.start(); XCTAssertTrue(c.waitUntilLive())
        waitFor("many replay parents converge", timeout: 5) {
            (0..<80).allSatisfy { c.index.entry(at: tree.path("d\($0)/renamed")) != nil }
        }
        assertWarm(c)
        XCTAssertTrue(try c.verify().isConsistent)
    }

    func testSecondInterruptPreservesOldSnapshotForReplay() throws {
        try requireFSEvents()
        let tree = try TemporaryTree(), cache = try TemporaryTree()
        try tree.file("seed"); try cold(tree, cache)
        let store = try SnapshotStore(directory: cache.root, identity: VolumeIdentity.discover(root: tree.root))
        let before = try stamp(store.path)
        let c = try make(tree, cache)
        try c.start(); XCTAssertTrue(c.waitUntilLive())
        try tree.file("after-checkpoint")
        waitFor("live change before interrupted exit") { c.index.entry(at: tree.path("after-checkpoint")) != nil }
        c.interrupt()
        XCTAssertEqual(c.currentState, .live)
        c.interrupt()
        c.stop()
        XCTAssertEqual(try stamp(store.path), before)
        let next = try make(tree, cache)
        defer { next.stop(saveCheckpoint: false) }
        try next.start(); XCTAssertTrue(next.waitUntilLive())
        waitFor("cancelled exit change recovered") { next.index.entry(at: tree.path("after-checkpoint")) != nil }
        assertWarm(next)
        XCTAssertTrue(try next.verify().isConsistent)
    }

    private func stamp(_ path: String) throws -> [UInt64] {
        var s = stat()
        guard lstat(path, &s) == 0 else { throw SnapshotError.io("test stat", errno) }
        return [s.st_ino, UInt64(s.st_size), UInt64(s.st_mtimespec.tv_sec), UInt64(s.st_mtimespec.tv_nsec)]
    }
}
