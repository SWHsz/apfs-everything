import Foundation
import XCTest
@testable import APFSFindCore

final class PathCanonicalizerTests: XCTestCase {
    func testLexicalNormalization() {
        XCTAssertEqual(PathCanonicalizer.normalize("//a/./b/../c///"), "/a/c")
        XCTAssertEqual(PathCanonicalizer.normalize("/../../"), "/")
        XCTAssertEqual(PathCanonicalizer.normalize("/"), "/")
        XCTAssertNil(PathCanonicalizer.normalize("relative"))
        XCTAssertNil(PathCanonicalizer.normalize("/bad\0name"))
    }

    func testRootContainmentUsesPathComponentBoundary() {
        XCTAssertTrue(PathCanonicalizer.isWithin("/a/b", root: "/a"))
        XCTAssertTrue(PathCanonicalizer.isWithin("/a", root: "/a"))
        XCTAssertFalse(PathCanonicalizer.isWithin("/ab", root: "/a"))
        XCTAssertFalse(PathCanonicalizer.isWithin("/a/../b", root: "/a"))
        XCTAssertTrue(PathCanonicalizer.isWithin("/any/path", root: "/"))
    }

    func testParentAndMinimalRoots() {
        XCTAssertEqual(PathCanonicalizer.parent(of: "/a/b/"), "/a")
        XCTAssertEqual(PathCanonicalizer.parent(of: "/a"), "/")
        XCTAssertEqual(PathCanonicalizer.parent(of: "/"), "/")
        XCTAssertEqual(PathCanonicalizer.minimalRoots(["/a/b", "/a", "/a", "/ab/c", "/ab/c/d", "relative"]), ["/a", "/ab/c"])
        XCTAssertEqual(PathCanonicalizer.minimalRoots(["/a/b", "/"]), ["/"])
    }

    func testMinimalRootsChecksAncestorsAcrossPunctuationAndNormalizedPaths() {
        XCTAssertEqual(PathCanonicalizer.minimalRoots([
            "/a", "/a-", "/a/child", "/a-/child", "/ab/child",
            "/a./child", "/a./child/grandchild", "/a//other/../child",
            "/a/child/deeper", "/ab/./child", "relative", "/bad\0name"
        ]), ["/a", "/a-", "/a./child", "/ab/child"])
        XCTAssertEqual(PathCanonicalizer.minimalRoots(["/", "/a-", "/a/child", "//"]), ["/"])
    }

    func testMinimalRootsHandlesTenThousandDispersedDirectories() {
        let roots = (0..<10_000).map { "/home/project-\($0)/build" }
        let nested = roots.map { $0 + "/nested/deeper" }
        // A large, dispersed replay batch exercises the formerly quadratic
        // retained-root comparisons without a machine-dependent timing limit.
        XCTAssertEqual(PathCanonicalizer.minimalRoots(roots + nested + roots), roots.sorted())
    }

    func testCanonicalRootResolvesExistingSymlinkAndRejectsFiles() throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("apfsfind-path-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: base) }
        try manager.createDirectory(at: base.appendingPathComponent("real"), withIntermediateDirectories: true)
        try manager.createSymbolicLink(atPath: base.appendingPathComponent("alias").path,
                                       withDestinationPath: base.appendingPathComponent("real").path)
        let resolved = try PathCanonicalizer.canonicalRoot(base.appendingPathComponent("alias").path)
        XCTAssertEqual(resolved, try PathCanonicalizer.canonicalRoot(base.appendingPathComponent("real").path))
        let file = base.appendingPathComponent("file")
        XCTAssertTrue(manager.createFile(atPath: file.path, contents: nil))
        XCTAssertThrowsError(try PathCanonicalizer.canonicalRoot(file.path))
        XCTAssertThrowsError(try PathCanonicalizer.canonicalRoot(base.appendingPathComponent("missing").path))
    }
}
