import CoreServices
import Darwin
import Foundation
import XCTest

@testable import APFSFindCore

final class HybridRecoveryTests: XCTestCase {
  private func seed(_ tree: TemporaryTree, _ cache: TemporaryTree) throws -> (
    SnapshotStore, VolumeIdentity
  ) {
    let p = try PersistentIndexCoordinator(root: tree.root, cacheDirectory: cache.root, maintenanceScheduler: .init())
    defer { p.stop(saveCheckpoint: false) }
    try p.start()
    XCTAssertTrue(p.waitUntilLive())
    XCTAssertTrue(p.waitForCheckpoint())
    let v = try VolumeIdentity.discover(root: tree.root)
    return (try SnapshotStore(directory: cache.root, identity: v), v)
  }
  private func core(_ store: SnapshotStore, _ v: VolumeIdentity, capacity: Int = 100000) throws
    -> UpdateCoordinator
  {
    let b = try XCTUnwrap(store.reader(expectedIdentity: v).mappedBase)
    let h = HybridIndex(base: b)
    let c = try UpdateCoordinator(
      root: v.root, configuration: .init(maxPendingEvents: capacity), index: h, maintenanceScheduler: .init())
    try c.start(restored: h, cursor: store.effectiveCursor(for: b.header).cursor, identity: v)
    XCTAssertTrue(c.waitUntilLive())
    XCTAssertTrue(c.flushEvents())
    return c
  }
  func testV1MigrationUsesOneFullScanAndNextStartupMapsV2() throws {
    try requireFSEvents()
    let tree = try TemporaryTree()
    let cache = try TemporaryTree(cache: true)
    try tree.file("old")
    let v = try VolumeIdentity.discover(root: tree.root)
    let s = try SnapshotStore(directory: cache.root, identity: v)
    let i = FileIndex(root: tree.root)
    i.apply([.upsert(.init(path: tree.path("old"), kind: .file, deviceID: v.deviceID))])
    _ = try SnapshotWriter.write(index: i, identity: v, cursor: v.currentEventID(), store: s)
    let p = try PersistentIndexCoordinator(root: tree.root, cacheDirectory: cache.root, maintenanceScheduler: .init())
    try p.start()
    XCTAssertTrue(p.waitUntilLive())
    XCTAssertTrue(p.waitForCheckpoint())
    XCTAssertEqual(p.stats().dictionary["startup_mode"] as? String, "format_migration_rebuild")
    XCTAssertEqual(p.metrics.snapshot()["full_scans"], 1)
    XCTAssertEqual(p.stats().dictionary["materialized_file_entries"] as? Int, 0)
    p.stop()
    let next = try PersistentIndexCoordinator(root: tree.root, cacheDirectory: cache.root, maintenanceScheduler: .init())
    defer { next.stop(saveCheckpoint: false) }
    try next.start()
    XCTAssertTrue(next.waitUntilLive())
    XCTAssertEqual(next.metrics.snapshot()["full_scans", default: 0], 0)
    XCTAssertEqual(try s.reader(expectedIdentity: v).formatVersion, 2)
    XCTAssertTrue(try next.verify().isConsistent)
  }
  func testStaleHintsAreAuthoritativeAndPureContentDoesNoMetadataWork() throws {
    try requireFSEvents()
    let tree = try TemporaryTree()
    let cache = try TemporaryTree(cache: true)
    try tree.file("kept")
    let (s, v) = try seed(tree, cache)
    let c = try core(s, v)
    defer { c.stop() }
    let before = c.index.stats().generation
    let lookups = c.metrics.snapshot()["namespace_metadata_lookups", default: 0]
    c.enqueue([
      .init(
        path: tree.path("kept"),
        flags: UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile))
    ])
    XCTAssertTrue(c.flushEvents())
    XCTAssertEqual(c.index.stats().generation, before)
    XCTAssertEqual(c.metrics.snapshot()["namespace_metadata_lookups", default: 0], lookups)
    c.enqueue([
      .init(
        path: tree.path("ghost"),
        flags: UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)),
      .init(
        path: tree.path("kept"),
        flags: UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile)),
    ])
    XCTAssertTrue(c.flushEvents())
    XCTAssertNil(c.index.entry(at: tree.path("ghost")))
    XCTAssertNotNil(c.index.entry(at: tree.path("kept")))
    XCTAssertTrue(try c.verify().isConsistent)
  }
  func testCompactionReplaysBufferedNamespaceAndKeepsDurableFenceBehindDelta() throws {
    try requireFSEvents()
    let tree = try TemporaryTree()
    let cache = try TemporaryTree(cache: true)
    try tree.file("seed")
    let (s, v) = try seed(tree, cache)
    let c = try core(s, v)
    defer { c.stop() }
    let ticket = try c.beginCompaction()
    try tree.file("during")
    c.enqueue([
      .init(
        path: tree.path("during"),
        flags: UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile),
        id: ticket.checkpoint.cursor + 1)
    ])
    XCTAssertTrue(c.flushEvents())
    XCTAssertNotNil(c.index.entry(at: tree.path("during")))
    let saved = try SnapshotV2Writer.write(
      source: .hybrid(ticket.snapshot), identity: v, generation: ticket.snapshot.generation,
      cursor: ticket.checkpoint.cursor, store: s,
      install: { b, map, publish in
        try c.finishCompaction(ticket, base: b, directories: map, publish: publish)
      })
    XCTAssertNotNil(c.index.entry(at: tree.path("during")))
    XCTAssertTrue(try c.verify().isConsistent)
    XCTAssertEqual(saved.header.lastProcessedEventID, ticket.checkpoint.cursor)
    let capture = try c.captureCheckpoint()
    XCTAssertGreaterThan(capture.metadata.generation, saved.header.indexGeneration)
    XCTAssertThrowsError(
      try s.writeState(
        header: saved.header, cursor: capture.cursor,
        beforePublish: {
          guard capture.metadata.generation == saved.header.indexGeneration else {
            throw SnapshotError.generationChanged
          }
        }))
    XCTAssertEqual(s.effectiveCursor(for: saved.header).cursor, ticket.checkpoint.cursor)
  }
  func testCompactionOverflowAndInvalidationAbortWithoutReplacingFinal() throws {
    try requireFSEvents()
    for invalidate in [false, true] {
      let tree = try TemporaryTree()
      let cache = try TemporaryTree(cache: true)
      try tree.file("seed")
      let (s, v) = try seed(tree, cache)
      let c = try core(s, v, capacity: 8)
      defer { c.stop() }
      let bytes = try Data(contentsOf: URL(fileURLWithPath: s.path))
      let ticket = try c.beginCompaction()
      if invalidate {
        c.enqueue([.init(path: tree.root, flags: UInt32(kFSEventStreamEventFlagKernelDropped))])
        c.synchronizeWriter()
        Thread.sleep(forTimeInterval: 0.02)
      } else {
        for _ in 0..<2 {
          c.enqueue(
            (0..<8).map { _ in
              .init(
                path: tree.path("seed"),
                flags: UInt32(
                  kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile))
            })
          XCTAssertTrue(c.flushEvents())
        }
      }
      XCTAssertThrowsError(
        try SnapshotV2Writer.write(
          source: .hybrid(ticket.snapshot), identity: v, generation: ticket.snapshot.generation,
          cursor: ticket.checkpoint.cursor, store: s,
          install: { b, map, publish in
            try c.finishCompaction(ticket, base: b, directories: map, publish: publish)
          }))
      c.abortCompaction(ticket)
      XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: s.path)), bytes)
    }
  }
  func testCompactionIOValidationCancellationFailuresPreserveBaseAndOverlay() throws {
    let cache = try TemporaryTree(cache: true)
    let v = snapshotIdentity()
    let s = try SnapshotStore(directory: cache.root, identity: v)
    let ram = sampleSnapshotIndex()
    _ = try SnapshotV2Writer.write(
      source: .ram(ram, ram.stats().generation), identity: v, generation: ram.stats().generation,
      cursor: 7, store: s)
    let h = HybridIndex(base: try XCTUnwrap(s.reader(expectedIdentity: v).mappedBase))
    h.apply([.upsert(.init(path: v.root + "/pending", kind: .file, deviceID: v.deviceID))])
    let old = try Data(contentsOf: URL(fileURLWithPath: s.path))
    let capture = h.capture()!
    for point in [SnapshotFailurePoint.beforeFileSync, .beforeRename, .afterRename, .directorySync]
    {
      XCTAssertThrowsError(
        try SnapshotV2Writer.write(
          source: .hybrid(capture), identity: v, generation: capture.generation, cursor: 8,
          store: s,
          fault: { if $0 == point { throw SnapshotError.io("injected", EIO) } },
          install: { b, map, publish in
            try publish()
            h.install(base: b, directoryMap: map)
          }))
      XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: s.path)), old)
      XCTAssertNotNil(h.entry(at: v.root + "/pending"))
    }
    XCTAssertThrowsError(
      try SnapshotV2Writer.write(
        source: .hybrid(capture), identity: v, generation: capture.generation, cursor: 8, store: s,
        fault: { point in
          if point == .beforeFileSync {
            let temp = try FileManager.default.contentsOfDirectory(atPath: cache.root).first {
              $0.hasSuffix(".tmp")
            }!
            let fd = open(cache.path(temp), O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
            defer { close(fd) }
            var byte: UInt8 = 99
            XCTAssertEqual(pwrite(fd, &byte, 1, 256), 1)
          }
        }))
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: s.path)), old)
    let token = CancellationToken()
    token.cancel()
    XCTAssertThrowsError(
      try SnapshotV2Writer.write(
        source: .hybrid(capture), identity: v, generation: capture.generation, cursor: 8, store: s,
        cancellation: token))
  }
  func testTwentyRoundsOfTenThousandUniqueFilesStayBoundedAndRestartCorrect() throws {
    let cache = try TemporaryTree(cache: true)
    let v = snapshotIdentity()
    let s = try SnapshotStore(directory: cache.root, identity: v)
    let ram = sampleSnapshotIndex()
    _ = try SnapshotV2Writer.write(
      source: .ram(ram, ram.stats().generation), identity: v, generation: ram.stats().generation,
      cursor: 7, store: s)
    let h = HybridIndex(base: try XCTUnwrap(s.reader(expectedIdentity: v).mappedBase))
    let baseline = h.snapshotPaths()
    var count = 0
    func compact() throws {
      let capture = h.capture()!
      _ = try SnapshotV2Writer.write(
        source: .hybrid(capture), identity: v, generation: capture.generation, cursor: 7, store: s,
        install: { b, map, publish in
          try publish()
          h.install(base: b, directoryMap: map)
        })
      count += 1
    }
    for round in 0..<20 {
      let stem = v.root + "/churn-\(round)-"
      h.apply(
        (0..<10000).map {
          .upsert(.init(path: stem + String($0), kind: .file, deviceID: v.deviceID))
        })
      if round == 0 { try compact() }
      h.apply((0..<10000).map { .remove(stem + String($0)) })
      if round == 0 { try compact() }
      XCTAssertEqual(h.hybridStats()["overlay_live_entries"] as? Int, 0)
      XCTAssertEqual(h.hybridStats()["base_tombstones"] as? Int, 0)
      XCTAssertEqual(h.stats().liveEntries, baseline.count)
      _ = h.search("dir")
      XCTAssertEqual(h.metrics.snapshot()["query_base_records_scanned"], baseline.count - 1)
      XCTAssertEqual(h.metrics.snapshot()["query_delta_records_scanned"], 0)
      XCTAssertLessThanOrEqual(h.hybridStats()["overlay_free_slots"] as? Int ?? 0, 10000)
    }
    XCTAssertGreaterThanOrEqual(count, 1)
    XCTAssertEqual(h.snapshotPaths(), baseline)
    XCTAssertEqual(
      HybridIndex(base: try XCTUnwrap(s.reader(expectedIdentity: v).mappedBase)).snapshotPaths(),
      baseline)
  }
}

