import APFSFindCore
import Darwin
import Foundation

struct MetadataBenchmarkRunner {
    let entries:Int
    func run() throws -> Int32 {
        let tree = try OwnedTemporaryDirectory(), cache = try OwnedTemporaryDirectory()
        defer { try? tree.remove(); try? cache.remove() }
        let root = tree.url.path
        for i in 0..<100 { try FileManager.default.createDirectory(atPath:root+"/d\(i)",withIntermediateDirectories:false) }
        func path(_ i:Int)->String { root+"/d\(i%100)/file-"+String(format:"%07d",i) }
        func write(_ i:Int,_ size:Int) throws {
            let fd = open(path(i),O_WRONLY|O_CREAT|O_CLOEXEC,0o600)
            guard fd >= 0 else { throw CLIError.input(errno) }; defer { close(fd) }
            guard ftruncate(fd,off_t(size)) == 0 else { throw CLIError.input(errno) }
        }
        let preparation = ProcessInfo.processInfo.systemUptime
        for i in 0..<(entries-101) { try write(i,i%1024); if i % 100000 == 99999 { TerminalOutput.info("Metadata fixture: \(i+1) files") } }
        let fixtureMS = (ProcessInfo.processInfo.systemUptime-preparation)*1000
        var policy = CompactionPolicy(); policy.liveLimit = 1_000_000; policy.overlayRatio = 10000; policy.tombstoneRatio = 10000
        let c = try PersistentIndexCoordinator(root:root,cacheDirectory:cache.url.path,compactionPolicy:policy)
        defer { c.stop(policy:.fast) }
        let resources = ProcessResourceSample.capture(), start = ProcessInfo.processInfo.systemUptime
        try c.start { TerminalOutput.info($0) }; guard c.waitUntilLive(timeout:120),c.waitForMetadata(timeout:120) else { throw CLIError.startupFailed("metadata benchmark startup") }
        let buildMS = (ProcessInfo.processInfo.systemUptime-start)*1000, buildResources = ProcessResourceSample.capture().delta(since:resources)
        guard c.metadata.capture().base?.header.count == UInt64(entries) else { throw CLIError.startupFailed("metadata count mismatch") }
        TerminalOutput.info("Metadata cold build ready; sorting")
        let queryReport = metadataQueries([c.index as! HybridIndex],exact:"file-0000000")
        let initialNSGeneration = c.index.stats().generation
        let before = c.metrics.snapshot(), contentResources = ProcessResourceSample.capture()
        TerminalOutput.info("Metadata content storm: one file")
        for _ in 0..<10000 { try write(0,12345) }
        try wait(phase:"single-file content storm",diagnostics:{ c.stats().description }) { c.metadata.capture().value(path:path(0)).logicalSize == 12345 }
        let after = c.metrics.snapshot(), contentDelta = ProcessResourceSample.capture().delta(since:contentResources)
        var latency:[Double] = []
        for i in 0..<30 {
            let began = ProcessInfo.processInfo.systemUptime, size = 20000+i
            try write(0,size); try wait(phase:"single-file visibility",diagnostics:{ c.stats().description }) { c.metadata.capture().value(path:path(0)).logicalSize == UInt64(size) }
            latency.append((ProcessInfo.processInfo.systemUptime-began)*1000)
        }
        let manyBefore = c.metrics.snapshot(), manyResources = ProcessResourceSample.capture(), manyStart = ProcessInfo.processInfo.systemUptime
        let fileCount = min(10000,entries-101)
        TerminalOutput.info("Metadata content storm: \(fileCount) files")
        for i in 0..<fileCount { try write(i,30000+i) }
        try wait(timeout:120,phase:"many-file content storm",diagnostics:{ c.stats().description }) { (0..<fileCount).allSatisfy { c.metadata.capture().value(path:path($0)).logicalSize == UInt64(30000+$0) } }
        let manyAfter = c.metrics.snapshot(), manyMS = (ProcessInfo.processInfo.systemUptime-manyStart)*1000
        let manyDelta = ProcessResourceSample.capture().delta(since:manyResources)
        let contentNoNSWork = c.index.stats().generation == initialNSGeneration
        let bytes = c.metadata.capture().base!.header.fileLength
        c.stop(policy:.fast)
        try write(0,99999)
        let warm = try PersistentIndexCoordinator(root:root,cacheDirectory:cache.url.path,compactionPolicy:policy)
        defer { warm.stop(policy:.fast) }
        let warmResources = ProcessResourceSample.capture(), warmStart = ProcessInfo.processInfo.systemUptime
        TerminalOutput.info("Metadata fast-exit replay")
        try warm.start { TerminalOutput.info($0) }; guard warm.waitUntilLive(timeout:120),warm.waitForMetadata(timeout:120) else { throw CLIError.startupFailed("metadata warm startup") }
        try wait(timeout:120,phase:"fast-exit metadata replay",diagnostics:{warm.stats().description}) { warm.metadata.capture().value(path:path(0)).logicalSize == 99999 }
        let replayMS = (ProcessInfo.processInfo.systemUptime-warmStart)*1000, warmDelta = ProcessResourceSample.capture().delta(since:warmResources)
        let fresh = try BulkScanner(root:root).readScannedDirectory(root+"/d0",rootDeviceID:try BulkScanner(root:root).rootDeviceID()).first { $0.namespace.path == path(0) }?.metadata
        let consistent = fresh == warm.metadata.capture().value(path:path(0))
        let lookups = after["metadata_lookups",default:0]-before["metadata_lookups",default:0]
        let report:[String:Any] = [
            "benchmark":"metadata","version":"0.5.0","entries":entries,"fixture_preparation_ms":fixtureMS,
            "bulk_build_ms":buildMS,"bulk_build_resources":buildResources,"metadata_bytes":bytes,
            "metadata_bytes_per_entry":Double(bytes)/Double(entries),"sort_queries":queryReport,
            "single_file_10000_writes":["lookup_count":lookups,"namespace_generation_unchanged":contentNoNSWork,
                "events":after["metadata_events_received",default:0]-before["metadata_events_received",default:0],
                "deduplicated":after["metadata_events_deduplicated",default:0]-before["metadata_events_deduplicated",default:0],
                "resources":contentDelta],
            "metadata_visibility_ms":benchmarkPercentiles(latency),
            "many_files_modified":["files":fileCount,"converge_ms":manyMS,
                "events":manyAfter["metadata_events_received",default:0]-manyBefore["metadata_events_received",default:0],
                "deduplicated":manyAfter["metadata_events_deduplicated",default:0]-manyBefore["metadata_events_deduplicated",default:0],
                "lookups":manyAfter["metadata_lookups",default:0]-manyBefore["metadata_lookups",default:0],
                "parent_microbatches":manyAfter["metadata_parent_microbatches",default:0]-manyBefore["metadata_parent_microbatches",default:0],
                "parent_enumerations":manyAfter["metadata_parent_bulk_enumerations",default:0]-manyBefore["metadata_parent_bulk_enumerations",default:0],
                "resources":manyDelta],
            "restart_replay_ms":replayMS,"restart_resources":warmDelta,
            "restart_matches_fresh_scan":consistent,"warm_full_namespace_scans":warm.metrics.snapshot()["full_scans",default:0],
            "policy":"raised namespace compaction thresholds; metadata production thresholds unchanged"
        ]
        print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
        return consistent && contentNoNSWork && lookups <= 5 ? 0 : 1
    }
    private func wait(timeout:Double = 20,phase:String,diagnostics:()->String,_ condition:()->Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime+timeout
        while !condition() { guard ProcessInfo.processInfo.systemUptime<deadline else { throw CLIError.startupFailed("metadata workload failed to converge: \(phase)\n\(diagnostics())") }; Thread.sleep(forTimeInterval:0.001) }
    }
}

