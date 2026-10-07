import APFSFindCore
import Darwin
import Foundation

/// This process measures compact metadata columns independently of a namespace
/// object graph. Real-file bootstrap runs in a fresh metadata-bench worker.
struct LightweightBenchmarkRunner {
  let entries:Int
  func run() throws -> Int32 {
    let root = try OwnedTemporaryDirectory(), cache = try OwnedTemporaryDirectory(); defer { try? root.remove(); try? cache.remove() }
    let identity = try VolumeIdentity.discover(root:root.url.path), ram = FileIndex(root:identity.root)
    let store = try SnapshotStore(directory:cache.url.path,identity:identity)
    var header = try SnapshotV2Writer.write(source:.ram(ram,ram.stats().generation),identity:identity,generation:ram.stats().generation,cursor:1,store:store).header
    header.recordCount = UInt64(entries) // Synthetic ordinal contract, explicitly reported.
    let before = ProcessResourceSample.capture(), start = ProcessInfo.processInfo.systemUptime
    var peak = before.rssBytes
    do {
      let buffer = try MetadataBuildBuffer(count:entries,directory:cache.url.path)
      for i in 0..<entries {
        buffer.update([ (i,.init(logicalSize:i%7 == 0 ? nil : UInt64(i%65536),modificationTimeNanoseconds:Int64(i))) ])
        if i%8192 == 0 { peak = max(peak,ProcessResourceSample.capture().rssBytes) }
      }
      _ = try MetadataWriter.write(store:store,base:header,cursor:1,value:{buffer.value(Int($0))},checkpoint:{peak = max(peak,ProcessResourceSample.capture().rssBytes)})
      let mapped = try store.metadataReader(base:header)
      guard mapped.value(at:UInt32(entries-1)).modificationTimeNanoseconds == Int64(entries-1) else { throw CLIError.startupFailed("streaming value mismatch") }
      peak = max(peak,ProcessResourceSample.capture().rssBytes)
    }
    let columnReport:[String:Any] = ["entries":entries,"kind":"synthetic ordinal columns, no namespace Swift graph",
      "buffer_bytes":entries*16+(entries+3)/4,"maximum_output_chunk_bytes":65536,"elapsed_ms":(ProcessInfo.processInfo.systemUptime-start)*1000,
      "peak_observed_rss_bytes":peak,"process_peak_rss_bytes":ProcessResourceSample.capture().peakRSSBytes,"resources":ProcessResourceSample.capture().delta(since:before)]
    let standalone=try benchmarkChild(["_cache-pressure-worker"])
    let pressure = try fakePressure()
    let cpu = try actualCPUBusy()
    let report:[String:Any] = ["benchmark":"lightweight","version":"0.6.1","standalone_cache_pressure":standalone,"metadata_columns":columnReport,"fake_pressure":pressure,"actual_cpu_busy":cpu,
      "limits":"real filesystem bootstrap peak is measured by metadata-bench in a fresh process; fake pressure never allocates system-wide memory pressure"]
    print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
    return peak <= 400*1024*1024 && pressure["passed"] as? Bool == true && cpu["ordinary_deferred"] as? Bool == true && cpu["recovery_resumed"] as? Bool == true ? 0 : 1
  }
  private func fakePressure() throws -> [String:Any] {
    let root = try OwnedTemporaryDirectory(), cache = try OwnedTemporaryDirectory(); defer { try? root.remove(); try? cache.remove() }
    let padding = String(repeating:"x",count:200)
    func directory(_ i:Int) -> String { root.url.path+"/d\(i)-"+padding }
    // Long but legal basenames make the small cache's released pages measurable
    // against runtime/allocator noise. This is an owned synthetic fixture.
    for i in 0..<5000 { try FileManager.default.createDirectory(atPath:directory(i),withIntermediateDirectories:false) }
    let signals = FakeResourceSignals(.init(timestamp:0,cpuIdleEWMA:0.05)), scheduler = MaintenanceScheduler(signals:signals)
    let c = try PersistentIndexCoordinator(root:root.url.path,cacheDirectory:cache.url.path,maintenanceScheduler:scheduler)
    defer { c.stop(policy:.fast) }
    try c.start(); guard c.waitUntilLive(timeout:30) else { throw CLIError.startupFailed("lightweight fixture startup") }
    for i in 0..<5000 { _ = c.index.entry(at:directory(i)); _ = c.metadata.capture().ordinal(directory(i)) }
    c.rebuildMetadata(urgency:.opportunistic)
    Thread.sleep(forTimeInterval:0.1)
    let blocked = schedulerSnapshot(scheduler).first?.startedAt == nil && signals.isSampling
    let added = directory(0)+"/search-visible"
    try Data().write(to:URL(fileURLWithPath:added))
    let deadline = ProcessInfo.processInfo.systemUptime+10
    while c.index.entry(at:added) == nil && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval:0.001) }
    let incremental = c.search("search-visible").hits.count == 1
    _ = c.core.flushEvents(); c.flushMetadata()
    Thread.sleep(forTimeInterval:0.3) // Exclude initial directory metadata debounce from pressure gauges.
    // The creation invalidates the namespace cache epoch. Warm it again so
    // pressure measures reclaiming populated caches rather than two root refs.
    for i in 0..<5000 { _ = c.index.entry(at:directory(i)); _ = c.metadata.capture().ordinal(directory(i)) }
    let processBeforePressure = ProcessResourceSample.capture().dictionary
    let beforePressure = (c.index as! HybridIndex).hotDirectoryCache.statistics
    signals.update(.init(timestamp:2,memoryPressure:.warning,cpuIdleEWMA:0.05)); Thread.sleep(forTimeInterval:0.05)
    let warning = (c.index as! HybridIndex).hotDirectoryCache.statistics
    signals.update(.init(timestamp:3,memoryPressure:.critical,cpuIdleEWMA:0.05)); Thread.sleep(forTimeInterval:0.05)
    let critical = (c.index as! HybridIndex).hotDirectoryCache.statistics
    let processAfterPressure = ProcessResourceSample.capture().dictionary
    let oldQueryable = c.search("search-visible").hits.count == 1
    signals.update(.init(timestamp:20,cpuIdleEWMA:1)); Thread.sleep(forTimeInterval:0.05)
    let stableWindow = schedulerSnapshot(scheduler).first?.startedAt == nil
    signals.update(.init(timestamp:31,cpuIdleEWMA:1))
    let end = ProcessInfo.processInfo.systemUptime+30
    while c.metrics.snapshot()["metadata_bootstraps",default:0] == 0 && ProcessInfo.processInfo.systemUptime < end { Thread.sleep(forTimeInterval:0.01) }
    let resumed = c.metrics.snapshot()["metadata_bootstraps",default:0] > 0
    c.stop(policy:.fast)
    let passed = blocked && incremental && oldQueryable && stableWindow && resumed && critical["hot_directory_cache_entries"] == 1 && warning["hot_directory_cache_capacity"] == 2048
    let decreased = (processAfterPressure["physical_footprint"] as? UInt64 ?? 0) < (processBeforePressure["physical_footprint"] as? UInt64 ?? 0)
    return ["passed":passed,"fixture":"5000 distinct directories with 200-byte basename padding; injected pressure, no system-wide pressure allocation","physical_footprint_decreased":decreased,"ordinary_deferred":blocked,"incremental_during_busy":incremental,"old_base_queryable":oldQueryable,"sustained_idle_gate":stableWindow,"maintenance_resumed":resumed,"process_before_pressure":processBeforePressure,"process_after_pressure":processAfterPressure,"cache_before":beforePressure,"cache_warning":warning,"cache_critical":critical,"sampler_inactive_after_stop":!signals.isSampling]
  }
  private func actualCPUBusy() throws -> [String:Any] {
    let signals = SystemResourceSignals(), scheduler = MaintenanceScheduler(signals:signals), token = CancellationToken()
    var processes:[Process] = []
    defer { for p in processes where p.isRunning { p.terminate() }; for p in processes { p.waitUntilExit() }; token.cancel() }
    // Only these owned child processes are terminated. No unknown workload is touched.
    for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
      let p = Process(); p.executableURL = URL(fileURLWithPath:"/usr/bin/yes"); p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
      try p.run(); processes.append(p)
    }
    let box = BenchmarkAsyncBox()
    Task.detached { do { let lease = try await scheduler.acquire(volumeID:UUID(),kind:.metadataBootstrap,urgency:.opportunistic,cancellation:token); lease.release(); box.finish(.success(["started":true])) } catch { box.finish(.success(["cancelled":true])) } }
    Thread.sleep(forTimeInterval:14)
    let value = signals.current(), queued = schedulerSnapshot(scheduler)
    let deferred = queued.first?.startedAt == nil && !queued.isEmpty
    for p in processes where p.isRunning { p.terminate() }; for p in processes { p.waitUntilExit() }
    let recoverUntil = ProcessInfo.processInfo.systemUptime+120
    while !box.isFinished && ProcessInfo.processInfo.systemUptime < recoverUntil { Thread.sleep(forTimeInterval:0.1) }
    let recovered = box.isFinished; token.cancel(); _ = try box.wait()
    return ["recovery_resumed":recovered,"owned_cpu_workers":processes.count,"cpu_idle_ewma":value.cpuIdleEWMA as Any? ?? NSNull(),"ordinary_deferred":deferred,"cpu_sampler_wakeups":signals.metrics.snapshot()["cpu_sampler_wakeups",default:0]]
  }
}
private final class BenchmarkAsyncBox: @unchecked Sendable {
  let lock = NSLock(), done = DispatchSemaphore(value:0)
  var result:Result<[String:Any],Error>?
  func finish(_ value:Result<[String:Any],Error>) { lock.withLock { result = value }; done.signal() }
  var isFinished:Bool { lock.withLock { result != nil } }
  func wait() throws -> [String:Any] { done.wait(); return try lock.withLock { try result!.get() } }
}
private func schedulerSnapshot(_ scheduler:MaintenanceScheduler)->[MaintenanceTaskSnapshot] {
  let box = BenchmarkSchedulerBox()
  Task.detached { box.values = await scheduler.snapshot(); box.done.signal() }
  box.done.wait(); return box.values
}
private final class BenchmarkSchedulerBox: @unchecked Sendable { let done = DispatchSemaphore(value:0); var values:[MaintenanceTaskSnapshot] = [] }

