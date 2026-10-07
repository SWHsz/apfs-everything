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
    init(originalPrefix:String,snapshot:MetadataQuerySnapshot) { self.originalPrefix = originalPrefix; self.snapshot = snapshot }
}
public struct MetadataQuerySnapshot: Sendable {
    public let namespace: MMapBaseIndex?
    public let base: MMapMetadataIndex?
    public let overlay: MetadataOverlay
    public let freshness: MetadataFreshness
    let directories: [String: UInt32]
    let renamedDirectories: [String: MetadataRenameSource]
    public var available: Bool { base != nil && base?.header.baseUUID == namespace?.header.snapshotUUID }
    public func ordinal(_ path: String) -> UInt32? {
        guard let namespace else { return nil }
        if path == namespace.root { return 0 }
        guard let parent = directories[PathCanonicalizer.parent(of:path)] else { return nil }
        return namespace.lookupChild(parent:parent,name:(path as NSString).lastPathComponent)
    }
    public func value(at id: UInt32) -> FileMetadataValue { overlay.baseOverrides[id] ?? base?.value(at:id) ?? .unknown }
    public func value(path: String) -> FileMetadataValue {
        // Frozen rename captures may form a chain. Walk it without recursive
        // calls so repeated directory renames cannot exhaust the query stack.
        var snapshot = self, resolved = path
        while true {
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
    private let lock = NSLock()
    private var namespace: MMapBaseIndex?
    private var base: MMapMetadataIndex?
    private var directories: [String: UInt32] = [:]
    private var overlay = MetadataOverlay()
    private var renamedDirectories: [String:MetadataRenameSource] = [:]
    private var freshness: MetadataFreshness = .unavailable
    private var cursor: UInt64 = 0
    private var floor: UInt64 = 0
    private var historyDone = false
    private var paused = false
    public init() {}
    public func capture() -> MetadataQuerySnapshot {
        lock.withLock { .init(namespace:namespace,base:base,overlay:overlay,freshness:freshness,directories:directories,renamedDirectories:renamedDirectories) }
    }
    func baseDirectoryMatches(path:String,fileID:UInt64?) -> Bool {
        lock.withLock {
            guard let namespace,let ordinal = directories[path] else { return false }
            let record = namespace.record(at:ordinal)
            return record.kind == .directory && record.fileID == fileID && !overlay.deleted.contains(path)
        }
    }
    public var processedCursor: UInt64 { lock.withLock { cursor } }
    public var isReplaying: Bool { lock.withLock { !historyDone } }
    public func restartReplay() { lock.withLock { floor = cursor; historyDone = false; freshness = base == nil ? .building : .catchingUp } }
    public var replayFloor: UInt64 { lock.withLock { floor } }
    public var isDirty: Bool { lock.withLock { overlay.entryCount > 0 || !renamedDirectories.isEmpty } }
    public func bind(namespace: MMapBaseIndex, mapped: MMapMetadataIndex? = nil, cursor: UInt64? = nil, retainOverlay: Bool = false) {
        let dirs = namespace.directoryMap().compactMapValues { ref -> UInt32? in if case .base(let id) = ref { return id }; return nil }
        lock.withLock {
            self.namespace = namespace; directories = dirs
            base = mapped?.header.matches(namespace.header) == true ? mapped : nil
            if !retainOverlay { overlay = .init(); renamedDirectories = [:] }
            let c = cursor ?? mapped?.header.cursor ?? 0
            self.cursor = c; floor = c
            freshness = base == nil ? .building : .catchingUp
        }
    }
    public func beginBootstrap(fence: UInt64) { lock.withLock { base = nil; overlay = .init(); renamedDirectories = [:]; floor = fence; cursor = fence; freshness = .building } }
    public func install(_ mapped: MMapMetadataIndex, expectedGeneration: UInt64? = nil) throws {
        try lock.withLock {
            guard let namespace, mapped.header.matches(namespace.header) else { throw SnapshotError.generationChanged }
            base = mapped
            if expectedGeneration == overlay.generation { overlay.baseOverrides = [:]; overlay.deleted = []; overlay.generation &+= 1 }
            freshness = paused ? .pausedStale : (historyDone ? .live : .catchingUp)
        }
    }
    public func update(path:String,value:FileMetadataValue?) {
        lock.withLock {
            let ordinal:UInt32?
            if path == namespace?.root { ordinal = 0 }
            else if let namespace, let parent = directories[PathCanonicalizer.parent(of:path)] {
                ordinal = namespace.lookupChild(parent:parent,name:(path as NSString).lastPathComponent)
            } else { ordinal = nil }
            let old = overlay.deltaValues[path] ?? ordinal.map { overlay.baseOverrides[$0] ?? base?.value(at:$0) ?? .unknown } ?? .unknown
            if let value {
                if old == value && !overlay.deleted.contains(path) { return }
                overlay.deleted.remove(path)
                if let ordinal { overlay.baseOverrides[ordinal] = value }
                else { overlay.deltaValues[path] = value }
                overlay.generation &+= 1
            } else {
                if let old = renamedDirectories.removeValue(forKey:path) {
                    overlay.retainedRenameBytes -= old.snapshot.overlay.estimatedBytes + 200
                    overlay.renameCount = renamedDirectories.count
                }
                let removed = overlay.deltaValues.removeValue(forKey:path)
                guard ordinal != nil || removed != nil else { return }
                if let ordinal { overlay.deleted.insert(path); overlay.baseOverrides[ordinal] = .unknown }
                overlay.generation &+= 1
            }
        }
    }
    public func reuseDirectoryRename(original:String,destination:String,from snapshot:MetadataQuerySnapshot) {
        lock.withLock {
            if let old = renamedDirectories[destination] { overlay.retainedRenameBytes -= old.snapshot.overlay.estimatedBytes + 200 }
            renamedDirectories[destination] = MetadataRenameSource(originalPrefix:original,snapshot:snapshot)
            overlay.retainedRenameBytes += snapshot.overlay.estimatedBytes + 200
            overlay.renameCount = renamedDirectories.count
            overlay.generation &+= 1
        }
    }
    public var hasUnpersistedPaths: Bool { lock.withLock { !overlay.deltaValues.isEmpty || !renamedDirectories.isEmpty } }
    public func markPending() { lock.withLock { if base != nil && !paused { freshness = .catchingUp } } }
    public func advance(_ id:UInt64, historyDone:Bool = false, pending:Bool = false) {
        lock.withLock {
            if id != UInt64.max { cursor = max(cursor,id) }
            self.historyDone = self.historyDone || historyDone
            if base != nil { freshness = paused ? .pausedStale : (self.historyDone && !pending ? .live : .catchingUp) }
        }
    }
    public func pause(_ enabled:Bool) { lock.withLock { paused = enabled; freshness = enabled ? .pausedStale : (base == nil ? .building : .catchingUp); if !enabled { historyDone = false } } }
    public func fail() { lock.withLock { base = nil; freshness = .failed } }
}
