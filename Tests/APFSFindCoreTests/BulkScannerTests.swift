import APFSFindCore
import CAPFSShim
import Darwin
import Foundation
import XCTest

final class BulkScannerTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("apfsfind-scanner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        // Foundation's temporaryDirectory resolver can retain /var; the scanner
        // deliberately uses realpath's /private/var spelling for event agreement.
        return URL(fileURLWithPath: try PathCanonicalizer.canonicalRoot(root.path), isDirectory: true)
    }

    func testInitialBulkScanIncludesSeedAndMetadata() throws {
        let root = try temporaryRoot()
        let child = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        let seed = child.appendingPathComponent("Seed.txt")
        try Data().write(to: seed)
        let result = try BulkScanner(root: root.path).scan()
        XCTAssertFalse(result.cancelled)
        XCTAssertEqual(result.unreadableDirectories, 0)
        XCTAssertEqual(Set(result.entries.map(\.path)), Set([root.path, child.path, seed.path]))
        let file = try XCTUnwrap(result.entries.first { $0.path == seed.path })
        XCTAssertEqual(file.kind, .file)
        XCTAssertEqual(file.deviceID, result.rootDeviceID)
        XCTAssertNotNil(file.fileID)
        XCTAssertGreaterThanOrEqual(result.elapsedMilliseconds, 0)
    }

    func testBulkBufferSpansSeveralPagesAndUnicodeNames() throws {
        let root = try temporaryRoot()
        for number in 0..<1500 {
            try Data().write(to: root.appendingPathComponent("长文件名-é-\(number).txt"))
        }
        let result = try BulkScanner(root: root.path, workerCount: 2).scan()
        XCTAssertEqual(result.entries.count, 1501)
        XCTAssertEqual(Set(result.entries.map(\.path)).count, 1501)
        XCTAssertTrue(result.entries.contains { $0.path.hasSuffix("长文件名-é-1499.txt") })
    }

    func testSymlinkDirectoryIsIndexedButNotEntered() throws {
        let root = try temporaryRoot()
        let outside = try temporaryRoot()
        try Data().write(to: outside.appendingPathComponent("private-seed.txt"))
        let link = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let result = try BulkScanner(root: root.path).scan()
        XCTAssertEqual(result.entries.count, 2)
        XCTAssertEqual(result.entries.first { $0.path == link.path }?.kind, .symlink)
        XCTAssertFalse(result.entries.contains { $0.path.contains("private-seed") })
    }

    func testReadDirectoryRejectsSymlinkIntermediateComponent() throws {
        let root = try temporaryRoot()
        let outside = try temporaryRoot()
        let directory = outside.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data().write(to: directory.appendingPathComponent("private-seed.txt"))
        let link = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let scanner = BulkScanner(root: root.path)
        let device = try scanner.rootDeviceID()
        XCTAssertThrowsError(try scanner.readDirectory(link.appendingPathComponent("child").path,
                                                      rootDeviceID: device))
        XCTAssertNil(BulkScanner.directoryStamp(link.appendingPathComponent("child").path))
    }

    func testDeviceAndMountBoundaryGate() {
        XCTAssertTrue(BulkScanner.shouldTraverse(deviceID: 42, rootDeviceID: 42))
        XCTAssertFalse(BulkScanner.shouldTraverse(deviceID: 43, rootDeviceID: 42))
        XCTAssertFalse(BulkScanner.shouldTraverse(
            entry: NamespaceEntry(path: "/mount", kind: .directory, deviceID: 42, isMountPoint: true), rootDeviceID: 42))
        XCTAssertFalse(BulkScanner.shouldTraverse(
            entry: NamespaceEntry(path: "/link", kind: .symlink, deviceID: 42), rootDeviceID: 42))
    }

    func testReadDirectoryRejectsWrongDevice() throws {
        let root = try temporaryRoot()
        let scanner = BulkScanner(root: root.path)
        let device = try scanner.rootDeviceID()
        XCTAssertThrowsError(try scanner.readDirectory(root.path, rootDeviceID: device ^ 1)) { error in
            XCTAssertEqual((error as? ScannerError)?.code, EXDEV)
        }
    }

    func testNamespaceListingRetainsOnlyPagedMetadataAndAllNamespaces() throws {
        let root = try temporaryRoot()
        for i in 0..<2048 { try Data().write(to: root.appendingPathComponent("entry-\(i)")) }
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: nested)
        let metrics = Metrics(), scanner = BulkScanner(root: root.path, metrics: metrics)
        let device = try scanner.rootDeviceID()
        let listing = try scanner.readDirectory(root.path, rootDeviceID: device, cancellation: CancellationToken())
        let oracle = try BulkScanner(root: root.path).readScannedDirectory(root.path, rootDeviceID: device)
        XCTAssertEqual(Set(listing.map(\.path)), Set(oracle.map(\.namespace.path)))
        XCTAssertEqual(listing.count, 2050)
        let byPath = Dictionary(uniqueKeysWithValues: oracle.map { ($0.namespace.path, $0.namespace) })
        for entry in listing { XCTAssertEqual(entry, byPath[entry.path]) }
        XCTAssertEqual(metrics.snapshot()["scanner_scanned_collected_entries_max"], 0)
        XCTAssertGreaterThan(metrics.snapshot()["scanner_scanned_page_entries_max"] ?? 0, 0)
        XCTAssertLessThan(metrics.snapshot()["scanner_scanned_page_entries_max"] ?? 2050, 2050)
        XCTAssertThrowsError(try scanner.readScannedDirectory(root.path, rootDeviceID: device,
            collectEntries: false, maximumEntries: 8, collectDirectories: false)) {
            XCTAssertEqual(($0 as? ScannerError)?.code, EOVERFLOW)
        }
        let cancelled = CancellationToken(); cancelled.cancel()
        XCTAssertThrowsError(try scanner.readDirectory(root.path, rootDeviceID: device, cancellation: cancelled)) {
            XCTAssertEqual(($0 as? ScannerError)?.code, ECANCELED)
        }
    }

    func testPreCancelledScanDoesNotEnumerateDescendants() throws {
        let root = try temporaryRoot()
        try Data().write(to: root.appendingPathComponent("seed.txt"))
        let token = CancellationToken()
        token.cancel()
        let result = try BulkScanner(root: root.path).scan(cancellation: token)
        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.entries.map(\.path), [root.path])
    }

    func testMissingRootIsFatal() throws {
        let root = try temporaryRoot()
        XCTAssertThrowsError(try BulkScanner(root: root.appendingPathComponent("missing").path).scan())
    }

    func testUnreadableChildIsCountedAndScanContinues() throws {
        guard geteuid() != 0 else { throw XCTSkip("Permission test requires an unprivileged user") }
        let root = try temporaryRoot()
        let blocked = root.appendingPathComponent("blocked", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        try Data().write(to: blocked.appendingPathComponent("hidden.txt"))
        XCTAssertEqual(chmod(blocked.path, 0), 0)
        defer { XCTAssertEqual(chmod(blocked.path, 0o700), 0) }
        let result = try BulkScanner(root: root.path).scan()
        XCTAssertEqual(result.unreadableDirectories, 1)
        XCTAssertTrue(result.entries.contains { $0.path == blocked.path })
        XCTAssertFalse(result.entries.contains { $0.path.hasSuffix("hidden.txt") })
    }
}
