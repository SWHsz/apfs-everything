import Foundation

/// A small decoder window, separate from the bounded backing cache. Neither
/// pointers nor a whole-index Data value are retained or returned to clients.
final class IndexFileBytes: @unchecked Sendable {
  let backing: any ReadOnlyIndexBacking
  private let lock = NSLock()
  private var pages: [Int: Data] = [:]
  private var order: [Int] = []
  private let pageSize = 64 * 1024
  init(_ backing: any ReadOnlyIndexBacking) { self.backing = backing }
  func clear() { lock.withLock { pages.removeAll(); order.removeAll() }; backing.reclaimPages() }
  func read(_ offset: Int, _ count: Int) throws -> Data { try backing.read(offset:offset,count:count,cancellation:nil) }
  func withBytes<T>(_ offset: Int, _ count: Int, _ body: (UnsafeRawBufferPointer) throws -> T) throws -> T {
    guard offset >= 0, count >= 0, offset <= backing.length, count <= backing.length-offset else {
      throw IndexBackingError.invalidRange
    }
    if count == 0 { return try Data().withUnsafeBytes(body) }
    let page = offset/pageSize, end = (offset+count-1)/pageSize
    if page != end { return try read(offset,count).withUnsafeBytes(body) }
    return try lock.withLock {
      // A zero-byte backing read validates storage even for a decoder cache hit.
      _ = try backing.read(offset:0,count:0,cancellation:nil)
      let bytes: Data
      if let cached = pages[page] { bytes = cached }
      else {
        bytes = try backing.read(offset:page*pageSize,count:min(pageSize,backing.length-page*pageSize),cancellation:nil)
        if pages.count == 4 { pages.removeValue(forKey:order.removeFirst()) }
        pages[page] = bytes; order.append(page)
      }
      return try bytes.withUnsafeBytes { raw in
        try body(UnsafeRawBufferPointer(rebasing:raw[(offset%pageSize)..<(offset%pageSize+count)]))
      }
    }
  }
  func number<T: FixedWidthInteger>(_ offset: Int, _: T.Type) throws -> T {
    try withBytes(offset,MemoryLayout<T>.size) { T(littleEndian:$0.loadUnaligned(as:T.self)) }
  }
  func byte(_ offset: Int) throws -> UInt8 { try number(offset,UInt8.self) }
  func slice(_ range: Range<Int>) throws -> Data { try read(range.lowerBound,range.count) }
  func crc(_ range: Range<Int>, checkpoint: () throws -> Void) throws -> UInt32 {
    var crc: UInt32 = 0
    for offset in stride(from:range.lowerBound,to:range.upperBound,by:1024*1024) {
      try checkpoint()
      let data = try read(offset,min(1024*1024,range.upperBound-offset))
      crc = SnapshotFormat.crc(data,previous:crc)
    }
    return crc
  }
}
