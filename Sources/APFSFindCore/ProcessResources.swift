import CAPFSShim
import Darwin
import Foundation

/// Actual cumulative process counters and memory gauges. Logical reads are
/// absent from rusage_info_v4; compressed bytes come from TASK_VM_INFO.
public struct ProcessResourceSample: Codable, Sendable {
    public let uptime: Double
    public let rssBytes: UInt64
    public let peakRSSBytes: UInt64
    public let userCPUSeconds: Double
    public let systemCPUSeconds: Double
    public let minorFaults: Int64?
    public let majorFaults: Int64?
    public let diskBytesRead: UInt64?
    public let diskBytesWritten: UInt64?
    public let logicalBytesWritten: UInt64?
    public let physicalFootprint: UInt64?
    public let peakPhysicalFootprint: UInt64?
    public let idleWakeups: UInt64?
    public let interruptWakeups: UInt64?
    public let pageins: UInt64?
    /// TASK_VM_INFO internal/external resident gauges; not a guessed allocation size.
    public let internalResidentBytes: UInt64?
    public let externalResidentBytes: UInt64?
    public let compressedBytes: UInt64?
    public let peakCompressedBytes: UInt64?
    public let apiError: Int32?

    public static func capture() -> Self {
        let usage = Metrics.processUsage()
        var info = APFSProcessResources(), ru = rusage()
        let status = apfs_process_resources(&info)
        let error = status == 0 ? nil : errno
        let ruOK = getrusage(RUSAGE_SELF, &ru) == 0
        return .init(uptime: ProcessInfo.processInfo.systemUptime,
            rssBytes: usage.residentBytes, peakRSSBytes: ruOK ? UInt64(max(0, ru.ru_maxrss)) : 0,
            userCPUSeconds: usage.userCPUSeconds, systemCPUSeconds: usage.systemCPUSeconds,
            minorFaults: ruOK ? Int64(ru.ru_minflt) : nil, majorFaults: ruOK ? Int64(ru.ru_majflt) : nil,
            diskBytesRead: status == 0 ? info.disk_bytes_read : nil,
            diskBytesWritten: status == 0 ? info.disk_bytes_written : nil,
            logicalBytesWritten: status == 0 ? info.logical_bytes_written : nil,
            physicalFootprint: status == 0 ? info.physical_footprint : nil,
            peakPhysicalFootprint: status == 0 ? info.peak_physical_footprint : nil,
            idleWakeups: status == 0 ? info.idle_wakeups : nil,
            interruptWakeups: status == 0 ? info.interrupt_wakeups : nil,
            pageins: status == 0 ? info.pageins : nil,
            internalResidentBytes: info.memory_info_valid == 1 ? info.internal_resident_bytes : nil,
            externalResidentBytes: info.memory_info_valid == 1 ? info.external_resident_bytes : nil,
            compressedBytes: info.memory_info_valid == 1 ? info.compressed_bytes : nil,
            peakCompressedBytes: info.memory_info_valid == 1 ? info.peak_compressed_bytes : nil, apiError: error)
    }
    public func delta(since old: Self) -> [String: Any] {
        func difference(_ a: UInt64?, _ b: UInt64?) -> Any {
            guard let a, let b, a >= b else { return NSNull() }
            return a - b
        }
        return ["wall_ms": (uptime - old.uptime) * 1000,
                "user_cpu_seconds": userCPUSeconds - old.userCPUSeconds,
                "system_cpu_seconds": systemCPUSeconds - old.systemCPUSeconds,
                "rss_before_bytes": old.rssBytes, "rss_after_bytes": rssBytes,
                "peak_rss_bytes": peakRSSBytes,
                "disk_bytes_read": difference(diskBytesRead, old.diskBytesRead),
                "disk_bytes_written": difference(diskBytesWritten, old.diskBytesWritten),
                "logical_bytes_written": difference(logicalBytesWritten, old.logicalBytesWritten),
                "logical_bytes_read": NSNull(),
                "compressed_before_bytes": old.compressedBytes as Any? ?? NSNull(),
                "compressed_bytes": compressedBytes as Any? ?? NSNull(),
                "peak_compressed_bytes": peakCompressedBytes as Any? ?? NSNull(),
                "idle_wakeups": difference(idleWakeups, old.idleWakeups),
                "interrupt_wakeups": difference(interruptWakeups, old.interruptWakeups),
                "pageins": difference(pageins, old.pageins),
                "minor_faults": minorFaults.flatMap { a in old.minorFaults.map { a - $0 } } as Any? ?? NSNull(),
                "major_faults": majorFaults.flatMap { a in old.majorFaults.map { a - $0 } } as Any? ?? NSNull()]
    }
    public var dictionary: [String: Any] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try! encoder.encode(self)
        var result = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        result["dirty_private_pages"] = NSNull()
        result["private_anonymous_footprint"] = NSNull() // Internal resident + compressed are reported separately, not relabelled as a ledger.
        return result
    }
}
