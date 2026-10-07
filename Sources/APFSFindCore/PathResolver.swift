import Foundation

public enum MemoryPressureLevel: String, Sendable { case normal, warning, critical }
public struct PathResolutionVersion: Hashable, Sendable {
    public let baseUUID: UUID
    public let generation: UInt64
}

/// Only scalar refs are retained. Old captures cannot insert into a newer epoch.
public final class HotDirectoryCache: @unchecked Sendable {
    private struct Value { let ref: EntryRef; var previous: String?; var next: String? }
    private let lock = NSLock()
    private var entries: [String: Value] = [:]
    private var first: String?, last: String?
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
        guard let value = entries[path] else { return }
        if let p = value.previous { entries[p]?.next = value.next } else { first = value.next }
        if let n = value.next { entries[n]?.previous = value.previous } else { last = value.previous }
    }
    private func append(_ path:String,ref:EntryRef) {
        entries[path] = .init(ref:ref,previous:last,next:nil)
        if let last { entries[last]?.next = path } else { first = path }
        last = path
    }
    private func evict() {
        guard let path = first else { return }
        unlink(path); entries.removeValue(forKey:path); metrics.record("hot_directory_cache_evictions")
    }
    public func reset(version: PathResolutionVersion, root: String, ref: EntryRef = .base(0)) {
        lock.withLock { self.version = version; rootPath = root; rootRef = ref; entries = [:]; first = nil; last = nil; append(root,ref:ref) }
    }
    public func lookup(_ path: String, version: PathResolutionVersion) -> EntryRef? {
        lock.withLock {
            guard self.version == version, let value = entries[path] else { metrics.record("hot_directory_cache_misses"); return nil }
            unlink(path); append(path,ref:value.ref); metrics.record("hot_directory_cache_hits"); return value.ref
        }
    }
    public func insert(_ path: String, ref: EntryRef, version: PathResolutionVersion) {
        lock.withLock {
            guard self.version == version, pressure != .critical else { return }
            if entries[path] != nil { unlink(path) }
            else if entries.count >= capacity { evict() }
            append(path,ref:ref); metrics.record("hot_directory_cache_inserts")
        }
    }
    public func invalidate(prefix: String) {
        lock.withLock { for key in entries.keys.filter({ PathCanonicalizer.isWithin($0,root:prefix) }) { unlink(key); entries.removeValue(forKey:key) } }
    }
    public func setPressure(_ level: MemoryPressureLevel, root:String) {
        lock.withLock {
            pressure = level
            capacity = level == .normal ? configuredCapacity : (level == .warning ? max(1024,configuredCapacity/4) : 1)
            if level == .critical { entries = [:]; first = nil; last = nil; append(rootPath,ref:rootRef) }
            else { while entries.count > capacity { evict() } }
        }
    }
    public var statistics: [String:Int] {
        lock.withLock { ["hot_directory_cache_entries":entries.count,"hot_directory_cache_capacity":capacity,
            "hot_directory_cache_bytes":entries.keys.reduce(0) { $0+128+$1.utf8.count }] }
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
        !tombstones.isEmpty && tombstones[Int(id)/64] & (1 << (Int(id)%64)) != 0
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
    public func resolve(_ path:String) -> EntryRef? {
        metrics.record("path_resolver_calls")
        guard PathCanonicalizer.normalize(path) == path,PathCanonicalizer.isWithin(path,root:base.root) else { metrics.record("path_resolver_failures"); return nil }
        if path == base.root { return rootRef }
        if let hit = cache?.lookup(path,version:version) { return hit }
        var prefix = base.root, ref = rootRef
        if let cache {
            var parent = PathCanonicalizer.parent(of:path)
            while parent != base.root && PathCanonicalizer.isWithin(parent,root:base.root) {
                if let cached = cache.lookup(parent,version:version),kind(cached) == .directory {
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
        var children: [EntryRef] = []
        if case .base(let id) = ref { children = base.directChildren(of:id).filter { !deleted($0) }.map { .base($0) } }
        children += (overlayChildren[ref] ?? [:]).values.compactMap { delta[$0] == nil ? nil : .delta($0) }
        return children
    }
}
