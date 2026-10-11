// Isolated removal experiment: the parent owns the image and captures signals.
// This helper never opens a source file's contents or installs a SIGBUS handler.
import APFSFindCore
import Darwin
import Foundation

func emit(_ value: [String: Any]) throws {
  let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  FileHandle.standardOutput.write(bytes + Data([10]))
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3 else { exit(2) }
let identity = try VolumeIdentity.discover(root: arguments[1])
let store = try SnapshotStore(directory: arguments[2], identity: identity)
if arguments[0] == "prepare" {
  let index = FileIndex(root: identity.root)
  for i in 0..<65_536 {
    index.apply([.upsert(.init(path: identity.root + "/probe-file-\(i)", kind: .file))])
  }
  let generation = index.stats().generation
  _ = try SnapshotV2Writer.write(source: .ram(index, generation), identity: identity,
    generation: generation, cursor: identity.currentEventID(), store: store)
  let base = try store.reader(expectedIdentity: identity).mappedBase!
  _ = try MetadataWriter.write(store: store, base: base.header, cursor: identity.currentEventID(),
    value: { ordinal in .init(logicalSize: UInt64(ordinal), modificationTimeNanoseconds: Int64(ordinal)) })
  try emit(["prepared": true, "namespace_records": base.count])
} else if arguments[0] == "pread" {
  let namespace = try PReadBacking(fileDescriptor: open(store.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW))
  let metadata = try PReadBacking(fileDescriptor: open(store.metadataPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW))
  try emit(["ready": true, "mode": "pread", "cache_limit_per_file": namespace.maximumCacheBytes])
  do {
    while true {
      namespace.reclaimPages(); metadata.reclaimPages()
      for backing in [namespace, metadata] {
        for offset in stride(from: 0, to: backing.length, by: 65_536) {
          _ = try backing.read(offset: offset, count: min(65_536, backing.length - offset))
        }
      }
      try emit(["pread_pass": true, "cached_bytes": namespace.cachedBytes + metadata.cachedBytes])
    }
  } catch {
    try emit(["structured_io_error": String(describing: error)])
    namespace.close(); metadata.close()
  }
} else if arguments[0] == "query" {
  let base = try store.reader(expectedIdentity: identity).mappedBase!
  let metadata = try store.metadataReader(base: base.header)
  try emit(["ready": true, "namespace_records": base.count, "metadata_records": metadata.header.count])
  while true {
    autoreleasepool {
      _ = base.reclaimPages(); _ = metadata.reclaimPages()
      let hits = base.searchBase(Array("probe-file".utf8), limit: 50,
        sort: .init(key: .size), metadata: { metadata.value(at: $0) }, deleted: { _ in false })
      try? emit(["query_hits": hits.count, "metadata_known": hits.allSatisfy { $0.metadata.logicalSize != nil }])
    }
    Thread.sleep(forTimeInterval: 0.02)
  }
} else { exit(2) }
