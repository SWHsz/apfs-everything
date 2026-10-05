import CAPFSShim
import Darwin
import Foundation
import XCTest
@testable import APFSFindCore

final class CShimSafetyTests: XCTestCase {
    func testRootResolutionBoundsAndStandardAlias() throws {
        var output = [CChar](repeating: 0, count: 4)
        XCTAssertEqual(apfs_resolve_local_root("/private/tmp", &output, output.count), -1)
        XCTAssertEqual(errno, ENAMETOOLONG)
        XCTAssertEqual(try PathCanonicalizer.canonicalRoot("/tmp"), "/private/tmp")
    }

    func testRootSymlinkLoopIsBounded() throws {
        let tree = try TemporaryTree()
        try FileManager.default.createSymbolicLink(atPath: tree.path("one"), withDestinationPath: "two")
        try FileManager.default.createSymbolicLink(atPath: tree.path("two"), withDestinationPath: "one")
        XCTAssertThrowsError(try PathCanonicalizer.canonicalRoot(tree.path("one"))) { error in
            guard case PathCanonicalizationError.inaccessibleRoot(_, let code) = error else {
                return XCTFail("Unexpected root resolver error: \(error)")
            }
            XCTAssertEqual(code, ELOOP)
        }
    }

    func testRootSymlinkThenParentPreservesFilesystemSemantics() throws {
        let tree = try TemporaryTree()
        try tree.directory("left")
        try tree.directory("right/child")
        try FileManager.default.createSymbolicLink(atPath: tree.path("left/alias"), withDestinationPath: "../right/child")
        XCTAssertEqual(try PathCanonicalizer.canonicalRoot(tree.path("left/alias/..")), tree.path("right"))
    }
}
