import APFSFindCore
import Darwin
import Foundation

private enum HybridBenchError: Error { case invalid(String) }
private final class BenchmarkSamples: @unchecked Sendable {
  private let lock = NSLock()
  private var data: [Double] = []
  func add(_ d: Double) { lock.withLock { data.append(d) } }
  var count: Int { lock.withLock { data.count } }
  func summary() -> [String: Double] {
    let a = lock.withLock { data.sorted() }
    func p(_ fraction: Double) -> Double {
      a.isEmpty ? 0 : a[min(a.count - 1, Int(ceil(Double(a.count) * fraction)) - 1)]
    }
    return [
      "samples": Double(a.count), "p50_ms": p(0.50), "p95_ms": p(0.95), "p99_ms": p(0.99),
      "max_ms": a.last ?? 0,
    ]
  }
}

/// Synthetic base measures mmap/RAM/query costs separately from the real-device
/// visibility probe below. No million-file filesystem fixture is fabricated.
struct HybridBenchmarkRunner {
  let entries: Int
  let deltaCount: Int
  let cacheDirectory: String?
  private func now() -> Double { ProcessInfo.processInfo.systemUptime }
  func run() throws -> Int32 {
    let tree = try OwnedTemporaryDirectory()
    let cache = try OwnedTemporaryDirectory(parentPath: cacheDirectory)
    defer {
      try? tree.remove()
      try? cache.remove()
    }
    let root = try PathCanonicalizer.canonicalRoot(tree.url.path)
    let v = try VolumeIdentity.discover(root: root)
    let store = try SnapshotStore(directory: cache.url.path, identity: v)
    var ram: FileIndex? = FileIndex(root: root)
    let directoryCount = min(1000, entries / 100)
    ram!.apply(
      (0..<directoryCount).map {
        .upsert(
          .init(path: root + String(format: "/d%04d", $0), kind: .directory, deviceID: v.deviceID))
      })
    let fileCount = entries - directoryCount - 1
    for start in stride(from: 0, to: fileCount, by: 4096) {
      ram!.apply(
        (start..<min(start + 4096, fileCount)).map {
          .upsert(
            .init(
              path: root + String(format: "/d%04d/f%07d", $0 % directoryCount, $0), kind: .file,
              deviceID: v.deviceID))
        })
    }
    let coldStart = now()
    let initial = try SnapshotV2Writer.write(
      source: .ram(ram!, ram!.stats().generation), identity: v,
      generation: ram!.stats().generation, cursor: v.currentEventID(), store: store)
    let buildMS = (now() - coldStart) * 1000
    ram = nil
    let before = Metrics.processUsage().residentBytes
    let loadStart = now()
    var base: MMapBaseIndex? = try MMapBaseIndex(path: store.path, identity: v)
    let map = base!
    let hybrid = HybridIndex(base: map)
    let warmMS = (now() - loadStart) * 1000
    let after = Metrics.processUsage().residentBytes
    base = nil
    var report: [String: Any] = [
      "version": "0.5.0", "synthetic_base_entries": entries, "initial_write_ms": buildMS,
      "base_bytes": initial.header.fileLength,
      "base_bytes_per_entry": Double(initial.header.fileLength) / Double(entries),
      "warm_load_ms": warmMS, "mmap_ms": map.mmapMilliseconds,
      "validation_ms": map.validationMilliseconds,
      "directory_map_ms": warmMS - map.mmapMilliseconds - map.validationMilliseconds,
      "rss_before_warm": before, "rss_after_warm": after, "mapped_bytes": map.mappedBytes,
      "warm_stats": hybrid.hybridStats(),
      "materialized_file_entries": 0, "full_scans": 0,
    ]
    func queryReport() -> [String: Any] {
      var result: [String: Any] = [:]
      for (kind, query) in [
        ("exact", "f0000500"), ("prefix", "f000"), ("substring", "050"), ("broad", "f"),
        ("no_result", "zzzz-no-match"),
      ] {
        let samples = BenchmarkSamples()
        let basePhase = BenchmarkSamples()
        let overlayPhase = BenchmarkSamples()
        let pathPhase = BenchmarkSamples()
        for _ in 0..<20 {
          samples.add(hybrid.search(query, limit: 50).latencyMilliseconds)
          let m = hybrid.metrics.snapshot()
          basePhase.add(Double(m["query_base_scan_us", default: 0]) / 1000)
          overlayPhase.add(Double(m["query_overlay_scan_us", default: 0]) / 1000)
          pathPhase.add(Double(m["query_path_reconstruction_us", default: 0]) / 1000)
        }
        var values: [String: Any] = samples.summary()
        values["base_scan"] = basePhase.summary()
        values["overlay_scan"] = overlayPhase.summary()
        values["path_reconstruction"] = pathPhase.summary()
        values["phases"] = hybrid.hybridStats().filter { $0.key.hasPrefix("query_") }
        result[kind] = values
      }
      return result
    }
    let probe = Process()
    let out = Pipe()
    let err = Pipe()
    probe.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    probe.arguments = ["_mmap-probe", root, cache.url.path]
    probe.standardOutput = out
    probe.standardError = err
    try probe.run()
    let probeData = out.fileHandleForReading.readDataToEndOfFile()
    let probeErrors = err.fileHandleForReading.readDataToEndOfFile()
    probe.waitUntilExit()
    guard probe.terminationStatus == 0,
      let fresh = try JSONSerialization.jsonObject(with: probeData) as? [String: Any],
      fresh["materialized_file_entries"] as? Int == 0, fresh["base_records"] as? Int == entries
    else {
      throw HybridBenchError.invalid(
        "Fresh process probe: " + String(decoding: probeErrors, as: UTF8.self))
    }
    report["fresh_process_mmap_probe"] = fresh
    report["base_queries"] = queryReport()
    let dStart = now()
    for start in stride(from: 0, to: deltaCount, by: 512) {
      hybrid.apply(
        (start..<min(start + 512, deltaCount)).map {
          .upsert(.init(path: root + "/delta-\($0)", kind: .file, deviceID: v.deviceID))
        })
    }
    report["overlay_build_ms"] = (now() - dStart) * 1000
    report["overlay_stats"] = hybrid.hybridStats()
    report["overlay_queries"] = queryReport()
    let finish = CancellationToken()
    let group = DispatchGroup()
    let querySamples = BenchmarkSamples()
    let writerSamples = BenchmarkSamples()
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      while !finish.isCancelled {
        querySamples.add(hybrid.search("f", limit: 50).latencyMilliseconds)
      }
      group.leave()
    }
    defer { finish.cancel(); group.wait() }
    let visibility = BenchmarkSamples()
    let maintenanceDeadline = now() + 30
    var i = 0
    // Continue real mutations until broad queries have completed enough samples;
    // a fast 100-operation loop otherwise yields only one query on a 1M base.
    while i < 100 || querySamples.count < 20 {
      guard now() < maintenanceDeadline else {
        throw HybridBenchError.invalid("Concurrent maintenance exceeded 30 seconds")
      }
      let p = root + "/concurrent-\(i)"
      let renamed = p + "-renamed"
      let t = now()
      hybrid.apply([.upsert(.init(path: p, kind: .file, deviceID: v.deviceID))])
      writerSamples.add((now() - t) * 1000)
      guard hybrid.entry(at: p) != nil else { throw HybridBenchError.invalid("concurrent create") }
      visibility.add((now() - t) * 1000)
      hybrid.apply([.remove(p), .upsert(.init(path: renamed, kind: .file, deviceID: v.deviceID))])
      guard hybrid.entry(at: p) == nil, hybrid.entry(at: renamed) != nil else {
        throw HybridBenchError.invalid("concurrent rename")
      }
      hybrid.apply([.remove(renamed)])
      i += 1
    }
    finish.cancel()
    group.wait()
    report["concurrent_broad_queries"] = querySamples.summary()
    report["namespace_patch_visibility"] = visibility.summary()
    report["writer_patch_ms"] = writerSamples.summary()
    report["concurrent_namespace_cycles"] = i
    var compactions = 0
    var compactionPeak: UInt64 = 0
    func compact() throws -> [String: Any] {
      let captured = hybrid.capture()!
      let cpuBefore = Metrics.processUsage()
      let started = now()
      let queries = BenchmarkSamples()
      let done = CancellationToken()
      let g = DispatchGroup()
      g.enter()
      DispatchQueue.global(qos: .userInitiated).async {
        while !done.isCancelled { queries.add(hybrid.search("f", limit: 50).latencyMilliseconds) }
        g.leave()
      }
      defer {
        done.cancel()
        g.wait()
      }
      let r = try SnapshotV2Writer.write(
        source: .hybrid(captured), identity: v, generation: captured.generation,
        cursor: initial.header.lastProcessedEventID, store: store,
        install: { b, map, publish in
          try publish()
          hybrid.install(base: b, directoryMap: map)
        })
      compactions += 1
      compactionPeak = max(compactionPeak, r.peakResidentBytes)
      let cpuAfter = Metrics.processUsage()
      return [
        "wall_ms": (now() - started) * 1000, "bytes_written": r.header.fileLength,
        "peak_rss": r.peakResidentBytes,
        "user_cpu_s": cpuAfter.userCPUSeconds - cpuBefore.userCPUSeconds,
        "system_cpu_s": cpuAfter.systemCPUSeconds - cpuBefore.systemCPUSeconds,
        "events_buffered": 0, "source": "immutable_synthetic_namespace",
        "concurrent_queries": queries.summary(), "stats_after": hybrid.hybridStats(),
      ]
    }
    report["compaction"] = try compact()
    guard hybrid.stats().liveEntries == entries + deltaCount,
      hybrid.entry(at: root + "/delta-0") != nil
    else { throw HybridBenchError.invalid("merged namespace") }
    var rounds: [[String: Any]] = []
    // Two compactions at the first round demonstrate reclamation; subsequent
    // unique deltas are eagerly removed and never accumulate historical slots.
    for round in 0..<20 {
      let stem = root + "/churn-\(round)-"
      hybrid.apply(
        (0..<10_000).map {
          .upsert(.init(path: stem + String($0), kind: .file, deviceID: v.deviceID))
        })
      if round == 0 { _ = try compact() }
      hybrid.apply((0..<10_000).map { .remove(stem + String($0)) })
      if round == 0 { _ = try compact() }
      let sample = BenchmarkSamples()
      for _ in 0..<5 { sample.add(hybrid.search("f", limit: 50).latencyMilliseconds) }
      var row = hybrid.hybridStats()
      row["round"] = round + 1
      row["rss_bytes"] = Metrics.processUsage().residentBytes
      row["query"] = sample.summary()
      row["compactions"] = compactions
      rounds.append(row)
      guard hybrid.stats().liveEntries == entries + deltaCount, hybrid.entry(at: stem + "0") == nil,
        hybrid.hybridStats()["overlay_live_entries"] as? Int == 0
      else { throw HybridBenchError.invalid("churn bounds") }
    }
    report["long_churn"] = rounds
    report["compaction_peak_rss"] = compactionPeak
    let reopen = HybridIndex(base: try MMapBaseIndex(path: store.path, identity: v))
    guard reopen.stats().liveEntries == entries + deltaCount,
      reopen.entry(at: root + "/delta-0") != nil
    else { throw HybridBenchError.invalid("restart synthetic model") }
    report["synthetic_restart_verified"] = true
    report["native_visibility"] = try nativeProbe()
    report["final_stats"] = hybrid.hybridStats()
    report["provisional_acceptance"] = true
    print(
      "Hybrid: \(entries) base + \(deltaCount) delta; \(String(format:"%.2f",Double(initial.header.fileLength)/Double(entries))) bytes/entry; warm \(String(format:"%.1f",warmMS)) ms; materialized_file_entries=0"
    )
    let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    return 0
  }
  private func nativeProbe() throws -> [String: Any] {
    let tree = try OwnedTemporaryDirectory()
    let cache = try OwnedTemporaryDirectory()
    defer {
      try? tree.remove()
      try? cache.remove()
    }
    let root = tree.url.path
    try FileManager.default.createDirectory(
      atPath: root + "/left", withIntermediateDirectories: false)
    try FileManager.default.createDirectory(
      atPath: root + "/right", withIntermediateDirectories: false)
    let controller = try PersistentIndexCoordinator(root: root, cacheDirectory: cache.url.path)
    defer { controller.stop(saveCheckpoint: false) }
    try controller.start()
    guard controller.waitUntilLive(timeout: 30) else {
      throw HybridBenchError.invalid("native startup")
    }
    let create = BenchmarkSamples()
    let rename = BenchmarkSamples()
    let crossRename = BenchmarkSamples()
    let delete = BenchmarkSamples()
    let query = BenchmarkSamples()
    let done = CancellationToken()
    let g = DispatchGroup()
    g.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      while !done.isCancelled {
        query.add(controller.index.search("native", limit: 50).latencyMilliseconds)
      }
      g.leave()
    }
    defer {
      done.cancel()
      g.wait()
    }
    func wait(_ condition: () -> Bool) throws {
      let deadline = now() + 2
      while !condition(), now() < deadline { Thread.sleep(forTimeInterval: 0.001) }
      guard condition() else { throw HybridBenchError.invalid("native visibility timeout") }
    }
    for i in 0..<50 {
      let p = root + "/left/native-\(i)"
      let q = p + "-renamed"
      let a = now()
      guard FileManager.default.createFile(atPath: p, contents: Data()) else {
        throw HybridBenchError.invalid("create fixture")
      }
      try wait { controller.index.search("native-\(i)", limit: 50).hits.contains { $0.path == p } }
      create.add((now() - a) * 1000)
      let b = now()
      try FileManager.default.moveItem(atPath: p, toPath: q)
      try wait {
        let hits = controller.index.search("native-\(i)", limit: 50).hits
        return hits.contains { $0.path == q } && !hits.contains { $0.path == p }
      }
      rename.add((now() - b) * 1000)
      let cross = root + "/right/native-\(i)"
      let crossStart = now()
      try FileManager.default.moveItem(atPath: q, toPath: cross)
      try wait {
        let hits = controller.index.search("native-\(i)", limit: 50).hits
        return hits.contains { $0.path == cross } && !hits.contains { $0.path == q }
      }
      crossRename.add((now() - crossStart) * 1000)
      let c = now()
      try FileManager.default.removeItem(atPath: cross)
      try wait {
        !controller.index.search("native-\(i)", limit: 50).hits.contains { $0.path == cross }
      }
      delete.add((now() - c) * 1000)
    }
    let beforeCompactionQueries = query.count
    let compactionStarted = now()
    guard controller.compact(), controller.waitForCheckpoint(timeout: 30),
      controller.metrics.snapshot()["compactions", default: 0] > 0
    else { throw HybridBenchError.invalid("native compaction") }
    let nativeCompactionMS = (now() - compactionStarted) * 1000
    let queriesDuringCompaction = query.count - beforeCompactionQueries
    done.cancel()
    g.wait()
    let verify = try controller.verify()
    guard verify.isConsistent else { throw HybridBenchError.invalid("native verify") }
    return [
      "create": create.summary(), "rename": rename.summary(), "cross_rename": crossRename.summary(),
      "delete": delete.summary(),
      "concurrent_queries": query.summary(),
      "verify_missing": verify.missing.count, "verify_extra": verify.extra.count,
      "compaction_ms": nativeCompactionMS,
      "compaction_queries_completed": queriesDuringCompaction,
      "compaction_events_buffered": controller.metrics.snapshot()["compaction_buffered_events", default: 0],
      "stats": controller.stats().dictionary,
    ]
  }
}
