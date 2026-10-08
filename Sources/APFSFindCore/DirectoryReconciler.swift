import Foundation
import Darwin

public struct ReconciliationFailure: Sendable, Equatable {
    public let path: String
    public let code: Int32
    public init(path: String, code: Int32) {
        self.path = path
        self.code = code
    }
}

public struct ReconciliationPlan: Sendable {
    public var mutations: [IndexMutation] = []
    public var cancelled = false
    public var gateSkipped = false
    public var failed = false
    public var requiresRebuild = false
    public var retryParents: [String] = []
    public var failures: [ReconciliationFailure] = []
    public var completedDirectories: [String] = []
    public var enumeratedEntries = 0
    public var frontier: [ReconcileFrontier] = []
    public var result: ReconcileResult {
        if requiresRebuild {
            let fatal = failures.filter { DirectoryReconciler.recovery(for: $0.code, isRoot: false) == .rebuild }
            return fatal.isEmpty ? .invalidated(.hardLimit) : .locallyFailed(fatal)
        }
        return frontier.isEmpty ? .completed : .deferred(frontier)
    }
    public init() {}
}

/// Called by the single writer. Directory I/O and diff happen before apply(),
/// so queries never wait on filesystem reads while holding an index lock.
public final class DirectoryReconciler {
    enum FailureRecovery: Equatable {
        case cancelled, preserveUnreadable, retryParent, rebuild
    }

    /// Permission/dataless exclusions preserve unreadable scopes, including the
    /// root. A vanished descendant is repaired through its parent; a vanished
    /// root or repeated authoritative I/O failure requires recovery.
    static func recovery(for code: Int32, isRoot: Bool) -> FailureRecovery {
        if code == ECANCELED { return .cancelled }
        if [EACCES, EPERM, ENODATA].contains(code) { return .preserveUnreadable }
        if isRoot { return .rebuild }
        switch code {
        case EACCES, EPERM, ENODATA: return .preserveUnreadable
        case ENOENT, ENOTDIR, ELOOP, EXDEV: return .retryParent
        default: return .rebuild
        }
    }

    private let scanner: any DirectoryReading
    private let index: any NamespaceIndex
    private let metrics: Metrics
    private let rootDeviceID: UInt64
    private var stamps: [String: DirectoryStamp] = [:]
    public init(scanner: any DirectoryReading, index: any NamespaceIndex, rootDeviceID: UInt64, metrics: Metrics) {
        self.scanner = scanner; self.index = index
        self.rootDeviceID = rootDeviceID; self.metrics = metrics
    }

    public static func diff(existing: [NamespaceEntry], actual: [NamespaceEntry]) -> [IndexMutation] {
        let new = Dictionary(actual.map { ($0.path, $0) }, uniquingKeysWith: { _, b in b })
        let old = Dictionary(existing.map { ($0.path, $0) }, uniquingKeysWith: { _, b in b })
        var changes = existing.filter { new[$0.path] == nil }.map { IndexMutation.remove($0.path) }
        for item in actual where old[item.path] != item { changes.append(.upsert(item)) }
        return changes
    }

