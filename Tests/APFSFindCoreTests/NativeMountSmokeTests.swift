import Darwin
import Foundation
import XCTest
@testable import APFSFindCore

final class NativeMountSmokeTests: XCTestCase {
    func testOptionalUserMountedImageBoundaryAndUnmountRecovery() throws {
        guard ProcessInfo.processInfo.environment["APFSFIND_RUN_MOUNT_TESTS"] == "1" else {
            throw XCTSkip("Opt in with APFSFIND_RUN_MOUNT_TESTS=1; no root required")
        }
        let tree = try TemporaryTree(), payload = try TemporaryTree()
        try tree.directory("mount")
        try tree.file("mount/underlying")
        try payload.file("mounted")
        func hdiutil(_ arguments: [String]) throws -> Int32 {
            let p = Process(), output = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            p.arguments = arguments; p.standardOutput = output; p.standardError = output
            try p.run(); _ = output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return p.terminationStatus
        }
        let image = tree.path("fixture.dmg"), mount = tree.path("mount")
        guard try hdiutil(["create", "-srcfolder", payload.root, "-format", "UDRO", "-volname", "apfsfind-mount-fixture", image]) == 0 else {
            throw XCTSkip("User-session disk-image creation unavailable")
        }
        let scanner = BulkScanner(root: tree.root), index = FileIndex(root: tree.root)
        let initial = try scanner.scan()
        index.apply(initial.entries.map { .upsert($0) })
        let reconciler = DirectoryReconciler(scanner: scanner, index: index, rootDeviceID: initial.rootDeviceID, metrics: Metrics())
        guard try hdiutil(["attach", image, "-mountpoint", mount, "-nobrowse", "-noautoopen"]) == 0 else {
            throw XCTSkip("User-session mount unavailable")
        }
        var attached = true
        defer { if attached { _ = try? hdiutil(["detach", mount]) } }
        index.apply(reconciler.prepare(tree.root, force: true).mutations)
        XCTAssertTrue(try XCTUnwrap(index.entry(at: mount)).isMountPoint)
        XCTAssertNil(index.entry(at: mount + "/underlying"))
        XCTAssertNil(index.entry(at: mount + "/mounted"))
        let detached = try hdiutil(["detach", mount])
        XCTAssertEqual(detached, 0)
        guard detached == 0 else { throw CocoaError(.fileWriteUnknown) }
        attached = false
        index.apply(reconciler.prepare(tree.root, force: true).mutations)
        XCTAssertNotNil(index.entry(at: mount + "/underlying"))
        XCTAssertEqual(index.snapshotPaths(), Set(try scanner.scan().entries.map(\.path)))
    }
}
