import Foundation
import Darwin
import XCTest
@testable import APFSFindCore

final class ReconcilerTests: XCTestCase {
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
