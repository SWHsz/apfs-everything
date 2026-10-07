import Foundation
import Darwin
import CoreServices
import XCTest
@testable import APFSFindCore

final class ReconcilerTests: XCTestCase {
    func testDeletedWideBaseRecoversBeforeMaterializingOldChildPaths() throws {
        let cache = try TemporaryTree(cache:true), identity = snapshotIdentity(), ram = FileIndex(root:identity.root)
        ram.apply((0..<100_001).map { .upsert(.init(path:identity.root+"/file\($0)",kind:.file)) })
        let store = try SnapshotStore(directory:cache.root,identity:identity)
        _ = try SnapshotV2Writer.write(source:.ram(ram,ram.stats().generation),identity:identity,generation:ram.stats().generation,cursor:1,store:store)
        let hybrid = HybridIndex(base:try store.reader(expectedIdentity:identity).mappedBase!)
        let metrics = Metrics(), reconciler = DirectoryReconciler(scanner:EmptyScopeReader(),index:hybrid,rootDeviceID:identity.deviceID,metrics:metrics)
        let plan = reconciler.prepare(identity.root,force:true)
        XCTAssertTrue(plan.requiresRebuild); XCTAssertTrue(plan.mutations.isEmpty)
        XCTAssertEqual(hybrid.stats().liveEntries,100_002)
        XCTAssertEqual(metrics.snapshot()["reconcile_old_children_limit"],1)
    }
    func testInvalidatedAndRootDirtyBatchesSkipObsoleteScopes() throws {
        for invalidatingFlag in [kFSEventStreamEventFlagUserDropped,kFSEventStreamEventFlagMustScanSubDirs] {
            let tree = try TemporaryTree(); try tree.directory("scope"); try tree.file("scope/old")
            let scanner = BulkScanner(root:tree.root), scan = try scanner.scan(), index = FileIndex(root:tree.root)
            index.apply(scan.entries.map { .upsert($0) }); let before = index.snapshotPaths()
            let reader = FatalScopeReader(), metrics = Metrics()
            let reconciler = DirectoryReconciler(scanner:reader,index:index,rootDeviceID:scan.rootDeviceID,metrics:metrics)
            let core = try UpdateCoordinator(root:tree.root,index:index,maintenanceScheduler:.init())
            defer { core.stop() }
            core.process([.init(path:tree.root,flags:UInt32(invalidatingFlag)),
                          .init(path:tree.path("scope/renamed"),flags:UInt32(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsFile))],into:index,using:reconciler,countMetrics:true,mayRebuild:true)
            XCTAssertEqual(reader.reads,0)
            XCTAssertEqual(index.snapshotPaths(),before)
            XCTAssertEqual(core.currentState,.dirty)
        }
    }
    func testRecoveryBuffersEventsWithoutReconcilingObsoleteBase() throws {
        let tree = try TemporaryTree(); try tree.file("old")
        let scanner = BulkScanner(root:tree.root), scan = try scanner.scan(), index = FileIndex(root:tree.root)
        index.apply(scan.entries.map { .upsert($0) })
        let scheduler = MaintenanceScheduler(), root = tree.root
        let core = try UpdateCoordinator(root:tree.root,configuration:.init(fullRebuildMinInterval:0),index:index,
            fenceProvider:{ _ in 100 },maintenanceScheduler:scheduler,replayStarter:{ _,deliver in
                deliver([.init(path:root,flags:UInt32(kFSEventStreamEventFlagHistoryDone),id:100)])
            })
        defer { core.stop() }
        try core.start(restored:index,cursor:100)
        XCTAssertTrue(core.waitUntilLive())
        let blocker = try scheduler.acquireBlocking(volumeID:UUID(),kind:.metadataBootstrap,cancellation:.init())
        defer { blocker.release() }
        core.rebuild()
        waitFor("recovery waits for global maintenance lease") { core.currentState == .rebuilding }
        let oldGeneration = index.stats().generation
        try tree.file("new")
        core.enqueue([.init(path:tree.root,flags:UInt32(kFSEventStreamEventFlagMustScanSubDirs),id:101),
                      .init(path:tree.path("new"),flags:UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile),id:102),
                      .init(path:tree.path("vanished-historical-create"),flags:UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile),id:99)])
        waitFor("events are buffered during recovery") { core.metrics.snapshot()["namespace_events_deferred_during_recovery"] == 3 }
        XCTAssertEqual(index.stats().generation,oldGeneration)
        XCTAssertEqual(core.metrics.snapshot()["directory_reconciles",default:0],0)
        XCTAssertNil(index.entry(at:tree.path("new")))
        XCTAssertNotNil(index.entry(at:tree.path("old")))
        XCTAssertGreaterThan(core.eventBufferEstimates()["pending_event_estimated_bytes",default:0],0)
        blocker.release()
        waitFor("recovery installs buffered changes",timeout:10) {
            core.currentState == .live && core.metrics.snapshot()["full_rebuilds"] == 1
        }
        XCTAssertNotNil(index.entry(at:tree.path("new")))
        XCTAssertNil(index.entry(at:tree.path("vanished-historical-create")))
        XCTAssertEqual(core.metrics.snapshot()["full_scans"],1)
        XCTAssertEqual(core.eventBufferEstimates()["pending_event_estimated_bytes"],0)
    }
    func testLargeUnchangedSubtreeDoesNotLoopThroughFullRecovery() throws {
        let tree = try TemporaryTree(), index = FileIndex(root:tree.root), reader = WideScopeReader(root:tree.root)
        index.apply(reader.entries.map { .upsert($0) })
        let metrics = Metrics(), reconciler = DirectoryReconciler(scanner:reader,index:index,rootDeviceID:7,metrics:metrics)
        let plan = reconciler.prepare(tree.root,subtree:true,force:true)
        XCTAssertFalse(plan.requiresRebuild); XCTAssertTrue(plan.mutations.isEmpty)
        XCTAssertEqual(metrics.snapshot()["directory_reconciles"],30_001)
    }
    func testRecoveryRequestStopsRemainingLargeScopesAndPreservesOldIndex() throws {
        let tree = try TemporaryTree(); try tree.directory("a"); try tree.directory("b")
        try tree.file("a/old"); try tree.file("b/old")
        let scanner = BulkScanner(root:tree.root), scan = try scanner.scan(), index = FileIndex(root:tree.root)
        index.apply(scan.entries.map { .upsert($0) }); let before = index.snapshotPaths()
        let reader = FatalScopeReader(), metrics = Metrics()
        let reconciler = DirectoryReconciler(scanner:reader,index:index,rootDeviceID:scan.rootDeviceID,metrics:metrics)
        let core = try UpdateCoordinator(root:tree.root,index:index,maintenanceScheduler:.init())
        defer { core.stop() }
        let flags = UInt32(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsFile)
        core.process([.init(path:tree.path("a/new"),flags:flags),.init(path:tree.path("b/new"),flags:flags)],into:index,using:reconciler,countMetrics:true,mayRebuild:true)
        XCTAssertEqual(reader.reads,1)
        XCTAssertEqual(index.snapshotPaths(),before)
        XCTAssertEqual(core.currentState,.dirty)
        XCTAssertEqual(core.metrics.snapshot()["reconcile_deferred_to_rebuild"],1)
    }
    func testDirectoryDiffAndTypeChange() {
        let old = [NamespaceEntry(path: "/test/remove", kind: .directory), .init(path: "/test/type", kind: .file)]
        let new = [NamespaceEntry(path: "/test/add", kind: .file), .init(path: "/test/type", kind: .directory)]
        let index = FileIndex(root: "/test")
        index.apply(old.map { .upsert($0) } + [.upsert(.init(path: "/test/remove/ghost", kind: .file))])
        index.apply(DirectoryReconciler.diff(existing: old, actual: new))
        XCTAssertEqual(index.snapshotPaths(), Set(["/test", "/test/add", "/test/type"]))
        XCTAssertEqual(index.entry(at: "/test/type")?.kind, .directory)
        XCTAssertTrue(DirectoryReconciler.diff(existing: new, actual: new).isEmpty)
    }

    func testNewDirectoryScansSubtreeAndDeletionRemovesGhosts() throws {
        let tree = try TemporaryTree()
        let scanner = BulkScanner(root: tree.root)
        let index = FileIndex(root: tree.root)
        let reconciler = DirectoryReconciler(scanner: scanner, index: index,
                                              rootDeviceID: try scanner.rootDeviceID(), metrics: Metrics())
        try tree.directory("new/deep")
        try tree.file("new/deep/seed")
        index.apply(reconciler.prepare(tree.root, force: true).mutations)
        XCTAssertNotNil(index.entry(at: tree.path("new/deep/seed")))
        try FileManager.default.removeItem(atPath: tree.path("new"))
        index.apply(reconciler.prepare(tree.root, force: true).mutations)
        XCTAssertEqual(index.snapshotPaths(), [tree.root])
    }

    func testMtimeGateCanBeBypassedForCorrectness() throws {
        let tree = try TemporaryTree()
        let scanner = BulkScanner(root: tree.root), metrics = Metrics(), index = FileIndex(root: tree.root)
        let reconciler = DirectoryReconciler(scanner: scanner, index: index,
                                              rootDeviceID: try scanner.rootDeviceID(), metrics: metrics)
        index.apply(reconciler.prepare(tree.root).mutations)
        XCTAssertTrue(reconciler.prepare(tree.root).gateSkipped)
        XCTAssertFalse(reconciler.prepare(tree.root, force: true).gateSkipped)
        XCTAssertEqual(metrics.snapshot()["mtime_gate_skips"], 1)
    }

    func testFailedReadDoesNotEraseIndexedSubtree() throws {
        let tree = try TemporaryTree()
        try tree.directory("dir")
        try tree.file("dir/child")
        let scanner = BulkScanner(root: tree.root), index = FileIndex(root: tree.root)
        index.apply(try scanner.scan().entries.map { .upsert($0) })
        let reconciler = DirectoryReconciler(scanner: scanner, index: index,
                                              rootDeviceID: try scanner.rootDeviceID(), metrics: Metrics())
        try FileManager.default.removeItem(atPath: tree.path("dir"))
        let plan = reconciler.prepare(tree.path("dir"), force: true)
        XCTAssertTrue(plan.failed)
        XCTAssertFalse(plan.requiresRebuild)
        XCTAssertEqual(plan.retryParents, [tree.root])
        XCTAssertEqual(plan.failures, [.init(path: tree.path("dir"), code: ENOENT)])
        XCTAssertTrue(plan.mutations.isEmpty)
        XCTAssertNotNil(index.entry(at: tree.path("dir/child")))
        index.apply(reconciler.prepare(tree.root, force: true).mutations)
        XCTAssertNil(index.entry(at: tree.path("dir/child")))
    }

    func testSymlinkReplacementRetriesParentWithoutFollowingTarget() throws {
        let tree = try TemporaryTree()
        try tree.directory("dir")
        try tree.file("dir/stale")
        try tree.directory("target")
        try tree.file("target/visible")
        let scanner = BulkScanner(root: tree.root), index = FileIndex(root: tree.root)
        let initial = try scanner.scan()
        index.apply(initial.entries.map { .upsert($0) })
        let reconciler = DirectoryReconciler(scanner: scanner, index: index,
                                             rootDeviceID: initial.rootDeviceID, metrics: Metrics())
        try FileManager.default.removeItem(atPath: tree.path("dir"))
        try FileManager.default.createSymbolicLink(atPath: tree.path("dir"),
                                                   withDestinationPath: tree.path("target"))
        let failed = reconciler.prepare(tree.path("dir"), force: true)
        XCTAssertTrue(failed.failed)
        XCTAssertFalse(failed.requiresRebuild)
        XCTAssertEqual(failed.retryParents, [tree.root])
        XCTAssertTrue(failed.mutations.isEmpty)
        XCTAssertNotNil(index.entry(at: tree.path("dir/stale")))

        index.apply(reconciler.prepare(tree.root, force: true).mutations)
        XCTAssertEqual(index.entry(at: tree.path("dir"))?.kind, .symlink)
        XCTAssertNil(index.entry(at: tree.path("dir/stale")))
        XCTAssertNil(index.entry(at: tree.path("dir/visible")))
        XCTAssertNotNil(index.entry(at: tree.path("target/visible")))
    }

    func testUnreadableDescendantPreservesSubtreeWithoutRootRebuild() throws {
        guard geteuid() != 0 else { throw XCTSkip("Permission exclusion requires a non-root process") }
        let tree = try TemporaryTree()
        try tree.directory("private")
        try tree.file("private/known")
        let scanner = BulkScanner(root: tree.root), index = FileIndex(root: tree.root), metrics = Metrics()
        let initial = try scanner.scan()
        index.apply(initial.entries.map { .upsert($0) })
        let reconciler = DirectoryReconciler(scanner: scanner, index: index,
                                             rootDeviceID: initial.rootDeviceID, metrics: metrics)
        XCTAssertEqual(chmod(tree.path("private"), 0), 0)
        defer { _ = chmod(tree.path("private"), 0o700) }
        let plan = reconciler.prepare(tree.path("private"), force: true)
        XCTAssertTrue(plan.failed)
        XCTAssertFalse(plan.requiresRebuild)
        XCTAssertTrue(plan.retryParents.isEmpty)
        XCTAssertEqual(plan.failures.first?.code, EACCES)
        XCTAssertTrue(plan.mutations.isEmpty)
        XCTAssertNotNil(index.entry(at: tree.path("private/known")))
        XCTAssertEqual(metrics.snapshot()["reconcile_unreadable_skips"], 1)

        XCTAssertEqual(chmod(tree.path("private"), 0o700), 0)
        try FileManager.default.removeItem(atPath: tree.path("private/known"))
        try tree.file("private/restored")
        let restored = reconciler.prepare(tree.path("private"), force: true)
        XCTAssertFalse(restored.failed)
        index.apply(restored.mutations)
        XCTAssertNil(index.entry(at: tree.path("private/known")))
        XCTAssertNotNil(index.entry(at: tree.path("private/restored")))
    }

    func testRootFailureRequiresRebuildRatherThanPublishingEmptyRoot() throws {
        let tree = try TemporaryTree()
        try tree.file("known")
        let scanner = BulkScanner(root: tree.root), index = FileIndex(root: tree.root)
        let initial = try scanner.scan()
        index.apply(initial.entries.map { .upsert($0) })
        let reconciler = DirectoryReconciler(scanner: scanner, index: index,
                                             rootDeviceID: initial.rootDeviceID, metrics: Metrics())
        try FileManager.default.removeItem(atPath: tree.root)
        let plan = reconciler.prepare(tree.root, force: true)
        XCTAssertTrue(plan.failed)
        XCTAssertTrue(plan.requiresRebuild)
        XCTAssertTrue(plan.retryParents.isEmpty)
        XCTAssertTrue(plan.mutations.isEmpty)
        XCTAssertEqual(plan.failures, [.init(path: tree.root, code: ENOENT)])
        XCTAssertNotNil(index.entry(at: tree.path("known")))
    }

    func testFailureRecoveryDistinguishesExclusionsRacesAndUnexpectedIO() {
        for code in [EACCES, EPERM, ENODATA] {
            XCTAssertEqual(DirectoryReconciler.recovery(for: code, isRoot: false), .preserveUnreadable)
            XCTAssertEqual(DirectoryReconciler.recovery(for: code, isRoot: true), .rebuild)
        }
        for code in [ENOENT, ENOTDIR, ELOOP, EXDEV] {
            XCTAssertEqual(DirectoryReconciler.recovery(for: code, isRoot: false), .retryParent)
            XCTAssertEqual(DirectoryReconciler.recovery(for: code, isRoot: true), .rebuild)
        }
        for code in [EIO, ENOMEM, EINVAL] {
            XCTAssertEqual(DirectoryReconciler.recovery(for: code, isRoot: false), .rebuild)
        }
        XCTAssertEqual(DirectoryReconciler.recovery(for: ECANCELED, isRoot: false), .cancelled)
        XCTAssertEqual(DirectoryReconciler.recovery(for: ECANCELED, isRoot: true), .cancelled)
    }

    func testCancellationDoesNotProduceFailureOrRebuild() throws {
        let tree = try TemporaryTree()
        let scanner = BulkScanner(root: tree.root), index = FileIndex(root: tree.root)
        let reconciler = DirectoryReconciler(scanner: scanner, index: index,
                                             rootDeviceID: try scanner.rootDeviceID(), metrics: Metrics())
        let cancellation = CancellationToken()
        cancellation.cancel()
        let plan = reconciler.prepare(tree.root, force: true, cancellation: cancellation)
        XCTAssertFalse(plan.failed)
        XCTAssertFalse(plan.requiresRebuild)
        XCTAssertTrue(plan.failures.isEmpty)
        XCTAssertTrue(plan.retryParents.isEmpty)
        XCTAssertTrue(plan.mutations.isEmpty)
    }

    func testReplacedDirectoryReinsertsDescendantsWhoseInodesSurvive() throws {
        let tree = try TemporaryTree()
        try tree.directory("folder/nested")
        try tree.file("folder/nested/same")
        let scanner = BulkScanner(root: tree.root), index = FileIndex(root: tree.root)
        let initial = try scanner.scan()
        index.apply(initial.entries.map { .upsert($0) })
        let oldFolder = try XCTUnwrap(index.entry(at: tree.path("folder")))
        let oldNested = try XCTUnwrap(index.entry(at: tree.path("folder/nested")))
        let oldFile = try XCTUnwrap(index.entry(at: tree.path("folder/nested/same")))
        // Keep the old directory inode allocated, ensuring the replacement gets
        // a different inode while the nested directory and file retain theirs.
        try FileManager.default.moveItem(atPath: tree.path("folder"), toPath: tree.path("retired"))
        try tree.directory("folder")
        try FileManager.default.moveItem(atPath: tree.path("retired/nested"), toPath: tree.path("folder/nested"))
        let reconciler = DirectoryReconciler(scanner: scanner, index: index,
                                              rootDeviceID: initial.rootDeviceID, metrics: Metrics())
        index.apply(reconciler.prepare(tree.root, force: true).mutations)
        XCTAssertNotEqual(index.entry(at: tree.path("folder"))?.fileID, oldFolder.fileID)
        XCTAssertEqual(index.entry(at: tree.path("folder/nested"))?.fileID, oldNested.fileID)
        XCTAssertEqual(index.entry(at: tree.path("folder/nested/same"))?.fileID, oldFile.fileID)
        XCTAssertEqual(index.snapshotPaths(), Set(try scanner.scan().entries.map(\.path)))
        XCTAssertTrue(reconciler.prepare(tree.root, force: true).mutations.isEmpty)
    }
}

private final class FatalScopeReader: DirectoryReading {
    var reads = 0
    func readDirectory(_ path:String,rootDeviceID:UInt64,cancellation:CancellationToken) throws -> [NamespaceEntry] {
        reads += 1; throw ScannerError(path:path,code:EIO)
    }
}

private final class WideScopeReader: DirectoryReading {
    let root:String
    var entries:[NamespaceEntry] {
        var result:[NamespaceEntry] = []
        for d in 0..<30_000 {
            let parent = root+"/d\(d)"
            result.append(.init(path:parent,kind:.directory,deviceID:7,fileID:UInt64(d+1)))
        }
        return result
    }
    init(root:String) { self.root = root }
    func readDirectory(_ path:String,rootDeviceID:UInt64,cancellation:CancellationToken) throws -> [NamespaceEntry] {
        if path == root { return entries }
        return []
    }
}

private final class EmptyScopeReader: DirectoryReading {
    func readDirectory(_ path:String,rootDeviceID:UInt64,cancellation:CancellationToken) throws -> [NamespaceEntry] { [] }
}
