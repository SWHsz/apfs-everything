import CoreServices
import Darwin
import Foundation
import XCTest

@testable import APFSFindCore

final class HybridIndexTests: XCTestCase {
  private func base(_ cache: TemporaryTree, index: FileIndex? = nil) throws -> MMapBaseIndex {
    let v = snapshotIdentity()
    let i = index ?? sampleSnapshotIndex()
    let s = try SnapshotStore(directory: cache.root, identity: v)
    _ = try SnapshotV2Writer.write(
      source: .ram(i, i.stats().generation), identity: v, generation: i.stats().generation,
      cursor: 7, store: s)
    return try XCTUnwrap(s.reader(expectedIdentity: v).mappedBase)
  }
  func testV2TreeLookupFoldAndPayloadDeterminism() throws {
    let c = try TemporaryTree(cache: true)
    let v = snapshotIdentity()
    let i = FileIndex(root: v.root)
    i.apply([
      .upsert(.init(path: v.root + "/a-/x", kind: .file)),
      .upsert(.init(path: v.root + "/a/x", kind: .file)),
      .upsert(.init(path: v.root + "/Z", kind: .file)),
      .upsert(.init(path:v.root+"/e\u{301}-name",kind:.file)),.upsert(.init(path:v.root+"/f-name",kind:.file)),
      .upsert(.init(path: v.root + "/ä", kind: .symlink)),
    ])
    let b = try base(c, index: i)
    let h = HybridIndex(base: b)
    XCTAssertEqual(b.header.recordCount, UInt64(i.stats().liveEntries))
    XCTAssertEqual(b.directChildren(of: 0).count, 6)
    XCTAssertEqual(b.subtreeRange(of: 0), 0..<UInt32(b.count))
    for e in i.snapshotEntries() { XCTAssertEqual(h.entry(at: e.path)?.kind, e.kind) }
    XCTAssertEqual(h.search("X").hits, i.search("X").hits)
    XCTAssertEqual(h.search("ä").hits, i.search("ä").hits)
    XCTAssertEqual(h.search("-name").hits,i.search("-name").hits)
    XCTAssertEqual(h.hybridStats()["materialized_file_entries"] as? Int, 0)
    XCTAssertEqual(h.hybridStats()["directory_map_entries"] as? Int, 3)
    let old = try Data(
      contentsOf: URL(fileURLWithPath: try SnapshotStore(directory: c.root, identity: v).path))
    let j = FileIndex(root: v.root)
    j.apply(i.snapshotEntries().reversed().map { .upsert($0) })
    _ = try base(c, index: j)
    let new = try Data(
      contentsOf: URL(fileURLWithPath: try SnapshotStore(directory: c.root, identity: v).path))
    XCTAssertEqual(old.dropFirst(256), new.dropFirst(256))
  }
  func testOverlayDeleteSubtreeRecreateAndRanking() throws {
    let cache = try TemporaryTree(cache: true)
    let v = snapshotIdentity()
    let b = try base(cache)
    let h = HybridIndex(base: b)
    h.apply([.remove(v.root + "/dir")])
    XCTAssertTrue(h.children(of: v.root + "/dir").isEmpty)
    XCTAssertFalse(h.snapshotPaths().contains { $0.hasPrefix(v.root + "/dir/") })
    h.apply([
      .upsert(.init(path: v.root + "/dir", kind: .directory, deviceID: v.deviceID)),
      .upsert(.init(path: v.root + "/dir/NEW.txt", kind: .file, deviceID: v.deviceID)),
      .upsert(.init(path: v.root + "/new", kind: .file, deviceID: v.deviceID)),
    ])
    XCTAssertEqual(h.search("new").hits.first?.path, v.root + "/new")
    XCTAssertEqual(h.search("txt").hits.filter { $0.path == v.root + "/dir/NEW.txt" }.count, 1)
    h.apply([.remove(v.root + "/dir")])
    XCTAssertNil(h.entry(at: v.root + "/dir/NEW.txt"))
    XCTAssertEqual(h.hybridStats()["overlay_deleted_entries"] as? Int, 0)
  }
  func testCaptureSurvivesBaseSwapAndConcurrentQueryDoesNotHoldWriter() throws {
    let c = try TemporaryTree(cache: true)
    let v = snapshotIdentity()
    let i = FileIndex(root: v.root)
    i.apply(
      (0..<10_000).map {
        .upsert(
          .init(path: v.root + String(format: "/file%06d", $0), kind: .file, deviceID: v.deviceID))
      })
    let b = try base(c, index: i)
    let h = HybridIndex(base: b)
    let capture = try XCTUnwrap(h.capture())
    let done = DispatchGroup()
    done.enter()
    DispatchQueue.global().async {
      _ = h.search("f", limit: 50)
      done.leave()
    }
    let start = ProcessInfo.processInfo.systemUptime
    h.apply([.upsert(.init(path: v.root + "/visible", kind: .file, deviceID: v.deviceID))])
    XCTAssertLessThan((ProcessInfo.processInfo.systemUptime - start) * 1000, 100)
    let store = try SnapshotStore(directory: c.root, identity: v)
    let saved = try XCTUnwrap(h.capture())
    _ = try SnapshotV2Writer.write(
      source: .hybrid(saved), identity: v, generation: saved.generation, cursor: 8, store: store,
      install: { new, map, publish in
        try publish()
        h.install(base: new, directoryMap: map)
      })
    XCTAssertEqual(capture.base.count, 10_001)
    XCTAssertEqual(capture.base.reconstructPath(1), v.root + "/file000000")
    XCTAssertNotNil(h.entry(at: v.root + "/visible"))
    XCTAssertEqual(h.hybridStats()["overlay_live_entries"] as? Int, 0)
    XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
  }
  func testV2CorruptSectionsAndTreeStructureRejectedWithRepairedCRC() throws {
    let cache = try TemporaryTree(cache: true)
    let v = snapshotIdentity()
    let b = try base(cache)
    let store = try SnapshotStore(directory: cache.root, identity: v)
    let good = try Data(contentsOf: URL(fileURLWithPath: store.path))
    let table = Int(b.header.recordTableOffset)
    func u64(_ d: Data, _ o: Int) -> Int {
      d.withUnsafeBytes {
        Int(UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt64.self)))
      }
    }
    func repair(_ d: inout Data) {
      d.put(SnapshotFormat.crc(Data(d[256..<(d.count - 16)])), at: d.count - 8)
      d.put(SnapshotFormat.crc(Data(d[256...])), at: 144)
      d.put(UInt32(0), at: 148)
      d.put(SnapshotFormat.crc(Data(d.prefix(256))), at: 148)
    }
    var cases: [Data] = []
    for offset in [32, 40, 48, 56, 64, 72, 192, 200, 208, 216] {
      var d = good
      d.put(UInt64.max, at: offset)
      repair(&d)
      cases.append(d)
    }
    for (o, value) in [
      (table + 12, UInt32(1)), (table + 40, UInt32.max), (table + 40 + 12, UInt32.max),
      (table + 4, UInt32.max), (table + 8, UInt32.max),
    ] {
      var d = good
      d.put(value, at: o)
      repair(&d)
      cases.append(d)
    }
    var d = good
    d[table + 30] = 1
    repair(&d)
    cases.append(d)
    d = good
    let folded = u64(d, 192)
    d[folded] = 0xff
    repair(&d)
    cases.append(d)
    d = good
    let child = u64(d, 208)
    d.put(UInt32(0), at: child)
    repair(&d)
    cases.append(d)
    d = good
    d[224] = 1
    repair(&d)
    cases.append(d)
    for data in cases {
      try data.write(to: URL(fileURLWithPath: store.path))
      XCTAssertThrowsError(try store.reader(expectedIdentity: v))
    }
    XCTAssertEqual(b.count, Int(b.header.recordCount), "old mapping survives replacement of path")
  }
}
