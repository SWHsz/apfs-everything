import CAPFSShim
import Darwin
import Foundation

/// Maps the immutable file once. Only the fixed header and individual decoded
/// basenames are copied; record/name sections remain borrowed mapped bytes.
public final class SnapshotReader: @unchecked Sendable {
    public let header: SnapshotHeader
    public let root: String
    public let loadMilliseconds: Double
    public let mmapMilliseconds: Double
    public let residentAfterMmap: UInt64
    private let mapping: UnsafeMutableRawPointer?
    public private(set) var mappedBase: MMapBaseIndex?
    public var formatVersion: UInt32 { mappedBase == nil ? 1 : 2 }
    private let length: Int

    public convenience init(path: String, expectedIdentity: VolumeIdentity) throws {
        let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw SnapshotError.io("open", errno) }
        try self.init(fileDescriptor: fd, expectedIdentity: expectedIdentity)
    }

    /// Takes ownership of the descriptor, including on validation failure.
    public init(fileDescriptor fd: Int32, expectedIdentity identity: VolumeIdentity) throws {
        var version: UInt32 = 0
        _ = pread(fd, &version, 4, 8)
        if UInt32(littleEndian: version) == 2 {
            let base = try MMapBaseIndex(fileDescriptor: fd, identity: identity)
            mappedBase = base; mapping = nil; length = 0; header = base.header; root = base.root
            mmapMilliseconds = base.mmapMilliseconds; residentAfterMmap = base.residentAfterMmap
            loadMilliseconds = base.validationMilliseconds + base.mmapMilliseconds
            return
        }
        defer { Darwin.close(fd) }
        let start = ProcessInfo.processInfo.systemUptime
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else { throw SnapshotError.io("fstat", errno) }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == geteuid(),
              metadata.st_mode & 0o7777 == 0o600 else { throw SnapshotError.unsafePath("snapshot owner/type/mode") }
        guard metadata.st_size >= SnapshotFormat.headerSize,
              UInt64(metadata.st_size) <= SnapshotFormat.maxFileBytes else { throw SnapshotError.invalid("file size") }
        let size = Int(metadata.st_size)
        let mapStart = ProcessInfo.processInfo.systemUptime
        guard let address = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0), address != MAP_FAILED else {
            throw SnapshotError.io("mmap", errno)
        }
        let mapMS = (ProcessInfo.processInfo.systemUptime - mapStart) * 1000
        let mapRSS = Metrics.processUsage().residentBytes
        do {
            let raw = UnsafeRawBufferPointer(start: address, count: size)
            let decoded = try Self.decodeHeader(raw)
            try Self.validateLayout(decoded, fileLength: UInt64(size))
            let rootBytes = UnsafeRawBufferPointer(rebasing: raw[Int(decoded.rootPathOffset)..<Int(decoded.rootPathOffset + decoded.rootPathLength)])
            guard let rootName = String(bytes: rootBytes, encoding: .utf8),
                  PathCanonicalizer.normalize(rootName) == rootName,
                  !rootName.utf8.contains(0) else { throw SnapshotError.invalid("root bytes") }
            guard Array(rootName.utf8) == Array(identity.root.utf8) else { throw SnapshotError.identity("root path") }
            guard decoded.rootDeviceID == identity.deviceID else { throw SnapshotError.identity("device ID") }
            guard decoded.rootFileID == identity.rootFileID else { throw SnapshotError.identity("root inode") }
            guard decoded.volumeUUID == identity.volumeUUID else { throw SnapshotError.identity("volume UUID") }
            guard decoded.historyUUID == identity.historyUUID else { throw SnapshotError.identity("FSEvents history UUID") }
            var crc: UInt32 = 0
            for offset in stride(from: SnapshotFormat.headerSize, to: size, by: 1_048_576) {
                crc = SnapshotFormat.crc(UnsafeRawBufferPointer(rebasing: raw[offset..<min(size, offset + 1_048_576)]), previous: crc)
            }
            guard crc == decoded.payloadCRC32 else { throw SnapshotError.invalid("payload CRC32") }
            var expectedNameOffset: UInt64 = 0
            var pathLengths = [UInt32]()
            pathLengths.reserveCapacity(Int(decoded.recordCount))
            for ordinal in 0..<Int(decoded.recordCount) {
                let record = try Self.decodeRecord(raw, header: decoded, ordinal: ordinal)
                guard UInt64(record.nameOffset) == expectedNameOffset else { throw SnapshotError.invalid("noncontiguous name blob") }
                let end = try SnapshotFormat.add(UInt64(record.nameOffset), UInt64(record.nameLength))
                guard end <= decoded.nameBlobLength else { throw SnapshotError.invalid("name offset/length") }
                expectedNameOffset = end
                if ordinal == 0 {
                    guard record.parentID == UInt32.max, record.kind == .directory,
                          record.nameLength == 0, record.flags == 0 else { throw SnapshotError.invalid("root record") }
                    pathLengths.append(UInt32(rootBytes.count))
                } else {
                    guard record.parentID < ordinal else { throw SnapshotError.invalid("parent does not precede child") }
                    let parent = try Self.decodeRecord(raw, header: decoded, ordinal: Int(record.parentID))
                    guard parent.kind == .directory, parent.flags & 1 == 0 else { throw SnapshotError.invalid("parent is not a traversable directory") }
                    guard record.nameLength > 0, record.nameLength <= NAME_MAX else { throw SnapshotError.invalid("basename length") }
                    let first = Int(decoded.nameBlobOffset) + Int(record.nameOffset)
                    let bytes = UnsafeRawBufferPointer(rebasing: raw[first..<(first + Int(record.nameLength))])
                    guard !bytes.contains(0), !bytes.contains(47),
                          let name = String(bytes: bytes, encoding: .utf8), name != ".", name != ".." else {
                        throw SnapshotError.invalid("basename bytes")
                    }
                    let parentLength = pathLengths[Int(record.parentID)]
                    let pathLength = parentLength + UInt32(record.nameLength) + (parentLength == 1 ? 0 : 1)
                    guard pathLength < PATH_MAX else { throw SnapshotError.invalid("restored path exceeds PATH_MAX") }
                    pathLengths.append(pathLength)
                }
            }
            guard expectedNameOffset == decoded.nameBlobLength else { throw SnapshotError.invalid("unreferenced name bytes") }
            self.mapping = address; self.length = size; self.header = decoded; self.root = rootName
            self.mmapMilliseconds = mapMS; self.residentAfterMmap = mapRSS
            self.loadMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
        } catch {
            munmap(address, size)
            throw error
        }
    }
    deinit { if let mapping { munmap(mapping, length) } }

    public func record(at ordinal: Int) -> SnapshotRecord {
        if let base = mappedBase {
            let r = base.record(at: UInt32(ordinal))
            return .init(parentID:r.parent,nameOffset:r.nameOffset,nameLength:r.nameLength,kind:r.kind,flags:r.flags,fileID:r.fileID)
        }
        precondition(ordinal >= 0 && ordinal < Int(header.recordCount))
        return try! Self.decodeRecord(UnsafeRawBufferPointer(start: mapping!, count: length), header: header, ordinal: ordinal)
    }
    public func name(at ordinal: Int) -> String {
        if let base = mappedBase { return base.name(at: UInt32(ordinal)) }
        let record = record(at: ordinal)
        let first = Int(header.nameBlobOffset) + Int(record.nameOffset)
        let bytes = UnsafeRawBufferPointer(start: mapping!.advanced(by: first), count: Int(record.nameLength))
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func number<T: FixedWidthInteger>(_ raw: UnsafeRawBufferPointer, _ offset: Int, _: T.Type) -> T {
        T(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: T.self))
    }
    private static func decodeHeader(_ raw: UnsafeRawBufferPointer) throws -> SnapshotHeader {
        guard Array(raw.prefix(8)) == SnapshotFormat.magic else { throw SnapshotError.invalid("magic") }
        guard number(raw, 8, UInt32.self) == SnapshotFormat.version else { throw SnapshotError.invalid("unsupported version") }
        guard number(raw, 12, UInt32.self) == SnapshotFormat.headerSize,
              number(raw, 16, UInt32.self) <= 1, number(raw, 20, UInt32.self) == SnapshotFormat.recordSize,
              raw[(number(raw, 16, UInt32.self) == 1 ? 184 : 168)..<192].allSatisfy({ $0 == 0 }) else { throw SnapshotError.invalid("header layout/flags") }
        var copy = Data(raw.prefix(SnapshotFormat.headerSize))
        let stored = number(raw, 148, UInt32.self)
        copy.put(UInt32(0), at: 148)
        guard SnapshotFormat.crc(copy) == stored else { throw SnapshotError.invalid("header CRC32") }
        return SnapshotHeader(recordCount: number(raw,24,UInt64.self), recordTableOffset: number(raw,32,UInt64.self),
            recordTableLength: number(raw,40,UInt64.self), nameBlobOffset: number(raw,48,UInt64.self),
            nameBlobLength: number(raw,56,UInt64.self), rootPathOffset: number(raw,64,UInt64.self),
            rootPathLength: number(raw,72,UInt64.self), createdAtUnixSeconds: number(raw,80,UInt64.self),
            indexGeneration: number(raw,88,UInt64.self), lastProcessedEventID: number(raw,96,UInt64.self),
            rootDeviceID: number(raw,104,UInt64.self), volumeUUID: UUID(bytes: Array(raw[112..<128])),
            historyUUID: UUID(bytes: Array(raw[128..<144])), payloadCRC32: number(raw,144,UInt32.self),
            fileLength: number(raw,152,UInt64.self), rootFileID: number(raw,160,UInt64.self),
            snapshotUUID: number(raw,16,UInt32.self) == 1 ? UUID(bytes: Array(raw[168..<184])) : nil)
    }
    private static func validateLayout(_ header: SnapshotHeader, fileLength: UInt64) throws {
        guard header.recordCount > 0, header.recordCount <= SnapshotFormat.maxRecords,
              header.lastProcessedEventID != UInt64.max, header.indexGeneration != UInt64.max,
              header.rootPathOffset == SnapshotFormat.headerSize,
              header.rootPathLength > 0, header.rootPathLength < PATH_MAX,
              header.nameBlobLength <= UInt32.max else { throw SnapshotError.invalid("count/root/blob limit") }
        let rootEnd = try SnapshotFormat.add(header.rootPathOffset, header.rootPathLength)
        let aligned = try SnapshotFormat.add(rootEnd, 7) & ~UInt64(7)
        let tableLength = try SnapshotFormat.multiply(header.recordCount, UInt64(SnapshotFormat.recordSize))
        guard header.recordTableOffset == aligned, header.recordTableLength == tableLength,
              try SnapshotFormat.add(aligned, tableLength) == header.nameBlobOffset,
              try SnapshotFormat.add(header.nameBlobOffset, header.nameBlobLength) == fileLength,
              header.fileLength == fileLength else { throw SnapshotError.invalid("section boundaries/lengths") }
    }
    private static func decodeRecord(_ raw: UnsafeRawBufferPointer, header: SnapshotHeader, ordinal: Int) throws -> SnapshotRecord {
        let base = Int(header.recordTableOffset) + ordinal * SnapshotFormat.recordSize
        guard let kind = EntryKind(snapshotCode: raw[base + 10]), raw[base + 11] & ~UInt8(1) == 0,
              number(raw, base + 12, UInt32.self) == 0 else { throw SnapshotError.invalid("record kind/flags/reserved") }
        return SnapshotRecord(parentID: number(raw,base,UInt32.self), nameOffset: number(raw,base + 4,UInt32.self),
            nameLength: number(raw,base + 8,UInt16.self), kind: kind, flags: raw[base + 11], fileID: number(raw,base + 16,UInt64.self))
    }
}
