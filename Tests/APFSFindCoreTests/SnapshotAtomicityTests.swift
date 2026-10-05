import Darwin
import Foundation
import XCTest
@testable import APFSFindCore

final class SnapshotAtomicityTests: XCTestCase {
    func testFailuresBeforeAndAfterRenameKeepOldValidSnapshot() throws {
        let cache = try TemporaryTree(), identity = snapshotIdentity(), index = sampleSnapshotIndex()
        let store = try SnapshotStore(directory: cache.root, identity: identity)
        _ = try SnapshotWriter.write(index: index, identity: identity, cursor: 7, store: store)
        let old = try Data(contentsOf: URL(fileURLWithPath: store.path))
        index.apply([.upsert(.init(path: identity.root + "/new", kind: .file))])
        for point in [SnapshotFailurePoint.afterHeader, .beforeFileSync, .beforeRename, .afterRename, .directorySync] {
            XCTAssertThrowsError(try SnapshotWriter.write(index: index, identity: identity, cursor: 8, store: store, fault: {
                if $0 == point { throw SnapshotError.io("injected failure", EIO) }
            }))
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: store.path)), old)
            XCTAssertEqual(try store.reader(expectedIdentity: identity).header.lastProcessedEventID, 7)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: cache.root).contains { $0.hasSuffix(".tmp") })
        }
    }

    func testGenerationChangeAbortsWithoutPublishingAndCancellationPreservesOld() throws {
        let cache = try TemporaryTree(), identity = snapshotIdentity(), index = sampleSnapshotIndex()
        let store = try SnapshotStore(directory: cache.root, identity: identity)
        _ = try SnapshotWriter.write(index: index, identity: identity, cursor: 7, store: store)
        let old = try Data(contentsOf: URL(fileURLWithPath: store.path))
        XCTAssertThrowsError(try SnapshotWriter.write(index: index, identity: identity, cursor: 8, store: store,
            fault: { if $0 == .beforeFileSync { index.apply([.upsert(.init(path: identity.root + "/changed", kind: .file))]) } }))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: store.path)), old)
        let token = CancellationToken(); token.cancel()
        XCTAssertThrowsError(try SnapshotWriter.write(index: index, identity: identity, cursor: 9, store: store, cancellation: token))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: store.path)), old)
    }

    func testStaleTempCleanupAndSymlinkRejection() throws {
        let cache = try TemporaryTree(), target = try TemporaryTree(), identity = snapshotIdentity()
        let store = try SnapshotStore(directory: cache.root, identity: identity)
        let stale = store.path + ".stale.tmp"
        try Data([1,2,3]).write(to: URL(fileURLWithPath: stale))
        _ = try SnapshotStore(directory: cache.root, identity: identity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale))
        try target.file("sentinel")
        try FileManager.default.createSymbolicLink(atPath: store.path, withDestinationPath: target.path("sentinel"))
        XCTAssertThrowsError(try store.reader(expectedIdentity: identity))
        XCTAssertThrowsError(try SnapshotWriter.write(index: sampleSnapshotIndex(), identity: identity, cursor: 1, store: store))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path("sentinel")))
        let alias = cache.path("alias")
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: target.root)
        XCTAssertThrowsError(try SnapshotStore(directory: alias, identity: identity))
        var metadata = stat(); XCTAssertEqual(lstat(target.root, &metadata), 0)
        XCTAssertNotEqual(metadata.st_mode & 0o777, 0o700)
    }

    func testConcurrentPublisherCannotDeleteAnActiveTemporary() throws {
        let cache = try TemporaryTree(), identity = snapshotIdentity(), index = sampleSnapshotIndex()
        let store = try SnapshotStore(directory: cache.root, identity: identity)
        _ = try SnapshotWriter.write(index: index, identity: identity, cursor: 7, store: store)
        _ = try SnapshotWriter.write(index: index, identity: identity, cursor: 8, store: store, fault: { point in
            if point == .beforeFileSync {
                let other = try SnapshotStore(directory: cache.root, identity: identity)
                XCTAssertThrowsError(try SnapshotWriter.write(index: index, identity: identity, cursor: 9, store: other)) {
                    guard case SnapshotError.busy = $0 else { return XCTFail("Expected busy, got \($0)") }
                }
                XCTAssertEqual(try other.reader(expectedIdentity: identity).header.lastProcessedEventID, 7)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.root).filter { $0.hasSuffix(".tmp") }.count, 1)
            }
        })
        XCTAssertEqual(try store.reader(expectedIdentity: identity).header.lastProcessedEventID, 8)
    }

    func testMidExportCancellationKeepsPreviousSnapshotAndStandardAliasesAreSafe() throws {
        let cache = try TemporaryTree(), identity = snapshotIdentity(), index = sampleSnapshotIndex()
        let store = try SnapshotStore(directory: cache.root, identity: identity)
        _ = try SnapshotWriter.write(index: index, identity: identity, cursor: 7, store: store)
        let token = CancellationToken()
        XCTAssertThrowsError(try SnapshotWriter.write(index: index, identity: identity, cursor: 8, store: store,
            cancellation: token, fault: { if $0 == .afterHeader { token.cancel() } }))
        XCTAssertEqual(try store.reader(expectedIdentity: identity).header.lastProcessedEventID, 7)
        let alias = String(cache.root.dropFirst("/private".count))
        XCTAssertEqual(try SnapshotStore(directory: alias, identity: identity).path, store.path)
        var info = stat()
        XCTAssertEqual(lstat(cache.root, &info), 0); XCTAssertEqual(info.st_mode & 0o7777, 0o700)
        XCTAssertEqual(lstat(store.path, &info), 0); XCTAssertEqual(info.st_mode & 0o7777, 0o600)
    }
}
