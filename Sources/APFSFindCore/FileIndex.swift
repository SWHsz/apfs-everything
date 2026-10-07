import Dispatch
import Foundation

/// One writer applies batches while independent query threads hold a read lock.
/// Paths and tombstones deliberately use straightforward storage in Sprint 1.
public final class FileIndex: @unchecked Sendable {
    public let root: String
    private let lock = RWLock()

    private struct Storage {
        var entries = ContiguousArray<FileEntry>()
        // Includes tombstones, permitting stable IDs when a path reappears.
        var pathToID: [String: Int32] = [:]
        var directoryToID: [String: Int32] = [:]
        var childrenByParent: [Int32: Set<Int32>] = [:]
        var liveEntries = 0
        var files = 0
        var directories = 0
        var tombstones = 0
        var generation: UInt64 = 0
    }

    private var storage = Storage()

    public init(root: String) {
        precondition(PathCanonicalizer.normalize(root) != nil, "Index root must be an absolute path")
        self.root = PathCanonicalizer.normalize(root)!
        _ = upsert(NamespaceEntry(path: self.root, kind: .directory))
    }

    /// All operations in a batch share one write critical section.
    public func apply(_ mutations: [IndexMutation]) {
        guard !mutations.isEmpty else { return }
        lock.withWriteLock {
            var changed = false
            for mutation in mutations {
                switch mutation {
                case .upsert(let entry):
                    guard let path = PathCanonicalizer.normalize(entry.path),
                          PathCanonicalizer.isWithin(path, root: root) else { continue }
                    var normalized = entry
                    normalized.path = path
                    changed = upsert(normalized) || changed
                case .remove(let rawPath):
                    guard let path = PathCanonicalizer.normalize(rawPath),
                          PathCanonicalizer.isWithin(path, root: root),
                          let id = storage.pathToID[path] else { continue }
                    changed = tombstoneSubtree(id) || changed
                }
            }
            if changed { storage.generation &+= 1 }
        }
    }

    /// Transfers a completed rebuild without copying the index or doing I/O under a lock.
    /// The donor receives the previous storage and should be discarded by the caller.
    public func replace(with replacement: FileIndex) {
        exchange(with: replacement, advanceGeneration: true)
    }

    /// Initial publication of a validated snapshot retains its durable G.
    /// Rebuild exchanges still advance G so active exports cannot survive them.
    internal func installSnapshot(_ replacement: FileIndex) {
        exchange(with: replacement, advanceGeneration: false)
    }

