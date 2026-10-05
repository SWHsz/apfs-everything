import Darwin
import Foundation
import XCTest
@testable import APFSFindCore

final class SnapshotRoundTripTests: XCTestCase {
    func testMinimalRootAndOneFileRoundTrip() throws {
        let cache = try TemporaryTree(cache: true), identity = snapshotIdentity()
        let store = try SnapshotStore(directory: cache.root, identity: identity)
        let index = FileIndex(root: identity.root)
        for withFile in [false, true] {
            if withFile { index.apply([.upsert(.init(path: identity.root + "/one", kind: .file))]) }
            let result = try SnapshotWriter.write(index: index, identity: identity, cursor: 17, store: store)
            let reader = try store.reader(expectedIdentity: identity)
            let restored = try FileIndex.restore(from: reader)
            XCTAssertEqual(restored.snapshotPaths(), index.snapshotPaths())
            XCTAssertEqual(result.header.recordCount, withFile ? 2 : 1)
            XCTAssertEqual(reader.header.lastProcessedEventID, 17)
            XCTAssertEqual(reader.header.indexGeneration, index.stats().generation)
        }
        var info = stat()
        XCTAssertEqual(lstat(store.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o7777, 0o600)
        XCTAssertEqual(lstat(cache.root, &info), 0)
        XCTAssertEqual(info.st_mode & 0o7777, 0o700)
    }

    func testDeepUnicodeSymlinkUnknownIDCompactionAndNoTombstones() throws {
        let cache = try TemporaryTree(cache: true), identity = snapshotIdentity(), index = sampleSnapshotIndex()
        let store = try SnapshotStore(directory: cache.root, identity: identity)
        _ = try SnapshotWriter.write(index: index, identity: identity, cursor: 100, store: store)
        let reader = try store.reader(expectedIdentity: identity)
        let restored = try FileIndex.restore(from: reader)
        XCTAssertEqual(restored.snapshotPaths(), index.snapshotPaths())
        XCTAssertEqual(restored.stats().tombstones, 0)
        XCTAssertEqual(reader.header.recordCount, UInt64(index.stats().liveEntries))
        XCTAssertLessThan(reader.header.recordCount, UInt64(index.stats().totalEntries))
        XCTAssertEqual(restored.entry(at: identity.root + "/link")?.kind, .symlink)
        XCTAssertEqual(restored.entry(at: identity.root + "/link")?.fileID, 42)
        XCTAssertNil(restored.entry(at: identity.root + "/dir/deep/Cafe\u{301}-b")?.fileID)
        for ordinal in 1..<Int(reader.header.recordCount) {
            XCTAssertLessThan(reader.record(at: ordinal).parentID, UInt32(ordinal))
            XCTAssertFalse(reader.name(at: ordinal).contains("/"))
        }
        XCTAssertEqual(restored.search("CAFÉ").hits.map(\.path), index.search("CAFÉ").hits.map(\.path))
        let names = (1..<Int(reader.header.recordCount)).map { Array(reader.name(at: $0).utf8) }
        XCTAssertTrue(names.contains(Array("Cafe\u{301}-b".utf8)))
    }

    func testSameLogicalContentHasDeterministicPayloadDespiteInsertionOrder() throws {
        let cache = try TemporaryTree(cache: true), identity = snapshotIdentity()
        let store = try SnapshotStore(directory: cache.root, identity: identity)
        let items: [NamespaceEntry] = [
            .init(path: identity.root + "/z/file", kind: .file),
            .init(path: identity.root + "/a-/file", kind: .file),
            .init(path: identity.root + "/a/deep/file", kind: .file)
        ]
        let first = FileIndex(root: identity.root), second = FileIndex(root: identity.root)
        first.apply(items.map { .upsert($0) }); second.apply(items.reversed().map { .upsert($0) })
        _ = try SnapshotWriter.write(index: first, identity: identity, cursor: 1, store: store)
        let payload = try Data(contentsOf: URL(fileURLWithPath: store.path)).dropFirst(SnapshotFormat.headerSize)
        _ = try SnapshotWriter.write(index: second, identity: identity, cursor: 2, store: store)
        XCTAssertEqual(payload, try Data(contentsOf: URL(fileURLWithPath: store.path)).dropFirst(SnapshotFormat.headerSize))
    }

    func testHundredThousandSyntheticEntriesStayUnder64BytesPerEntry() throws {
        let cache = try TemporaryTree(cache: true), identity = snapshotIdentity(), index = FileIndex(root: "/snapshot-fixture")
        var batch: [IndexMutation] = []
        for ordinal in 0..<99_899 {
            batch.append(.upsert(.init(path: identity.root + String(format: "/d%03d/f%05d", ordinal % 100, ordinal), kind: .file)))
            if batch.count == 4096 { index.apply(batch); batch.removeAll(keepingCapacity: true) }
        }
        index.apply(batch)
        XCTAssertEqual(index.stats().liveEntries, 100_000)
        let store = try SnapshotStore(directory: cache.root, identity: identity)
        let result = try SnapshotWriter.write(index: index, identity: identity, cursor: 1, store: store)
        XCTAssertLessThanOrEqual(result.bytesPerEntry, 64)
        let restored = try FileIndex.restore(from: store.reader(expectedIdentity: identity))
        XCTAssertEqual(restored.snapshotPaths(), index.snapshotPaths())
        print("[synthetic] records=100000 bytes=\(result.header.fileLength) bytes_per_entry=\(result.bytesPerEntry)")
    }
}
