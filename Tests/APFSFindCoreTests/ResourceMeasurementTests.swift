import Darwin
import Foundation
import XCTest
@testable import APFSFindCore

final class ResourceMeasurementTests: XCTestCase {
    func testProcessResourceAPIAndMonotonicIO() throws {
        let before = ProcessResourceSample.capture()
        XCTAssertNil(before.apiError)
        let tree = try TemporaryTree()
        try Data(repeating: 42, count: 65536).write(to: URL(fileURLWithPath: tree.path("write")))
        let after = ProcessResourceSample.capture()
        XCTAssertGreaterThan(after.rssBytes, 0)
        XCTAssertNotNil(after.compressedBytes)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(after.peakCompressedBytes), try XCTUnwrap(after.compressedBytes))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(after.logicalBytesWritten), try XCTUnwrap(before.logicalBytesWritten))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(after.diskBytesRead), try XCTUnwrap(before.diskBytesRead))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(after.diskBytesWritten), try XCTUnwrap(before.diskBytesWritten))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(after.minorFaults), try XCTUnwrap(before.minorFaults))
    }
    func testFoldedDedupStatisticsUseActualBytesWithoutChangingV2() throws {
        let cache = try TemporaryTree(cache: true), identity = snapshotIdentity(), index = FileIndex(root: identity.root)
        let names = ["lower.txt", "UPPER.txt", "café-a", "cafe\u{301}-b"]
        index.apply(names.enumerated().map { .upsert(.init(path: identity.root + "/" + $0.element,
                                                          kind: .file, deviceID: identity.deviceID, fileID: UInt64($0.offset + 1))) })
        let store = try SnapshotStore(directory: cache.root, identity: identity)
        _ = try SnapshotV2Writer.write(source: .ram(index, index.stats().generation), identity: identity,
                                      generation: index.stats().generation, cursor: 7, store: store)
        let bytesBefore = try Data(contentsOf: URL(fileURLWithPath: store.path))
        let base = try MMapBaseIndex(path: store.path, identity: identity), s = base.layoutStatistics()
        XCTAssertEqual(s["folded_same_as_original_count"] as? Int, 2)
        XCTAssertEqual(s["folded_same_as_original_bytes"] as? Int, "lower.txt".utf8.count + "café-a".utf8.count)
        XCTAssertEqual(s["file_id_nonzero_files"] as? Int, 4)
        XCTAssertEqual(s["record_table_bytes"] as? UInt64, 200)
        XCTAssertEqual(s["child_table_bytes"] as? UInt64, 16)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: store.path)), bytesBefore)
        XCTAssertEqual(base.foldedName(at: try XCTUnwrap(base.lookupChild(parent: 0, name: "cafe\u{301}-b"))), "café-b")
    }
    func testStateOnlyCheckpointWritesFarLessThanFullSnapshot() throws {
        let cache = try TemporaryTree(cache: true), identity = snapshotIdentity(), index = FileIndex(root: identity.root)
        index.apply((0..<20000).map { .upsert(.init(path: identity.root + String(format: "/f%06d", $0), kind: .file, deviceID: identity.deviceID)) })
        let store = try SnapshotStore(directory: cache.root, identity: identity)
        let before = ProcessResourceSample.capture()
        let full = try SnapshotV2Writer.write(source: .ram(index, index.stats().generation), identity: identity,
                                              generation: index.stats().generation, cursor: 7, store: store)
        let fullAfter = ProcessResourceSample.capture()
        let stateBefore = ProcessResourceSample.capture()
        try store.writeState(header: full.header, cursor: 8, beforePublish: {})
        let stateAfter = ProcessResourceSample.capture()
        let fullWrites = try XCTUnwrap(fullAfter.logicalBytesWritten) - XCTUnwrap(before.logicalBytesWritten)
        let stateWrites = try XCTUnwrap(stateAfter.logicalBytesWritten) - XCTUnwrap(stateBefore.logicalBytesWritten)
        XCTAssertGreaterThan(fullWrites, 100000)
        XCTAssertLessThan(stateWrites, fullWrites / 10)
        XCTAssertEqual(try store.reader(expectedIdentity: identity).header.fileLength, full.header.fileLength)
    }
}
