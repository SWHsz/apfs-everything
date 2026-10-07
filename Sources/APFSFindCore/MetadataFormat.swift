import Darwin
import Foundation

/// Independent sidecar, explicitly little endian. Namespace v2 never changes.
public struct MetadataHeader: Sendable, Equatable {
    public let count: UInt64
    public let baseUUID: UUID
    public let baseGeneration: UInt64
    public let baseLength: UInt64
    public let baseCRC: UInt32
    public let metadataUUID: UUID
    public let volumeUUID: UUID
    public let historyUUID: UUID
    public let cursor: UInt64
    public let createdAtUnixSeconds: UInt64
    public let payloadCRC: UInt32
    public var sizeOffset: UInt64 { 256 }
    public var sizeLength: UInt64 { count * 8 }
    public var timeOffset: UInt64 { 256 + count * 8 }
    public var timeLength: UInt64 { count * 8 }
    public var validityOffset: UInt64 { 256 + count * 16 }
    public var validityLength: UInt64 { (count + 3) / 4 }
    public var fileLength: UInt64 { validityOffset + validityLength + 16 }
    public init(base: SnapshotHeader, cursor: UInt64, metadataUUID: UUID = UUID(),
                createdAtUnixSeconds: UInt64 = UInt64(Date().timeIntervalSince1970), payloadCRC: UInt32 = 0) throws {
        guard let uuid = base.snapshotUUID, base.recordCount > 0,
              base.recordCount <= SnapshotFormat.maxRecords, cursor != UInt64.max else {
            throw SnapshotError.invalid("metadata base/count/cursor")
        }
        count = base.recordCount; baseUUID = uuid; baseGeneration = base.indexGeneration
        baseLength = base.fileLength; baseCRC = base.payloadCRC32
        self.metadataUUID = metadataUUID; volumeUUID = base.volumeUUID; historyUUID = base.historyUUID
        self.cursor = cursor; self.createdAtUnixSeconds = createdAtUnixSeconds; self.payloadCRC = payloadCRC
    }
    public func matches(_ base: SnapshotHeader) -> Bool {
        count == base.recordCount && baseUUID == base.snapshotUUID && baseGeneration == base.indexGeneration &&
            baseLength == base.fileLength && baseCRC == base.payloadCRC32 && volumeUUID == base.volumeUUID && historyUUID == base.historyUUID
    }
    func encoded() -> Data {
        var d = Data(repeating: 0, count: 256)
        d.replaceSubrange(0..<8, with: Array("APFSMETA".utf8)); d.put(UInt32(1), at: 8); d.put(UInt32(256), at: 12)
        for (o,v) in [(16,count),(40,baseGeneration),(48,baseLength),(112,cursor),(120,sizeOffset),(128,sizeLength),
                      (136,timeOffset),(144,timeLength),(152,validityOffset),(160,validityLength),
                      (168,createdAtUnixSeconds),(176,fileLength)] { d.put(v, at:o) }
        d.put(baseCRC, at:56); d.put(payloadCRC, at:184)
        for (o,u) in [(24,baseUUID),(64,metadataUUID),(80,volumeUUID),(96,historyUUID)] {
            d.replaceSubrange(o..<(o+16), with:u.bytes)
        }
        d.put(SnapshotFormat.crc(d), at:188); return d
    }
    static func decode(_ raw: UnsafeRawBufferPointer, base: SnapshotHeader, checkpoint: () throws -> Void = {}) throws -> MetadataHeader {
        guard raw.count >= 272 else { throw SnapshotError.invalid("metadata truncated") }
        func n<T: FixedWidthInteger>(_ o:Int,_ t:T.Type)->T { T(littleEndian:raw.loadUnaligned(fromByteOffset:o,as:t)) }
        guard Array(raw.prefix(8)) == Array("APFSMETA".utf8), n(8,UInt32.self) == 1, n(12,UInt32.self) == 256,
              raw[60..<64].allSatisfy({$0 == 0}), raw[192..<256].allSatisfy({$0 == 0}) else { throw SnapshotError.invalid("metadata header") }
        var copy = Data(raw.prefix(256)); copy.put(UInt32(0), at:188)
        guard SnapshotFormat.crc(copy) == n(188,UInt32.self) else { throw SnapshotError.invalid("metadata header CRC") }
        let h = try MetadataHeader(base:base, cursor:n(112,UInt64.self),
            metadataUUID:UUID(bytes:Array(raw[64..<80])),createdAtUnixSeconds:n(168,UInt64.self),payloadCRC:n(184,UInt32.self))
        guard n(16,UInt64.self) == h.count, UUID(bytes:Array(raw[24..<40])) == h.baseUUID,
              n(40,UInt64.self) == h.baseGeneration, n(48,UInt64.self) == h.baseLength, n(56,UInt32.self) == h.baseCRC,
              UUID(bytes:Array(raw[80..<96])) == h.volumeUUID, UUID(bytes:Array(raw[96..<112])) == h.historyUUID else {
            throw SnapshotError.identity("metadata namespace base")
        }
        for (o,v) in [(120,h.sizeOffset),(128,h.sizeLength),(136,h.timeOffset),(144,h.timeLength),
                      (152,h.validityOffset),(160,h.validityLength),(176,h.fileLength)] {
            guard n(o,UInt64.self) == v else { throw SnapshotError.invalid("metadata column offsets") }
        }
        guard h.fileLength == UInt64(raw.count), Array(raw[(raw.count-16)..<(raw.count-8)]) == Array("APFMTEND".utf8),
              n(raw.count-8,UInt64.self) == h.fileLength else { throw SnapshotError.invalid("metadata footer/length") }
        guard try SnapshotFormat.checkedCRC(UnsafeRawBufferPointer(rebasing:raw[256..<(raw.count-16)]),checkpoint:checkpoint) == h.payloadCRC else {
            throw SnapshotError.invalid("metadata payload CRC")
        }
        if h.count % 4 != 0 {
            let used = Int(h.count % 4) * 2
            guard raw[raw.count-17] >> used == 0 else { throw SnapshotError.invalid("metadata bitmap padding") }
        }
        return h
    }
}

