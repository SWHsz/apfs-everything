import Darwin
import Foundation
import XCTest
@testable import APFSFindCore

final class BenchmarkDirectoryTests: XCTestCase {
    func testExactOwnedUUIDCleanupAndIdempotence() throws {
        let parent = try TemporaryTree()
        let owned = try OwnedBenchmarkDirectory(parent: parent.root, prefix: "apfsfind-real-bench-")
        try owned.validate()
        XCTAssertThrowsError(try OwnedBenchmarkDirectory(newPath: owned.path, parent: parent.root,
                                                        prefix: "apfsfind-real-bench-"))
        try owned.remove(); try owned.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
    }
    func testRejectsRootParentNonUUIDAndForeignPath() throws {
        let parent = try TemporaryTree(), other = try TemporaryTree()
        for path in ["/", parent.root, parent.root + "/ordinary", other.root + "/apfsfind-real-bench-" + UUID().uuidString] {
            XCTAssertThrowsError(try OwnedBenchmarkDirectory(newPath: path, parent: parent.root, prefix: "apfsfind-real-bench-"))
        }
    }
    func testSymlinkAndReplacedInodeCannotRedirectCleanup() throws {
        let parent = try TemporaryTree(), other = try TemporaryTree()
        let owned = try OwnedBenchmarkDirectory(parent: parent.root, prefix: "apfsfind-real-bench-")
        let retired = parent.path("retired")
        try FileManager.default.moveItem(atPath: owned.path, toPath: retired)
        try FileManager.default.createSymbolicLink(atPath: owned.path, withDestinationPath: other.root)
        XCTAssertThrowsError(try owned.remove())
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.root))
        try FileManager.default.removeItem(atPath: owned.path)
        try FileManager.default.createDirectory(atPath: owned.path, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        XCTAssertThrowsError(try owned.remove())
    }
}
