import Dispatch
import XCTest
@testable import APFSFindCore

final class FileIndexTests: XCTestCase {
    func testRootAndBatchInsert() {
        let index = FileIndex(root: "/test")
        index.apply([
            .upsert(NamespaceEntry(path: "/test/a.txt", kind: .file, deviceID: 9, fileID: 12)),
            .upsert(NamespaceEntry(path: "/test/dir", kind: .directory)),
            .upsert(NamespaceEntry(path: "/test/dir/b.txt", kind: .file))
        ])
        XCTAssertEqual(index.snapshotPaths(), ["/test", "/test/a.txt", "/test/dir", "/test/dir/b.txt"])
        XCTAssertEqual(index.stats().generation, 1)
        XCTAssertEqual(index.stats().files, 2)
        XCTAssertEqual(index.stats().directories, 2)
        XCTAssertEqual(index.entry(at: "/test/a.txt")?.fileID, 12)
        XCTAssertEqual(index.children(of: "/test").map(\.path), ["/test/a.txt", "/test/dir"])
    }

    func testMissingParentsAreInsertedBeforeChildren() {
        let index = FileIndex(root: "/test")
        index.apply([.upsert(NamespaceEntry(path: "/test/a/b/c.txt", kind: .file))])
        XCTAssertEqual(index.stats().liveEntries, 4)
        XCTAssertEqual(index.children(of: "/test/a").map(\.path), ["/test/a/b"])
        XCTAssertEqual(index.entry(at: "/test/a")?.kind, .directory)
    }

    func testChildUpsertMaintainsDirectoryParentInvariant() {
        let index = FileIndex(root: "/test")
        index.apply([.upsert(NamespaceEntry(path: "/test/parent", kind: .file))])
        // Out-of-order scanner input establishes that this path is now a
        // directory. Namespace event conflicts are reconciled by the coordinator.
        index.apply([.upsert(NamespaceEntry(path: "/test/parent/child", kind: .file))])
        XCTAssertEqual(index.entry(at: "/test/parent")?.kind, .directory)
        XCTAssertEqual(index.children(of: "/test/parent").map(\.path), ["/test/parent/child"])
        XCTAssertEqual(index.stats().files, 1)
        XCTAssertEqual(index.stats().directories, 2)
        XCTAssertEqual(index.stats().liveEntries + index.stats().tombstones, index.stats().totalEntries)
    }

    func testRepeatedSubtreeDeletionAndSelectiveResurrection() {
        let index = FileIndex(root: "/test")
        index.apply((0..<1000).map { .upsert(NamespaceEntry(path: "/test/folder/sub/file-\($0)", kind: .file)) })
        index.apply([.remove("/test/folder")])
        let generation = index.stats().generation
        let tombstones = index.stats().tombstones
        index.apply([.remove("/test/folder"), .remove("/test/folder/sub")])
        XCTAssertEqual(index.stats().generation, generation)
        XCTAssertEqual(index.stats().tombstones, tombstones)
        index.apply([.upsert(NamespaceEntry(path: "/test/folder/sub/fresh", kind: .file))])
        XCTAssertEqual(index.snapshotPaths(), ["/test", "/test/folder", "/test/folder/sub", "/test/folder/sub/fresh"])
        index.apply([.remove("/test/folder")])
        XCTAssertEqual(index.snapshotPaths(), ["/test"])
    }

    func testIdempotentUpsertAndRemoval() {
        let index = FileIndex(root: "/test")
        let entry = NamespaceEntry(path: "/test/a", kind: .file)
        index.apply([.upsert(entry), .upsert(entry)])
        let inserted = index.stats()
        index.apply([.upsert(entry)])
        XCTAssertEqual(index.stats().generation, inserted.generation)
        XCTAssertEqual(index.stats().totalEntries, inserted.totalEntries)
        index.apply([.remove(entry.path), .remove(entry.path), .remove("/test/missing")])
        XCTAssertEqual(index.stats().liveEntries, 1)
        XCTAssertEqual(index.stats().tombstones, 1)
        let generation = index.stats().generation
        index.apply([.remove(entry.path)])
        XCTAssertEqual(index.stats().generation, generation)
        index.apply([.upsert(entry)])
        XCTAssertEqual(index.stats().totalEntries, inserted.totalEntries)
        XCTAssertEqual(index.stats().tombstones, 0)
    }

    func testDirectoryRemovalTombstonesEntireSubtree() {
        let index = FileIndex(root: "/test")
        index.apply([
            .upsert(NamespaceEntry(path: "/test/folder/sub/file", kind: .file)),
            .upsert(NamespaceEntry(path: "/test/folderish/file", kind: .file))
        ])
        index.apply([.remove("/test/folder")])
        XCTAssertEqual(index.snapshotPaths(), ["/test", "/test/folderish", "/test/folderish/file"])
        XCTAssertEqual(index.stats().tombstones, 3)
        XCTAssertEqual(index.search("file").hits.map(\.path), ["/test/folderish/file"])
        XCTAssertTrue(index.children(of: "/test/folder").isEmpty)
    }

    func testDirectoryToFileAndBackDoNotReviveGhostChildren() {
        let index = FileIndex(root: "/test")
        index.apply([.upsert(NamespaceEntry(path: "/test/item/old", kind: .file))])
        index.apply([.upsert(NamespaceEntry(path: "/test/item", kind: .file))])
        XCTAssertNil(index.entry(at: "/test/item/old"))
        XCTAssertEqual(index.entry(at: "/test/item")?.kind, .file)
        XCTAssertEqual(index.stats().files, 1)
        index.apply([.upsert(NamespaceEntry(path: "/test/item", kind: .directory))])
        XCTAssertTrue(index.children(of: "/test/item").isEmpty)
        index.apply([.upsert(NamespaceEntry(path: "/test/item/new", kind: .file))])
        XCTAssertEqual(index.children(of: "/test/item").map(\.path), ["/test/item/new"])
        XCTAssertEqual(index.stats().liveEntries + index.stats().tombstones, index.stats().totalEntries)
    }

