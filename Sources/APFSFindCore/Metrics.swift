import Foundation
import Darwin

public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [UUID: @Sendable () -> Void] = [:]
    public init() {}
    public var isCancelled: Bool { lock.withLock { cancelled } }
    @discardableResult public func onCancel(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        let invoke = lock.withLock { if cancelled { return true }; handlers[id] = handler; return false }
        if invoke { handler() }; return id
    }
    public func removeCancellationHandler(_ id: UUID) { _ = lock.withLock { handlers.removeValue(forKey: id) } }
    public func cancel() {
        let callbacks = lock.withLock { cancelled = true; let copy = Array(handlers.values); handlers = [:]; return copy }
        callbacks.forEach { $0() }
    }
}

public struct APFSFindConfiguration: Sendable {
    public var latencyMilliseconds: Double
    public var workerCount: Int
    public var directPatchBatchLimit: Int
    public var dirtyParentLimit: Int
    public var microBatchWindowMilliseconds: Double
    public var fullRebuildMinInterval: TimeInterval
    public var rebuildDebounceMilliseconds: Double
    public var maxPendingEvents: Int
    public var maxConsecutiveRebuildFailures: Int
    public init(latencyMilliseconds: Double = 20, workerCount: Int = 4,
                directPatchBatchLimit: Int = 256, dirtyParentLimit: Int = 64,
                microBatchWindowMilliseconds: Double = 5,
                fullRebuildMinInterval: TimeInterval = 30,
                rebuildDebounceMilliseconds: Double = 100, maxPendingEvents: Int = 100_000,
                maxConsecutiveRebuildFailures: Int = 8) {
        self.latencyMilliseconds = min(1000, max(1, latencyMilliseconds))
        self.workerCount = min(16, max(1, workerCount))
        self.directPatchBatchLimit = max(1, directPatchBatchLimit)
        self.dirtyParentLimit = max(1, dirtyParentLimit)
        self.microBatchWindowMilliseconds = max(0, microBatchWindowMilliseconds)
        self.fullRebuildMinInterval = max(0, fullRebuildMinInterval)
        self.rebuildDebounceMilliseconds = max(0, rebuildDebounceMilliseconds)
        self.maxPendingEvents = max(1, maxPendingEvents)
        self.maxConsecutiveRebuildFailures = max(1, maxConsecutiveRebuildFailures)
    }
}

public struct ProcessUsage: Sendable {
    public let residentBytes: UInt64
    public let userCPUSeconds: Double
    public let systemCPUSeconds: Double
}

public final class Metrics: @unchecked Sendable {
    private let lock = NSLock()
    private var counters: [String: Int] = [:]
    private var resourceTotals: [String:[String:Double]] = [:]
    private var resourceStages: [String: [String: Any]] = [:]
    public init() {}
    public func record(_ name: String, by value: Int = 1) {
        lock.withLock { counters[name, default: 0] += value }
    }
    public func set(_ name: String, to value: Int) { lock.withLock { counters[name] = value } }
    public func maximum(_ name: String, _ value: Int) {
        lock.withLock { counters[name] = max(counters[name, default: 0], value) }
    }
    public func snapshot() -> [String: Int] { lock.withLock { counters } }
    public func recordResources(_ stage: String, since before: ProcessResourceSample) {
        let delta = ProcessResourceSample.capture().delta(since: before)
        lock.withLock {
            resourceStages[stage] = delta
            var totals=resourceTotals[stage,default:[:]]
            totals["invocations",default:0] += 1
            for key in ["wall_ms","user_cpu_seconds","system_cpu_seconds","disk_bytes_read","disk_bytes_written","logical_bytes_written"] {
                if let value=delta[key] as? NSNumber {totals[key,default:0] += value.doubleValue}
            }
            resourceTotals[stage]=totals
        }
    }
    public func recordResourceGauge(_ stage: String, sample: ProcessResourceSample = .capture()) { lock.withLock { resourceStages[stage] = sample.dictionary } }
    public func cumulativeResourceSnapshot() -> [String:[String:Double]] {lock.withLock {resourceTotals}}
    public func resourceSnapshot() -> [String: [String: Any]] { lock.withLock { resourceStages } }
    public static func processUsage() -> ProcessUsage {
        var usage = rusage()
        let resourceOK = getrusage(RUSAGE_SELF, &usage) == 0
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return ProcessUsage(residentBytes: result == KERN_SUCCESS ? UInt64(info.resident_size) : 0,
                            userCPUSeconds: resourceOK ? Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6 : 0,
                            systemCPUSeconds: resourceOK ? Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6 : 0)
    }
}
