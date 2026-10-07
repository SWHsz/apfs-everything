import CAPFSShim
import Foundation

/// Logical file length and Unix time only. Unknown values remain unknown.
public struct FileMetadataValue: Sendable, Equatable {
    public let logicalSize: UInt64?
    public let modificationTimeNanoseconds: Int64?
    public init(logicalSize: UInt64? = nil, modificationTimeNanoseconds: Int64? = nil) {
        self.logicalSize = logicalSize
        self.modificationTimeNanoseconds = modificationTimeNanoseconds
    }
    public static let unknown = FileMetadataValue()
    public static func unixNanoseconds(seconds: Int64, nanoseconds: Int64) -> Int64? {
        guard (0..<1_000_000_000).contains(nanoseconds) else { return nil }
        let product = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !product.overflow else { return nil }
        let sum = product.partialValue.addingReportingOverflow(nanoseconds)
        return sum.overflow ? nil : sum.partialValue
    }
    init(_ record: APFSDirectoryEntry) {
        logicalSize = record.has_size != 0 && record.object_type == UInt32(APFS_OBJECT_FILE.rawValue)
            ? record.logical_size : nil
        modificationTimeNanoseconds = record.has_mtime != 0
            ? Self.unixNanoseconds(seconds: record.mtime_seconds, nanoseconds: Int64(record.mtime_nanoseconds)) : nil
    }
}
public struct ScannedEntry: Sendable, Equatable {
    public let namespace: NamespaceEntry
    public let metadata: FileMetadataValue
    public init(namespace: NamespaceEntry, metadata: FileMetadataValue = .unknown) {
        self.namespace = namespace; self.metadata = metadata
    }
}
public enum MetadataFreshness: String, Sendable, Codable {
    case unavailable, building, catchingUp, live, pausedStale, failed
}
