import XCTest
@testable import APFSFindCore

final class JournalExclusionTests: XCTestCase {
    func testOnlyTheActualVolumeRootJournalIsExcluded() {
        XCTAssertEqual(BulkScanner.volumeJournalExclusions(root: "/volume", mountPoint: "/volume"), ["/volume/.fseventsd"])
        XCTAssertEqual(BulkScanner.volumeJournalExclusions(root: "/volume/home", mountPoint: "/volume"), [])
        XCTAssertEqual(BulkScanner.volumeJournalExclusions(root: "/", mountPoint: "/"), ["/.fseventsd"])
    }
    func testSameNamedUserDirectoryIsStillScanned() throws {
        let tree = try TemporaryTree()
        try tree.directory(".fseventsd")
        try tree.file(".fseventsd/user-file")
        XCTAssertTrue(try BulkScanner(root: tree.root).scan().entries.contains { $0.path == tree.path(".fseventsd/user-file") })
    }
    func testWarmInstallRemovesPreviouslyIndexedExcludedSubtreeWithoutScan() throws {
        try requireFSEvents()
        let tree = try TemporaryTree(), restored = FileIndex(root: tree.root)
        restored.apply([.upsert(.init(path: tree.path("excluded/ghost"), kind: .file))])
        let core = try UpdateCoordinator(root: tree.root, excludedRoots: [tree.path("excluded")], maintenanceScheduler: .init())
        defer { core.stop() }
        let identity = try VolumeIdentity.discover(root: tree.root)
        try core.start(restored: restored, cursor: identity.currentEventID(), identity: identity)
        XCTAssertNil(core.index.entry(at: tree.path("excluded")))
        XCTAssertNil(core.index.entry(at: tree.path("excluded/ghost")))
        XCTAssertEqual(core.metrics.snapshot()["full_scans", default: 0], 0)
    }
}
