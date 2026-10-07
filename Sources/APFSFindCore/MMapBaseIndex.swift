import Darwin
import Foundation

public struct BaseRecord: Sendable {
  public var parent: UInt32
  public var firstChild: UInt32
  public var childCount: UInt32
  public var subtreeEnd: UInt32
  public var nameOffset: UInt32
  public var foldedOffset: UInt32
  public var nameLength: UInt16
  public var foldedLength: UInt16
  public var kind: EntryKind
  public var flags: UInt8
  public var fileID: UInt64
  var encoded: Data {
    var d = Data(repeating: 0, count: 40)
    for (o, v) in [
      (0, parent), (4, firstChild), (8, childCount), (12, subtreeEnd), (16, nameOffset),
      (20, foldedOffset),
    ] { d.put(v, at: o) }
    d.put(nameLength, at: 24)
    d.put(foldedLength, at: 26)
    d[28] = kind.snapshotCode
    d[29] = flags
    d.put(fileID, at: 32)
    return d
  }
}

/// Owns a single read-only mapping and descriptor. Query captures retain this
/// object across atomic rename and base swaps; no mapped pointer escapes it.
public final class MMapBaseIndex: @unchecked Sendable {
  public static let version: UInt32 = 2
  public static let headerSize = 256
  public let header: SnapshotHeader
  public let root: String
  public let mmapMilliseconds: Double
  public let validationMilliseconds: Double
  public let residentAfterMmap: UInt64
  public let residentAfterValidation: UInt64
  public let residentAfterRuntimeRemap: UInt64
  public let files: Int
  public let directories: Int
  private let fd: Int32
  private let address: UnsafeMutableRawPointer
  private let length: Int
  private let foldedOffset: Int
  private let childOffset: Int
  public var count: Int { Int(header.recordCount) }
  public var mappedBytes: Int { length }
  public convenience init(path: String, identity: VolumeIdentity) throws {
    let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw SnapshotError.io("open base", errno) }
    try self.init(fileDescriptor: fd, identity: identity)
  }
  public init(fileDescriptor: Int32, identity: VolumeIdentity, checkpoint: () throws -> Void = {}) throws {
    let started = ProcessInfo.processInfo.systemUptime
    var st = stat()
    guard fcntl(fileDescriptor, F_GETFL) & O_ACCMODE == O_RDONLY, fstat(fileDescriptor, &st) == 0,
      st.st_uid == geteuid(), st.st_mode & S_IFMT == S_IFREG,
      st.st_mode & 0o7777 == 0o600
    else {
      close(fileDescriptor)
      throw SnapshotError.unsafePath("base owner/type/mode")
    }
    guard st.st_size >= 272, UInt64(st.st_size) <= SnapshotFormat.maxFileBytes else {
      close(fileDescriptor)
      throw SnapshotError.invalid("v2 size")
    }
    let size = Int(st.st_size)
    let mapStart = ProcessInfo.processInfo.systemUptime
    guard let pointer = mmap(nil, size, PROT_READ, MAP_PRIVATE, fileDescriptor, 0),
      pointer != MAP_FAILED
    else {
      let code = errno
      close(fileDescriptor)
      throw SnapshotError.io("mmap base", code)
    }
    let mapMS = (ProcessInfo.processInfo.systemUptime - mapStart) * 1000
    let rss = Metrics.processUsage().residentBytes
    do {
      let raw = UnsafeRawBufferPointer(start: pointer, count: size)
      func n<T: FixedWidthInteger>(_ o: Int, _ type: T.Type) -> T {
        T(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: type))
      }
      guard Array(raw.prefix(8)) == SnapshotFormat.magic, n(8, UInt32.self) == 2,
        n(12, UInt32.self) == 256, n(16, UInt32.self) == 1, n(20, UInt32.self) == 40,
        raw[184..<192].allSatisfy({ $0 == 0 }), raw[224..<256].allSatisfy({ $0 == 0 })
      else { throw SnapshotError.invalid("v2 header") }
      var copy = Data(raw.prefix(256))
      copy.put(UInt32(0), at: 148)
      guard SnapshotFormat.crc(copy) == n(148, UInt32.self) else {
        throw SnapshotError.invalid("v2 header CRC")
      }
      let h = SnapshotHeader(
        recordCount: n(24, UInt64.self), recordTableOffset: n(32, UInt64.self),
        recordTableLength: n(40, UInt64.self),
        nameBlobOffset: n(48, UInt64.self), nameBlobLength: n(56, UInt64.self),
        rootPathOffset: n(64, UInt64.self), rootPathLength: n(72, UInt64.self),
        createdAtUnixSeconds: n(80, UInt64.self), indexGeneration: n(88, UInt64.self),
        lastProcessedEventID: n(96, UInt64.self), rootDeviceID: n(104, UInt64.self),
        volumeUUID: UUID(bytes: Array(raw[112..<128])),
        historyUUID: UUID(bytes: Array(raw[128..<144])), payloadCRC32: n(144, UInt32.self),
        fileLength: n(152, UInt64.self), rootFileID: n(160, UInt64.self),
        snapshotUUID: UUID(bytes: Array(raw[168..<184])))
      let foldOffset = n(192, UInt64.self)
      let foldLength = n(200, UInt64.self)
      let childrenOffset = n(208, UInt64.self)
      let childrenLength = n(216, UInt64.self)
      guard h.recordCount > 0, h.recordCount <= SnapshotFormat.maxRecords, h.fileLength == size,
        h.indexGeneration != .max, h.lastProcessedEventID != .max, h.rootPathOffset == 256,
        h.rootPathLength > 0, h.rootPathLength < PATH_MAX, h.nameBlobLength <= UInt32.max,
        foldLength <= UInt32.max,
        h.recordTableLength == h.recordCount * 40,
        h.recordTableOffset
          == (try SnapshotFormat.add(try SnapshotFormat.add(256, h.rootPathLength), 7)) & ~UInt64(
            7),
        h.nameBlobOffset == (try SnapshotFormat.add(h.recordTableOffset, h.recordTableLength)),
        foldOffset == (try SnapshotFormat.add(h.nameBlobOffset, h.nameBlobLength)),
        childrenOffset == (try SnapshotFormat.add(foldOffset, foldLength)),
        childrenLength == (h.recordCount - 1) * 4,
        (try SnapshotFormat.add(try SnapshotFormat.add(childrenOffset, childrenLength), 16))
          == h.fileLength
      else {
        throw SnapshotError.invalid("v2 section layout")
      }
      guard raw[Int(256 + h.rootPathLength)..<Int(h.recordTableOffset)].allSatisfy({ $0 == 0 }),
        Array(raw[(size - 16)..<(size - 8)]) == Array("APFSEND\0".utf8),
        n(size - 4, UInt32.self) == 0
      else { throw SnapshotError.invalid("v2 padding/footer") }
      guard
        try SnapshotFormat.checkedCRC(UnsafeRawBufferPointer(rebasing: raw[256..<(size - 16)]), checkpoint:checkpoint)
          == n(size - 8, UInt32.self),
        try SnapshotFormat.checkedCRC(UnsafeRawBufferPointer(rebasing: raw[256..<size]), checkpoint:checkpoint) == h.payloadCRC32
      else { throw SnapshotError.invalid("v2 payload/footer CRC") }
      guard let root = String(bytes: raw[256..<Int(256 + h.rootPathLength)], encoding: .utf8),
        PathCanonicalizer.normalize(root) == root, !root.utf8.contains(0),
        Array(root.utf8) == Array(identity.root.utf8),
        h.volumeUUID == identity.volumeUUID, h.historyUUID == identity.historyUUID,
        h.rootDeviceID == identity.deviceID, h.rootFileID == identity.rootFileID
      else { throw SnapshotError.identity("v2 root/device/UUID") }
      func record(_ i: Int) throws -> BaseRecord {
        let o = Int(h.recordTableOffset) + i * 40
        guard let kind = EntryKind(snapshotCode: raw[o + 28]), raw[o + 29] & ~UInt8(1) == 0,
          n(o + 30, UInt16.self) == 0
        else { throw SnapshotError.invalid("v2 record flags") }
        return .init(
          parent: n(o, UInt32.self), firstChild: n(o + 4, UInt32.self),
          childCount: n(o + 8, UInt32.self), subtreeEnd: n(o + 12, UInt32.self),
          nameOffset: n(o + 16, UInt32.self), foldedOffset: n(o + 20, UInt32.self),
          nameLength: n(o + 24, UInt16.self), foldedLength: n(o + 26, UInt16.self),
          kind: kind, flags: raw[o + 29], fileID: n(o + 32, UInt64.self))
      }
      var nameEnd: UInt64 = 0
      var foldEnd: UInt64 = 0
      var childEnd: UInt64 = 0
      var lengths = [UInt32](repeating: 0, count: Int(h.recordCount))
      var fileCount = 0
      var dirCount = 0
      for i in 0..<Int(h.recordCount) {
        if i % 4096 == 0 { try checkpoint() }
        let r = try record(i)
        guard UInt64(r.nameOffset) == nameEnd, UInt64(r.foldedOffset) == foldEnd,
          UInt64(r.firstChild) == childEnd, UInt64(r.subtreeEnd) > i,
          UInt64(r.subtreeEnd) <= h.recordCount
        else { throw SnapshotError.invalid("v2 offsets/subtree") }
        nameEnd += UInt64(r.nameLength)
        foldEnd += UInt64(r.foldedLength)
        childEnd += UInt64(r.childCount)
        guard nameEnd <= h.nameBlobLength, foldEnd <= foldLength, childEnd <= h.recordCount - 1
        else { throw SnapshotError.invalid("v2 blob/child bounds") }
        if i == 0 {
          guard r.parent == .max, r.kind == .directory, r.flags == 0, r.nameLength == 0,
            r.foldedLength == 0, r.subtreeEnd == h.recordCount
          else { throw SnapshotError.invalid("v2 root record") }
          lengths[0] = UInt32(h.rootPathLength)
        } else {
          guard r.parent < i, r.nameLength > 0, r.nameLength <= NAME_MAX else {
            throw SnapshotError.invalid("v2 parent/name")
          }
          let parent = try record(Int(r.parent))
          guard parent.kind == .directory, parent.flags == 0, r.subtreeEnd <= parent.subtreeEnd
          else { throw SnapshotError.invalid("v2 nested subtree") }
          let a = Int(h.nameBlobOffset) + Int(r.nameOffset)
          let b = Int(foldOffset) + Int(r.foldedOffset)
          guard let name = String(bytes: raw[a..<a + Int(r.nameLength)], encoding: .utf8),
            name != ".", name != "..",
            !name.utf8.contains(0), !name.utf8.contains(47),
            let folded = String(bytes: raw[b..<b + Int(r.foldedLength)], encoding: .utf8),
            Array(FileEntry.fold(name).utf8) == Array(folded.utf8)
          else { throw SnapshotError.invalid("v2 name/fold") }
          lengths[i] = lengths[Int(r.parent)] + UInt32(r.nameLength) + 1
          guard lengths[i] < PATH_MAX else { throw SnapshotError.invalid("v2 path length") }
        }
        if r.kind == .file { fileCount += 1 }
        if r.kind == .directory { dirCount += 1 }
        if r.childCount == 0 {
          guard r.subtreeEnd == i + 1 else { throw SnapshotError.invalid("v2 leaf subtree") }
        } else {
          guard r.kind == .directory, r.flags == 0 else {
            throw SnapshotError.invalid("v2 non-directory children")
          }
        }
        var next = UInt32(i + 1)
        var previous: (String, String, UInt8)?
        for j in 0..<Int(r.childCount) {
          if j % 4096 == 0 { try checkpoint() }
          let child = n(Int(childrenOffset) + (Int(r.firstChild) + j) * 4, UInt32.self)
          guard child == next, child < h.recordCount else {
            throw SnapshotError.invalid("v2 child coverage/order")
          }
          let cr = try record(Int(child))
          guard cr.parent == i else { throw SnapshotError.invalid("v2 child parent") }
          let a = Int(h.nameBlobOffset) + Int(cr.nameOffset)
          let b = Int(foldOffset) + Int(cr.foldedOffset)
          guard UInt64(cr.nameOffset) + UInt64(cr.nameLength) <= h.nameBlobLength,
            UInt64(cr.foldedOffset) + UInt64(cr.foldedLength) <= foldLength
          else { throw SnapshotError.invalid("v2 child name bounds") }
          let key = (
            String(decoding: raw[b..<b + Int(cr.foldedLength)], as: UTF8.self),
            String(decoding: raw[a..<a + Int(cr.nameLength)], as: UTF8.self), cr.kind.snapshotCode
          )
          if let p = previous {
            guard Self.less(p, key), p.1 != key.1 else {
              throw SnapshotError.invalid("v2 child sorting/duplicate")
            }
          }
          previous = key
          next = cr.subtreeEnd
        }
        if r.childCount > 0 {
          guard next == r.subtreeEnd else { throw SnapshotError.invalid("v2 subtree coverage") }
        }
      }
      guard nameEnd == h.nameBlobLength, foldEnd == foldLength, childEnd == h.recordCount - 1 else {
        throw SnapshotError.invalid("v2 unreferenced sections")
      }
      self.fd = fileDescriptor
      let validatedRSS = Metrics.processUsage().residentBytes
      guard let runtime = mmap(nil,size,PROT_READ,MAP_PRIVATE,fileDescriptor,0),runtime != MAP_FAILED else { throw SnapshotError.io("remap runtime base",errno) }
      munmap(pointer,size)
      address = runtime
      length = size
      header = h
      self.root = root
      self.foldedOffset = Int(foldOffset)
      childOffset = Int(childrenOffset)
      files = fileCount
      directories = dirCount
      mmapMilliseconds = mapMS
      residentAfterMmap = rss
      validationMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000 - mapMS
      residentAfterValidation = validatedRSS
      residentAfterRuntimeRemap = Metrics.processUsage().residentBytes
    } catch {
      munmap(pointer, size)
      close(fileDescriptor)
      throw error
    }
  }
  deinit {
    munmap(address, length)
    close(fd)
  }
  /// Advisory only: a later read faults validated immutable pages back in.
  @discardableResult public func reclaimPages() -> Bool { madvise(address,length,MADV_DONTNEED) == 0 }
  /// Read mapped byte ranges directly: Unicode canonical equality is not byte
  /// equality and would overestimate savings for decomposed basenames.
  public func layoutStatistics() -> [String: Any] {
    var sameCount = 0, sameBytes = 0, fileIDs = 0, directoryIDs = 0
    for i in 0..<count {
      let id = UInt32(i), r = record(at: id)
      if r.fileID != 0 {
        if r.kind == .file { fileIDs += 1 }
        if r.kind == .directory { directoryIDs += 1 }
      }
      if i != 0, originalNameBytes(at: id).elementsEqual(foldedBytes(at: id)) {
        sameCount += 1; sameBytes += Int(r.foldedLength)
      }
    }
    let foldedLength: UInt64 = n(200, UInt64.self)
    let childLength: UInt64 = n(216, UInt64.self)
    return ["record_table_bytes": header.recordTableLength,
      "child_table_bytes": childLength, "original_name_blob_bytes": header.nameBlobLength,
      "folded_name_blob_bytes": foldedLength,
      "folded_same_as_original_count": sameCount, "folded_same_as_original_bytes": sameBytes,
      "potential_fold_dedup_saving_bytes": sameBytes,
      "potential_fold_dedup_saving_ratio": Double(sameBytes) / Double(length),
      "file_id_nonzero_files": fileIDs, "file_id_nonzero_directories": directoryIDs]
  }
  static func less(_ a: (String, String, UInt8), _ b: (String, String, UInt8)) -> Bool {
    if Array(a.0.utf8) != Array(b.0.utf8) { return a.0.utf8.lexicographicallyPrecedes(b.0.utf8) }
    if Array(a.1.utf8) != Array(b.1.utf8) { return a.1.utf8.lexicographicallyPrecedes(b.1.utf8) }
    return a.2 < b.2
  }
  private func n<T: FixedWidthInteger>(_ o: Int, _ type: T.Type) -> T {
    T(littleEndian: address.loadUnaligned(fromByteOffset: o, as: type))
  }
  public func record(at i: UInt32) -> BaseRecord {
    precondition(i < count)
    let o = Int(header.recordTableOffset) + Int(i) * 40
    return .init(
      parent: n(o, UInt32.self), firstChild: n(o + 4, UInt32.self),
      childCount: n(o + 8, UInt32.self), subtreeEnd: n(o + 12, UInt32.self),
      nameOffset: n(o + 16, UInt32.self), foldedOffset: n(o + 20, UInt32.self),
      nameLength: n(o + 24, UInt16.self), foldedLength: n(o + 26, UInt16.self),
      kind: EntryKind(snapshotCode: address.load(fromByteOffset: o + 28, as: UInt8.self))!,
      flags: address.load(fromByteOffset: o + 29, as: UInt8.self), fileID: n(o + 32, UInt64.self))
  }
  public func name(at i: UInt32) -> String {
    let r = record(at: i)
    return String(
      decoding: UnsafeRawBufferPointer(
        start: address.advanced(by: Int(header.nameBlobOffset) + Int(r.nameOffset)),
        count: Int(r.nameLength)), as: UTF8.self)
  }
  func originalNameBytes(at i: UInt32) -> UnsafeRawBufferPointer {
    let r = record(at: i)
    return .init(
      start: address.advanced(by: Int(header.nameBlobOffset) + Int(r.nameOffset)),
      count: Int(r.nameLength))
  }
  public func foldedName(at i: UInt32) -> String {
    String(decoding: foldedBytes(at: i), as: UTF8.self)
  }
  func foldedBytes(at i: UInt32) -> UnsafeRawBufferPointer {
    let r = record(at: i)
    return .init(
      start: address.advanced(by: foldedOffset + Int(r.foldedOffset)), count: Int(r.foldedLength))
  }
  public func directChildren(of i: UInt32) -> [UInt32] {
    let r = record(at: i)
    return (0..<Int(r.childCount)).map {
      n(childOffset + (Int(r.firstChild) + $0) * 4, UInt32.self)
    }
  }
  public func subtreeRange(of i: UInt32) -> Range<UInt32> { i..<record(at: i).subtreeEnd }
  public func lookupChild(parent: UInt32, name: String) -> UInt32? {
    let key = (FileEntry.fold(name), name, UInt8(0))
    let r = record(at: parent)
    var lo = 0
    var hi = Int(r.childCount)
    while lo < hi {
      let m = (lo + hi) / 2
      let id: UInt32 = n(childOffset + (Int(r.firstChild) + m) * 4, UInt32.self)
      let k = (foldedName(at: id), self.name(at: id), record(at: id).kind.snapshotCode)
      if Self.less(k, key) { lo = m + 1 } else { hi = m }
    }
    guard lo < Int(r.childCount) else { return nil }
    let id: UInt32 = n(childOffset + (Int(r.firstChild) + lo) * 4, UInt32.self)
    return Array(self.name(at: id).utf8) == Array(name.utf8) ? id : nil
  }
  public func reconstructPath(_ i: UInt32) -> String {
    var parts: [String] = []
    var id = i
    while id != 0 {
      parts.append(name(at: id))
      id = record(at: id).parent
    }
    return parts.isEmpty
      ? root : (root == "/" ? "" : root) + "/" + parts.reversed().joined(separator: "/")
  }
  public func directoryMap() -> [String: EntryRef] {
    var map: [String: EntryRef] = [root: .base(0)]
    var paths: [UInt32: String] = [0: root]
    map.reserveCapacity(directories)
    paths.reserveCapacity(directories)
    for i in 1..<count where record(at: UInt32(i)).kind == .directory {
      let id = UInt32(i)
      let r = record(at: id)
      let parent = paths[r.parent]!
      let path = (parent == "/" ? "" : parent) + "/" + name(at: id)
      paths[id] = path
      map[path] = .base(id)
    }
    return map
  }
}
