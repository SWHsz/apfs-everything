import Foundation

public struct DeltaEntry: Sendable {
  public let id: UInt32
  public let entry: NamespaceEntry
  public let name: String
  public let foldedName: String
}
public struct HybridCapture: Sendable {
  public let base: MMapBaseIndex
  public let tombstones: [UInt64]
  public let delta: [UInt32: DeltaEntry]
  public let directories: [String: EntryRef]
  public let deltaChildren: [String: Set<UInt32>]
  public let generation: UInt64
  public func deleted(_ id: UInt32) -> Bool {
    tombstones[Int(id) / 64] & (1 << (Int(id) % 64)) != 0
  }
  public func item(_ ref: EntryRef) -> NamespaceEntry {
    switch ref {
    case .delta(let id): return delta[id]!.entry
    case .base(let id):
      let r = base.record(at: id)
      return .init(
        path: base.reconstructPath(id), kind: r.kind, deviceID: base.header.rootDeviceID,
        fileID: r.fileID == 0 ? nil : r.fileID, isMountPoint: r.flags != 0)
    }
  }
  public func name(_ ref: EntryRef) -> String {
    switch ref {
    case .base(let i): base.name(at: i)
    case .delta(let i): delta[i]!.name
    }
  }
  public func kind(_ ref: EntryRef) -> EntryKind {
    switch ref {
    case .base(let i): base.record(at: i).kind
    case .delta(let i): delta[i]!.entry.kind
    }
  }
  public func children(_ directory: EntryRef, path: String) -> [EntryRef] {
    var refs: [EntryRef] = []
    if case .base(let id) = directory {
      refs = base.directChildren(of: id).filter { !deleted($0) }.map { .base($0) }
    }
    refs += (deltaChildren[path] ?? []).compactMap { delta[$0] == nil ? nil : .delta($0) }
    return refs.sorted {
      let a = name($0)
      let b = name($1)
      return MMapBaseIndex.less(
        (FileEntry.fold(a), a, kind($0).snapshotCode), (FileEntry.fold(b), b, kind($1).snapshotCode)
      )
    }
  }
}
public struct CompactionPolicy: Sendable {
  public var liveLimit: Int = 50_000
  public var byteLimit: Int = 64 * 1024 * 1024
  public var tombstoneLimit: Int = 50_000
  public var tombstoneRatio: Double = 0.05
  public var overlayRatio: Double = 0.05
  public var quietSeconds: Double = 2
  public var safetyByteLimit: Int = 128 * 1024 * 1024
  public init() {}
}

