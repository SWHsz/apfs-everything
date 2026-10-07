import Foundation

/// The two durable fences are independent; an invalid state falls back to its sidecar header.
public struct MetadataCursorState: Sendable {
    public static let size = 160
    let metadataUUID: UUID
    let baseUUID: UUID
    let baseGeneration: UInt64
    let baseLength: UInt64
    let baseCRC: UInt32
    let metadataCRC: UInt32
    let metadataLength: UInt64
    let volumeUUID: UUID
    let historyUUID: UUID
    public let cursor: UInt64
    public init(header: MetadataHeader, cursor: UInt64) throws {
        guard cursor >= header.cursor, cursor != UInt64.max else { throw SnapshotError.invalid("metadata state cursor") }
        metadataUUID = header.metadataUUID; baseUUID = header.baseUUID; baseGeneration = header.baseGeneration
        baseLength = header.baseLength; baseCRC = header.baseCRC; metadataCRC = header.payloadCRC
        metadataLength = header.fileLength; volumeUUID = header.volumeUUID; historyUUID = header.historyUUID
        self.cursor = cursor
    }
    private init(_ d: Data) {
        func n<T: FixedWidthInteger>(_ o:Int,_ t:T.Type)->T { d.withUnsafeBytes { T(littleEndian:$0.loadUnaligned(fromByteOffset:o,as:t)) } }
        metadataUUID = UUID(bytes:Array(d[16..<32])); baseUUID = UUID(bytes:Array(d[32..<48]))
        baseGeneration = n(48,UInt64.self); baseLength = n(56,UInt64.self); baseCRC = n(64,UInt32.self)
        metadataCRC = n(68,UInt32.self); metadataLength = n(72,UInt64.self)
        volumeUUID = UUID(bytes:Array(d[80..<96])); historyUUID = UUID(bytes:Array(d[96..<112])); cursor = n(112,UInt64.self)
    }
    public func matches(_ h: MetadataHeader) -> Bool {
        metadataUUID == h.metadataUUID && baseUUID == h.baseUUID && baseGeneration == h.baseGeneration &&
            baseLength == h.baseLength && baseCRC == h.baseCRC && metadataCRC == h.payloadCRC &&
            metadataLength == h.fileLength && volumeUUID == h.volumeUUID && historyUUID == h.historyUUID &&
            cursor >= h.cursor && cursor != UInt64.max
    }
    public func encoded() -> Data {
        var d = Data(repeating:0,count:Self.size)
        d.replaceSubrange(0..<8,with:Array("APFMSTAT".utf8)); d.put(UInt32(1),at:8); d.put(UInt32(Self.size),at:12)
        for (o,u) in [(16,metadataUUID),(32,baseUUID),(80,volumeUUID),(96,historyUUID)] { d.replaceSubrange(o..<(o+16),with:u.bytes) }
        d.put(baseGeneration,at:48); d.put(baseLength,at:56); d.put(baseCRC,at:64); d.put(metadataCRC,at:68)
        d.put(metadataLength,at:72); d.put(cursor,at:112); d.put(SnapshotFormat.crc(d),at:120); return d
    }
    public static func decode(_ d:Data) throws -> MetadataCursorState {
        guard d.count == Self.size else { throw SnapshotError.invalid("metadata state size") }
        var copy = d; copy.put(UInt32(0),at:120)
        let valid = d.withUnsafeBytes { raw in
            Array(raw.prefix(8)) == Array("APFMSTAT".utf8) &&
                UInt32(littleEndian:raw.loadUnaligned(fromByteOffset:8,as:UInt32.self)) == 1 &&
                UInt32(littleEndian:raw.loadUnaligned(fromByteOffset:12,as:UInt32.self)) == Self.size &&
                UInt32(littleEndian:raw.loadUnaligned(fromByteOffset:120,as:UInt32.self)) == SnapshotFormat.crc(copy)
        }
        guard valid, d[124..<160].allSatisfy({$0 == 0}) else { throw SnapshotError.invalid("metadata state layout/CRC") }
        return MetadataCursorState(d)
    }
    public static func streamStart(namespaceCursor: UInt64, metadataCursor: UInt64) -> UInt64 {
        min(namespaceCursor,metadataCursor)
    }
}