public final class MMapMetadataIndex: @unchecked Sendable {
    public let header: MetadataHeader
    public let residentAfterValidation: UInt64
    public let residentAfterRuntimeRemap: UInt64
    private let address: UnsafeMutableRawPointer
    private let length: Int
    public convenience init(path: String, base: SnapshotHeader) throws {
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw SnapshotError.io("open metadata",errno) }
        try self.init(fileDescriptor:fd,base:base)
    }
    /// Owns descriptor, also on validation failure.
    public init(fileDescriptor fd: Int32, base: SnapshotHeader, checkpoint: () throws -> Void = {}) throws {
        defer { close(fd) }
        var st = stat()
        guard fcntl(fd,F_GETFL) & O_ACCMODE == O_RDONLY, fstat(fd,&st) == 0,
              st.st_uid == geteuid(), st.st_mode & S_IFMT == S_IFREG, st.st_mode & 0o7777 == 0o600 else {
            throw SnapshotError.unsafePath("metadata owner/type/mode")
        }
        guard st.st_size >= 272, UInt64(st.st_size) <= SnapshotFormat.maxFileBytes else { throw SnapshotError.invalid("metadata size") }
        let size = Int(st.st_size)
        guard let p = mmap(nil,size,PROT_READ,MAP_PRIVATE,fd,0), p != MAP_FAILED else { throw SnapshotError.io("mmap metadata",errno) }
        do {
            let raw = UnsafeRawBufferPointer(start:p,count:size)
            let h = try MetadataHeader.decode(raw,base:base,checkpoint:checkpoint)
            // Invalid values have canonical zero columns, never sentinel values.
            for id in 0..<Int(h.count) {
                if id % 4096 == 0 { try checkpoint() }
                let bits = (raw[Int(h.validityOffset)+id/4] >> ((id%4)*2)) & 3
                if bits & 1 == 0 && raw.loadUnaligned(fromByteOffset:256+id*8,as:UInt64.self) != 0 {
                    throw SnapshotError.invalid("metadata unknown size column")
                }
                if bits & 2 == 0 && raw.loadUnaligned(fromByteOffset:Int(h.timeOffset)+id*8,as:UInt64.self) != 0 {
                    throw SnapshotError.invalid("metadata unknown time column")
                }
            }
            residentAfterValidation = Metrics.processUsage().residentBytes
            guard let runtime = mmap(nil,size,PROT_READ,MAP_PRIVATE,fd,0),runtime != MAP_FAILED else { throw SnapshotError.io("remap runtime metadata",errno) }
            munmap(p,size)
            header = h; address = runtime; length = size
            residentAfterRuntimeRemap = Metrics.processUsage().residentBytes
        } catch { munmap(p,size); throw error }
    }
    deinit { munmap(address,length) }
    @discardableResult public func reclaimPages() -> Bool { madvise(address,length,MADV_DONTNEED) == 0 }
    public func value(at ordinal: UInt32) -> FileMetadataValue {
        guard UInt64(ordinal) < header.count else { return .unknown }
        let i = Int(ordinal)
        let flags = address.load(fromByteOffset:Int(header.validityOffset)+i/4,as:UInt8.self) >> ((i%4)*2)
        return FileMetadataValue(
            logicalSize:flags & 1 != 0 ? UInt64(littleEndian:address.loadUnaligned(fromByteOffset:256+i*8,as:UInt64.self)) : nil,
            modificationTimeNanoseconds:flags & 2 != 0 ? Int64(littleEndian:address.loadUnaligned(fromByteOffset:Int(header.timeOffset)+i*8,as:Int64.self)) : nil)
    }
}

