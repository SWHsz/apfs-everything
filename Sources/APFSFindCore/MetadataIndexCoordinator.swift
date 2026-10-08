import CAPFSShim
import CoreServices
import Darwin
import Foundation

public struct MetadataOverlay: Sendable {
    public var baseOverrides: [UInt32: FileMetadataValue] = [:]
    public var deltaValues: [String: FileMetadataValue] = [:]
    public var deleted: Set<String> = []
    public var retainedRenameBytes: Int = 0
    public var renameCount: Int = 0
    public var generation: UInt64 = 0
    public var estimatedBytes: Int { retainedRenameBytes + baseOverrides.count * 64 + deltaValues.reduce(0) { $0 + 96 + $1.key.utf8.count } + deleted.reduce(0) { $0 + 48 + $1.utf8.count } }
    public var entryCount: Int { renameCount + baseOverrides.count + deltaValues.count + deleted.count }
}
public final class MetadataRenameSource: @unchecked Sendable {
    let originalPrefix: String
    let snapshot: MetadataQuerySnapshot
    let depth: Int
    init(originalPrefix:String,snapshot:MetadataQuerySnapshot) { self.originalPrefix = originalPrefix; self.snapshot = snapshot; depth = snapshot.maximumAliasDepth+1 }
}
public struct MetadataQuerySnapshot: Sendable {
    public let namespace: MMapBaseIndex?
    public let base: MMapMetadataIndex?
    public let overlay: MetadataOverlay
    public let freshness: MetadataFreshness
    let resolver: PathResolverSnapshot?
    let renamedDirectories: [String: MetadataRenameSource]
    public var maximumAliasDepth: Int { renamedDirectories.values.map(\.depth).max() ?? 0 }
    public var available: Bool { base != nil && base?.header.baseUUID == namespace?.header.snapshotUUID }
    public func ordinal(_ path: String) -> UInt32? {
        guard case .base(let id)? = resolver?.resolve(path) else { return nil }
        return id
    }
    public func value(at id: UInt32) -> FileMetadataValue { overlay.baseOverrides[id] ?? base?.value(at:id) ?? .unknown }
    public func value(path: String) -> FileMetadataValue {
        // Frozen rename captures may form a chain. Walk it without recursive
        // calls so repeated directory renames cannot exhaust the query stack.
        var snapshot = self, resolved = path
        for _ in 0...MetadataIndexCoordinator.maximumRenameAliasDepth {
            if snapshot.overlay.deleted.contains(resolved) { return .unknown }
            if let value = snapshot.overlay.deltaValues[resolved] { return value }
            if let prefix = snapshot.renamedDirectories.keys.filter({PathCanonicalizer.isWithin(resolved,root:$0)}).max(by:{$0.count < $1.count}),
               let source = snapshot.renamedDirectories[prefix] {
                resolved = source.originalPrefix + String(resolved.dropFirst(prefix.count))
                snapshot = source.snapshot
                continue
            }
            return snapshot.ordinal(resolved).map { snapshot.value(at:$0) } ?? .unknown
        }
        return .unknown // Defensive bound even for an injected malformed capture.
    }
}
public struct MetadataCheckpointPolicy: Sendable {
    public var entryLimit = 100_000
    public var byteLimit = 32 * 1024 * 1024
    public var quietSeconds: Double = 30
    public var minimumInterval: Double = 600
    public var safetyBytes = 256 * 1024 * 1024
    public init() {}
}

