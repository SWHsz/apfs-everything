import Foundation

public enum MemoryPressureLevel: String, Sendable { case normal, warning, critical }
public struct PathResolutionVersion: Hashable, Sendable {
    public let baseUUID: UUID
    public let generation: UInt64
    public init(baseUUID:UUID,generation:UInt64) {self.baseUUID=baseUUID;self.generation=generation}
}

/// Only scalar refs are retained. Old captures cannot insert into a newer epoch.
public final class HotDirectoryCache: @unchecked Sendable {
    private struct Value { let ref: EntryRef; var previous: String?; var next: String? }
    private final class Storage { var entries: [String: Value] = [:]; var first: String?, last: String? }
    private let lock = NSLock()
    private var storage = Storage()
    private var storageGeneration = 0, storageRebuilds = 0
    private var capacityBefore = 0, capacityAfter = 0, bytesBefore = 0, bytesAfter = 0
    private var version: PathResolutionVersion?
    private let configuredCapacity: Int
    private var capacity: Int
    private var rootPath = "", rootRef: EntryRef = .base(0)
    private var pressure: MemoryPressureLevel = .normal
    public let metrics: Metrics
    public init(capacity: Int = 8192, metrics: Metrics = Metrics()) {
        configuredCapacity = min(16384,max(1024,capacity)); self.capacity = configuredCapacity; self.metrics = metrics
    }
    private func unlink(_ path:String) {
        guard let value = storage.entries[path] else { return }
        if let p = value.previous { storage.entries[p]?.next = value.next } else { storage.first = value.next }
        if let n = value.next { storage.entries[n]?.previous = value.previous } else { storage.last = value.previous }
    }
    private func append(_ path:String,ref:EntryRef) {
        storage.entries[path] = .init(ref:ref,previous:storage.last,next:nil)
        if let last = storage.last { storage.entries[last]?.next = path } else { storage.first = path }
        storage.last = path
    }
    private func evict() {
        guard let path = storage.first else { return }
        unlink(path); storage.entries.removeValue(forKey:path); metrics.record("hot_directory_cache_evictions")
    }
    private func estimate() -> Int { storage.entries.keys.reduce(0) { $0+128+$1.utf8.count } }
    private func replaceStorage(keeping values:[(String,EntryRef)]) {
        capacityBefore = storage.entries.capacity; bytesBefore = estimate()
        let replacement = Storage(); replacement.entries.reserveCapacity(values.count)
        storage = replacement
        for (path,ref) in values { append(path,ref:ref) }
        storageGeneration &+= 1; storageRebuilds &+= 1
        capacityAfter = storage.entries.capacity; bytesAfter = estimate()
        metrics.record("hot_directory_cache_rebuilds")
    }
    public func reset(version: PathResolutionVersion, root: String, ref: EntryRef = .base(0)) {
        lock.withLock { self.version = version; rootPath = root; rootRef = ref; storage = Storage(); storageGeneration &+= 1; append(root,ref:ref) }
    }
    public func lookup(_ path: String, version: PathResolutionVersion) -> EntryRef? {
        lock.withLock {
            guard self.version == version, let value = storage.entries[path] else { metrics.record("hot_directory_cache_misses"); return nil }
            unlink(path); append(path,ref:value.ref); metrics.record("hot_directory_cache_hits"); return value.ref
        }
    }
    public func insert(_ path: String, ref: EntryRef, version: PathResolutionVersion) {
        lock.withLock {
            guard self.version == version, pressure != .critical else { return }
            if storage.entries[path] != nil { unlink(path) }
            else if storage.entries.count >= capacity { evict() }
            append(path,ref:ref); metrics.record("hot_directory_cache_inserts")
        }
    }
    public func invalidate(prefix: String) {
        lock.withLock { for key in storage.entries.keys.filter({ PathCanonicalizer.isWithin($0,root:prefix) }) { unlink(key); storage.entries.removeValue(forKey:key) } }
    }
    public func setPressure(_ level: MemoryPressureLevel, root:String) {
        lock.withLock {
            if rootPath.isEmpty { rootPath = root }
            pressure = level
            capacity = level == .normal ? configuredCapacity : (level == .warning ? min(configuredCapacity,2048) : 1)
            guard level != .normal else { return } // Grow only through subsequent accesses.
            if level == .critical { replaceStorage(keeping:[(rootPath,rootRef)]); return }
            var retained: [(String,EntryRef)] = [], path = storage.last
            while let current = path, retained.count < capacity, let value = storage.entries[current] {
                retained.append((current,value.ref)); path = value.previous
            }
            let discarded = storage.entries.count-retained.count
            replaceStorage(keeping:Array(retained.reversed()))
            metrics.record("hot_directory_cache_evictions",by:discarded)
        }
    }
    /// Tests can hold a weak reference to verify that replacement releases the old container.
    var storageForTesting: AnyObject { lock.withLock { storage } }
    public var statistics: [String:Int] {
        lock.withLock { ["hot_directory_cache_entries":storage.entries.count,"hot_directory_cache_capacity":capacity,
            "hot_directory_cache_storage_capacity":storage.entries.capacity,"hot_directory_cache_bytes":estimate(),
            "hot_directory_cache_storage_generation":storageGeneration,"hot_directory_cache_rebuilds":storageRebuilds,
            "hot_directory_cache_capacity_before":capacityBefore,"hot_directory_cache_capacity_after":capacityAfter,
            "hot_directory_cache_bytes_before":bytesBefore,"hot_directory_cache_bytes_after":bytesAfter] }
    }
}

