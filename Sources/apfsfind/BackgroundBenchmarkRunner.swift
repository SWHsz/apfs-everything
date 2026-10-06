import APFSFindCore
import Foundation

struct BackgroundBenchmarkRunner {
  let idleSeconds: Double
  func run() throws -> Int32 {
    let tree = try OwnedTemporaryDirectory(), cache = try OwnedTemporaryDirectory()
    defer { try? tree.remove(); try? cache.remove() }
    let root = tree.url.path
    func path(_ name: String) -> String { root + "/" + name }
    func touch(_ name: String) throws { try Data().write(to: URL(fileURLWithPath: path(name))) }
    func wait(_ condition: () -> Bool) throws {
      let end = ProcessInfo.processInfo.systemUptime + 20
      while !condition() {
        guard ProcessInfo.processInfo.systemUptime < end else { throw CLIError.startupFailed("background benchmark did not converge") }
        Thread.sleep(forTimeInterval: 0.001)
      }
    }
    try touch("seed")
    var policy = CompactionPolicy()
    policy.liveLimit = 1_000_000; policy.byteLimit = 1024 * 1024 * 1024
    policy.overlayRatio = 10_000; policy.tombstoneRatio = 10_000
    let p = try PersistentIndexCoordinator(root: root, cacheDirectory: cache.url.path, compactionPolicy: policy)
    defer { p.stop(policy: .fast) }
    try p.start(); guard p.waitUntilLive(timeout: 20), p.waitForCheckpoint() else { throw CLIError.startupFailed("background startup") }
    _ = p.core.flushEvents()
    let idleStart = ProcessResourceSample.capture(), idleCounts = p.metrics.snapshot()
    let idleWall = ProcessInfo.processInfo.systemUptime
    Thread.sleep(forTimeInterval: idleSeconds)
    let idle = ProcessResourceSample.capture().delta(since: idleStart)
    let idleDuration = ProcessInfo.processInfo.systemUptime - idleWall
    let idleEndCounts = p.metrics.snapshot()
    var timings: [String: [Double]] = ["create": [], "rename": [], "delete": []]
    for i in 0..<30 {
      var start = ProcessInfo.processInfo.systemUptime
      try touch("created-\(i)")
      try wait { p.index.entry(at: path("created-\(i)")) != nil }
      timings["create"]!.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
      start = ProcessInfo.processInfo.systemUptime
      try FileManager.default.moveItem(atPath: path("created-\(i)"), toPath: path("renamed-\(i)"))
      try wait { p.index.entry(at: path("renamed-\(i)")) != nil && p.index.entry(at: path("created-\(i)")) == nil }
      timings["rename"]!.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
      start = ProcessInfo.processInfo.systemUptime
      try FileManager.default.removeItem(atPath: path("renamed-\(i)"))
      try wait { p.index.entry(at: path("renamed-\(i)")) == nil }
      timings["delete"]!.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
    }
    p.pause()
    let generation = p.index.stats().generation
    for i in 0..<1000 { try touch("paused-\(i)") }
    let retained = p.index.stats().generation == generation && p.search("paused").hits.isEmpty && p.search("seed").freshness == .pausedStale
    let resumed = ProcessInfo.processInfo.systemUptime
    try p.resume(); try wait { p.currentState == .live && p.index.entry(at: path("paused-999")) != nil }
    let convergeMS = (ProcessInfo.processInfo.systemUptime - resumed) * 1000
    let verified = try p.verify().isConsistent
    let report: [String: Any] = [
      "benchmark": "background", "scope": "window-independent engine; native window lifecycle is validated separately",
      "idle_seconds": idleDuration, "idle_resources": idle,
      "idle_compaction_scheduler_wakeups": idleEndCounts["compaction_scheduler_wakeups", default: 0] - idleCounts["compaction_scheduler_wakeups", default: 0],
      "periodic_polling": 0, "pause_mutations": 1000, "paused_retained_stale": retained,
      "resume_converge_ms": convergeMS, "verify_consistent": verified,
      "visibility_ms": timings.mapValues(benchmarkPercentiles),
      "compaction_policy": "raised thresholds isolate namespace pause and idle from compaction"
    ]
    print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    return retained && verified ? 0 : 1
  }
}
