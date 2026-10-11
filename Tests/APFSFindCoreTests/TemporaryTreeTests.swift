import Foundation
import XCTest
@testable import APFSFindCore

final class TemporaryTreeTests: XCTestCase {
    func testExplicitOwnedRootAndCleanup() throws {
        let parent = try TemporaryTree(cache: true)
        var child: TemporaryTree? = try TemporaryTree(temporaryDirectory: parent.root)
        let path = try XCTUnwrap(child).root
        XCTAssertEqual(PathCanonicalizer.parent(of: path), parent.root)
        try child?.file("fixture")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "/fixture"))
        child = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testMissingOverrideDoesNotCreateDirectory() throws {
        let parent = try TemporaryTree(cache: true)
        let missing = parent.path("missing")
        XCTAssertThrowsError(try TemporaryTree(temporaryDirectory: missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing))
    }

    func testUnsafeModeIsRejectedWithoutChangingPermissions() throws {
        let parent = try TemporaryTree(cache: true)
        let unsafe = parent.path("unsafe")
        try FileManager.default.createDirectory(atPath: unsafe, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o755])
        XCTAssertThrowsError(try TemporaryTree(temporaryDirectory: unsafe))
        let mode = try FileManager.default.attributesOfItem(atPath: unsafe)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o755)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: unsafe).isEmpty)
    }

    func testSymlinkOverrideIsRejected() throws {
        let parent = try TemporaryTree(cache: true)
        try FileManager.default.createSymbolicLink(atPath: parent.path("alias"), withDestinationPath: parent.root)
        XCTAssertThrowsError(try TemporaryTree(temporaryDirectory: parent.path("alias")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.root), ["alias"])
    }
}