public enum MetadataWriter {
    public static let maximumChunkBytes = 65536
    private static func emit(fd:Int32,base:SnapshotHeader,provisional:MetadataHeader,value:(UInt32)->FileMetadataValue,
                             fault:((SnapshotFailurePoint)throws->Void)?,checkpoint:()throws->Void) throws -> MetadataHeader {
        try snapshotWriteAll(fd,Data(repeating:0,count:256)); try fault?(.afterHeader)
        var crc:UInt32 = 0
        func chunk(_ data:Data) throws { try checkpoint(); try snapshotWriteAll(fd,data); crc = SnapshotFormat.crc(data,previous:crc) }
        let count = Int(provisional.count)
        for time in [false,true] {
            for start in stride(from:0,to:count,by:8192) {
                var bytes = Data(repeating:0,count:min(8192,count-start)*8)
                for id in start..<min(start+8192,count) {
                    let v = value(UInt32(id))
                    if time { bytes.put(v.modificationTimeNanoseconds ?? 0,at:(id-start)*8) }
                    else { bytes.put(v.logicalSize ?? 0,at:(id-start)*8) }
                }
                try chunk(bytes)
            }
        }
        for start in stride(from:0,to:count,by:16384) {
            var bytes = Data(repeating:0,count:(min(16384,count-start)+3)/4)
            for id in start..<min(start+16384,count) {
                let v = value(UInt32(id)), flags:UInt8 = (v.logicalSize == nil ? 0 : 1) | (v.modificationTimeNanoseconds == nil ? 0 : 2)
                bytes[(id-start)/4] |= flags << (((id-start)%4)*2)
            }
            try chunk(bytes)
        }
        let header = try MetadataHeader(base:base,cursor:provisional.cursor,
            metadataUUID:provisional.metadataUUID,createdAtUnixSeconds:provisional.createdAtUnixSeconds,payloadCRC:crc)
        var footer = Data("APFMTEND".utf8); footer.append(Data(repeating:0,count:8)); footer.put(header.fileLength,at:8)
        try snapshotWriteAll(fd,footer); try snapshotWriteAll(fd,header.encoded(),offset:0)
        return header
    }
    static func stage(store:SnapshotStore,base:SnapshotHeader,cursor:UInt64,value:(UInt32)->FileMetadataValue,
                      fault:((SnapshotFailurePoint)throws->Void)?,checkpoint:()throws->Void = {}) throws -> StagedMetadataFile {
        let provisional = try MetadataHeader(base:base,cursor:cursor)
        return try store.stageMetadata(base:base,write:{ fd in try emit(fd:fd,base:base,provisional:provisional,value:value,fault:fault,checkpoint:checkpoint) },fault:fault)
    }
    @discardableResult
    public static func write(store:SnapshotStore,base:SnapshotHeader,cursor:UInt64,
        metadataUUID:UUID = UUID(),createdAtUnixSeconds:UInt64 = UInt64(Date().timeIntervalSince1970),
        value:(UInt32)->FileMetadataValue,beforePublish:()throws->Void = {},fault:((SnapshotFailurePoint)throws->Void)? = nil,
        cancellation:CancellationToken = .init(),checkpoint:@escaping ()throws->Void = {}) throws -> MetadataHeader {
        let provisional = try MetadataHeader(base:base,cursor:cursor,metadataUUID:metadataUUID,createdAtUnixSeconds:createdAtUnixSeconds)
        func check() throws { guard !cancellation.isCancelled else { throw SnapshotError.cancelled }; try checkpoint() }
        return try store.publish(name:store.metadataFilename,write:{ fd in
            try emit(fd:fd,base:base,provisional:provisional,value:value,fault:fault,checkpoint:check)
        },beforePublish:{ try check(); try beforePublish() },fault:fault,validate:{fd in _ = try MMapMetadataIndex(fileDescriptor:fd,base:base,checkpoint:check)})
    }
}