/// Base records stay mapped. Only directories and changed paths are retained in
/// RAM. A cold/recovery build temporarily owns the reference index until mapped.
public final class HybridIndex: NamespaceIndex, @unchecked Sendable {
  public let root: String
  public let metrics = Metrics()
  private let lock = NSLock()
  private var bootstrap: FileIndex?
  private var base: MMapBaseIndex?
  private var words: [UInt64] = []
  private var delta: [UInt32: DeltaEntry] = [:]
  private var deltaPaths: [String: UInt32] = [:]
  private var deltaChildren: [String: Set<UInt32>] = [:]
  private var directoryPaths: [String: EntryRef] = [:]
  private var nextID: UInt32 = 0
  private var freeIDs: [UInt32] = []
  private var generation: UInt64 = 0
  private var files = 0, dirs = 0, dead = 0, overlayBytes = 0
  private var activeQueries = 0
  private var writerWaits: [Double] = []
  private var writerWaitSlot = 0
  private var writerWaitMaximum = 0.0
  private var lastMutation = ProcessInfo.processInfo.systemUptime
  public init(root: String) {
    self.root = root
    bootstrap = FileIndex(root: root)
  }
  public init(base: MMapBaseIndex) {
    root = base.root
    bootstrap = nil
    install(base: base)
  }
  public var mappedBase: MMapBaseIndex? { lock.withLock { base } }
  public var transientIndex: FileIndex? { lock.withLock { bootstrap } }
  public func install(
    base: MMapBaseIndex, directoryMap: [String: EntryRef]? = nil, generation: UInt64? = nil
  ) {
    let map = directoryMap ?? base.directoryMap()
    lock.withLock {
      self.base = base
      words = Array(repeating: 0, count: (base.count + 63) / 64)
      bootstrap = nil
      delta = [:]
      deltaPaths = [:]
      deltaChildren = [:]
      directoryPaths = map
      nextID = 0
      freeIDs = []
      dead = 0
      overlayBytes = 0
      files = base.files
      dirs = base.directories
      self.generation = generation ?? base.header.indexGeneration
    }
  }
  public func installSnapshot(_ replacement: any NamespaceIndex) {
    if let h = replacement as? HybridIndex, let c = h.capture() {
      install(base: c.base, directoryMap: c.directories)
    } else if let f = replacement as? FileIndex {
      lock.withLock {
        bootstrap = f
        base = nil
        generation = f.stats().generation
      }
    }
  }
  public func replace(with replacement: FileIndex) {
    lock.withLock {
      let old = bootstrap?.stats().generation ?? generation
      generation = max(old, replacement.stats().generation) + 1
      bootstrap = replacement
      base = nil
      words = []
      delta = [:]
      deltaPaths = [:]
      deltaChildren = [:]
      directoryPaths = [:]
      dead = 0
      overlayBytes = 0
    }
  }
  private func deleted(_ id: UInt32) -> Bool { words[Int(id) / 64] & (1 << (Int(id) % 64)) != 0 }
  private func reference(_ path: String) -> EntryRef? {
    if let id = deltaPaths[path] { return .delta(id) }
    if let ref = directoryPaths[path] { return ref }
    guard let b = base,
      case .base(let parent)? = directoryPaths[PathCanonicalizer.parent(of: path)],
      let id = b.lookupChild(parent: parent, name: String(path.split(separator: "/").last ?? "")),
      !deleted(id)
    else { return nil }
    return .base(id)
  }
  private func item(_ ref: EntryRef, path: String) -> NamespaceEntry {
    switch ref {
    case .delta(let id): return delta[id]!.entry
    case .base(let id):
      let b = base!
      let r = b.record(at: id)
      return .init(
        path: path, kind: r.kind, deviceID: b.header.rootDeviceID,
        fileID: r.fileID == 0 ? nil : r.fileID, isMountPoint: r.flags != 0)
    }
  }
  public func entry(at path: String) -> NamespaceEntry? {
    lock.withLock {
      if let b = bootstrap { return b.entry(at: path) }
      guard let r = reference(path) else { return nil }
      return item(r, path: path)
    }
  }
  public func children(of path: String) -> [NamespaceEntry] {
    lock.lock()
    if let b = bootstrap {
      lock.unlock()
      return b.children(of: path)
    }
    let mapped = base
    let ref = directoryPaths[path]
    let bitmap = words
    let changed = (deltaChildren[path] ?? []).compactMap { delta[$0]?.entry }
    lock.unlock()
    var result: [NamespaceEntry] = []
    if let b = mapped, case .base(let id)? = ref {
      for child in b.directChildren(of: id)
      where bitmap[Int(child) / 64] & (1 << (Int(child) % 64)) == 0 {
        let r = b.record(at: child)
        result.append(
          .init(
            path: (path == "/" ? "" : path) + "/" + b.name(at: child), kind: r.kind,
            deviceID: b.header.rootDeviceID, fileID: r.fileID == 0 ? nil : r.fileID,
            isMountPoint: r.flags != 0))
      }
    }
    result += changed
    return result.sorted { $0.path < $1.path }
  }
  @discardableResult private func remove(_ path: String) -> Bool {
    guard path != root else { return false }
    guard let ref = reference(path) else { return false }
    let old = item(ref, path: path)
    let isDir = old.kind == .directory
    if case .base(let id) = ref, let b = base {
      for i in b.subtreeRange(of: id) where !deleted(i) {
        words[Int(i) / 64] |= 1 << (Int(i) % 64)
        dead += 1
        let kind = b.record(at: i).kind
        if kind == .file { files -= 1 }
        if kind == .directory { dirs -= 1 }
      }
    }
    let removals =
      isDir
      ? delta.values.filter { PathCanonicalizer.isWithin($0.entry.path, root: path) }.map(\.id)
      : {
        if case .delta(let id) = ref { return [id] }
        return []
      }()
    for id in removals {
      guard let d = delta.removeValue(forKey: id) else { continue }
      freeIDs.append(id)
      deltaPaths.removeValue(forKey: d.entry.path)
      deltaChildren[PathCanonicalizer.parent(of: d.entry.path)]?.remove(id)
      if deltaChildren[PathCanonicalizer.parent(of: d.entry.path)]?.isEmpty == true {
        deltaChildren.removeValue(forKey: PathCanonicalizer.parent(of: d.entry.path))
      }
      overlayBytes -= estimate(d)
      if d.entry.kind == .file { files -= 1 }
      if d.entry.kind == .directory { dirs -= 1 }
    }
    if isDir {
      for key in directoryPaths.keys.filter({ PathCanonicalizer.isWithin($0, root: path) }) {
        directoryPaths.removeValue(forKey: key)
      }
    }
    return true
  }
  private func estimate(_ d: DeltaEntry) -> Int {
    192 + d.entry.path.utf8.count * 2 + d.name.utf8.count + d.foldedName.utf8.count
  }
  public func apply(_ mutations: [IndexMutation]) {
    let start = ProcessInfo.processInfo.systemUptime
    lock.lock()
    let waited = (ProcessInfo.processInfo.systemUptime - start) * 1000
    writerWaitMaximum = max(writerWaitMaximum, waited)
    if writerWaits.count < 4096 {
      writerWaits.append(waited)
    } else {
      writerWaits[writerWaitSlot] = waited
      writerWaitSlot = (writerWaitSlot + 1) % 4096
    }
    metrics.maximum("writer_lock_wait_us", Int(waited * 1000))
    defer { lock.unlock() }
    if let b = bootstrap {
      let old = b.stats().generation
      b.apply(mutations)
      if b.stats().generation != old { generation &+= 1 }
      return
    }
    guard !mutations.isEmpty else { return }
    if activeQueries > 0 {
      words = words.map { $0 }
      metrics.record("tombstone_cow_copies")
    }
    var changed = false
    for m in mutations {
      switch m {
      case .remove(let path): changed = remove(path) || changed
      case .upsert(let e):
        guard PathCanonicalizer.normalize(e.path) == e.path,
          PathCanonicalizer.isWithin(e.path, root: root)
        else { continue }
        if let r = reference(e.path), item(r, path: e.path) == e { continue }
        guard e.path == root || directoryPaths[PathCanonicalizer.parent(of: e.path)] != nil else {
          continue
        }
        _ = remove(e.path)
        let name = e.path == root ? "" : String(e.path.split(separator: "/").last!)
        let d = DeltaEntry(
          id: freeIDs.popLast() ?? nextID, entry: e, name: name, foldedName: FileEntry.fold(name))
        if d.id == nextID { nextID &+= 1 }
        delta[d.id] = d
        deltaPaths[e.path] = d.id
        deltaChildren[PathCanonicalizer.parent(of: e.path), default: []].insert(d.id)
        if e.kind == .directory {
          directoryPaths[e.path] = .delta(d.id)
          dirs += 1
        }
        if e.kind == .file { files += 1 }
        overlayBytes += estimate(d)
        changed = true
      }
    }
    if changed {
      generation &+= 1
      lastMutation = ProcessInfo.processInfo.systemUptime
      metrics.record("namespace_mutations")
    }
  }
  func ensureGeneration(atLeast value: UInt64) {
    lock.withLock { generation = max(generation, value) }
  }
  public func capture() -> HybridCapture? {
    lock.withLock {
      guard let b = base else { return nil }
      return .init(
        base: b, tombstones: words, delta: delta, directories: directoryPaths,
        deltaChildren: deltaChildren, generation: generation)
    }
  }
  public func stats() -> IndexStats {
    lock.withLock {
      if let b = bootstrap {
        let s = b.stats()
        return .init(
          totalEntries: s.totalEntries, liveEntries: s.liveEntries, tombstones: s.tombstones,
          files: s.files, directories: s.directories, generation: generation)
      }
      return .init(
        totalEntries: (base?.count ?? 0) + delta.count,
        liveEntries: (base?.count ?? 0) - dead + delta.count, tombstones: dead, files: files,
        directories: dirs, generation: generation)
    }
  }
  public func captureSnapshotMetadata() -> SnapshotExportMetadata {
    let s = stats()
    return .init(generation: s.generation, totalEntries: s.totalEntries, liveEntries: s.liveEntries)
  }
  public func snapshotEntries() -> [NamespaceEntry] {
    if let b = lock.withLock({ bootstrap }) { return b.snapshotEntries() }
    guard let c = capture() else { return [] }
    return (0..<c.base.count).compactMap { c.deleted(UInt32($0)) ? nil : c.item(.base(UInt32($0))) }
      + c.delta.values.map(\.entry)
  }
  public func snapshotPaths() -> Set<String> { Set(snapshotEntries().map(\.path)) }
  public func shouldCompact(_ policy: CompactionPolicy) -> Bool {
    lock.withLock {
      guard let b = base, dead > 0 || !delta.isEmpty else { return false }
      let trigger =
        delta.count >= policy.liveLimit || overlayBytes >= policy.byteLimit
        || dead >= policy.tombstoneLimit || Double(dead) / Double(b.count) >= policy.tombstoneRatio
        || Double(delta.count) / Double(b.count) >= policy.overlayRatio
      return overlayBytes >= policy.safetyByteLimit
        || (trigger && ProcessInfo.processInfo.systemUptime - lastMutation >= policy.quietSeconds)
    }
  }
  public func hybridStats() -> [String: Any] {
    lock.withLock {
      var v: [String: Any] = [
        "base_mapped_bytes": base?.mappedBytes ?? 0, "base_records": base?.count ?? 0,
        "base_directories": base?.directories ?? 0,
        "materialized_file_entries": bootstrap?.stats().files ?? 0,
        "base_materialized_file_entries": 0,
        "directory_map_entries": directoryPaths.count,
        "directory_map_estimated_bytes": directoryPaths.keys.reduce(0) { $0 + 80 + $1.utf8.count },
        "overlay_live_entries": delta.count,
        "overlay_deleted_entries": 0, "overlay_estimated_bytes": overlayBytes + freeIDs.count * 4,
        "base_tombstones": dead, "tombstone_bitmap_bytes": words.count * 8,
        "base_tombstone_ratio": Double(dead) / Double(max(1, base?.count ?? 1)),
        "hybrid_generation": generation,
      ]
      let waits = writerWaits.sorted()
      for (name, fraction) in [("p50", 0.5), ("p95", 0.95), ("p99", 0.99)] {
        v["writer_lock_wait_" + name + "_ms"] =
          waits.isEmpty
          ? 0 : waits[min(waits.count - 1, max(0, Int(ceil(Double(waits.count) * fraction)) - 1))]
      }
      v["writer_lock_wait_max_ms"] = writerWaitMaximum
      v["overlay_free_slots"] = freeIDs.count
      for (k, n) in metrics.snapshot() { v[k] = n }
      return v
    }
  }
  public func search(_ query: String, limit: Int = 50) -> SearchResult {
    let start = ProcessInfo.processInfo.systemUptime
    let q = FileEntry.fold(query)
    let bytes = Array(q.utf8)
    lock.lock()
    if let b = bootstrap {
      lock.unlock()
      return b.search(query, limit: limit)
    }
    guard let base else {
      lock.unlock()
      return .init(hits: [], latencyMilliseconds: 0, generation: generation)
    }
    let bitmap = words
    let live = Array(delta.values)
    let g = generation
    activeQueries += 1
    lock.unlock()
    defer { lock.withLock { activeQueries -= 1 } }
    let baseStart = ProcessInfo.processInfo.systemUptime
    let winners = base.searchBase(
      bytes, limit: max(0, limit), deleted: { bitmap[Int($0) / 64] & (1 << (Int($0) % 64)) != 0 })
    let baseMS = (ProcessInfo.processInfo.systemUptime - baseStart) * 1000
    let overlayStart = ProcessInfo.processInfo.systemUptime
    var extra: [(Int, String, EntryKind)] = []
    if !q.isEmpty, limit > 0 {
      let rootName = FileEntry.fold(root == "/" ? "/" : String(root.split(separator: "/").last!))
      if rootName.contains(q) {
        extra.append((rootName == q ? 0 : (rootName.hasPrefix(q) ? 1 : 2), root, .directory))
      }
      for d in live where d.foldedName.contains(q) {
        let candidate = (
          d.foldedName == q ? 0 : (d.foldedName.hasPrefix(q) ? 1 : 2), d.entry.path, d.entry.kind
        )
        func less(_ a: (Int, String, EntryKind), _ b: (Int, String, EntryKind)) -> Bool {
          a.0 == b.0 ? a.1 < b.1 : a.0 < b.0
        }
        if extra.count == limit, let last = extra.last, !less(candidate, last) { continue }
        var lo = 0
        var hi = extra.count
        while lo < hi {
          let mid = (lo + hi) / 2
          if less(candidate, extra[mid]) { hi = mid } else { lo = mid + 1 }
        }
        extra.insert(candidate, at: lo)
        if extra.count > limit { extra.removeLast() }
      }
      extra.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
    }
    let overlayMS = (ProcessInfo.processInfo.systemUptime - overlayStart) * 1000
    let pathStart = ProcessInfo.processInfo.systemUptime
    var all =
      winners.map { ($0.rank, base.reconstructPath($0.id), base.record(at: $0.id).kind) }
      + Array(extra.prefix(max(0, limit)))
    all.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
    var seen = Set<String>()
    let hits = all.filter { seen.insert($0.1).inserted }.prefix(max(0, limit)).map {
      SearchHit(path: $0.1, kind: $0.2)
    }
    metrics.set("query_base_records_scanned", to: bytes.isEmpty || limit <= 0 ? 0 : base.count - 1)
    metrics.set("query_delta_records_scanned", to: bytes.isEmpty || limit <= 0 ? 0 : live.count)
    metrics.set("query_base_scan_us", to: Int(baseMS * 1000))
    metrics.set("query_overlay_scan_us", to: Int(overlayMS * 1000))
    metrics.set(
      "query_path_reconstruction_us",
      to: Int((ProcessInfo.processInfo.systemUptime - pathStart) * 1_000_000))
    metrics.set("query_retries", to: 0)
    return .init(
      hits: hits, latencyMilliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000,
      generation: g)
  }
}
