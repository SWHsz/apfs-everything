import CoreServices
import Foundation
import XCTest
@testable import APFSFindCore

final class CoordinatorBatchTests: XCTestCase {
    func testDirectoryRemoveWithStaleChildCreateCannotResurrectSubtree() throws {
        let tree = try TemporaryTree()
        try tree.directory("removed")
        try tree.file("removed/old")
        let scanner = BulkScanner(root: tree.root)
        let device = try scanner.rootDeviceID()
        let coordinator = try UpdateCoordinator(root: tree.root, maintenanceScheduler: .init())
        defer { coordinator.stop() }
        // Device 0 deliberately permits direct patches before conflict handling.
        coordinator.index.apply(try scanner.scan().entries.filter { $0.path != tree.root }.map {
            var entry = $0
            entry.deviceID = 0
            return .upsert(entry)
        })
        try FileManager.default.removeItem(atPath: tree.path("removed"))
        let reconciler = DirectoryReconciler(scanner: scanner, index: coordinator.index,
                                              rootDeviceID: device, metrics: coordinator.metrics)
        coordinator.process([
            .init(path: tree.path("removed"), flags: UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsDir)),
            .init(path: tree.path("removed/ghost"), flags: UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile))
        ], into: coordinator.index, using: reconciler, countMetrics: true, mayRebuild: false)
        XCTAssertEqual(coordinator.index.snapshotPaths(), [tree.root])
        XCTAssertEqual(coordinator.index.stats().files, 0)
        XCTAssertEqual(coordinator.metrics.snapshot()["direct_patches", default: 0], 0)
    }

    func testSeparateCreateAndRemoveEventsForSamePathUseCurrentDiskState() throws {
        let tree = try TemporaryTree()
        try tree.file("survivor")
        let scanner = BulkScanner(root: tree.root)
        let device = try scanner.rootDeviceID()
        let actual = try XCTUnwrap(scanner.readDirectory(tree.root, rootDeviceID: device).first)
        let coordinator = try UpdateCoordinator(root: tree.root, maintenanceScheduler: .init())
        defer { coordinator.stop() }
        coordinator.index.apply([.upsert(actual)])
        let reconciler = DirectoryReconciler(scanner: scanner, index: coordinator.index,
                                              rootDeviceID: device, metrics: coordinator.metrics)
        let created = FileSystemEvent(path: actual.path, flags: UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile))
        let removed = FileSystemEvent(path: actual.path, flags: UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile))
        coordinator.process([created, removed], into: coordinator.index, using: reconciler,
                            countMetrics: true, mayRebuild: false)
        XCTAssertEqual(coordinator.index.entry(at: actual.path), actual)
        coordinator.process([removed, created], into: coordinator.index, using: reconciler,
                            countMetrics: true, mayRebuild: false)
        XCTAssertEqual(coordinator.index.entry(at: actual.path), actual)
        XCTAssertEqual(coordinator.metrics.snapshot()["direct_patches", default: 0], 0)
    }

    func testAmbiguousRootEventReconcilesWithoutTraversingAboveRoot() throws {
        let tree = try TemporaryTree()
        try tree.file("seed")
        let scanner = BulkScanner(root: tree.root)
        let coordinator = try UpdateCoordinator(root: tree.root, maintenanceScheduler: .init())
        defer { coordinator.stop() }
        let reconciler = DirectoryReconciler(scanner: scanner, index: coordinator.index,
                                              rootDeviceID: try scanner.rootDeviceID(), metrics: coordinator.metrics)
        coordinator.process([
            .init(path: tree.root, flags: UInt32(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsDir))
        ], into: coordinator.index, using: reconciler, countMetrics: true, mayRebuild: false)
        XCTAssertNotNil(coordinator.index.entry(at: tree.path("seed")))
        XCTAssertEqual(coordinator.index.snapshotPaths(), [tree.root, tree.path("seed")])
    }

    func testReconciliationOverridesStaleCreateInSameBatch() throws {
        let tree = try TemporaryTree()
        try tree.file("anchor")
        let scanner = BulkScanner(root: tree.root)
        let device = try scanner.rootDeviceID()
        let coordinator = try UpdateCoordinator(root: tree.root, maintenanceScheduler: .init())
        defer { coordinator.stop() }
        // Keep the synthetic index root's device 0, enabling the direct create
        // fast path without starting a real stream in this deterministic test.
        coordinator.index.apply(try scanner.readDirectory(tree.root, rootDeviceID: device).map { .upsert($0) })
        let reconciler = DirectoryReconciler(scanner: scanner, index: coordinator.index,
                                              rootDeviceID: device, metrics: coordinator.metrics)
        coordinator.process([
            .init(path: tree.path("ghost"), flags: UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)),
            .init(path: tree.path("anchor"), flags: UInt32(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsFile))
        ], into: coordinator.index, using: reconciler, countMetrics: true, mayRebuild: false)
        XCTAssertNil(coordinator.index.entry(at: tree.path("ghost")))
        XCTAssertNotNil(coordinator.index.entry(at: tree.path("anchor")))
        XCTAssertEqual(coordinator.metrics.snapshot()["direct_patches", default: 0], 0)
        XCTAssertEqual(coordinator.index.snapshotPaths(), [tree.root, tree.path("anchor")])
    }

    func testReconciliationOverridesStaleRemoveInSameBatch() throws {
        let tree = try TemporaryTree()
        try tree.file("survivor")
        let scanner = BulkScanner(root: tree.root)
        let device = try scanner.rootDeviceID()
        let coordinator = try UpdateCoordinator(root: tree.root, maintenanceScheduler: .init())
        defer { coordinator.stop() }
        coordinator.index.apply(try scanner.readDirectory(tree.root, rootDeviceID: device).map { .upsert($0) })
        let reconciler = DirectoryReconciler(scanner: scanner, index: coordinator.index,
                                              rootDeviceID: device, metrics: coordinator.metrics)
        coordinator.process([
            .init(path: tree.path("survivor"), flags: UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile)),
            .init(path: tree.path("renamed"), flags: UInt32(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsFile))
        ], into: coordinator.index, using: reconciler, countMetrics: true, mayRebuild: false)
        XCTAssertNotNil(coordinator.index.entry(at: tree.path("survivor")))
        XCTAssertEqual(coordinator.metrics.snapshot()["direct_patches", default: 0], 0)
        XCTAssertEqual(coordinator.index.stats().tombstones, 0)
    }

    func testAncestorDirtyScopeIncludesSuppressedNestedCreate() throws {
        let tree = try TemporaryTree()
        try tree.directory("nested")
        let scanner = BulkScanner(root: tree.root)
        let device = try scanner.rootDeviceID()
        let coordinator = try UpdateCoordinator(root: tree.root, maintenanceScheduler: .init())
        defer { coordinator.stop() }
        var directory = try XCTUnwrap(scanner.readDirectory(tree.root, rootDeviceID: device).first)
        directory.deviceID = 0 // Enable a direct patch beneath the indexed child.
        coordinator.index.apply([.upsert(directory)])
        try tree.file("nested/created")
        let reconciler = DirectoryReconciler(scanner: scanner, index: coordinator.index,
                                              rootDeviceID: device, metrics: coordinator.metrics)
        coordinator.process([
            .init(path: tree.path("nested/created"), flags: UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)),
            .init(path: tree.path("renamed"), flags: UInt32(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsFile))
        ], into: coordinator.index, using: reconciler, countMetrics: true, mayRebuild: false)
        XCTAssertNotNil(coordinator.index.entry(at: tree.path("nested/created")))
        XCTAssertEqual(coordinator.metrics.snapshot()["direct_patches", default: 0], 0)
        XCTAssertEqual(coordinator.metrics.snapshot()["directory_reconciles", default: 0], 2)
        XCTAssertEqual(coordinator.metrics.snapshot()["subtree_reconciles", default: 0], 0,
            "the root and requested child listings do not require recursive siblings")
    }

    func testVanishedDirtyDirectoryRepairsParentWithoutFullRebuild() throws {
        let tree = try TemporaryTree()
        try tree.directory("gone/deep")
        try tree.file("gone/deep/ghost")
        let scanner = BulkScanner(root: tree.root)
        let scan = try scanner.scan()
        let coordinator = try UpdateCoordinator(root: tree.root, maintenanceScheduler: .init())
        defer { coordinator.stop() }
        coordinator.index.apply(scan.entries.map { .upsert($0) })
        let reconciler = DirectoryReconciler(scanner: scanner, index: coordinator.index,
            rootDeviceID: scan.rootDeviceID, metrics: coordinator.metrics)
        try FileManager.default.removeItem(atPath: tree.path("gone"))
        // Its parent is still indexed, but has vanished before the ambiguous
        // child event is processed. The repair must climb to the surviving root.
        coordinator.process([
            .init(path: tree.path("gone/deep/ghost"), flags: UInt32(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsFile))
        ], into: coordinator.index, using: reconciler, countMetrics: true, mayRebuild: true)
        XCTAssertEqual(coordinator.index.snapshotPaths(), [tree.root])
        XCTAssertEqual(coordinator.metrics.snapshot()["rebuild_requests_reconcile_error", default: 0], 0)
        XCTAssertGreaterThan(coordinator.metrics.snapshot()["reconcile_races", default: 0], 0)
    }
}