    func testSamePathDirectoryReplacementClearsOldDescendants() {
        let index = FileIndex(root: "/test")
        index.apply([
            .upsert(NamespaceEntry(path: "/test/folder", kind: .directory, fileID: 1)),
            .upsert(NamespaceEntry(path: "/test/folder/old", kind: .file))
        ])
        index.apply([.upsert(NamespaceEntry(path: "/test/folder", kind: .directory, fileID: 2))])
        XCTAssertNil(index.entry(at: "/test/folder/old"))
        XCTAssertEqual(index.entry(at: "/test/folder")?.fileID, 2)
    }

    func testRankingLimitAndCaseInsensitiveSubstring() {
        let index = FileIndex(root: "/test")
        index.apply([
            .upsert(NamespaceEntry(path: "/test/z/alpha", kind: .file)),
            .upsert(NamespaceEntry(path: "/test/Alphabet", kind: .file)),
            .upsert(NamespaceEntry(path: "/test/a/ALPHA", kind: .directory)),
            .upsert(NamespaceEntry(path: "/test/x-alpha-y", kind: .file))
        ])
        let result = index.search("aLpHa")
        XCTAssertEqual(result.hits.map(\.path), ["/test/a/ALPHA", "/test/z/alpha", "/test/Alphabet", "/test/x-alpha-y"])
        XCTAssertEqual(index.search("alpha", limit: 2).hits.count, 2)
        XCTAssertTrue(index.search("").hits.isEmpty)
        XCTAssertTrue(index.search("alpha", limit: 0).hits.isEmpty)
        XCTAssertGreaterThanOrEqual(result.latencyMilliseconds, 0)
        XCTAssertEqual(result.generation, index.stats().generation)
    }

    func testUnicodeCaseFoldingAndCanonicalEquivalence() {
        let index = FileIndex(root: "/test")
        index.apply([
            .upsert(NamespaceEntry(path: "/test/Caf\u{00e9}.txt", kind: .file)),
            .upsert(NamespaceEntry(path: "/test/Stra\u{00df}e.txt", kind: .file))
        ])
        XCTAssertEqual(index.search("CAFE\u{0301}").hits.count, 1)
        XCTAssertEqual(index.search("STRASSE").hits.count, 1)
        XCTAssertTrue(index.search("cafe").hits.isEmpty, "Case folding must retain accents")
    }

    func testPathsOutsideRootAndMalformedPathsAreIgnored() {
        let index = FileIndex(root: "/test")
        index.apply([
            .upsert(NamespaceEntry(path: "/test2/a", kind: .file)),
            .upsert(NamespaceEntry(path: "relative", kind: .file)),
            .upsert(NamespaceEntry(path: "/test/../outside", kind: .file)),
            .remove("/")
        ])
        XCTAssertEqual(index.snapshotPaths(), ["/test"])
        XCTAssertEqual(index.stats().generation, 0)
    }

    func testLexicalPathNormalizationAndMountMetadata() {
        let index = FileIndex(root: "/test/")
        index.apply([.upsert(NamespaceEntry(path: "/test//mount/./", kind: .directory, deviceID: 77, fileID: 99, isMountPoint: true))])
        XCTAssertEqual(index.entry(at: "/test/mount")?.isMountPoint, true)
        XCTAssertEqual(index.snapshotEntries().first(where: { $0.path == "/test/mount" })?.deviceID, 77)
        XCTAssertEqual(index.children(of: "/test/").count, 1)
    }

    func testReplacementDropsTombstonesAndPreservesGeneration() {
        let index = FileIndex(root: "/test")
        index.apply([.upsert(NamespaceEntry(path: "/test/old", kind: .file))])
        index.apply([.remove("/test/old")])
        let oldGeneration = index.stats().generation
        let replacement = FileIndex(root: "/test")
        replacement.apply([.upsert(NamespaceEntry(path: "/test/new", kind: .file))])
        index.replace(with: replacement)
        XCTAssertEqual(index.snapshotPaths(), ["/test", "/test/new"])
        XCTAssertEqual(index.stats().tombstones, 0)
        XCTAssertGreaterThan(index.stats().generation, oldGeneration)
        index.apply([.upsert(NamespaceEntry(path: "/test/after", kind: .file))])
        XCTAssertNotNil(index.entry(at: "/test/after"))
    }

    func testParallelReadersAndBatchWriterSeeCompleteBatches() {
        let index = FileIndex(root: "/test")
        let entries = (0..<100).map { NamespaceEntry(path: "/test/needle-\($0)", kind: .file) }
        let inserts = entries.map(IndexMutation.upsert)
        let deletes = entries.map { IndexMutation.remove($0.path) }
        DispatchQueue.concurrentPerform(iterations: 80) { iteration in
            if iteration.isMultiple(of: 4) {
                index.apply(inserts)
                index.apply(deletes)
            } else {
                let count = index.search("needle", limit: 200).hits.count
                XCTAssertTrue(count == 0 || count == 100, "Readers cannot see a partial mutation batch")
            }
        }
        let stats = index.stats()
        XCTAssertEqual(stats.totalEntries, stats.liveEntries + stats.tombstones)
    }
}
