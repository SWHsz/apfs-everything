import Foundation

/// A fixed 128-byte durable fence bound to exactly one immutable snapshot.
/// A damaged/stale state is ignored; it never invalidates the base snapshot.
public struct CursorState: Sendable {
    public static let size = 128
    let uuid: UUID
    let generation: UInt64
    let length: UInt64
    let payloadCRC: UInt32
    let volume: UUID
    let history: UUID
    public let cursor: UInt64

    init(header: SnapshotHeader, cursor: UInt64) throws {
        guard let uuid = header.snapshotUUID, cursor >= header.lastProcessedEventID, cursor != UInt64.max else {
            throw SnapshotError.invalid("state UUID/cursor")
        }
        self.uuid = uuid; generation = header.indexGeneration; length = header.fileLength
        payloadCRC = header.payloadCRC32; volume = header.volumeUUID; history = header.historyUUID
        self.cursor = cursor
    }
    private init(uuid: UUID, generation: UInt64, length: UInt64, payloadCRC: UInt32,
                 volume: UUID, history: UUID, cursor: UInt64) {
        self.uuid = uuid; self.generation = generation; self.length = length; self.payloadCRC = payloadCRC
        self.volume = volume; self.history = history; self.cursor = cursor
    }
    func matches(_ h: SnapshotHeader) -> Bool {
        uuid == h.snapshotUUID && generation == h.indexGeneration && length == h.fileLength &&
        payloadCRC == h.payloadCRC32 && volume == h.volumeUUID && history == h.historyUUID &&
        cursor >= h.lastProcessedEventID && cursor != UInt64.max
    }
    func encoded() -> Data {
        var d = Data(repeating: 0, count: Self.size)
        d.replaceSubrange(0..<8, with: Array("APFSSTA\0".utf8))
        d.put(UInt32(1), at: 8); d.put(UInt32(Self.size), at: 12)
        d.replaceSubrange(16..<32, with: uuid.bytes)
        d.put(generation, at: 32); d.put(length, at: 40); d.put(payloadCRC, at: 48)
        d.replaceSubrange(56..<72, with: volume.bytes); d.replaceSubrange(72..<88, with: history.bytes)
        d.put(cursor, at: 88); d.put(SnapshotFormat.crc(d), at: 96)
        return d
    }
    static func decode(_ d: Data) throws -> CursorState {
        guard d.count == size else { throw SnapshotError.invalid("state size") }
        func n<T: FixedWidthInteger>(_ offset: Int, _: T.Type) -> T {
            d.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
        }
        var copy = d; copy.put(UInt32(0), at: 96)
        guard Array(d.prefix(8)) == Array("APFSSTA\0".utf8), n(8, UInt32.self) == 1,
              n(12, UInt32.self) == size, n(52, UInt32.self) == 0,
              d[100..<128].allSatisfy({ $0 == 0 }), SnapshotFormat.crc(copy) == n(96, UInt32.self) else {
            throw SnapshotError.invalid("state layout/CRC")
        }
        return .init(uuid: UUID(bytes: Array(d[16..<32])), generation: n(32, UInt64.self),
            length: n(40, UInt64.self), payloadCRC: n(48, UInt32.self),
            volume: UUID(bytes: Array(d[56..<72])), history: UUID(bytes: Array(d[72..<88])), cursor: n(88, UInt64.self))
    }
}