    private func exchange(with replacement: FileIndex, advanceGeneration: Bool) {
        guard replacement !== self else { return }
        precondition(replacement.root == root, "Replacement index must use the same scan root")
        let selfAddress = UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())
        let otherAddress = UInt(bitPattern: Unmanaged.passUnretained(replacement).toOpaque())
        let first = selfAddress < otherAddress ? self : replacement
        let second = selfAddress < otherAddress ? replacement : self
        first.lock.withWriteLock {
            second.lock.withWriteLock {
                let nextGeneration = advanceGeneration ? max(storage.generation, replacement.storage.generation) &+ 1 :
                    replacement.storage.generation
                swap(&storage, &replacement.storage)
                storage.generation = nextGeneration
            }
        }
    }

    func metadataSeed(_ entries: [ScannedEntry],directory:String) throws -> MetadataBuildBuffer {
        try lock.withReadLock {
            let values = try MetadataBuildBuffer(count:storage.entries.count,directory:directory)
            for entry in entries { if let id = storage.pathToID[entry.namespace.path] { values.update(entry.metadata,at:Int(id)) } }
            return values
        }
    }
    func entryID(at path: String) -> Int32? { lock.withReadLock { storage.pathToID[path] } }

    public func entry(at path: String) -> NamespaceEntry? {
        guard let path = PathCanonicalizer.normalize(path) else { return nil }
        return lock.withReadLock {
            guard let id = storage.pathToID[path] else { return nil }
            let entry = storage.entries[Int(id)]
            return entry.isDeleted ? nil : entry.namespaceEntry
        }
    }

    public func children(of path: String) -> [NamespaceEntry] {
        guard let path = PathCanonicalizer.normalize(path) else { return [] }
        return lock.withReadLock {
            guard let id = storage.directoryToID[path] else { return [] }
            return (storage.childrenByParent[id] ?? []).compactMap { childID in
                let child = storage.entries[Int(childID)]
                return child.isDeleted ? nil : child.namespaceEntry
            }.sorted { $0.path < $1.path }
        }
    }

    public func snapshotEntries() -> [NamespaceEntry] {
        lock.withReadLock {
            storage.entries.compactMap { $0.isDeleted ? nil : $0.namespaceEntry }
        }
    }

    public func snapshotPaths() -> Set<String> {
        lock.withReadLock {
            Set(storage.entries.lazy.filter { !$0.isDeleted }.map(\.path))
        }
    }

    public func stats() -> IndexStats {
        lock.withReadLock {
            IndexStats(totalEntries: storage.entries.count, liveEntries: storage.liveEntries,
                       tombstones: storage.tombstones, files: storage.files,
                       directories: storage.directories, generation: storage.generation)
        }
    }

    public func captureSnapshotMetadata() -> SnapshotExportMetadata {
        lock.withReadLock {
            .init(generation: storage.generation, totalEntries: storage.entries.count, liveEntries: storage.liveEntries)
        }
    }

    /// Canonical DFS order uses only IDs. Each directory is visited under a
    /// separate read lock; no full paths/Strings are copied for an export plan.
    public func snapshotExportOrder(expectedGeneration: UInt64, cancellation: CancellationToken = .init()) throws -> [Int32] {
        var result: [Int32] = [], pending: [Int32] = [0]
        let metadata = captureSnapshotMetadata()
        guard metadata.generation == expectedGeneration else { throw SnapshotError.generationChanged }
        result.reserveCapacity(metadata.liveEntries)
        while let id = pending.popLast() {
            guard !cancellation.isCancelled else { throw SnapshotError.cancelled }
            let children: [Int32] = try lock.withReadLock {
                guard storage.generation == expectedGeneration else { throw SnapshotError.generationChanged }
                guard Int(id) < storage.entries.count, !storage.entries[Int(id)].isDeleted else {
                    throw SnapshotError.invalid("deleted root/ancestor")
                }
                return (storage.childrenByParent[id] ?? []).filter { !storage.entries[Int($0)].isDeleted }.sorted {
                    storage.entries[Int($0)].name.utf8.lexicographicallyPrecedes(storage.entries[Int($1)].name.utf8)
                }
            }
            result.append(id); pending.append(contentsOf: children.reversed())
        }
        return result
    }

    public func exportLiveChunk(ids: ArraySlice<Int32>, expectedGeneration: UInt64,
                                rootDeviceID: UInt64) throws -> [SnapshotExportEntry] {
        try lock.withReadLock {
            guard storage.generation == expectedGeneration else { throw SnapshotError.generationChanged }
            return try ids.map { id in
                guard id >= 0, Int(id) < storage.entries.count, !storage.entries[Int(id)].isDeleted else {
                    throw SnapshotError.invalid("export ID is not live")
                }
                let entry = storage.entries[Int(id)]
                return .init(id: id, parentID: entry.parentID, name: entry.name, kind: entry.kind,
                    fileID: entry.fileID, isBoundary: entry.isMountPoint || (entry.deviceID != 0 && entry.deviceID != rootDeviceID))
            }
        }
    }

    func exportTreeChildren(_ id:Int32,generation:UInt64) throws->[Int32] {
        try lock.withReadLock {
            guard storage.generation==generation else{throw SnapshotError.generationChanged}
            return (storage.childrenByParent[id] ?? []).filter{!storage.entries[Int($0)].isDeleted}.sorted {
                let a=storage.entries[Int($0)],b=storage.entries[Int($1)]
                return MMapBaseIndex.less((a.foldedName,a.name,a.kind.snapshotCode),(b.foldedName,b.name,b.kind.snapshotCode))
            }
        }
    }
    /// The reader has already validated parent-before-child and basename bytes.
    /// Build all runtime maps once, without apply/upsert/normalization recursion.
    public static func restore(from reader: SnapshotReader, cancellation: CancellationToken = .init()) throws -> FileIndex {
        let index = FileIndex(root: reader.root)
        var restored = Storage()
        let count = Int(reader.header.recordCount)
        restored.entries.reserveCapacity(count)
        restored.pathToID.reserveCapacity(count)
        restored.directoryToID.reserveCapacity(count / 8)
        restored.childrenByParent.reserveCapacity(count / 8)
        for ordinal in 0..<count {
            if ordinal % 4096 == 0, cancellation.isCancelled { throw SnapshotError.cancelled }
            let record = reader.record(at: ordinal)
            let name = ordinal == 0 ? (reader.root == "/" ? "/" : String(reader.root.split(separator: "/").last!)) : reader.name(at: ordinal)
            let parentID = ordinal == 0 ? Int32(-1) : Int32(record.parentID)
            let parentPath = ordinal == 0 ? "" : restored.entries[Int(parentID)].path
            let path = ordinal == 0 ? reader.root : (parentPath == "/" ? "/" : parentPath + "/") + name
            guard path.utf8.count < 4096, restored.pathToID[path] == nil else {
                throw SnapshotError.invalid("duplicate or overlong restored path")
            }
            let id = Int32(ordinal)
            restored.entries.append(FileEntry(id: id, parentID: parentID, name: name,
                foldedName: FileEntry.fold(name), kind: record.kind, isDeleted: false, path: path,
                deviceID: reader.header.rootDeviceID, fileID: record.fileID == 0 ? nil : record.fileID,
                isMountPoint: record.flags & 1 != 0))
            restored.pathToID[path] = id
            if record.kind == .directory { restored.directoryToID[path] = id; restored.directories += 1 }
            if record.kind == .file { restored.files += 1 }
            if parentID >= 0 { restored.childrenByParent[parentID, default: []].insert(id) }
        }
        restored.liveEntries = count
        restored.generation = reader.header.indexGeneration
        index.storage = restored
        return index
    }

    /// A linear filename substring scan with bounded result storage.
    public func search(_ query: String, limit: Int = 50) -> SearchResult {
        return search(.init(query: query, limit: limit))
    }
    public func search(_ request: SearchRequest) -> SearchResult { search(request,metadata:{ _ in .unknown }) }
    public func search(_ request: SearchRequest, metadata:(String)->FileMetadataValue) -> SearchResult {
        let start = DispatchTime.now().uptimeNanoseconds
        let foldedQuery = FileEntry.fold(request.query)
        let limit = request.limit
        return lock.withReadLock {
            let limit = max(0, limit)
            var ranked = BoundedTopK<SearchHit>(limit:limit) { SearchOrdering.less($0,$1,sort:request.sort) }
            if !foldedQuery.isEmpty, limit > 0 {
                for (ordinal, entry) in storage.entries.enumerated() {
                    if ordinal % 4096 == 0, request.cancellation.isCancelled { break }
                    guard !entry.isDeleted && entry.foldedName.contains(foldedQuery) else { continue }
                    let rank = entry.foldedName == foldedQuery ? 0 : (entry.foldedName.hasPrefix(foldedQuery) ? 1 : 2)
                    let value = metadata(entry.path)
                    ranked.insert(SearchHit(path:entry.path,kind:entry.kind,matchRank:MatchRank(rawValue:rank)!,logicalSize:entry.kind == .file ? value.logicalSize : nil,modificationTimeNanoseconds:value.modificationTimeNanoseconds))
                }
            }
            return SearchResult(hits:ranked.sorted(),latencyMilliseconds:Double(DispatchTime.now().uptimeNanoseconds-start)/1_000_000,
                generation:storage.generation,cancelled:request.cancellation.isCancelled)
        }
    }

    private func precedes(_ lhs: (rank: Int, path: String, kind: EntryKind),
                          _ rhs: (rank: Int, path: String, kind: EntryKind)) -> Bool {
        SearchOrdering.less(lhs.rank, lhs.path, rhs.rank, rhs.path)
    }

    /// Inserts missing ancestors before the child, including parents discovered out of order.
    private func ensureParent(for entry: NamespaceEntry) -> Int32 {
        if entry.path == root { return -1 }
        let parent = PathCanonicalizer.parent(of: entry.path)
        if let id = storage.directoryToID[parent] { return id }
        _ = upsert(NamespaceEntry(path: parent, kind: .directory, deviceID: entry.deviceID))
        return storage.directoryToID[parent]!
    }

    @discardableResult
    private func upsert(_ entry: NamespaceEntry) -> Bool {
        let parentID = ensureParent(for: entry)
        if let id = storage.pathToID[entry.path] {
            let existing = storage.entries[Int(id)]
            guard existing.isDeleted || existing.namespaceEntry != entry else { return false }
            let directoryReplaced = existing.kind == .directory && entry.kind == .directory &&
                !existing.namespaceEntry.hasSameDirectoryIdentity(as: entry)
            if existing.kind == .directory, entry.kind != .directory || directoryReplaced {
                for childID in storage.childrenByParent[id] ?? [] {
                    _ = tombstoneSubtree(childID)
                }
            }
            if !existing.isDeleted { decrementLive(existing.kind) }
            else { storage.tombstones -= 1 }
            storage.directoryToID.removeValue(forKey: entry.path)
            storage.entries[Int(id)] = makeEntry(entry, id: id, parentID: parentID)
            incrementLive(entry.kind)
            if entry.kind == .directory { storage.directoryToID[entry.path] = id }
            if parentID >= 0 { storage.childrenByParent[parentID, default: []].insert(id) }
            return true
        }
        precondition(storage.entries.count < Int(Int32.max), "Index exceeds Sprint 1 entry ID capacity")
        let id = Int32(storage.entries.count)
        storage.entries.append(makeEntry(entry, id: id, parentID: parentID))
        storage.pathToID[entry.path] = id
        if entry.kind == .directory { storage.directoryToID[entry.path] = id }
        if parentID >= 0 { storage.childrenByParent[parentID, default: []].insert(id) }
        incrementLive(entry.kind)
        return true
    }

    private func makeEntry(_ entry: NamespaceEntry, id: Int32, parentID: Int32) -> FileEntry {
        let name = entry.path == "/" ? "/" : String(entry.path.split(separator: "/").last!)
        return FileEntry(id: id, parentID: parentID, name: name, foldedName: FileEntry.fold(name),
                         kind: entry.kind, isDeleted: false, path: entry.path,
                         deviceID: entry.deviceID, fileID: entry.fileID, isMountPoint: entry.isMountPoint)
    }

    @discardableResult
    private func tombstoneSubtree(_ id: Int32) -> Bool {
        // Every live child's ancestors are live directories. A deleted root
        // therefore guarantees its retained descendant graph is already deleted.
        guard !storage.entries[Int(id)].isDeleted else { return false }
        var pending = [id]
        var changed = false
        while let current = pending.popLast() {
            pending.append(contentsOf: storage.childrenByParent[current] ?? [])
            if storage.entries[Int(current)].isDeleted { continue }
            let entry = storage.entries[Int(current)]
            storage.entries[Int(current)].isDeleted = true
            storage.directoryToID.removeValue(forKey: entry.path)
            decrementLive(entry.kind)
            storage.tombstones += 1
            changed = true
        }
        return changed
    }

    private func incrementLive(_ kind: EntryKind) {
        storage.liveEntries += 1
        if kind == .file { storage.files += 1 }
        if kind == .directory { storage.directories += 1 }
    }

    private func decrementLive(_ kind: EntryKind) {
        storage.liveEntries -= 1
        if kind == .file { storage.files -= 1 }
        if kind == .directory { storage.directories -= 1 }
    }
}
