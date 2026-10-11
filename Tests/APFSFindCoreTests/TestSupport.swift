import CAPFSShim
import Darwin
import Foundation
import XCTest
@testable import APFSFindCore

final class TemporaryTree {
    let root: String
    private let cleanupRoot: String
    init(cache: Bool = false, temporaryDirectory: String? = nil) throws {
        // Foundation on macOS can ignore TMPDIR. Use an explicit test-only
        // override so synthetic fixtures can stay inside an excluded cache.
        if let supplied = temporaryDirectory ?? ProcessInfo.processInfo.environment["APFSFIND_TEST_TEMP_ROOT"] {
            let normalized = try SnapshotStore.normalizedDirectory(supplied)
            let fd = apfs_open_cache_directory(normalized, 0)
            guard fd >= 0 else { throw SnapshotError.unsafePath("test temporary root must exist, be owned 0700, and contain no symlink components") }
            close(fd)
            cleanupRoot = normalized
        } else {
            cleanupRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        }
        let url = URL(fileURLWithPath: cleanupRoot).appendingPathComponent("apfsfind-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
            attributes: cache ? [.posixPermissions: 0o700] : nil)
        root = try PathCanonicalizer.canonicalRoot(url.path)
    }
    func path(_ relative: String) -> String { root + "/" + relative }
    func directory(_ relative: String) throws {
        try FileManager.default.createDirectory(atPath: path(relative), withIntermediateDirectories: true)
    }
    func file(_ relative: String) throws { try Data().write(to: URL(fileURLWithPath: path(relative))) }
    deinit {
        if PathCanonicalizer.isWithin(root, root: cleanupRoot), root != cleanupRoot,
           URL(fileURLWithPath: root).lastPathComponent.hasPrefix("apfsfind-tests-") {
            try? FileManager.default.removeItem(atPath: root)
        }
    }
}

func waitFor(_ message: String, timeout: TimeInterval = 2, file: StaticString = #filePath,
             line: UInt = #line, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
    XCTAssertTrue(condition(), message, file: file, line: line)
}

func requireFSEvents() throws {
    if ProcessInfo.processInfo.environment["APFSFIND_SKIP_FSEVENTS_TESTS"] == "1" {
        throw XCTSkip("APFSFIND_SKIP_FSEVENTS_TESTS=1")
    }
}
