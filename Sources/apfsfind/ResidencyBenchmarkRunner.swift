import APFSFindCore
import Foundation

/// Opens daily indexes read-only. Missing metadata is built only in owned scratch.
struct ResidencyBenchmarkRunner {
    let roots: [String]
    let cacheDirectory: String
    let idleSeconds: Double
    func run() throws -> Int32 {
        let scratch = try OwnedTemporaryDirectory(); defer { try? scratch.remove() }
        let cache = try ReadOnlyIndexCache(directory:cacheDirectory)
        var phases: [[String:Any]] = [], volumes: [[String:Any]] = []
        var indices: [HybridIndex] = [], sources: [MetadataIndexCoordinator] = []
        func phase(_ stage:String) { phases.append(["stage":stage,"process":ProcessResourceSample.capture().dictionary,
            "namespace":indices.map { $0.hybridStats() },"metadata":sources.map { $0.residencyStatistics() }]) }
        phase("process_start")
        for root in roots {
            let identity = try VolumeIdentity.discover(root:root), start = ProcessInfo.processInfo.systemUptime
            let base = try cache.mappedBase(identity:identity); phase("namespace_mmap_\(volumes.count)")
            let mapped: MMapMetadataIndex
            if let existing = try? cache.mappedMetadata(base:base.header) { mapped = existing }
            else {
                TerminalOutput.info("Residency benchmark builds missing metadata in owned scratch: \(root)")
                mapped = try buildMetadata(base:base,identity:identity,scratch:scratch.url.path)
            }
            phase("metadata_mmap_\(volumes.count)")
            let runtime = HybridIndex(base:base); indices.append(runtime); phase("namespace_runtime_\(volumes.count)")
            let meta = MetadataIndexCoordinator(); meta.bind(namespace:base,mapped:mapped); meta.advance(mapped.header.cursor,historyDone:true)
            sources.append(meta); runtime.setMetadataSource(meta); phase("metadata_runtime_\(volumes.count)")
            volumes.append(["root":root,"entries":base.count,"directories":base.directories,
                "namespace_bytes":base.mappedBytes,"metadata_bytes":mapped.header.fileLength,
                "search_ready_ms":(ProcessInfo.processInfo.systemUptime-start)*1000])
        }
        phase("base_ready")
        let before = ProcessResourceSample.capture()
        TerminalOutput.info("Residency idle measurement: \(idleSeconds) seconds")
        Thread.sleep(forTimeInterval:idleSeconds)
        let after = ProcessResourceSample.capture(); phase("hidden_read_only_idle")
        for i in 0..<30 {
            let sort = SearchSortDescriptor(key:SearchSortKey.allCases[i % SearchSortKey.allCases.count])
            for index in indices { _ = index.search(.init(query:"f",limit:51,sort:sort)) }
        }
        phase("after_30_broad_queries")
        let queries = metadataQueries(indices,exact:indices[0].mappedBase!.name(at:1))
        phase("after_query_benchmark")
        for (index,source) in zip(indices,sources) {
            index.hotDirectoryCache.setPressure(.critical,root:index.root)
            source.hotDirectoryCache.setPressure(.critical,root:index.root)
            _ = index.mappedBase?.reclaimPages(); _ = source.capture().base?.reclaimPages()
        }
        phase("after_reclaim_opportunity")
        let report:[String:Any] = ["benchmark":"residency-read-only","version":"0.6-component-walk",
            "daily_cache_modified":false,"scope":"read-only namespace cache plus matched metadata; no live replay; stale paths may be unknown",
            "volumes":volumes,"phases":phases,"idle":after.delta(since:before),"sort_queries":queries,
            "estimates":"application map/overlay byte estimates are separate from TASK_VM_INFO and rusage counters"]
        print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
        return 0
    }
    private func buildMetadata(base:MMapBaseIndex,identity:VolumeIdentity,scratch:String) throws -> MMapMetadataIndex {
        let meta = MetadataIndexCoordinator(); meta.bind(namespace:base); let lookup = meta.capture()
        let values = try MetadataBuildBuffer(count:base.count,directory:scratch)
        _ = try BulkScanner(root:identity.root,excludedRoots:[cacheDirectory,scratch]).scan(collectEntries:false,visit:{ entries in
            values.update(entries.compactMap { e in
                guard let id = lookup.ordinal(e.namespace.path) else { return nil }
                let r = base.record(at:id)
                guard r.kind == e.namespace.kind,r.fileID == (e.namespace.fileID ?? 0) else { return nil }
                return (Int(id),e.metadata)
            })
        })
        let store = try SnapshotStore(directory:scratch,identity:identity)
        _ = try MetadataWriter.write(store:store,base:base.header,cursor:identity.currentEventID(),value:{ values.value(Int($0)) })
        return try store.metadataReader(base:base.header)
    }
}
