import APFSFindCore
import Foundation
import Darwin

private final class AsyncCLIResult: @unchecked Sendable {
  let lock = NSLock(), completed = DispatchSemaphore(value: 0)
  var value: Result<String, Error>?
}
func runAsyncCLI(_ operation: @escaping @Sendable () async throws -> String) throws -> Int32 {
  let box = AsyncCLIResult()
  Task.detached {
    let value: Result<String, Error>
    do { value = .success(try await operation()) } catch { value = .failure(error) }
    box.lock.withLock { box.value = value }; box.completed.signal()
  }
  box.completed.wait(); print(try box.lock.withLock { try box.value!.get() }); return 0
}
func benchmarkJSON(_ value: [String: Any]) throws -> String {
  String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
}
func benchmarkPercentiles(_ values: [Double]) -> [String: Double] {
  let sorted = values.sorted()
  var result: [String: Double] = [:]
  for (key, p) in [("p50", 0.5), ("p90", 0.9), ("p95", 0.95), ("p99", 0.99), ("max", 1.0)] {
    result[key] = sorted.isEmpty ? 0 : sorted[max(0, Int(ceil(Double(sorted.count) * p)) - 1)]
  }
  return result
}
struct UsabilityBenchmarkRunner {
  let root: String
  let cacheDirectory: String?
  let idleSeconds: Double
  func run() throws -> Int32 {
    let canonical = try PathCanonicalizer.canonicalRoot(root)
    let newCache = cacheDirectory == nil ? try OwnedBenchmarkDirectory(parent: "/private/tmp", prefix: "apfsfind-real-cache-") : nil
    let cache = cacheDirectory ?? newCache!.path
    let parent = canonical == "/" ? "/private/tmp" : canonical
    let fixture = try OwnedBenchmarkDirectory(parent: parent, prefix: "apfsfind-real-bench-")
    do {
      var cold: [String: Any]? = nil
      if newCache != nil { cold = try child(["prepare", canonical, cache, fixture.path, "0"]) }
      var result = try child(["warm", canonical, cache, fixture.path, String(idleSeconds)])
      if let cold { result["cold"] = cold }
      try fixture.remove(); try newCache?.remove()
      result["cleanup_completed"] = true
      TerminalOutput.info("Search ready \(result["base_ready_ms"] ?? "?") ms; live \(result["live_ms"] ?? "?") ms; fast exit \(result["fast_exit_ms"] ?? "?") ms")
      print(try benchmarkJSON(result)); return 0
    } catch {
      try fixture.remove(); try newCache?.remove(); throw error
    }
  }
  private func child(_ args: [String]) throws -> [String: Any] {
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["_usability-worker"] + args
    process.standardOutput = output; process.standardError = FileHandle.standardError
    try process.run()
    let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    guard process.terminationStatus == 0, let last = String(decoding: bytes, as: UTF8.self).split(separator: "\n").last,
          let result = try JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any] else {
      throw CLIError.startupFailed("Usability child failed: \(process.terminationStatus)")
    }
    return result
  }
  static func worker(_ args: [String]) throws -> Int32 {
    guard args.count == 5, let idle = Double(args[4]), idle.isFinite, (0...3600).contains(idle) else { throw CLIError.usage("Invalid usability worker") }
    let root = args[1], cache = args[2], fixture = args[3]
    // Internal workers never clean a path passed from their parent.
    guard PathCanonicalizer.isWithin(fixture, root: root), URL(fileURLWithPath: fixture).lastPathComponent.hasPrefix("apfsfind-real-bench-") else { throw CLIError.usage("Fixture outside root") }
    var policy = CompactionPolicy(); policy.liveLimit = Int.max; policy.tombstoneLimit = Int.max
    policy.byteLimit = Int.max; policy.safetyByteLimit = Int.max; policy.overlayRatio = 2; policy.tombstoneRatio = 2
    let p = try PersistentIndexCoordinator(root: root, cacheDirectory: cache, compactionPolicy: policy)
    defer { p.stop(policy: .fast) }
    let begin = ProcessInfo.processInfo.systemUptime
    try p.start()
    let ready = (ProcessInfo.processInfo.systemUptime - begin) * 1000
    let readyStatus = p.readinessSnapshot()
    guard readyStatus.searchAvailable, p.waitUntilLive(timeout: 1800) else { throw CLIError.replayTimedOut }
    let live = (ProcessInfo.processInfo.systemUptime - begin) * 1000
    var result: [String: Any] = ["root": root, "pid": getpid(), "base_ready_ms": ready, "live_ms": live,
      "ready_freshness": readyStatus.freshness.rawValue, "indexed_entries": p.index.stats().liveEntries,
      "startup_mode": p.stats().dictionary["startup_mode"] ?? "", "snapshot_format_version": 2]
    if args[0] == "warm" {
      guard p.stats().dictionary["startup_mode"] as? String == "warm_snapshot" else { throw CLIError.startupFailed("Warm benchmark needs a valid existing test snapshot") }
      let idleStart = ProcessResourceSample.capture()
      let before = p.metrics.snapshot()
      Thread.sleep(forTimeInterval: idle)
      let after = p.metrics.snapshot()
      result["idle_resources"] = ProcessResourceSample.capture().delta(since: idleStart)
      result["compaction_scheduler_wakeups"] = after["compaction_scheduler_wakeups", default: 0] - before["compaction_scheduler_wakeups", default: 0]
      result["idle_namespace_events"] = after["direct_patches", default: 0] - before["direct_patches", default: 0]
      let token = SearchCancellationToken(), finished = DispatchSemaphore(value: 0)
      let cancellationStart = ProcessInfo.processInfo.systemUptime
      DispatchQueue.global(qos: .userInitiated).async { _ = p.search(.init(query: "a", cancellation: token)); finished.signal() }
      Thread.sleep(forTimeInterval: 0.001); token.cancel()
      guard finished.wait(timeout: .now() + 2) == .success else { throw CLIError.startupFailed("Cancelled query did not return") }
      result["query_cancel_ms"] = (ProcessInfo.processInfo.systemUptime - cancellationStart) * 1000
      let path = fixture + "/small-overlay"
      guard FileManager.default.createFile(atPath: path, contents: Data()) else { throw CLIError.startupFailed("Cannot create owned fixture") }
      guard p.core.flushEvents(timeout: 30), p.index.entry(at: path) != nil else { throw CLIError.startupFailed("Owned create not observed") }
    }
    let beforeExit = ProcessResourceSample.capture()
    p.stop(policy: .fast)
    result["fast_exit_ms"] = (ProcessInfo.processInfo.systemUptime - beforeExit.uptime) * 1000
    result["exit_resources"] = ProcessResourceSample.capture().delta(since: beforeExit)
    let metrics = p.metrics.snapshot()
    for key in ["replay_overlap_events_skipped", "replay_events_applied", "replay_special_events_applied", "replay_metadata_lookups", "replay_directory_reconciles", "replay_subtree_reconciles", "full_scans", "compactions", "fast_exit_unpersisted_namespace"] {
      result[key] = metrics[key, default: 0]
    }
    result["rss_bytes"] = Metrics.processUsage().residentBytes
    print(try benchmarkJSON(result)); return 0
  }
}