public protocol NamespacePathResolving: Sendable {
    func resolve(_ canonicalPath: String) -> EntryRef?
    func resolveDirectory(_ canonicalPath: String) -> EntryRef?
    func entry(_ canonicalPath: String) -> NamespaceEntry?
    func children(of directory: EntryRef) -> [EntryRef]
}

/// Immutable COW view, pinned base and changed children only. Component lookups
/// use the mapped child table without building sibling arrays or full paths.
public struct PathResolverSnapshot: NamespacePathResolving, Sendable {
    public let base: MMapBaseIndex
    public let tombstones: [UInt64]
    public let delta: [UInt32:DeltaEntry]
    public let overlayChildren: [EntryRef:[String:UInt32]]
    public let rootRef: EntryRef
    public let version: PathResolutionVersion
    public let cache: HotDirectoryCache?
    public let metrics: Metrics
    public init(base:MMapBaseIndex,tombstones:[UInt64] = [],delta:[UInt32:DeltaEntry] = [:],
                overlayChildren:[EntryRef:[String:UInt32]] = [:],rootRef:EntryRef = .base(0),
                generation:UInt64 = 0,cache:HotDirectoryCache? = nil,metrics:Metrics = Metrics()) {
        self.base = base; self.tombstones = tombstones; self.delta = delta; self.overlayChildren = overlayChildren
        self.rootRef = rootRef; version = .init(baseUUID:base.header.snapshotUUID!,generation:generation)
        self.cache = cache; self.metrics = metrics
    }
    public func deleted(_ id:UInt32) -> Bool {
        Int(id) >= base.count || (!tombstones.isEmpty && (Int(id)/64 >= tombstones.count || tombstones[Int(id)/64] & (1 << (Int(id)%64)) != 0))
    }
    public func kind(_ ref:EntryRef) -> EntryKind? {
        switch ref { case .base(let id): return deleted(id) ? nil : base.record(at:id).kind
        case .delta(let id): return delta[id]?.entry.kind }
    }
    private func traversable(_ ref:EntryRef) -> Bool {
        guard kind(ref) == .directory else { return false }
        switch ref { case .base(let id): return base.record(at:id).flags == 0
        case .delta(let id): return delta[id]?.entry.isMountPoint == false && (delta[id]?.entry.deviceID == 0 || delta[id]?.entry.deviceID == base.header.rootDeviceID) }
    }
    public func child(parent:EntryRef,name:String) -> EntryRef? {
        guard traversable(parent) else { return nil }
        if let id = overlayChildren[parent]?[name],delta[id] != nil { metrics.record("path_resolver_overlay_hits"); return .delta(id) }
        guard case .base(let p) = parent else { return nil }
        metrics.record("path_resolver_base_child_lookups")
        guard let id = base.lookupChild(parent:p,name:name),!deleted(id) else { return nil }
        return .base(id)
    }
    private func validCached(_ ref:EntryRef,path:String)->Bool {
        switch ref {case .base(let id):return !deleted(id)
        case .delta(let id):return delta[id]?.entry.path == path}
    }
    public func resolve(_ path:String) -> EntryRef? {
        metrics.record("path_resolver_calls")
        guard PathCanonicalizer.normalize(path) == path,PathCanonicalizer.isWithin(path,root:base.root) else { metrics.record("path_resolver_failures"); return nil }
        if path == base.root { return rootRef }
        if let hit = cache?.lookup(path,version:version),validCached(hit,path:path) { return hit }
        var prefix = base.root, ref = rootRef
        if let cache {
            var parent = PathCanonicalizer.parent(of:path)
            while parent != base.root && PathCanonicalizer.isWithin(parent,root:base.root) {
                if let cached = cache.lookup(parent,version:version),kind(cached) == .directory,validCached(cached,path:parent) {
                    prefix = parent; ref = cached; break
                }
                parent = PathCanonicalizer.parent(of:parent)
            }
        }
        let relative = path.dropFirst(prefix == "/" ? 1 : prefix.count+1)
        for component in relative.split(separator:"/") {
            metrics.record("path_resolver_components")
            guard let next = child(parent:ref,name:String(component)) else { metrics.record("path_resolver_failures"); return nil }
            ref = next
        }
        if kind(ref) == .directory { cache?.insert(path,ref:ref,version:version) }
        return ref
    }
    public func resolveDirectory(_ path:String) -> EntryRef? {
        guard let ref = resolve(path),kind(ref) == .directory else { return nil }; return ref
    }
    public func entry(_ path:String) -> NamespaceEntry? {
        guard let ref = resolve(path) else { return nil }
        switch ref { case .delta(let id): return delta[id]?.entry
        case .base(let id): let r = base.record(at:id); return .init(path:path,kind:r.kind,deviceID:base.header.rootDeviceID,fileID:r.fileID == 0 ? nil : r.fileID,isMountPoint:r.flags != 0) }
    }
    public func children(of ref:EntryRef) -> [EntryRef] {
        guard traversable(ref) else { return [] }
        var children: [EntryRef] = []
        if case .base(let id) = ref { children = base.directChildren(of:id).filter { !deleted($0) }.map { .base($0) } }
        children += (overlayChildren[ref] ?? [:]).values.compactMap { delta[$0] == nil ? nil : .delta($0) }
        return children
    }
}
