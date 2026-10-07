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
    public var gateSkipped = false
    public var failed = false
    public var requiresRebuild = false
    public var retryParents: [String] = []
    public var failures: [ReconciliationFailure] = []
    public init() {}
}

/// Called by the single writer. Directory I/O and diff happen before apply(),
/// so queries never wait on filesystem reads while holding an index lock.
public final class DirectoryReconciler {
    enum FailureRecovery: Equatable {
        case cancelled, preserveUnreadable, retryParent, rebuild
    }

    /// Permission/dataless exclusions apply to individual descendants, just as
    /// in the initial scan. A vanished/replaced directory is repaired by reading
    /// its parent; only root failures and unexpected I/O invalidate the scan.
    static func recovery(for code: Int32, isRoot: Bool) -> FailureRecovery {
        if code == ECANCELED { return .cancelled }
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
                        cancellation: CancellationToken = CancellationToken()) -> ReconciliationPlan {
        var plan = ReconciliationPlan()
        guard PathCanonicalizer.isWithin(path, root: index.root), !cancellation.isCancelled else { return plan }
        let before = BulkScanner.directoryStamp(path)
        if !force && !subtree, let before, stamps[path] == before {
            metrics.record("mtime_gate_skips")
            plan.gateSkipped = true
            return plan
        }
        var pending: [(path: String, reset: Bool)] = [(path, false)]
        var seen = Set<String>()
        var retryParents = Set<String>()
        while let work = pending.popLast(), !cancellation.isCancelled {
            if plan.mutations.count >= 100_000 || seen.count >= 16_384 {
                // Atomic diffs cannot grow without bound; recovery keeps the old
                // cursor and scans on a resource-aware maintenance queue.
                plan.mutations.removeAll(); plan.requiresRebuild = true; break
            }
            let directory = work.path
            guard seen.insert(directory).inserted else { continue }
            do {
                let startStamp = BulkScanner.directoryStamp(directory)
                let actual = try scanner.readDirectory(directory, rootDeviceID: rootDeviceID, cancellation: cancellation)
                // A parent replacement tombstones its old subtree during apply.
                // Reinsert all observed descendants even if their inode survives.
                let existing = work.reset ? [] : index.children(of: directory)
                plan.mutations += Self.diff(existing: existing, actual: actual)
                metrics.record("directory_reconciles")
                let old = Dictionary(existing.map { ($0.path, $0) }, uniquingKeysWith: { _, b in b })
                for child in actual where BulkScanner.shouldTraverse(entry: child, rootDeviceID: rootDeviceID) {
                    // New/type-replaced directories can already contain a complete tree.
                    let replaced = old[child.path]?.hasSameDirectoryIdentity(as: child) != true
                    if subtree || work.reset || replaced {
                        pending.append((child.path, work.reset || replaced))
                    }
                }
                let endStamp = BulkScanner.directoryStamp(directory)
                if let startStamp, startStamp == endStamp { if stamps.count >= 8192 { stamps.removeAll(keepingCapacity:false) }; stamps[directory] = startStamp }
                else { stamps.removeValue(forKey: directory) }
            } catch {
                if cancellation.isCancelled { break }
                let code = (error as? ScannerError)?.code ?? EIO
                let recovery = Self.recovery(for: code, isRoot: directory == index.root)
                if recovery == .cancelled { break }
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
        plan.retryParents = PathCanonicalizer.minimalRoots(Array(retryParents))
        if subtree { metrics.record("subtree_reconciles") }
        return plan
    }
}
