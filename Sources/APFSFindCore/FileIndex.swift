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
        guard replacement !== self else { return }
        precondition(replacement.root == root, "Replacement index must use the same scan root")
        let selfAddress = UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())
        let otherAddress = UInt(bitPattern: Unmanaged.passUnretained(replacement).toOpaque())
        let first = selfAddress < otherAddress ? self : replacement
        let second = selfAddress < otherAddress ? replacement : self
        first.lock.withWriteLock {
            second.lock.withWriteLock {
                let nextGeneration = max(storage.generation, replacement.storage.generation) &+ 1
                swap(&storage, &replacement.storage)
                storage.generation = nextGeneration
            }
        }
    }

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

    /// A linear filename substring scan with bounded result storage.
    public func search(_ query: String, limit: Int = 50) -> SearchResult {
        let start = DispatchTime.now().uptimeNanoseconds
        let foldedQuery = FileEntry.fold(query)
        return lock.withReadLock {
            let limit = max(0, limit)
            var ranked: [(rank: Int, path: String, kind: EntryKind)] = []
            if !foldedQuery.isEmpty, limit > 0 {
                ranked.reserveCapacity(min(limit, storage.liveEntries))
                for entry in storage.entries where !entry.isDeleted && entry.foldedName.contains(foldedQuery) {
                    let rank = entry.foldedName == foldedQuery ? 0 : (entry.foldedName.hasPrefix(foldedQuery) ? 1 : 2)
                    let candidate = (rank: rank, path: entry.path, kind: entry.kind)
                    if ranked.count == limit, let last = ranked.last,
                       !precedes(candidate, last) { continue }
                    var lower = 0
                    var upper = ranked.count
                    while lower < upper {
                        let middle = lower + (upper - lower) / 2
                        if precedes(candidate, ranked[middle]) { upper = middle }
                        else { lower = middle + 1 }
                    }
                    ranked.insert(candidate, at: lower)
                    if ranked.count > limit { ranked.removeLast() }
                }
            }
            return SearchResult(hits: ranked.map { SearchHit(path: $0.path, kind: $0.kind) },
                                latencyMilliseconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000,
                                generation: storage.generation)
        }
    }

    private func precedes(_ lhs: (rank: Int, path: String, kind: EntryKind),
                          _ rhs: (rank: Int, path: String, kind: EntryKind)) -> Bool {
        lhs.rank == rhs.rank ? lhs.path < rhs.path : lhs.rank < rhs.rank
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
                existing.fileID != nil && entry.fileID != nil && existing.fileID != entry.fileID
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
