import Darwin
import Foundation

/// Metadata sidecar v1 with bounded pread; no mmap is used to validate columns.
public final class PReadMetadataIndex: ImmutableMetadataBase, @unchecked Sendable {
  public let header: MetadataHeader
  public let residentAfterValidation: UInt64
  public var residentAfterRuntimeRemap: UInt64 { residentAfterValidation }
  private let backing: PReadBacking
  private let bytes: IndexFileBytes
  public init(fileDescriptor:Int32,base:SnapshotHeader,maximumCacheBytes:Int = 4*1024*1024,
    validateStorage:@escaping @Sendable () throws -> Void = {},checkpoint:()throws->Void = {}) throws {
    let backing = try PReadBacking(fileDescriptor:fileDescriptor,maximumCacheBytes:maximumCacheBytes,validateStorage:validateStorage)
    let raw = IndexFileBytes(backing)
    do {
      let h = try Self.decode(raw,base:base,checkpoint:checkpoint)
      for start in stride(from:0,to:Int(h.count),by:4096) {
        try checkpoint()
        let end = min(Int(h.count),start+4096)
        let sizes = try raw.read(256+start*8,(end-start)*8)
        let times = try raw.read(Int(h.timeOffset)+start*8,(end-start)*8)
        let firstByte = start/4, lastByte = (end+3)/4
        let validity = try raw.read(Int(h.validityOffset)+firstByte,lastByte-firstByte)
        try sizes.withUnsafeBytes { s in
          try times.withUnsafeBytes { t in
            for id in start..<end {
              let bits = (validity[id/4-firstByte] >> ((id%4)*2)) & 3
              if bits & 1 == 0 && s.loadUnaligned(fromByteOffset:(id-start)*8,as:UInt64.self) != 0 { throw SnapshotError.invalid("metadata unknown size column") }
              if bits & 2 == 0 && t.loadUnaligned(fromByteOffset:(id-start)*8,as:UInt64.self) != 0 { throw SnapshotError.invalid("metadata unknown time column") }
            }
          }
        }
      }
      self.header = h; self.backing = backing; self.bytes = raw
      raw.clear(); residentAfterValidation = Metrics.processUsage().residentBytes
    } catch { backing.close(); throw error }
  }
  private static func decode(_ raw:IndexFileBytes,base:SnapshotHeader,checkpoint:()throws->Void) throws -> MetadataHeader {
    let size = raw.backing.length
    func n<T:FixedWidthInteger>(_ offset:Int,_ type:T.Type)throws->T { try raw.number(offset,type) }
        guard size >= 272 else { throw SnapshotError.invalid("metadata truncated") }
        guard Array((try raw.read(0,8))) == Array("APFSMETA".utf8), (try n(8,UInt32.self)) == 1, (try n(12,UInt32.self)) == 256,
              (try raw.slice(60..<64)).allSatisfy({$0 == 0}), (try raw.slice(192..<256)).allSatisfy({$0 == 0}) else { throw SnapshotError.invalid("metadata header") }
        var copy = Data((try raw.read(0,256))); copy.put(UInt32(0), at:188)
        guard SnapshotFormat.crc(copy) == (try n(188,UInt32.self)) else { throw SnapshotError.invalid("metadata header CRC") }
        let h = try MetadataHeader(base:base, cursor:(try n(112,UInt64.self)),
            metadataUUID:UUID(bytes:Array((try raw.slice(64..<80)))),createdAtUnixSeconds:(try n(168,UInt64.self)),payloadCRC:(try n(184,UInt32.self)))
        guard (try n(16,UInt64.self)) == h.count, UUID(bytes:Array((try raw.slice(24..<40)))) == h.baseUUID,
              (try n(40,UInt64.self)) == h.baseGeneration, (try n(48,UInt64.self)) == h.baseLength, (try n(56,UInt32.self)) == h.baseCRC,
              UUID(bytes:Array((try raw.slice(80..<96)))) == h.volumeUUID, UUID(bytes:Array((try raw.slice(96..<112)))) == h.historyUUID else {
            throw SnapshotError.identity("metadata namespace base")
        }
        for (o,v) in [(120,h.sizeOffset),(128,h.sizeLength),(136,h.timeOffset),(144,h.timeLength),
                      (152,h.validityOffset),(160,h.validityLength),(176,h.fileLength)] {
            guard (try n(o,UInt64.self)) == v else { throw SnapshotError.invalid("metadata column offsets") }
        }
        guard h.fileLength == UInt64(size), Array((try raw.slice((size-16)..<(size-8)))) == Array("APFMTEND".utf8),
              (try n(size-8,UInt64.self)) == h.fileLength else { throw SnapshotError.invalid("metadata footer/length") }
        guard try raw.crc(256..<(size-16),checkpoint:checkpoint) == h.payloadCRC else {
            throw SnapshotError.invalid("metadata payload CRC")
        }
        if h.count % 4 != 0 {
            let used = Int(h.count % 4) * 2
            guard (try raw.byte(size-17)) >> used == 0 else { throw SnapshotError.invalid("metadata bitmap padding") }
        }
        return h
  }
  public func checkStorage() throws { _ = try backing.read(offset:0,count:0,cancellation:nil) }
  public func close() { backing.close(); bytes.clear() }
  public var cachedBytes:Int { backing.cachedBytes }
  @discardableResult public func reclaimPages() -> Bool { bytes.clear(); return true }
  struct ReadBlock {
    let start:Int,end:Int,sizes:Data,times:Data,validity:Data
    func value(_ id:UInt32) -> FileMetadataValue {
      let i = Int(id),flags = validity[(i-start)/4] >> ((i%4)*2)
      let size:UInt64? = flags & 1 == 0 ? nil : sizes.withUnsafeBytes {UInt64(littleEndian:$0.loadUnaligned(fromByteOffset:(i-start)*8,as:UInt64.self))}
      let time:Int64? = flags & 2 == 0 ? nil : times.withUnsafeBytes {Int64(littleEndian:$0.loadUnaligned(fromByteOffset:(i-start)*8,as:Int64.self))}
      return .init(logicalSize:size,modificationTimeNanoseconds:time)
    }
  }
  func readBlock(containing id:UInt32) throws -> ReadBlock {
    let start = Int(id)/4096*4096,end = min(Int(header.count),start+4096)
    guard start < end else {throw IndexBackingError.invalidRange}
    return try .init(start:start,end:end,sizes:bytes.read(256+start*8,(end-start)*8),
      times:bytes.read(Int(header.timeOffset)+start*8,(end-start)*8),
      validity:bytes.read(Int(header.validityOffset)+start/4,(end-start+3)/4))
  }
  public func value(at ordinal:UInt32) throws -> FileMetadataValue {
    guard UInt64(ordinal) < header.count else { return .unknown }
    let i = Int(ordinal)
    let flags = try bytes.byte(Int(header.validityOffset)+i/4) >> ((i%4)*2)
    let size:UInt64? = flags & 1 == 0 ? nil : try bytes.number(256+i*8,UInt64.self)
    let time:Int64? = flags & 2 == 0 ? nil : try bytes.number(Int(header.timeOffset)+i*8,Int64.self)
    return .init(logicalSize:size,modificationTimeNanoseconds:time)
  }
}
