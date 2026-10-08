import Foundation

public struct ActiveLiveSample: Sendable {
    public let received: Int, processed: Int, eventBacklog: Int, dirtyBacklog: Int
    public let fullScans: Int, resourceYieldRebuilds: Int, recoveryYields: Int
    public let physicalBytes: UInt64
    public init(received: Int, processed: Int, eventBacklog: Int, dirtyBacklog: Int,
                fullScans: Int, resourceYieldRebuilds: Int, recoveryYields: Int, physicalBytes: UInt64) {
        self.received = received; self.processed = processed; self.eventBacklog = eventBacklog
        self.dirtyBacklog = dirtyBacklog; self.fullScans = fullScans
        self.resourceYieldRebuilds = resourceYieldRebuilds; self.recoveryYields = recoveryYields
        self.physicalBytes = physicalBytes
    }
}

/// Benchmark-only window checks. Namespace/metadata generations may change;
/// real incoming events must be consumed without unbounded queues or recovery.
public struct ActiveLiveConvergenceGate: Sendable {
    private let baseline: ActiveLiveSample
    private var samples: [ActiveLiveSample] = []
    private var failures = Set<String>()
    public init(baseline: ActiveLiveSample) { self.baseline = baseline }
    public mutating func observe(_ sample: ActiveLiveSample) {
        if sample.fullScans != baseline.fullScans { failures.insert("full scan during active window") }
        if sample.resourceYieldRebuilds != baseline.resourceYieldRebuilds { failures.insert("resource_yield rebuild") }
        if sample.recoveryYields-baseline.recoveryYields > 3 { failures.insert("recovery restart loop") }
        if sample.eventBacklog > 100_000 { failures.insert("event backlog limit") }
        if sample.dirtyBacklog > 4096 { failures.insert("dirty backlog limit") }
        if sample.physicalBytes > 150 * 1024 * 1024 { failures.insert("physical footprint limit") }
        samples.append(sample)
        if samples.count > 240 { samples.removeFirst() }
    }
    public var blockers: [String] {
        var result = failures
        if let end = samples.last {
            // A final transient callback may be queued: account for the measured
            // backlog rather than discarding it or demanding no external events.
            if end.received-baseline.received > end.processed-baseline.processed + end.eventBacklog {
                result.insert("processing fell behind input")
            }
        }
        if samples.count >= 12 {
            let tail = Array(samples.suffix(12))
            for key in [\ActiveLiveSample.eventBacklog, \ActiveLiveSample.dirtyBacklog] {
                if tail.last![keyPath: key] > tail.first![keyPath: key],
                   zip(tail, tail.dropFirst()).allSatisfy({ $1[keyPath: key] >= $0[keyPath: key] }) {
                    result.insert("monotonic backlog growth")
                }
            }
        }
        return result.sorted()
    }
}