extension HybridRecoveryTests {
  func testManagedCompactionSuppressesDuplicatesWhileWriterKeepsUpdating() throws {
    try requireFSEvents()
    let tree = try TemporaryTree()
    let cache = try TemporaryTree(cache: true)
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let p = try PersistentIndexCoordinator(
      root: tree.root, cacheDirectory: cache.root,
      compactionFault: { point in
        if point == .beforeFileSync {
          entered.signal()
          guard release.wait(timeout: .now() + 10) == .success else {
            throw SnapshotError.cancelled
          }
        }
      }, maintenanceScheduler: .init())
    defer {
      release.signal()
      p.stop(saveCheckpoint: false)
    }
    try p.start()
    XCTAssertTrue(p.waitUntilLive())
    XCTAssertTrue(p.compact())
    XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
    XCTAssertFalse(p.compact())
    try tree.file("while-compacting")
    waitFor("writer remains live during staged I/O") {
      p.index.entry(at: tree.path("while-compacting")) != nil
    }
    release.signal()
    XCTAssertTrue(p.waitForCheckpoint())
    XCTAssertEqual(p.metrics.snapshot()["compactions"], 1)
    XCTAssertTrue(try p.verify().isConsistent)
    XCTAssertNotNil(p.index.entry(at: tree.path("while-compacting")))
  }
  func testAutomaticQuietCompactionReleasesOverlay() throws {
    try requireFSEvents()
    let tree = try TemporaryTree()
    let cache = try TemporaryTree(cache: true)
    var policy = CompactionPolicy()
    policy.liveLimit = 2
    policy.quietSeconds = 0.05
    let p = try PersistentIndexCoordinator(
      root: tree.root, cacheDirectory: cache.root, compactionPolicy: policy, maintenanceScheduler: .init())
    defer { p.stop(saveCheckpoint: false) }
    try p.start()
    XCTAssertTrue(p.waitUntilLive())
    try tree.file("one")
    try tree.file("two")
    waitFor("automatic compaction", timeout: 5) {
      p.metrics.snapshot()["compactions", default: 0] > 0
    }
    XCTAssertEqual(p.stats().dictionary["overlay_live_entries"] as? Int, 0)
    XCTAssertTrue(try p.verify().isConsistent)
  }
  func testOldLegacyV1WithoutUUIDIgnoresState() throws {
    let cache = try TemporaryTree(cache: true)
    let v = snapshotIdentity()
    let s = try SnapshotStore(directory: cache.root, identity: v)
    let h = try SnapshotWriter.write(index: sampleSnapshotIndex(), identity: v, cursor: 7, store: s)
      .header
    try s.writeState(header: h, cursor: 9, beforePublish: {})
    var bytes = try Data(contentsOf: URL(fileURLWithPath: s.path))
    bytes.put(UInt32(0), at: 16)
    bytes.replaceSubrange(168..<184, with: Data(repeating: 0, count: 16))
    bytes = repairedChecksums(bytes)
    try bytes.write(to: URL(fileURLWithPath: s.path))
    let old = try s.reader(expectedIdentity: v).header
    XCTAssertNil(old.snapshotUUID)
    XCTAssertEqual(s.effectiveCursor(for: old).cursor, 7)
  }
}
