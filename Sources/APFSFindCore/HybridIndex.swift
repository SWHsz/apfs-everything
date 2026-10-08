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
  public let deltaChildren: [EntryRef: [String: UInt32]]
  public let hotDirectoryCache: HotDirectoryCache
  public let metrics: Metrics
  public var resolver: PathResolverSnapshot { .init(base:base,tombstones:tombstones,delta:delta,overlayChildren:deltaChildren,generation:generation,cache:hotDirectoryCache,metrics:metrics) }
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
    refs += (deltaChildren[directory] ?? [:]).values.compactMap { delta[$0] == nil ? nil : .delta($0) }
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

/// Base records stay mapped. Only changed paths and bounded hot directories
/// remain in RAM. Cold/recovery builds temporarily own the reference index.
public final class HybridIndex: NamespaceIndex, @unchecked Sendable {
  public let root: String
  public let metrics = Metrics()
  private let lock = NSLock()
  private var metadataSource: MetadataIndexCoordinator?
  public func setMetadataSource(_ source: MetadataIndexCoordinator) { lock.withLock { metadataSource = source } }
  private var bootstrap: FileIndex?
  private var base: MMapBaseIndex?
  private var words: [UInt64] = []
  private var delta: [UInt32: DeltaEntry] = [:]
  private var deltaPaths: [String: UInt32] = [:]
  private var deltaChildren: [EntryRef: [String:UInt32]] = [:]
  private var deltaParents: [UInt32:EntryRef] = [:]
  public let hotDirectoryCache = HotDirectoryCache()
  private var nextID: UInt32 = 0
  private var freeIDs: [UInt32] = []
  private var generation: UInt64 = 0
  private var files = 0, dirs = 0, dead = 0, overlayBytes = 0
  private let maximumOverlayEntries: Int
  private let maximumOverlayBytes: Int
  private var overflowed = false
  public var requiresRecovery: Bool { lock.withLock { overflowed } }
  private var activeQueries = 0
  private var writerWaits: [Double] = []
  private var writerWaitSlot = 0
  private var writerWaitMaximum = 0.0
  private var lastMutation = ProcessInfo.processInfo.systemUptime
  public init(root: String, maximumOverlayEntries:Int = 500_000, maximumOverlayBytes:Int = 128*1024*1024) {
    self.maximumOverlayEntries = maximumOverlayEntries; self.maximumOverlayBytes = maximumOverlayBytes
    self.root = root
    bootstrap = FileIndex(root: root)
  }
  public init(base: MMapBaseIndex, maximumOverlayEntries:Int = 500_000, maximumOverlayBytes:Int = 128*1024*1024) {
    self.maximumOverlayEntries = maximumOverlayEntries; self.maximumOverlayBytes = maximumOverlayBytes
    root = base.root
    bootstrap = nil
    install(base: base)
  }
  public var mappedBase: MMapBaseIndex? { lock.withLock { base } }
  public func resetWriterWaitMeasurements() {
    lock.withLock {
      writerWaits.removeAll(keepingCapacity: true); writerWaitSlot = 0; writerWaitMaximum = 0
      metrics.set("writer_lock_wait_us", to: 0)
    }
  }
  public var transientIndex: FileIndex? { lock.withLock { bootstrap } }
  public func install(
    base: MMapBaseIndex, directoryMap: [String: EntryRef]? = nil, generation: UInt64? = nil
  ) {
    lock.withLock {
      overflowed = false
    self.base = base
      words = Array(repeating: 0, count: (base.count + 63) / 64)
      bootstrap = nil
      delta = [:]
      deltaPaths = [:]
      deltaChildren = [:]
      deltaParents = [:]
      hotDirectoryCache.reset(version:.init(baseUUID:base.header.snapshotUUID!,generation:generation ?? base.header.indexGeneration),root:root)
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
      install(base: c.base)
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
      overflowed = false
      let old = bootstrap?.stats().generation ?? generation
      generation = max(old, replacement.stats().generation) + 1
      bootstrap = replacement
      base = nil
      words = []
      delta = [:]
      deltaPaths = [:]
      deltaChildren = [:]
      deltaParents = [:]
      dead = 0
      overlayBytes = 0
    }
  }
  private func deleted(_ id: UInt32) -> Bool { words[Int(id) / 64] & (1 << (Int(id) % 64)) != 0 }
  private func reference(_ path: String) -> EntryRef? {
    guard let base else { return nil }
    return PathResolverSnapshot(base:base,tombstones:words,delta:delta,overlayChildren:deltaChildren,
        generation:generation,cache:hotDirectoryCache,metrics:metrics).resolve(path)
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
    guard let canonical = PathCanonicalizer.normalize(path) else { return nil }
    // Borrow only the immutable mapping. Holding an overlay capture here forces
    // large COW copies during concurrent updates; walking paths while holding
    // the writer lock instead can delay replay behind metadata readers.
    let capturedBase = lock.withLock { base }
    let candidate = capturedBase.flatMap {
      PathResolverSnapshot(base:$0,metrics:metrics).resolve(canonical)
    }
    return lock.withLock {
      if let bootstrap { return bootstrap.entry(at:canonical) }
      guard base === capturedBase else {
        // Rare publication race: resolve against the newly installed mapping.
        guard let ref = reference(canonical) else { return nil }
        return item(ref,path:canonical)
      }
      // Every live overlay entry is keyed by its exact canonical path. Directory
      // removal/replacement clears attached delta descendants and tombstones
      // its whole immutable subtree, so checking these scalar results is enough.
      if let id = deltaPaths[canonical],let entry = delta[id] { return entry.entry }
      guard case .base(let id)? = candidate,!deleted(id) else { return nil }
      return item(.base(id),path:canonical)
    }
  }
  public func childCount(of path:String) -> Int? {
    guard let captured = capture(),let ref = captured.resolver.resolveDirectory(path) else { return nil }
    // A conservative sibling count is used only to choose bulk vs sparse I/O.
    let original: Int
    if case .base(let id) = ref { original = Int(captured.base.record(at:id).childCount) } else { original = 0 }
    return original+(captured.deltaChildren[ref]?.count ?? 0)
  }
  public func children(of path: String) -> [NamespaceEntry] {
    if let bootstrap = lock.withLock({bootstrap}) { return bootstrap.children(of:path) }
    guard let captured = capture(),let ref = captured.resolver.resolveDirectory(path) else { return [] }
    // Reconciliation needs canonical path order, not search/ranking order.
    // Sorting the same siblings by folded name first performs thousands of
    // unnecessary Unicode folds per parent under ASan and query pressure.
    return captured.resolver.children(of:ref).map { child in
      switch child {
      case .delta(let id): return captured.delta[id]!.entry
      case .base(let id): let r = captured.base.record(at:id)
        return .init(path:(path == "/" ? "" : path)+"/"+captured.base.name(at:id),kind:r.kind,
          deviceID:captured.base.header.rootDeviceID,fileID:r.fileID == 0 ? nil : r.fileID,isMountPoint:r.flags != 0)
      }
    }.sorted { $0.path < $1.path }
  }
  @discardableResult private func remove(_ path: String) -> Bool {
    guard path != root else { return false }
    guard let ref = reference(path) else { return false }
    let old = item(ref, path: path)
    let isDir = old.kind == .directory
    var removals:[UInt32]=[]
    if case .base(let id) = ref, let b = base {
      let range=b.subtreeRange(of:id)
      if range.count > 100_000 { overflowed = true; metrics.record("overlay_large_subtree_recovery"); return false }
      for i in range {
        // Delta descendants can attach to any immutable directory in this range.
        // Follow existing adjacency links, never filter unrelated overlay paths.
        if isDir {removals.append(contentsOf:deltaChildren[.base(i)]?.values.map{$0} ?? [])}
        if deleted(i) {continue}
        words[Int(i) / 64] |= 1 << (Int(i) % 64)
        dead += 1
        let kind = b.record(at: i).kind
        if kind == .file { files -= 1 }
        if kind == .directory { dirs -= 1 }
      }
    } else if case .delta(let id)=ref {removals.append(id)}
    var position=0
    while position<removals.count {
      let id=removals[position];position+=1
      removals.append(contentsOf:deltaChildren[.delta(id)]?.values.map{$0} ?? [])
    }
    metrics.record("overlay_delete_descendants_visited",by:removals.count)
    for id in removals {
      guard let d = delta.removeValue(forKey: id) else { continue }
      freeIDs.append(id)
      deltaPaths.removeValue(forKey: d.entry.path)
      if let parent = deltaParents.removeValue(forKey:id) {
        deltaChildren[parent]?.removeValue(forKey:d.name)
        if deltaChildren[parent]?.isEmpty == true { deltaChildren.removeValue(forKey:parent) }
      }
      deltaChildren.removeValue(forKey:.delta(id))
      overlayBytes -= estimate(d)
      if d.entry.kind == .file { files -= 1 }
      if d.entry.kind == .directory { dirs -= 1 }
    }
    // Cached refs are checked against this capture's tombstones/delta identities.
    // The completed batch replaces the cache epoch once, instead of scanning
    // all cached paths for every removed directory.
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
      if overflowed { continue }
      if delta.count >= maximumOverlayEntries || overlayBytes >= maximumOverlayBytes { overflowed = true; metrics.record("overlay_safety_stops"); continue }
      switch m {
      case .remove(let path): changed = remove(path) || changed
      case .upsert(let e):
        guard PathCanonicalizer.normalize(e.path) == e.path,
          PathCanonicalizer.isWithin(e.path, root: root)
        else { continue }
        if let r = reference(e.path), item(r, path: e.path) == e { continue }
        guard e.path != root, let parent = reference(PathCanonicalizer.parent(of:e.path)), item(parent,path:PathCanonicalizer.parent(of:e.path)).kind == .directory else { continue }
        let parentEntry = item(parent,path:PathCanonicalizer.parent(of:e.path))
        guard !parentEntry.isMountPoint, parentEntry.deviceID == 0 || parentEntry.deviceID == base?.header.rootDeviceID else { continue }
        if overlayBytes + 192 + e.path.utf8.count*2 + e.path.split(separator:"/").last!.utf8.count + FileEntry.fold(String(e.path.split(separator:"/").last!)).utf8.count > maximumOverlayBytes { overflowed = true; metrics.record("overlay_safety_stops"); continue }
        _ = remove(e.path)
        if overflowed { continue }
        let name = e.path == root ? "" : String(e.path.split(separator: "/").last!)
        let d = DeltaEntry(
          id: freeIDs.popLast() ?? nextID, entry: e, name: name, foldedName: FileEntry.fold(name))
        if d.id == nextID { nextID &+= 1 }
        delta[d.id] = d
        deltaPaths[e.path] = d.id
        deltaChildren[parent, default: [:]][name] = d.id
        deltaParents[d.id] = parent
        if e.kind == .directory {
          dirs += 1
        }
        if e.kind == .file { files += 1 }
        overlayBytes += estimate(d)
        changed = true
      }
    }
    if changed {
      generation &+= 1
      if let base { hotDirectoryCache.reset(version:.init(baseUUID:base.header.snapshotUUID!,generation:generation),root:root) }
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
        base: b, tombstones: words, delta: delta, deltaChildren: deltaChildren, hotDirectoryCache:hotDirectoryCache, metrics:metrics, generation: generation)
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
  public func compactionTrigger(_ policy: CompactionPolicy) -> (threshold: Bool, safety: Bool) {
    var immediate = policy; immediate.quietSeconds = 0
    let threshold = shouldCompact(immediate)
    let safety = lock.withLock { overlayBytes >= policy.safetyByteLimit }
    return (threshold, safety)
  }
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
  public func resourcePressure() -> InternalResourcePressure {
    lock.withLock { var result = InternalResourcePressure(); result.namespaceEntries = delta.count; result.namespaceBytes = overlayBytes; result.tombstones = dead; result.tombstoneRatio = Double(dead)/Double(max(1,base?.count ?? 1)); return result }
  }
  public func hybridStats() -> [String: Any] {
    lock.withLock {
      var v: [String: Any] = [
        "base_mapped_bytes": base?.mappedBytes ?? 0, "base_records": base?.count ?? 0,
        "base_directories": base?.directories ?? 0,
        "materialized_file_entries": bootstrap?.stats().files ?? 0,
        "base_materialized_file_entries": 0,
        "directory_map_entries": 0,
        "directory_map_estimated_bytes": 0,
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
      for (k,n) in hotDirectoryCache.statistics { v[k] = n }
      for (k,n) in hotDirectoryCache.metrics.snapshot() { v[k] = n }
      for (k, n) in metrics.snapshot() { v[k] = n }
      return v
    }
  }
  public func search(_ query: String, limit: Int = 50) -> SearchResult {
    return search(.init(query: query, limit: limit))
  }
  public func search(_ request: SearchRequest) -> SearchResult {
    InteractiveActivityController.shared.beginQuery()
    defer { InteractiveActivityController.shared.endQuery() }
    metrics.record("search_requests")
    let start = ProcessInfo.processInfo.systemUptime
    let limit = request.limit
    let q = FileEntry.fold(request.query)
    let bytes = Array(q.utf8)
    lock.lock()
    if let b = bootstrap {
      lock.unlock()
      return b.search(request)
    }
    guard let base else {
      lock.unlock()
      return .init(hits: [], latencyMilliseconds: 0, generation: generation)
    }
    let metadataCapture = metadataSource?.capture()
    let metadata = metadataCapture?.namespace?.header.snapshotUUID == base.header.snapshotUUID ? metadataCapture : nil
    let bitmap = words
    let live = Array(delta.values)
    let g = generation
    activeQueries += 1
    lock.unlock()
    defer { lock.withLock { activeQueries -= 1 } }
    let baseStart = ProcessInfo.processInfo.systemUptime
    var scanned = 0, metadataReads = 0
    let winners = base.searchBase(
      bytes, limit: max(0, limit), cancellation: request.cancellation, scanned: { scanned = $0 }, sort: request.sort, metadata: { metadataReads += 1; return metadata?.value(at:$0) ?? .unknown }, deleted: { bitmap[Int($0) / 64] & (1 << (Int($0) % 64)) != 0 })
    let baseMS = (ProcessInfo.processInfo.systemUptime - baseStart) * 1000
    let overlayStart = ProcessInfo.processInfo.systemUptime
    let fresh = metadata?.freshness ?? .unavailable
    func hit(_ path:String,_ kind:EntryKind,_ rank:Int,_ value:FileMetadataValue) -> SearchHit {
      .init(path:path,kind:kind,matchRank:MatchRank(rawValue:rank)!,logicalSize:value.logicalSize,
        modificationTimeNanoseconds:value.modificationTimeNanoseconds,metadataFreshness:fresh)
    }
    var extra = BoundedTopK<SearchHit>(limit:limit) { SearchOrdering.less($0,$1,sort:request.sort) }
    if !q.isEmpty, limit > 0 {
      let rootName = FileEntry.fold(root == "/" ? "/" : String(root.split(separator:"/").last!))
      if rootName.contains(q) { metadataReads += 1; extra.insert(hit(root,.directory,rootName == q ? 0 : (rootName.hasPrefix(q) ? 1 : 2),metadata?.value(at:0) ?? .unknown)) }
      for (ordinal,d) in live.enumerated() {
        if ordinal % 4096 == 0, request.cancellation.isCancelled { break }
        guard d.foldedName.contains(q) else { continue }
        metadataReads += 1
        extra.insert(hit(d.entry.path,d.entry.kind,d.foldedName == q ? 0 : (d.foldedName.hasPrefix(q) ? 1 : 2),metadata?.value(path:d.entry.path) ?? .unknown))
      }
    }
    let overlayMS = (ProcessInfo.processInfo.systemUptime-overlayStart)*1000
    let pathStart = ProcessInfo.processInfo.systemUptime
    var all = winners.map { candidate in
      if !request.sort.key.requiresMetadata { metadataReads += 1 }
      return hit(base.reconstructPath(candidate.id),base.record(at:candidate.id).kind,candidate.rank,
      request.sort.key.requiresMetadata ? candidate.metadata : (metadata?.value(at:candidate.id) ?? .unknown)) } + extra.sorted()
    all.sort { SearchOrdering.less($0,$1,sort:request.sort) }
    var seen = Set<String>()
    let hits = Array(all.filter { seen.insert($0.path).inserted }.prefix(max(0,limit)))
    metrics.set("query_metadata_values_read",to:metadataReads)
    metrics.set("query_base_records_scanned", to: scanned)
    if request.cancellation.isCancelled {
      metrics.record("search_cancelled")
      metrics.set("search_records_scanned_before_cancel", to: scanned)
    } else { metrics.maximum("search_latest_completed_id", Int(clamping: request.id)) }
    metrics.set("query_delta_records_scanned", to: bytes.isEmpty || limit <= 0 ? 0 : live.count)
    metrics.set("query_base_scan_us", to: Int(baseMS * 1000))
    metrics.set("query_overlay_scan_us", to: Int(overlayMS * 1000))
    metrics.set(
      "query_path_reconstruction_us",
      to: Int((ProcessInfo.processInfo.systemUptime - pathStart) * 1_000_000))
    metrics.set("query_retries", to: 0)
    return .init(
      hits: hits, latencyMilliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000,
      generation: g, cancelled: request.cancellation.isCancelled)
  }
}