/// Isolates warm-cache filesystem bootstrap from the cold namespace builder's peak.
func metadataBootstrapWorker(root:String,cache:String) throws -> Int32 {
  guard URL(fileURLWithPath:root).lastPathComponent.hasPrefix("apfsfind-bench-"), URL(fileURLWithPath:cache).lastPathComponent.hasPrefix("apfsfind-bench-") else { throw CLIError.usage("Metadata worker requires owned benchmark directories") }
  let c = try PersistentIndexCoordinator(root:root,cacheDirectory:cache)
  defer { c.stop(policy:.fast) }
  try c.start(); guard c.waitUntilLive(timeout:120) else { throw CLIError.startupFailed("bootstrap worker live") }
  let start = ProcessResourceSample.capture(); c.rebuildMetadata()
  let deadline = ProcessInfo.processInfo.systemUptime+180
  while c.metrics.snapshot()["metadata_bootstraps",default:0] == 0 {
    if let error = c.metadataFailure { throw CLIError.startupFailed(error) }
    guard ProcessInfo.processInfo.systemUptime < deadline else { throw CLIError.startupFailed("metadata-only bootstrap timeout") }
    Thread.sleep(forTimeInterval:0.01)
  }
  let after = ProcessResourceSample.capture()
  let report:[String:Any] = ["kind":"fresh process, existing namespace, real-file bulk metadata bootstrap","entries":c.index.stats().liveEntries,"process":after.dictionary,"resources":after.delta(since:start),"full_namespace_scans":c.metrics.snapshot()["full_scans",default:0],"passed":after.peakRSSBytes <= 400*1024*1024]
  print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),as:UTF8.self)); return 0
}
func benchmarkChild(_ arguments:[String]) throws -> [String:Any] {
  let process = Process(), output = Pipe(), errors = Pipe(), group = DispatchGroup()
  process.executableURL = URL(fileURLWithPath:CommandLine.arguments[0]); process.arguments = arguments; process.standardOutput = output; process.standardError = errors
  try process.run(); group.enter()
  DispatchQueue.global(qos:.utility).async {
    while let bytes = try? errors.fileHandleForReading.read(upToCount:4096), !bytes.isEmpty { FileHandle.standardError.write(bytes) }; group.leave()
  }
  let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); group.wait()
  guard process.terminationStatus == 0, let value = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw CLIError.startupFailed("benchmark worker failed: \(process.terminationStatus)") }; return value
}