/// Owns read-only columns and changed values. Namespace records never acquire metadata fields.
public final class MetadataIndexCoordinator: @unchecked Sendable {
    public static let maximumRenameAliasDepth = 16
    public static let maximumRenameAliasCount = 64
    public static let maximumRetainedRenameBytes = 32*1024*1024
    private let lock = NSLock()
    private var namespace: MMapBaseIndex?
    private var base: MMapMetadataIndex?
    private var resolver: PathResolverSnapshot?
    public let hotDirectoryCache = HotDirectoryCache()
    private var overlay = MetadataOverlay()
    private var renamedDirectories: [String:MetadataRenameSource] = [:]
    private var freshness: MetadataFreshness = .unavailable
    private var cursor: UInt64 = 0
    private var floor: UInt64 = 0
    private var historyDone = false
    private var paused = false
    private var bootstrapPending = false
    private var overflowed = false
    private var overflowEpoch:UInt64 = 0
    private var safetyBytes = 0
    private var aliasPressure = false
    private let overlayByteLimit:Int
    private let overlayEntryLimit:Int
    public var renameNeedsMaintenance: Bool { lock.withLock { aliasPressure } }
    public var requiresRecovery: Bool { lock.withLock { overflowed } }
    var recoveryState:(overflowed:Bool,epoch:UInt64) {lock.withLock {(overflowed,overflowEpoch)}}
    public init() { overlayByteLimit = 128*1024*1024;overlayEntryLimit = 500_000 }
    // Smaller limits let tests exercise the same production boundary without
    // allocating a second large index under the sanitizers.
    init(overlayByteLimit:Int,overlayEntryLimit:Int) {
        self.overlayByteLimit = min(128*1024*1024,max(1,overlayByteLimit))
        self.overlayEntryLimit = min(500_000,max(1,overlayEntryLimit))
    }
    public func capture() -> MetadataQuerySnapshot {
        lock.withLock { .init(namespace:namespace,base:base,overlay:overlay,freshness:freshness,resolver:resolver,renamedDirectories:renamedDirectories) }
    }
    func baseDirectoryMatches(path:String,fileID:UInt64?) -> Bool {
        let snapshot = capture()
        guard let namespace = snapshot.namespace,case .base(let ordinal)? = snapshot.resolver?.resolveDirectory(path) else { return false }
        let record = namespace.record(at:ordinal)
        return record.kind == .directory && record.fileID == fileID && !snapshot.overlay.deleted.contains(path)
    }
    public func resourceUsage() -> (entries:Int,bytes:Int) { lock.withLock { (overlay.entryCount,safetyBytes+overlay.retainedRenameBytes) } }
    public func residencyStatistics() -> [String: Any] {
        lock.withLock { ["cache_storage":hotDirectoryCache.statistics,"metadata_directory_map_entries":0,
            "metadata_directory_map_estimated_bytes":0,
            "metadata_hot_directory_cache_entries":hotDirectoryCache.statistics["hot_directory_cache_entries",default:0],
            "metadata_hot_directory_cache_bytes":hotDirectoryCache.statistics["hot_directory_cache_bytes",default:0],
            "metadata_hot_directory_cache_capacity":hotDirectoryCache.statistics["hot_directory_cache_capacity",default:0],
            "metadata_hot_directory_cache_hits":hotDirectoryCache.metrics.snapshot()["hot_directory_cache_hits",default:0],
            "metadata_hot_directory_cache_misses":hotDirectoryCache.metrics.snapshot()["hot_directory_cache_misses",default:0],
            "metadata_overlay_entries":overlay.entryCount,"metadata_overlay_bytes":overlay.estimatedBytes,
            "metadata_overlay_accounted_bytes":safetyBytes+overlay.retainedRenameBytes,"metadata_overlay_overflowed":overflowed,
            "rename_alias_count":renamedDirectories.count,"rename_alias_bytes":overlay.retainedRenameBytes,"rename_alias_depth":renamedDirectories.values.map(\.depth).max() ?? 0,"rename_alias_cap_hits":aliasPressure ? 1 : 0] }
    }
    public var processedCursor: UInt64 { lock.withLock { cursor } }
    public var isReplaying: Bool { lock.withLock { !historyDone } }
    public func restartReplay() { lock.withLock { floor = cursor; historyDone = false; freshness = base == nil ? .building : .catchingUp } }
    public var replayFloor: UInt64 { lock.withLock { floor } }
    public var isDirty: Bool { lock.withLock { overflowed || bootstrapPending || overlay.entryCount > 0 || !renamedDirectories.isEmpty } }
    public func bind(namespace: MMapBaseIndex, mapped: MMapMetadataIndex? = nil, cursor: UInt64? = nil, retainOverlay: Bool = false) {
        let pathResolver = PathResolverSnapshot(base:namespace,cache:hotDirectoryCache)
        hotDirectoryCache.reset(version:pathResolver.version,root:namespace.root)
        lock.withLock {
            overflowed = false; aliasPressure = false; safetyBytes = 0; bootstrapPending = false
            self.namespace = namespace; resolver = pathResolver
            base = mapped?.header.matches(namespace.header) == true ? mapped : nil
            if !retainOverlay { overlay = .init(); renamedDirectories = [:] }
            else {safetyBytes = overlay.estimatedBytes-overlay.retainedRenameBytes}
            let c = cursor ?? mapped?.header.cursor ?? 0
            self.cursor = c; floor = c
            freshness = base == nil ? .building : .catchingUp
        }
    }
    public func beginBootstrap(fence: UInt64) { lock.withLock { bootstrapPending = true; floor = fence; if base == nil { cursor = fence }; freshness = .building } }
    public func install(_ mapped: MMapMetadataIndex, expectedGeneration: UInt64? = nil) throws {
        try lock.withLock {
            guard let namespace, mapped.header.matches(namespace.header) else { throw SnapshotError.generationChanged }
            base = mapped; bootstrapPending = false
            if expectedGeneration == overlay.generation { overlay.baseOverrides = [:]; overlay.deleted = []; safetyBytes = overlay.deltaValues.reduce(0) { $0+96+$1.key.utf8.count }; overlay.generation &+= 1 }
            freshness = paused ? .pausedStale : (historyDone ? .live : .catchingUp)
        }
    }
    public func update(path:String,value:FileMetadataValue?) {
        for _ in 0..<2 {
            let lookup = lock.withLock { resolver }
            let ordinal:UInt32?
            if case .base(let id)? = lookup?.resolve(path) { ordinal = id } else { ordinal = nil }
            let applied = lock.withLock {
                guard lookup?.base.header.snapshotUUID == namespace?.header.snapshotUUID else { return false }
                updateLocked(path:path,value:value,ordinal:ordinal); return true
            }
            if applied { return }
        }
    }
    private func updateLocked(path:String,value:FileMetadataValue?,ordinal:UInt32?) {
            guard !overflowed else { return }
            let old = overlay.deltaValues[path] ?? ordinal.map { overlay.baseOverrides[$0] ?? base?.value(at:$0) ?? .unknown } ?? .unknown
            if let value {
                if old == value && !overlay.deleted.contains(path) { return }
                let deletedBytes = overlay.deleted.contains(path) ? 48+path.utf8.count : 0
                let addedBytes = ordinal.map {overlay.baseOverrides[$0] == nil ? 64 : 0} ?? (overlay.deltaValues[path] == nil ? 96+path.utf8.count : 0)
                let addedEntries = addedBytes == 0 ? 0 : 1
                guard canGrow(bytes:addedBytes-deletedBytes,entries:addedEntries-(deletedBytes == 0 ? 0 : 1)) else {return}
                if overlay.deleted.remove(path) != nil {safetyBytes -= deletedBytes}
                if let ordinal { if overlay.baseOverrides[ordinal] == nil { safetyBytes += 64 }; overlay.baseOverrides[ordinal] = value }
                else { if overlay.deltaValues[path] == nil { safetyBytes += 96+path.utf8.count }; overlay.deltaValues[path] = value }
                overlay.generation &+= 1
            } else {
                if overlay.deleted.contains(path),overlay.deltaValues[path] == nil,renamedDirectories[path] == nil {return}
                let removedBytes = overlay.deltaValues[path] == nil ? 0 : 96+path.utf8.count
                let addedOverride = ordinal.map {overlay.baseOverrides[$0] == nil ? 64 : 0} ?? 0
                let addedDeletion = ordinal != nil && !overlay.deleted.contains(path) ? 48+path.utf8.count : 0
                guard canGrow(bytes:addedOverride+addedDeletion-removedBytes,
                              entries:(addedOverride == 0 ? 0 : 1)+(addedDeletion == 0 ? 0 : 1)-(removedBytes == 0 ? 0 : 1)) else {return}
                if let old = renamedDirectories.removeValue(forKey:path) {
                    overlay.retainedRenameBytes -= old.snapshot.overlay.estimatedBytes + 200
                    overlay.renameCount = renamedDirectories.count
                }
                let removed = overlay.deltaValues.removeValue(forKey:path)
                if removed != nil {safetyBytes -= removedBytes}
                guard ordinal != nil || removed != nil else { return }
                if let ordinal {safetyBytes += addedOverride+addedDeletion;overlay.deleted.insert(path);overlay.baseOverrides[ordinal] = .unknown}
                overlay.generation &+= 1
            }
    }
    private func canGrow(bytes:Int,entries:Int) -> Bool {
        guard safetyBytes+overlay.retainedRenameBytes+bytes <= overlayByteLimit,
              overlay.entryCount+entries <= overlayEntryLimit else {overflowed = true;overflowEpoch &+= 1;return false}
        return true
    }
    @discardableResult public func reuseDirectoryRename(original:String,destination:String,from snapshot:MetadataQuerySnapshot) -> Bool {
        lock.withLock {
            let bytes = snapshot.overlay.estimatedBytes + 200
            let oldBytes = renamedDirectories[destination].map { $0.snapshot.overlay.estimatedBytes+200 } ?? 0
            guard snapshot.maximumAliasDepth < Self.maximumRenameAliasDepth,
                  renamedDirectories.count + (renamedDirectories[destination] == nil ? 1 : 0) <= Self.maximumRenameAliasCount,
                  overlay.retainedRenameBytes-oldBytes+bytes <= Self.maximumRetainedRenameBytes else {
                aliasPressure = true; return false
            }
            renamedDirectories[destination] = MetadataRenameSource(originalPrefix:original,snapshot:snapshot)
            overlay.retainedRenameBytes += bytes-oldBytes
            overlay.renameCount = renamedDirectories.count; overlay.generation &+= 1
            return true
        }
    }
    public var hasUnpersistedPaths: Bool { lock.withLock { !overlay.deltaValues.isEmpty || !renamedDirectories.isEmpty } }
    public func markPending() { lock.withLock { if base != nil && !paused { freshness = .catchingUp } } }
    public func advance(_ id:UInt64, historyDone:Bool = false, pending:Bool = false) {
        lock.withLock {
            if !overflowed, id != UInt64.max { cursor = max(cursor,id) }
            self.historyDone = self.historyDone || historyDone
            if base != nil { freshness = paused ? .pausedStale : (self.historyDone && !pending ? .live : .catchingUp) }
        }
    }
    public func pause(_ enabled:Bool) { lock.withLock { paused = enabled; freshness = enabled ? .pausedStale : (base == nil ? .building : .catchingUp); if !enabled { historyDone = false } } }
    public func fail() { lock.withLock { base = nil; freshness = .failed } }
}
