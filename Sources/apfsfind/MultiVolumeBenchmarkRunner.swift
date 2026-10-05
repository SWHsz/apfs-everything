import APFSFindCore
import Foundation

private struct BenchmarkVolumeProvider: MountedVolumeProvider {
  let values: [VolumeDescriptor]
  func mountedVolumes() throws -> [VolumeDescriptor] { values }
}
private final class BenchmarkSelection: VolumeSelectionStore, @unchecked Sendable {
  let ids: Set<UUID>
  init(_ ids: Set<UUID>) { self.ids = ids }
  func load() -> Set<UUID> { ids }
  func save(_ ids: Set<UUID>) {}
}
private final class MappedBenchmarkSession: VolumeSearching, @unchecked Sendable {
  let volume: VolumeDescriptor
  let index: HybridIndex
  init(volume: VolumeDescriptor, index: HybridIndex) { self.volume = volume; self.index = index }
  func start() {}
  func stop(policy: ShutdownPolicy) async {}
  func snapshot() -> VolumeSessionSnapshot { .init(volume: volume, state: .live, searchAvailable: true, freshness: .live, indexedEntries: index.stats().liveEntries, snapshotBytes: UInt64(index.mappedBase?.mappedBytes ?? 0), unreadableDirectories: 0, pendingReplayEvents: 0) }
  func changes() -> AsyncStream<VolumeSessionSnapshot> { AsyncStream { $0.yield(snapshot()) } }
  func search(_ request: SearchRequest) -> SearchResult { index.search(request) }
  func reconcileParent(of path: String) {}
}
struct MultiVolumeBenchmarkRunner: Sendable {
  let entries: Int
  let volumeCount: Int
  func run() throws -> Int32 { try runAsyncCLI { try await measure() } }
  // Private measurement entry point: caller owns the cache and its cleanup.
  static func realWorker(_ args: [String]) throws -> Int32 {
    guard args.count >= 3 else { throw CLIError.usage("Expected cache and at least two roots") }
    let cache = args[0], roots = Array(args.dropFirst())
    return try runAsyncCLI {
      var volumes: [VolumeDescriptor] = [], indexes: [UUID: HybridIndex] = [:]
      for (i, root) in roots.enumerated() {
        let identity = try VolumeIdentity.discover(root: root)
        let store = try SnapshotStore(directory: cache, identity: identity)
        let base = try store.reader(expectedIdentity: identity).mappedBase!
        let volume = VolumeDescriptor(volumeUUID: identity.volumeUUID, displayName: root,
                                      mountPath: root, isSystemVolume: i == 0)
        volumes.append(volume); indexes[volume.volumeUUID] = HybridIndex(base: base)
      }
      let mapped = indexes
      let coordinator = MultiVolumeCoordinator(provider: BenchmarkVolumeProvider(values: volumes),
        selectionStore: BenchmarkSelection(Set(volumes.map(\.volumeUUID))),
        factory: { volume, _ in MappedBenchmarkSession(volume: volume, index: mapped[volume.volumeUUID]!) })
      await coordinator.start()
      var reports: [String: Any] = [:]
      for query in ["apfsfi", "swift", "config", "document"] {
        var samples: [Double] = []; var count = 0
        for i in 0..<35 {
          let result = await coordinator.search(.init(id: UInt64(i), query: query, limit: 50))
          if i >= 5 { samples.append(result.latencyMilliseconds) }; count = result.hits.count
        }
        reports[query] = ["latency_ms": benchmarkPercentiles(samples), "results": count]
      }
      await coordinator.stop()
      return try benchmarkJSON(["synthetic": false, "roots": roots, "volumes": volumes.count,
        "indexed_entries": mapped.values.reduce(0) { $0 + $1.stats().liveEntries },
        "global_limit": 50, "warmup": 5, "samples_per_query": 30, "queries": reports,
        "rss_bytes": Metrics.processUsage().residentBytes])
    }
  }
  private func measure() async throws -> String {
    let fixture = try OwnedBenchmarkDirectory(parent: "/private/tmp", prefix: "apfsfind-real-bench-")
    let owned = try OwnedBenchmarkDirectory(parent: "/private/tmp", prefix: "apfsfind-real-cache-")
    do {
      var volumes: [VolumeDescriptor] = [], indexes: [UUID: HybridIndex] = [:]
      for i in 0..<volumeCount {
        let root = fixture.path + "/volume-\(i)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
        let volume = VolumeDescriptor(volumeUUID: UUID(), displayName: "Volume \(i)", mountPath: root, isSystemVolume: i == 0)
        let identity = try VolumeIdentity.discover(root: root), ram = FileIndex(root: root)
        for offset in stride(from: 0, to: entries, by: 4096) {
          ram.apply((offset..<min(entries, offset + 4096)).map { .upsert(.init(path: root + "/needle-\($0).txt", kind: .file)) })
        }
        let store = try SnapshotStore(directory: owned.path, identity: identity)
        _ = try SnapshotV2Writer.write(source: .ram(ram, ram.stats().generation), identity: identity,
                                       generation: ram.stats().generation, cursor: 0, store: store)
        indexes[volume.volumeUUID] = HybridIndex(base: try store.reader(expectedIdentity: identity).mappedBase!)
        volumes.append(volume)
      }
      let mapped = indexes
      let coordinator = MultiVolumeCoordinator(provider: BenchmarkVolumeProvider(values: volumes),
        selectionStore: BenchmarkSelection(Set(volumes.map(\.volumeUUID))),
        factory: { volume, _ in MappedBenchmarkSession(volume: volume, index: mapped[volume.volumeUUID]!) })
      await coordinator.start()
      var samples: [Double] = [], last: MultiVolumeSearchResult?
      for i in 0..<35 {
        let result = await coordinator.search(.init(id: UInt64(i), query: "needle", limit: 50))
        if i >= 5 { samples.append(result.latencyMilliseconds) }; last = result
      }
      await coordinator.stop()
      let report: [String: Any] = ["synthetic": true, "entries_per_volume": entries, "volumes": volumeCount,
        "global_limit": 50, "results": last?.hits.count ?? 0, "query": "needle", "warmup": 5, "samples": 30,
        "latency_ms": benchmarkPercentiles(samples), "rss_bytes": Metrics.processUsage().residentBytes]
      let json = try benchmarkJSON(report); try fixture.remove(); try owned.remove(); return json
    } catch { try fixture.remove(); try owned.remove(); throw error }
  }
}