/// A fresh process holds only the cache. No namespace, fixture tree, or retained path array.
func standaloneCachePressureWorker() throws -> Int32 {
  let cache=HotDirectoryCache(capacity:16384),version=PathResolutionVersion(baseUUID:UUID(),generation:1)
  cache.reset(version:version,root:"/owned",ref:.base(0))
  for i in 0..<16383 {cache.insert("/owned/\(i)/"+String(repeating:"long-component/",count:160)+"leaf",ref:.base(UInt32(i+1)),version:version)}
  func sample()->[[String:Any]] { (0..<5).map { _ in Thread.sleep(forTimeInterval:0.05);return ProcessResourceSample.capture().dictionary } }
  let beforeStats=cache.statistics,before=sample()
  cache.setPressure(.warning,root:"/owned");let warningStats=cache.statistics,warning=sample()
  cache.setPressure(.critical,root:"/owned");let criticalStats=cache.statistics,critical=sample()
  cache.setPressure(.normal,root:"/owned")
  let passed=beforeStats["hot_directory_cache_entries"]==16384 && warningStats["hot_directory_cache_entries"]==2048 && criticalStats["hot_directory_cache_entries"]==1 && cache.statistics["hot_directory_cache_entries"]==1
  let report:[String:Any]=["passed":passed,"kind":"fresh process; cache-only unique long path allocations","samples_before":before,"samples_warning":warning,"samples_critical":critical,"cache_before":beforeStats,"cache_warning":warningStats,"cache_critical":criticalStats,"interpretation":"Dictionary storage is replaced; physical gauges include allocator retention. Functional old-storage release is covered by weak-reference tests."]
  print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),as:UTF8.self));return passed ? 0:1
}
