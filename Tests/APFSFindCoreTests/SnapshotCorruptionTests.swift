import Darwin
import Foundation
import XCTest
@testable import APFSFindCore

final class SnapshotCorruptionTests: XCTestCase {
    func testMalformedSnapshotsAreRejectedWithoutUnsafeReads() throws {
        let cache = try TemporaryTree(), identity = snapshotIdentity()
        let store = try SnapshotStore(directory: cache.root, identity: identity)
        _ = try SnapshotWriter.write(index: sampleSnapshotIndex(), identity: identity, cursor: 7, store: store)
        let valid = try Data(contentsOf: URL(fileURLWithPath: store.path))
        let reader = try store.reader(expectedIdentity: identity)
        var variants: [(String, Data)] = []
        var bytes = valid; bytes[0] ^= 1; variants.append(("magic", bytes))
        bytes = valid; bytes.put(UInt32(99), at: 8); variants.append(("version", repairedChecksums(bytes)))
        variants.append(("truncated header", Data(valid.prefix(191))))
        variants.append(("truncated records", Data(valid.prefix(Int(reader.header.nameBlobOffset) - 1))))
        variants.append(("truncated blob", Data(valid.dropLast())))
        for offset in [32,40,48,56,64,72] {
            bytes = valid; bytes.put(UInt64.max, at: offset)
            variants.append(("overflow at \(offset)", repairedChecksums(bytes)))
        }
        bytes = valid; bytes.put(UInt64.max, at: 24); variants.append(("malicious count", repairedChecksums(bytes)))
        for offset in [88,96] {
            bytes = valid; bytes.put(UInt64.max, at: offset)
            variants.append(("generation/cursor sentinel", repairedChecksums(bytes)))
        }
        let second = Int(reader.header.recordTableOffset) + SnapshotFormat.recordSize
        for parent: UInt32 in [UInt32.max, 1, UInt32(reader.header.recordCount)] {
            bytes = valid; bytes.put(parent, at: second)
            variants.append(("bad/future parent \(parent)", repairedChecksums(bytes, payload: true)))
        }
        for illegal: UInt8 in [0,47,255] {
            bytes = valid; bytes[Int(reader.header.nameBlobOffset)] = illegal
            variants.append(("basename byte \(illegal)", repairedChecksums(bytes, payload: true)))
        }
        bytes = valid; bytes[148] ^= 1; variants.append(("header CRC", bytes))
        bytes = valid; bytes[bytes.count - 1] ^= 1; variants.append(("payload CRC", bytes))
        bytes = valid; bytes.put(UInt16.max, at: second + 8); variants.append(("name length", repairedChecksums(bytes, payload: true)))
        bytes = valid; bytes[second + 10] = 99; variants.append(("kind", repairedChecksums(bytes, payload: true)))
        bytes = valid; bytes[second + 11] = 128; variants.append(("flags", repairedChecksums(bytes, payload: true)))
        for (label, malformed) in variants {
            try malformed.write(to: URL(fileURLWithPath: store.path))
            XCTAssertThrowsError(try store.reader(expectedIdentity: identity), label)
        }
    }

    func testAllIdentityMismatchesAreRejected() throws {
        let cache = try TemporaryTree(), identity = snapshotIdentity()
        let store = try SnapshotStore(directory: cache.root, identity: identity)
        _ = try SnapshotWriter.write(index: sampleSnapshotIndex(), identity: identity, cursor: 1, store: store)
        for wrong in [snapshotIdentity(root: "/another-root"), snapshotIdentity(device: 10),
                      snapshotIdentity(volume: UUID()), snapshotIdentity(history: UUID())] {
            XCTAssertThrowsError(try store.reader(expectedIdentity: wrong))
        }
    }

    func testUnsafeFinalTypeAndModeAreRejected() throws {
        let cache = try TemporaryTree(), identity = snapshotIdentity()
        let store = try SnapshotStore(directory: cache.root, identity: identity)
        _ = try SnapshotWriter.write(index: sampleSnapshotIndex(), identity: identity, cursor: 1, store: store)
        XCTAssertEqual(chmod(store.path, 0o644), 0)
        XCTAssertThrowsError(try store.reader(expectedIdentity: identity))
        XCTAssertThrowsError(try SnapshotWriter.write(index: sampleSnapshotIndex(), identity: identity, cursor: 1, store: store))
        try FileManager.default.removeItem(atPath: store.path)
        try FileManager.default.createDirectory(atPath: store.path, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.reader(expectedIdentity: identity))
    }
}
