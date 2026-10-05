import CAPFSShim
import Foundation

public enum SnapshotError: Error, Sendable, CustomStringConvertible {
    case invalid(String), identity(String), unsafePath(String), io(String, Int32)
    case generationChanged, cancelled, busy
    public var description: String {
        switch self {
        case .invalid(let reason): return "Invalid snapshot: \(reason)"
        case .identity(let reason): return "Snapshot identity mismatch: \(reason)"
        case .unsafePath(let path): return "Unsafe snapshot/cache path: \(path)"
        case .io(let operation, let code): return "Snapshot \(operation): \(String(cString: strerror(code))) (\(code))"
        case .generationChanged: return "Checkpoint aborted: namespace generation changed"
        case .cancelled: return "Checkpoint cancelled"
        case .busy: return "Checkpoint already running"
        }
    }
}

/// Explicit little-endian v1. No Swift/C object layout is written to disk.
public enum SnapshotFormat {
    public static let version: UInt32 = 1
    public static let headerSize = 192
    public static let recordSize = 24
    public static let maxRecords: UInt64 = 20_000_000
    public static let maxFileBytes: UInt64 = 8 * 1024 * 1024 * 1024
    static let magic: [UInt8] = [65,80,70,83,73,68,88,0] // APFSIDX\0
    static func add(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let result = a.addingReportingOverflow(b)
        guard !result.overflow else { throw SnapshotError.invalid("offset/length overflow") }
        return result.partialValue
    }
    static func multiply(_ a: UInt64, _ b: UInt64) throws -> UInt64 {
        let result = a.multipliedReportingOverflow(by: b)
        guard !result.overflow else { throw SnapshotError.invalid("record length overflow") }
        return result.partialValue
    }
    static func crc(_ bytes: UnsafeRawBufferPointer, previous: UInt32 = 0) -> UInt32 {
        apfs_crc32(previous, bytes.baseAddress, bytes.count)
    }
    static func crc(_ data: Data, previous: UInt32 = 0) -> UInt32 {
        data.withUnsafeBytes { crc($0, previous: previous) }
    }
}

public struct SnapshotHeader: Sendable {
    public var recordCount: UInt64
    public var recordTableOffset: UInt64
    public var recordTableLength: UInt64
    public var nameBlobOffset: UInt64
    public var nameBlobLength: UInt64
    public var rootPathOffset: UInt64 = UInt64(SnapshotFormat.headerSize)
    public var rootPathLength: UInt64
    public var createdAtUnixSeconds: UInt64
    public var indexGeneration: UInt64
    public var lastProcessedEventID: UInt64
    public var rootDeviceID: UInt64
    public var volumeUUID: UUID
    public var historyUUID: UUID
    public var payloadCRC32: UInt32
    public var fileLength: UInt64
    public var rootFileID: UInt64
    public var snapshotUUID: UUID? = nil

    func encoded() -> Data {
        var bytes = Data(repeating: 0, count: SnapshotFormat.headerSize)
        bytes.replaceSubrange(0..<8, with: SnapshotFormat.magic)
        bytes.put(SnapshotFormat.version, at: 8)
        bytes.put(UInt32(SnapshotFormat.headerSize), at: 12)
        bytes.put(UInt32(SnapshotFormat.recordSize), at: 20)
        for (offset, value) in [(24,recordCount),(32,recordTableOffset),(40,recordTableLength),
            (48,nameBlobOffset),(56,nameBlobLength),(64,rootPathOffset),(72,rootPathLength),
            (80,createdAtUnixSeconds),(88,indexGeneration),(96,lastProcessedEventID),(104,rootDeviceID),
            (152,fileLength),(160,rootFileID)] { bytes.put(value, at: offset) }
        bytes.replaceSubrange(112..<128, with: volumeUUID.bytes)
        bytes.replaceSubrange(128..<144, with: historyUUID.bytes)
        // Additive v1 flag: legacy v1 with zero reserved bytes remains readable.
        // v0.3 migrates both forms to the separate v2 layout.
        if let snapshotUUID {
            bytes.put(UInt32(1), at: 16)
            bytes.replaceSubrange(168..<184, with: snapshotUUID.bytes)
        }
        bytes.put(payloadCRC32, at: 144)
        bytes.put(SnapshotFormat.crc(bytes), at: 148) // Header CRC field is zero while hashing.
        return bytes
    }
}

public struct SnapshotRecord: Sendable {
    public let parentID: UInt32
    public let nameOffset: UInt32
    public let nameLength: UInt16
    public let kind: EntryKind
    public let flags: UInt8
    public let fileID: UInt64
    var encoded: Data {
        var bytes = Data(repeating: 0, count: SnapshotFormat.recordSize)
        bytes.put(parentID, at: 0); bytes.put(nameOffset, at: 4); bytes.put(nameLength, at: 8)
        bytes[10] = kind.snapshotCode; bytes[11] = flags
        bytes.put(fileID, at: 16)
        return bytes
    }
}

extension EntryKind {
    var snapshotCode: UInt8 {
        switch self { case .file: 1; case .directory: 2; case .symlink: 3; case .other: 4 }
    }
    init?(snapshotCode: UInt8) {
        switch snapshotCode { case 1: self = .file; case 2: self = .directory
        case 3: self = .symlink; case 4: self = .other; default: return nil }
    }
}

extension Data {
    mutating func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { replaceSubrange(offset..<(offset + $0.count), with: $0) }
    }
}

public struct SnapshotExportMetadata: Sendable {
    public let generation: UInt64
    public let totalEntries: Int
    public let liveEntries: Int
}
public struct CheckpointCapture: Sendable {
    public let metadata: SnapshotExportMetadata
    public let cursor: UInt64
    public let identity: VolumeIdentity
    let epoch: UInt64
}
public struct SnapshotExportEntry: Sendable {
    public let id: Int32
    public let parentID: Int32
    public let name: String
    public let kind: EntryKind
    public let fileID: UInt64?
    public let isBoundary: Bool
}

public struct SnapshotWriteResult: Sendable {
    public let header: SnapshotHeader
    public let durationMilliseconds: Double
    public let peakResidentBytes: UInt64
    public var bytesPerEntry: Double { Double(header.fileLength) / Double(header.recordCount) }
}

public enum SnapshotFailurePoint: Sendable {
    case afterHeader, beforeFileSync, beforeRename, afterRename, directorySync
}