/// Only opens existing daily namespace snapshots read-only. Sidecars are built in an owned scratch cache.
struct RealMetadataBenchmarkRunner {
    let roots:[String]
    let cacheDirectory:String
    func run() throws -> Int32 {
        let scratch = try OwnedTemporaryDirectory(); defer { try? scratch.remove() }
        let dailyCache = try ReadOnlyIndexCache(directory:cacheDirectory)
        var runtimes:[HybridIndex] = [], buildReports:[[String:Any]] = []
        for root in roots {
            let identity = try VolumeIdentity.discover(root:root)
            let base = try dailyCache.mappedBase(identity:identity)
            TerminalOutput.info("Read-only metadata benchmark: \(root), \(base.count) records")
            let meta = MetadataIndexCoordinator(); meta.bind(namespace:base)
            let lookup = meta.capture(), values = try MetadataBuildBuffer(count:base.count,directory:scratch.url.path)
            let start = ProcessInfo.processInfo.systemUptime, resources = ProcessResourceSample.capture()
            _ = try BulkScanner(root:root,excludedRoots:[cacheDirectory,scratch.url.path]).scan(collectEntries:false,visit:{ entries in
                values.update(entries.compactMap { e in
                    guard let ordinal = lookup.ordinal(e.namespace.path) else { return nil }
                    let record = base.record(at:ordinal)
                    guard record.kind == e.namespace.kind,record.fileID == (e.namespace.fileID ?? 0) else { return nil }
                    return (Int(ordinal),e.metadata)
                })
            })
            let store = try SnapshotStore(directory:scratch.url.path,identity:identity)
            let header = try MetadataWriter.write(store:store,base:base.header,cursor:identity.currentEventID(),value:{values.value(Int($0))})
            meta.bind(namespace:base,mapped:try store.metadataReader(base:base.header)); meta.advance(header.cursor,historyDone:true)
            let runtime = HybridIndex(base:base); runtime.setMetadataSource(meta); runtimes.append(runtime)
            buildReports.append(["root":root,"entries":base.count,"metadata_bytes":header.fileLength,
                "bytes_per_entry":Double(header.fileLength)/Double(base.count),"build_ms":(ProcessInfo.processInfo.systemUptime-start)*1000,
                "resources":ProcessResourceSample.capture().delta(since:resources),"unknown_size_records":values.unknownSizes])
        }
        let first = runtimes[0].mappedBase!, exact = first.count > 1 ? first.name(at:1) : "unlikely"
        let report:[String:Any] = ["benchmark":"metadata-real-read-only","daily_cache_modified":false,
            "volumes":buildReports,"entries":runtimes.reduce(0) { $0+($1.mappedBase?.count ?? 0) },
            "sort_queries":metadataQueries(runtimes,exact:exact),"scope":"fresh metadata mapped to existing snapshot ordinals; cache may contain stale paths; no replay of daily namespace"]
        print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self)); return 0
    }
}
private final class QueryBatch: @unchecked Sendable {
    private let lock = NSLock(); private var hits:[SearchHit] = []
    func append(_ result:SearchResult) { lock.withLock { hits += result.hits } }
    func sorted(_ sort:SearchSortDescriptor)->[SearchHit] { lock.withLock { Array(hits.sorted { SearchOrdering.less($0,$1,sort:sort) }.prefix(50)) } }
}
func metadataQueries(_ indices:[HybridIndex],exact:String)->[String:Any] {
    var reports:[String:Any] = [:]
    for key in SearchSortKey.allCases {
        let directions:[SortDirection] = key == .relevance ? [.ascending] : [.ascending,.descending]
        for direction in directions {
            let order = SearchSortDescriptor(key:key,direction:direction)
            var categories:[String:Any] = [:]
            for (category,query) in [("exact",exact),("substring","ile"),("one_character","f"),("no_result","apfsfind-absent-"+UUID().uuidString)] {
                var samples:[Double] = []
                for _ in 0..<20 {
                    let began = ProcessInfo.processInfo.systemUptime, group = DispatchGroup(), results = QueryBatch()
                    for index in indices {
                        group.enter(); DispatchQueue.global(qos:.userInitiated).async { results.append(index.search(.init(query:query,limit:51,sort:order))); group.leave() }
                    }
                    group.wait(); _ = results.sorted(order); samples.append((ProcessInfo.processInfo.systemUptime-began)*1000)
                }
                var result = benchmarkPercentiles(samples)
                result["records_scanned"] = Double(indices.reduce(0) { $0+($1.metrics.snapshot()["query_base_records_scanned",default:0]) })
                result["metadata_values_read"] = Double(indices.reduce(0) { $0+($1.metrics.snapshot()["query_metadata_values_read",default:0]) })
                categories[category] = result
            }
            reports[key.rawValue+"_"+direction.rawValue] = categories
        }
    }
    return reports
}
