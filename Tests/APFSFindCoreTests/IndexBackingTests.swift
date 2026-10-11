import Darwin
import Foundation
import XCTest
@testable import APFSFindCore

final class IndexBackingTests: XCTestCase {
  func testPReadCrossBlockRangesAndBoundedCache() throws {
    let tree = try TemporaryTree(), path = tree.path("index")
    let bytes = Data((0..<2_000_000).map { UInt8($0 % 251) })
    try bytes.write(to: URL(fileURLWithPath: path)); XCTAssertEqual(chmod(path, 0o600), 0)
    let backing = try PReadBacking(fileDescriptor: open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW), maximumCacheBytes: 128*1024)
    for offset in stride(from: 55_000, to: 1_800_000, by: 61_000) {
      XCTAssertEqual(try backing.read(offset: offset, count: 100_000), bytes.subdata(in: offset..<(offset+100_000)))
      XCTAssertLessThanOrEqual(backing.cachedBytes, 128*1024)
    }
    backing.reclaimPages(); XCTAssertEqual(backing.cachedBytes, 0)
    XCTAssertThrowsError(try backing.read(offset: -1, count: 1))
    XCTAssertThrowsError(try backing.read(offset: 0, count: 1_048_577))
    XCTAssertThrowsError(try backing.read(offset: backing.length, count: 1))
  }
  func testCancellationCloseAndReturnedBytesSurviveRelease() throws {
    let tree = try TemporaryTree(), path = tree.path("index")
    try Data(repeating: 42, count: 70_000).write(to: URL(fileURLWithPath: path)); XCTAssertEqual(chmod(path, 0o600), 0)
    let backing = try PReadBacking(fileDescriptor: open(path, O_RDONLY | O_NOFOLLOW))
    let retained = try backing.read(offset: 10, count: 100)
    let token = SearchCancellationToken(); token.cancel()
    XCTAssertThrowsError(try backing.read(offset: 0, count: 10, cancellation: token)) {
      XCTAssertEqual($0 as? IndexBackingError, .cancelled)
    }
    backing.close(); backing.close()
    XCTAssertEqual(retained, Data(repeating: 42, count: 100))
    XCTAssertThrowsError(try backing.read(offset: 0, count: 1)) { XCTAssertEqual($0 as? IndexBackingError, .closed) }
  }
  func testShortReadIsStructuredIOErrorNotMappedFault() throws {
    let tree = try TemporaryTree(), path = tree.path("index")
    try Data(repeating: 42, count: 70_000).write(to: URL(fileURLWithPath: path)); XCTAssertEqual(chmod(path, 0o600), 0)
    let backing = try PReadBacking(fileDescriptor: open(path, O_RDONLY | O_NOFOLLOW), maximumCacheBytes: 0)
    XCTAssertEqual(truncate(path, 0), 0)
    XCTAssertThrowsError(try backing.read(offset: 0, count: 10)) { XCTAssertEqual($0 as? IndexBackingError, .storageIO(EIO)) }
    XCTAssertEqual(backing.cachedBytes, 0)
  }
  func testCachedPagesStillValidateStorageIdentity() throws {
    final class Availability: @unchecked Sendable {
      let lock = NSLock(); var offline = false
      func check() throws { try lock.withLock { if offline { throw IndexBackingError.storageIO(ENXIO) } } }
    }
    let tree = try TemporaryTree(), path = tree.path("index"), availability = Availability()
    try Data(repeating: 42, count: 70_000).write(to: URL(fileURLWithPath: path)); XCTAssertEqual(chmod(path, 0o600), 0)
    let backing = try PReadBacking(fileDescriptor: open(path, O_RDONLY | O_NOFOLLOW), validateStorage: { try availability.check() })
    _ = try backing.read(offset: 0, count: 10)
    availability.lock.withLock { availability.offline = true }
    XCTAssertThrowsError(try backing.read(offset: 0, count: 10)) { XCTAssertEqual($0 as? IndexBackingError, .storageIO(ENXIO)) }
  }
}