    public func prepare(_ path: String, subtree: Bool = false, force: Bool = false,
                        cancellation: CancellationToken = CancellationToken(),
                        frontier: [ReconcileFrontier]? = nil, directoryLimit: Int? = nil,
                        timeLimit: TimeInterval = 0.02) -> ReconciliationPlan {
        var plan = ReconciliationPlan()
        defer { if cancellation.isCancelled { metrics.record("reconcile_cancellations") } }
        if cancellation.isCancelled { plan.cancelled = true; return plan }
        guard PathCanonicalizer.isWithin(path, root: index.root), !cancellation.isCancelled else { return plan }
        let before = BulkScanner.directoryStamp(path)
        if frontier == nil && !force && !subtree, let before, stamps[path] == before {
            metrics.record("mtime_gate_skips")
            plan.gateSkipped = true
            return plan
        }
        var pending = frontier ?? [ReconcileFrontier(path: path,recursive:subtree)]
        var completed = 0
        var seen: [String:Bool] = [:]
        var retryParents = Set<String>()
        let start = ProcessInfo.processInfo.systemUptime
        while let work = pending.popLast(), !cancellation.isCancelled {
            // Complete at least one bounded, atomic parent diff even during
            // continuous queries; yield between directories, never mid-listing.
            if completed > 0, let directoryLimit {
                let resources = SystemResourceSignals.shared.current()
                if completed >= directoryLimit || ProcessInfo.processInfo.systemUptime-start >= timeLimit ||
                    resources.activeQueries > 0 || resources.memoryPressure == .critical {
                    pending.append(work); metrics.record("reconcile_chunk_yields"); break
                }
            }
            if plan.mutations.count >= 100_000 || pending.count > 100_000 {
                // Atomic diffs cannot grow without bound; recovery keeps the old
                // cursor and scans on a resource-aware maintenance queue.
                metrics.record(plan.mutations.count >= 100_000 ? "reconcile_mutation_limit" : "reconcile_frontier_limit")
                plan.mutations.removeAll(); plan.requiresRebuild = true; break
            }
            // Filesystem children are strictly deeper paths and symlinks are
            // never traversed. Keep only a bounded duplicate window: visiting
            // 16k unchanged directories is not evidence that recovery is needed.
            if seen.count >= 16_384 { seen.removeAll(keepingCapacity:true) }
            let directory = work.path
            // A parent replacement discovered later in the same slice must
            // upgrade an earlier ordinary visit into a resetting subtree walk.
            if let reset = seen[directory], reset || !work.reset {continue}
            seen[directory] = work.reset
            do {
                let startStamp = BulkScanner.directoryStamp(directory)
                let actual = try scanner.readDirectory(directory, rootDeviceID: rootDeviceID, cancellation: cancellation)
                // A mostly deleted wide base can have a tiny actual listing.
                // Bound the old side before reconstructing all of its paths.
                if !work.reset, let hybrid = index as? HybridIndex,
                   let oldCount = hybrid.childCount(of:directory), oldCount > 100_000 {
                    plan.mutations.removeAll(); plan.requiresRebuild = true
                    metrics.record("reconcile_old_children_limit"); break
                }
                // A parent replacement tombstones its old subtree during apply.
                // Reinsert all observed descendants even if their inode survives.
                let existing = work.reset ? [] : index.children(of: directory)
                plan.enumeratedEntries += actual.count + existing.count
                let changes = Self.diff(existing:existing,actual:actual)
                guard changes.count <= 100_000-plan.mutations.count else {
                    plan.mutations.removeAll(); plan.requiresRebuild = true
                    metrics.record("reconcile_mutation_limit"); break
                }
                plan.mutations += changes
                metrics.record("directory_reconciles"); completed += 1; plan.completedDirectories.append(directory)
                let old = Dictionary(existing.map { ($0.path, $0) }, uniquingKeysWith: { _, b in b })
                for child in actual where BulkScanner.shouldTraverse(entry: child, rootDeviceID: rootDeviceID) {
                    guard PathCanonicalizer.parent(of:child.path) == directory else { continue }
                    // New/type-replaced directories can already contain a complete tree.
                    let replaced = old[child.path]?.hasSameDirectoryIdentity(as: child) != true
                    let recursive = work.recursive ?? subtree
                    if recursive || work.reset || replaced {
                        pending.append(.init(path: child.path, reset: work.reset || replaced,recursive:recursive))
                    }
                }
                let endStamp = BulkScanner.directoryStamp(directory)
                if let startStamp, startStamp == endStamp { if stamps.count >= 8192 { stamps.removeAll(keepingCapacity:false) }; stamps[directory] = startStamp }
                else { stamps.removeValue(forKey: directory) }
            } catch is MaintenanceYield {
                pending.append(work); metrics.record("reconcile_resource_yields"); break
            } catch {
                if cancellation.isCancelled { break }
                let code = (error as? ScannerError)?.code ?? EIO
                let recovery = Self.recovery(for: code, isRoot: directory == index.root)
                if recovery == .cancelled { plan.cancelled=true;plan.mutations.removeAll();break }
                plan.failed = true
                plan.failures.append(ReconciliationFailure(path: directory, code: code))
                metrics.record("reconcile_errors")
                metrics.record("reconcile_errno_\(code)")
                stamps.removeValue(forKey: directory)
                // Do not erase a previously indexed unreadable directory. Its parent
                // diff will handle disappearance/type replacement authoritatively.
                switch recovery {
                case .preserveUnreadable:
                    metrics.record("reconcile_unreadable_skips")
                case .retryParent:
                    metrics.record(code == EXDEV ? "reconcile_boundary_skips" : "reconcile_races")
                    let parent = PathCanonicalizer.parent(of: directory)
                    if PathCanonicalizer.isWithin(parent, root: index.root) {
                        retryParents.insert(parent)
                    } else {
                        plan.requiresRebuild = true
                    }
                case .rebuild:
                    metrics.record("reconcile_fatal_errors")
                    plan.requiresRebuild = true
                case .cancelled: break
                }
            }
        }
        if cancellation.isCancelled { plan.mutations.removeAll(); plan.cancelled = true }
        if !plan.cancelled && !plan.requiresRebuild { plan.frontier = pending }
        plan.retryParents = PathCanonicalizer.minimalRoots(Array(retryParents))
        if subtree || frontier?.contains(where: { $0.recursive == true }) == true { metrics.record("subtree_reconciles") }
        return plan
    }
}
