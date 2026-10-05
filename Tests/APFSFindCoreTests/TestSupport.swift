import Foundation
import XCTest
@testable import APFSFindCore

final class TemporaryTree {
    let root: String
    init(cache: Bool = false) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("apfsfind-tests-" + UUID().uuidString)
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
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        if PathCanonicalizer.isWithin(root, root: temp), root != temp,
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
