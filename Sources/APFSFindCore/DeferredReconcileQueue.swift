import Foundation

public enum ReconcileReason: String, Sendable { case event, parentRepair, retry }
public enum ReconcileInvalidation: String, Sendable { case hardLimit, repeatedIO }
public struct ReconcileFrontier: Sendable, Equatable {
    public let path: String
    public let reset: Bool
    public init(path: String, reset: Bool = false) { self.path = path; self.reset = reset }
}
public enum ReconcileResult: Sendable {
    case completed
    case deferred([ReconcileFrontier])
    case invalidated(ReconcileInvalidation)
    case locallyFailed([ReconciliationFailure])
}
public struct DeferredReconcileWork: Sendable {
    public let root: String
    public let reason: ReconcileReason
    public var minimumCursor: UInt64
    public var generation: UInt64
    public var retryCount = 0
    public var nextAttempt: TimeInterval = 0
    public var subtree: Bool
    public var frontier: [ReconcileFrontier]
    public init(root: String, reason: ReconcileReason, minimumCursor: UInt64,
                generation: UInt64, subtree: Bool = false, frontier: [ReconcileFrontier]? = nil) {
        self.root = PathCanonicalizer.normalize(root) ?? root; self.reason = reason; self.minimumCursor = minimumCursor
        self.generation = generation; self.subtree = subtree
        self.frontier = frontier ?? [.init(path: root)]
    }
}

/// Single-writer FIFO. Coalescing retains unfinished frontiers and their oldest
/// cursor; it never silently drops work to satisfy the limits.
public struct DeferredReconcileQueue: Sendable {
    private var works: [DeferredReconcileWork] = []
    public let capacity: Int
    public let frontierCapacity: Int
    public init(capacity: Int = 4096, frontierCapacity: Int = 100_000) {
        self.capacity = max(1, capacity); self.frontierCapacity = max(1, frontierCapacity)
    }
    public var count: Int { works.count }
    public var frontierCount: Int { works.reduce(0) { $0 + $1.frontier.count } }
    public var minimumCursor: UInt64? { works.map(\.minimumCursor).min() }
    public var nextAttempt: TimeInterval? { works.map(\.nextAttempt).min() }
    public var estimatedBytes: Int {
        works.reduce(0) { sum, work in sum + work.root.utf8.count + 128 + work.frontier.reduce(0) { $0 + $1.path.utf8.count + 32 } }
    }
    public mutating func removeAll() { works.removeAll() }
    @discardableResult public mutating func insert(_ work: DeferredReconcileWork) -> Bool {
        guard PathCanonicalizer.normalize(work.root) != nil else { return false }
        var candidate = self
        candidate.mergeInsert(work)
        guard candidate.count <= capacity, candidate.frontierCount <= frontierCapacity,
            candidate.estimatedBytes <= 32 * 1024 * 1024 else { return false }
        self = candidate; return true
    }
    private mutating func mergeInsert(_ work: DeferredReconcileWork) {
        let root = work.root
        var merged = work
        if let i = works.firstIndex(where: { Self.covers(root, ancestor: $0.root) }) {
            var old = works.remove(at: i)
            old.minimumCursor = min(old.minimumCursor, work.minimumCursor)
            old.generation = max(old.generation, work.generation)
            old.nextAttempt = min(old.nextAttempt, work.nextAttempt)
            old.subtree = old.subtree || work.subtree || old.root != root
            merge(work.frontier, into: &old.frontier, preserveProgress: true)
            works.insert(old, at: i)
        } else {
            let children = works.filter { Self.covers($0.root, ancestor: root) }
            for old in children {
                merged.minimumCursor = min(merged.minimumCursor, old.minimumCursor)
                merged.generation = max(merged.generation, old.generation)
                merged.nextAttempt = min(merged.nextAttempt, old.nextAttempt)
                merged.subtree = true
                merge(old.frontier, into: &merged.frontier)
            }
            works.removeAll { Self.covers($0.root, ancestor: root) }
            works.append(merged)
        }
    }
    // Both inputs are canonical queue roots. Avoid repeating normalization for
    // every unrelated root in a burst; this is bounded queue state, not a map.
    private static func covers(_ path: String, ancestor: String) -> Bool {
        ancestor == "/" || path == ancestor || path.hasPrefix(ancestor + "/")
    }
    private func merge(_ extra: [ReconcileFrontier], into frontier: inout [ReconcileFrontier], preserveProgress: Bool = false) {
        var positions = Dictionary(frontier.enumerated().map { ($0.element.path, $0.offset) }, uniquingKeysWith: { a, _ in a })
        let priorCount = frontier.count
        for item in extra {
            if let i = positions[item.path] {
                if item.reset && !frontier[i].reset { frontier[i] = item }
            } else { positions[item.path] = frontier.count; frontier.append(item) }
        }
        // The reconciler consumes from the end. A fresh ancestor event must
        // not repeatedly preempt an unfinished descendant frontier.
        if preserveProgress, frontier.count > priorCount {
            frontier = Array(frontier[priorCount...]) + Array(frontier[..<priorCount])
        }
    }
    public mutating func popReady(now: TimeInterval) -> DeferredReconcileWork? {
        guard let i = works.firstIndex(where: { $0.nextAttempt <= now }) else { return nil }
        return works.remove(at: i)
    }
}
