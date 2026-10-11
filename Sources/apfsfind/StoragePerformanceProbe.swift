import APFSFindCore
import Foundation

enum StoragePerformanceProbe {
  static func run(_ args:[String]) throws -> Int32 {
    guard args.count == 3,["mmap","pread"].contains(args[2]) else {throw CLIError.usage("storage performance requires source root/cache/backing")}
    let identity = try VolumeIdentity.discover(root:args[0]),cache = try ReadOnlyIndexCache(directory:args[1]),pread = args[2] == "pread"
    let before = ProcessResourceSample.capture(),began = ProcessInfo.processInfo.systemUptime
    let base = try cache.immutableBase(identity:identity,usePRead:pread),meta = try cache.immutableMetadata(base:base.header,usePRead:pread)
    let loadMS = (ProcessInfo.processInfo.systemUptime-began)*1000
    let metadata = MetadataIndexCoordinator();metadata.bind(namespace:base,mapped:meta,cursor:meta.header.cursor)
    let hybrid = HybridIndex(base:base);hybrid.setMetadataSource(metadata)
    var records:[[String:Any]] = []
    for key in SearchSortKey.allCases {
      for query in ["netforensic","net","a"] {
        var times:[Double] = []
        var expected:[String]?
        for _ in 0..<5 {
          let result = hybrid.search(.init(query:query,limit:50,sort:.init(key:key)))
          if let error = result.storageError {throw error}
          if let expected,expected != result.hits.map(\.path) {throw SnapshotError.invalid("unstable storage query")}
          expected = result.hits.map(\.path);times.append(result.latencyMilliseconds)
        }
        records.append(["sort":key.rawValue,"query":query,"samples_ms":times,"p95_ms":times.sorted().last!,"hits":expected ?? []])
      }
    }
    try StorageRemovalProbe.emit(["backing":args[2],"source_volume_uuid":identity.volumeUUID.uuidString,
      "records":base.count,"namespace_bytes":base.header.fileLength,"metadata_bytes":meta.header.fileLength,
      "load_ms":loadMS,"measurements":records,"resources":ProcessResourceSample.capture().delta(since:before),
      "namespace_cache_bytes":(base as? PReadNamespaceIndex)?.cachedBytes ?? 0,"metadata_cache_bytes":(meta as? PReadMetadataIndex)?.cachedBytes ?? 0])
    return 0
  }
}
