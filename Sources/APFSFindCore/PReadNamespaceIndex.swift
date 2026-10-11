import Darwin
import Foundation

/// Namespace v2 on disconnectable storage. Validation and queries use owned
/// blocks throughout; no file mapping is created, including during validation.
public final class PReadNamespaceIndex: ImmutableNamespaceBase, @unchecked Sendable {
  public let header: SnapshotHeader
  public let root: String
  public let validationMilliseconds: Double
  public let files: Int
  public let directories: Int
  public var count: Int { Int(header.recordCount) }
  public var mappedBytes: Int { 0 }
  public var mmapMilliseconds: Double { 0 }
  public var residentAfterMmap: UInt64 { 0 }
  public let residentAfterValidation: UInt64
  public var residentAfterRuntimeRemap: UInt64 { residentAfterValidation }
  private let bytes: IndexFileBytes
  private let backing: PReadBacking
  private let foldedOffset: Int
  private let childOffset: Int
  public init(fileDescriptor: Int32, identity: VolumeIdentity,
    maximumCacheBytes: Int = 4*1024*1024,
    allowRootRebinding: Bool = false,
    validateStorage: @escaping @Sendable () throws -> Void = {},
    checkpoint: () throws -> Void = {}) throws {
    let started = ProcessInfo.processInfo.systemUptime
    let backing = try PReadBacking(fileDescriptor:fileDescriptor,maximumCacheBytes:maximumCacheBytes,validateStorage:validateStorage)
    let raw = IndexFileBytes(backing), size = backing.length
    do {
      guard size >= 272 else { throw SnapshotError.invalid("v2 size") }
      func n<T: FixedWidthInteger>(_ offset:Int,_ type:T.Type) throws -> T { try raw.number(offset,type) }
      guard Array((try raw.read(0,8))) == SnapshotFormat.magic, (try n(8, UInt32.self)) == 2,
        (try n(12, UInt32.self)) == 256, (try n(16, UInt32.self)) == 1, (try n(20, UInt32.self)) == 40,
        (try raw.slice(184..<192)).allSatisfy({ $0 == 0 }), (try raw.slice(224..<256)).allSatisfy({ $0 == 0 })
      else { throw SnapshotError.invalid("v2 header") }
      var copy = Data((try raw.read(0,256)))
      copy.put(UInt32(0), at: 148)
      guard SnapshotFormat.crc(copy) == (try n(148, UInt32.self)) else {
        throw SnapshotError.invalid("v2 header CRC")
      }
      var h = SnapshotHeader(
        recordCount: (try n(24, UInt64.self)), recordTableOffset: (try n(32, UInt64.self)),
        recordTableLength: (try n(40, UInt64.self)),
        nameBlobOffset: (try n(48, UInt64.self)), nameBlobLength: (try n(56, UInt64.self)),
        rootPathOffset: (try n(64, UInt64.self)), rootPathLength: (try n(72, UInt64.self)),
        createdAtUnixSeconds: (try n(80, UInt64.self)), indexGeneration: (try n(88, UInt64.self)),
        lastProcessedEventID: (try n(96, UInt64.self)), rootDeviceID: (try n(104, UInt64.self)),
        volumeUUID: UUID(bytes: Array((try raw.slice(112..<128)))),
        historyUUID: UUID(bytes: Array((try raw.slice(128..<144)))), payloadCRC32: (try n(144, UInt32.self)),
        fileLength: (try n(152, UInt64.self)), rootFileID: (try n(160, UInt64.self)),
        snapshotUUID: UUID(bytes: Array((try raw.slice(168..<184)))))
      let foldOffset = (try n(192, UInt64.self))
      let foldLength = (try n(200, UInt64.self))
      let childrenOffset = (try n(208, UInt64.self))
      let childrenLength = (try n(216, UInt64.self))
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
      guard (try raw.slice(Int(256 + h.rootPathLength)..<Int(h.recordTableOffset))).allSatisfy({ $0 == 0 }),
        Array((try raw.slice((size - 16)..<(size - 8)))) == Array("APFSEND\0".utf8),
        (try n(size - 4, UInt32.self)) == 0
      else { throw SnapshotError.invalid("v2 padding/footer") }
      guard
        try raw.crc(256..<(size-16), checkpoint:checkpoint)
          == (try n(size - 8, UInt32.self)),
        try raw.crc(256..<size, checkpoint:checkpoint) == h.payloadCRC32
      else { throw SnapshotError.invalid("v2 payload/footer CRC") }
      guard let root = String(bytes: (try raw.slice(256..<Int(256 + h.rootPathLength))), encoding: .utf8),
        PathCanonicalizer.normalize(root) == root, !root.utf8.contains(0),
        (allowRootRebinding || Array(root.utf8) == Array(identity.root.utf8)),
        h.volumeUUID == identity.volumeUUID, h.historyUUID == identity.historyUUID,
        (allowRootRebinding || h.rootDeviceID == identity.deviceID), h.rootFileID == identity.rootFileID
      else { throw SnapshotError.identity("v2 root/device/UUID") }
      func record(_ i: Int) throws -> BaseRecord {
        let o = Int(h.recordTableOffset) + i * 40
        guard let kind = EntryKind(snapshotCode: (try raw.byte(o + 28))), (try raw.byte(o + 29)) & ~UInt8(1) == 0,
          (try n(o + 30, UInt16.self)) == 0
        else { throw SnapshotError.invalid("v2 record flags") }
        return .init(
          parent: (try n(o, UInt32.self)), firstChild: (try n(o + 4, UInt32.self)),
          childCount: (try n(o + 8, UInt32.self)), subtreeEnd: (try n(o + 12, UInt32.self)),
          nameOffset: (try n(o + 16, UInt32.self)), foldedOffset: (try n(o + 20, UInt32.self)),
          nameLength: (try n(o + 24, UInt16.self)), foldedLength: (try n(o + 26, UInt16.self)),
          kind: kind, flags: (try raw.byte(o + 29)), fileID: (try n(o + 32, UInt64.self)))
      }
      var nameEnd: UInt64 = 0
      var foldEnd: UInt64 = 0
      var childEnd: UInt64 = 0
      var ancestors: [(id:UInt32,end:UInt32,length:UInt32)] = []
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
          if r.childCount > 0 { ancestors.append((0,r.subtreeEnd,UInt32(h.rootPathLength))) }
        } else {
          guard r.parent < i, r.nameLength > 0, r.nameLength <= NAME_MAX else {
            throw SnapshotError.invalid("v2 parent/name")
          }
          let parent = try record(Int(r.parent))
          guard parent.kind == .directory, parent.flags == 0, r.subtreeEnd <= parent.subtreeEnd
          else { throw SnapshotError.invalid("v2 nested subtree") }
          let a = Int(h.nameBlobOffset) + Int(r.nameOffset)
          let b = Int(foldOffset) + Int(r.foldedOffset)
          guard let name = String(bytes: (try raw.slice(a..<a + Int(r.nameLength))), encoding: .utf8),
            name != ".", name != "..",
            !name.utf8.contains(0), !name.utf8.contains(47),
            let folded = String(bytes: (try raw.slice(b..<b + Int(r.foldedLength))), encoding: .utf8),
            Array(FileEntry.fold(name).utf8) == Array(folded.utf8)
          else { throw SnapshotError.invalid("v2 name/fold") }
          while let last = ancestors.last, UInt32(i) >= last.end { ancestors.removeLast() }
          guard let last = ancestors.last, last.id == r.parent else { throw SnapshotError.invalid("v2 ancestor coverage") }
          let pathLength = last.length + UInt32(r.nameLength) + 1
          guard pathLength < PATH_MAX else { throw SnapshotError.invalid("v2 path length") }
          if r.childCount > 0 { ancestors.append((UInt32(i),r.subtreeEnd,pathLength)) }
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
          let child = (try n(Int(childrenOffset) + (Int(r.firstChild) + j) * 4, UInt32.self))
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
            String(decoding: (try raw.slice(b..<b + Int(cr.foldedLength))), as: UTF8.self),
            String(decoding: (try raw.slice(a..<a + Int(cr.nameLength))), as: UTF8.self), cr.kind.snapshotCode
          )
          if let p = previous {
            guard MMapBaseIndex.less(p, key), p.1 != key.1 else {
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

      // Only a caller pinned to the locator's UUID/root inode/relative-root
      // identity may rebind a mount incarnation. Disk CRC and cursor bindings
      // remain the original values; the runtime device/path uses this mount.
      if allowRootRebinding { h.rootDeviceID = identity.deviceID }
      self.header = h; self.root = allowRootRebinding ? identity.root : root; self.files = fileCount; self.directories = dirCount
      self.foldedOffset = Int(foldOffset); self.childOffset = Int(childrenOffset)
      self.bytes = raw; self.backing = backing
      raw.clear()
      validationMilliseconds = (ProcessInfo.processInfo.systemUptime-started)*1000
      residentAfterValidation = Metrics.processUsage().residentBytes
    } catch { backing.close(); throw error }
  }
  public func checkStorage() throws { _ = try backing.read(offset:0,count:0,cancellation:nil) }
  public func close() { backing.close(); bytes.clear() }
  public var cachedBytes: Int { backing.cachedBytes }
  @discardableResult public func reclaimPages() -> Bool { bytes.clear(); return true }
  private static func decodeRecord(_ raw:UnsafeRawBufferPointer) throws -> BaseRecord {
    func n<T:FixedWidthInteger>(_ o:Int,_ t:T.Type)->T { T(littleEndian:raw.loadUnaligned(fromByteOffset:o,as:t)) }
    guard let kind = EntryKind(snapshotCode:raw[28]), raw[29] & ~UInt8(1) == 0, n(30,UInt16.self) == 0 else { throw SnapshotError.invalid("v2 record flags") }
    return .init(parent:n(0,UInt32.self),firstChild:n(4,UInt32.self),childCount:n(8,UInt32.self),subtreeEnd:n(12,UInt32.self),nameOffset:n(16,UInt32.self),foldedOffset:n(20,UInt32.self),nameLength:n(24,UInt16.self),foldedLength:n(26,UInt16.self),kind:kind,flags:raw[29],fileID:n(32,UInt64.self))
  }
  public func record(at id:UInt32) throws -> BaseRecord {
    guard id < count else { throw IndexBackingError.invalidRange }
    return try bytes.withBytes(Int(header.recordTableOffset)+Int(id)*40,40,Self.decodeRecord)
  }
  public func name(at id:UInt32) throws -> String {
    let r = try record(at:id)
    return try bytes.withBytes(Int(header.nameBlobOffset)+Int(r.nameOffset),Int(r.nameLength)) { String(decoding:$0,as:UTF8.self) }
  }
  public func foldedName(at id:UInt32) throws -> String {
    let r = try record(at:id)
    return try bytes.withBytes(foldedOffset+Int(r.foldedOffset),Int(r.foldedLength)) { String(decoding:$0,as:UTF8.self) }
  }
  public func directChildren(of id:UInt32) throws -> [UInt32] {
    let r = try record(at:id)
    return try (0..<Int(r.childCount)).map { try bytes.number(childOffset+(Int(r.firstChild)+$0)*4,UInt32.self) }
  }
  public func subtreeRange(of id:UInt32) throws -> Range<UInt32> { id..<(try record(at:id)).subtreeEnd }
  public func lookupChild(parent:UInt32,name:String) throws -> UInt32? {
    let r = try record(at:parent), folded = FileEntry.fold(name)
    var lo = 0, hi = Int(r.childCount)
    while lo < hi {
      let mid = (lo+hi)/2
      let id:UInt32 = try bytes.number(childOffset+(Int(r.firstChild)+mid)*4,UInt32.self)
      if try foldedName(at:id).utf8.lexicographicallyPrecedes(folded.utf8) { lo = mid+1 } else { hi = mid }
    }
    while lo < Int(r.childCount) {
      let id:UInt32 = try bytes.number(childOffset+(Int(r.firstChild)+lo)*4,UInt32.self)
      guard try foldedName(at:id).utf8.elementsEqual(folded.utf8) else { break }
      if try self.name(at:id) == name { return id }; lo += 1
    }
    return nil
  }
  public func reconstructPath(_ ordinal:UInt32) throws -> String {
    var parts:[String] = [], id = ordinal
    while id != 0 {
      guard parts.count < 2048 else { throw SnapshotError.invalid("v2 path depth") }
      parts.append(try name(at:id)); let parent = try record(at:id).parent
      guard parent < id else { throw SnapshotError.invalid("v2 parent") }; id = parent
    }
    return parts.isEmpty ? root : (root == "/" ? "" : root)+"/"+parts.reversed().joined(separator:"/")
  }
  public func searchBase(_ query:[UInt8],limit:Int,cancellation:SearchCancellationToken?,
    scanned:((Int)->Void)?,sort:SearchSortDescriptor,
    metadata:(UInt32)throws->FileMetadataValue,deleted:(UInt32)->Bool) throws -> [MMapBaseIndex.Candidate] {
    try checkStorage()
    guard !query.isEmpty, limit > 0 else { return [] }
    final class CandidatePath {var ancestors:[UInt32]?}
    struct Ranked { let candidate:MMapBaseIndex.Candidate; let folded:String; let foldedBytes:[UInt8]; let path:CandidatePath }
    var failure:Error?
    var parents:[UInt32:UInt32] = [:],parentOrder:[UInt32] = [],parentSlot = 0
    // Repeated basename ties share a small set of ancestor components. Cache
    // their owned bytes with an independent hard bound, never complete paths.
    var originals:[UInt32:Data] = [:],originalOrder:[UInt32] = [],originalHead = 0,originalBytes = 0
    func parent(_ id:UInt32) throws -> UInt32 {
      if let cached = parents[id] {return cached}
      let value:UInt32 = try bytes.number(Int(header.recordTableOffset)+Int(id)*40,UInt32.self)
      if parents.count == 4096 {
        parents.removeValue(forKey:parentOrder[parentSlot]);parentOrder[parentSlot] = id
        parentSlot = (parentSlot+1)%4096
      } else {parentOrder.append(id)}
      parents[id] = value;return value
    }
    func ancestors(_ value:Ranked) throws -> [UInt32] {
      if let cached = value.path.ancestors {return cached}
      var result:[UInt32] = [],id = value.candidate.id
      while id != 0 {
        guard result.count < 2048 else {throw SnapshotError.invalid("v2 path depth")}
        result.append(id);let next = try parent(id)
        guard next < id else {throw SnapshotError.invalid("v2 parent")};id = next
      }
      value.path.ancestors = result;return result
    }
    func original(_ id:UInt32) throws -> Data {
      if let cached = originals[id] {return cached}
      let r = try record(at:id)
      let value = try bytes.read(Int(header.nameBlobOffset)+Int(r.nameOffset),Int(r.nameLength))
      while originalBytes+value.count > 256*1024 || originals.count >= 4096 {
        let evicted = originalOrder[originalHead];originalHead += 1
        originalBytes -= originals.removeValue(forKey:evicted)?.count ?? 0
      }
      originals[id] = value;originalBytes += value.count;originalOrder.append(id)
      if originalHead >= 4096 {originalOrder.removeFirst(originalHead);originalHead = 0}
      return value
    }
    func pathLess(_ a:Ranked,_ b:Ranked) throws -> Bool {
      let aa = try ancestors(a),bb = try ancestors(b)
      for offset in 0..<min(aa.count,bb.count) {
        let i = aa[aa.count-1-offset],j = bb[bb.count-1-offset]
        if i == j {continue}
        let p = try original(i),q = try original(j)
        let at = i == a.candidate.id,bt = j == b.candidate.id
        if p.contains(where:{$0 >= 128}) || q.contains(where:{$0 >= 128}) {
          let x = String(decoding:p,as:UTF8.self),y = String(decoding:q,as:UTF8.self)
          if x == y {continue};return x+(at ? "" : "/") < y+(bt ? "" : "/")
        }
        for k in 0..<min(p.count,q.count) where p[k] != q[k] {return p[k] < q[k]}
        if p.count != q.count {
          if p.count < q.count {return at || UInt8(47) < q[p.count]}
          return !bt && p[q.count] < UInt8(47)
        }
      }
      return aa.count < bb.count
    }
    func less(_ a:Ranked,_ b:Ranked) -> Bool {
      if sort.key == .size, let result = SearchOrdering.valueLess(a.candidate.metadata.logicalSize,b.candidate.metadata.logicalSize,direction:sort.direction) { return result }
      if sort.key == .modificationTime, let result = SearchOrdering.valueLess(a.candidate.metadata.modificationTimeNanoseconds,b.candidate.metadata.modificationTimeNanoseconds,direction:sort.direction) { return result }
      if sort.key == .name {
        if a.folded != b.folded { return sort.direction == .ascending ? a.folded < b.folded : b.folded < a.folded }
        do {
          let x = try name(at:a.candidate.id),y = try name(at:b.candidate.id)
          if x != y {return sort.direction == .ascending ? x < y : y < x}
        } catch {failure = error;return false}
      } else if a.candidate.rank != b.candidate.rank { return a.candidate.rank < b.candidate.rank }
      if a.folded != b.folded { return a.folded < b.folded }
      do { return try pathLess(a,b) }
      catch { failure = error; return false }
    }
    var top = BoundedTopK<Ranked>(limit:limit,less:less), visited = 0
    defer { scanned?(visited) }
    var foldStart = 0, foldData = Data()
    for start in stride(from:1,to:count,by:4096) {
      if cancellation?.isCancelled == true { throw IndexBackingError.cancelled }
      try checkStorage()
      let end = min(count,start+4096)
      let records = try backing.read(offset:Int(header.recordTableOffset)+start*40,count:(end-start)*40,cancellation:cancellation)
      try records.withUnsafeBytes { raw in
        for ordinal in start..<end {
          visited += 1; let id = UInt32(ordinal)
          if deleted(id) { continue }
          let r = try Self.decodeRecord(UnsafeRawBufferPointer(rebasing:raw[(ordinal-start)*40..<(ordinal-start+1)*40]))
          if Int(r.foldedOffset) < foldStart || Int(r.foldedOffset)+Int(r.foldedLength) > foldStart+foldData.count {
            foldStart = Int(r.foldedOffset)
            let available = childOffset-foldedOffset-foldStart
            foldData = try backing.read(offset:foldedOffset+foldStart,count:min(1024*1024,available),cancellation:cancellation)
          }
          try foldData.withUnsafeBytes { buffer in
            let name = UnsafeRawBufferPointer(rebasing:buffer[(Int(r.foldedOffset)-foldStart)..<(Int(r.foldedOffset)-foldStart+Int(r.foldedLength))])
            guard name.count >= query.count else { return }
            var matched:Int?
            for pos in 0...(name.count-query.count) where name[pos] == query[0] {
              var equal = true
              for j in 1..<query.count where name[pos+j] != query[j] { equal = false; break }
              if equal { matched = pos; break }
            }
            guard let matched else { return }
            var candidate = MMapBaseIndex.Candidate(id:id,rank:name.count == query.count ? 0 : (matched == 0 ? 1 : 2))
            if sort.key.requiresMetadata {
              candidate.metadata = try metadata(id)
              if sort.key == .size, r.kind != .file { candidate.metadata = .init(modificationTimeNanoseconds:candidate.metadata.modificationTimeNanoseconds) }
            }
            // Reject losers before allocating a String or reconstructing a
            // path. The heap retains at most K names and a bounded tie cache.
            if let worst = top.worstIfFull {
              var primary:Bool?
              if sort.key == .size {primary = SearchOrdering.valueLess(candidate.metadata.logicalSize,worst.candidate.metadata.logicalSize,direction:sort.direction)}
              if sort.key == .modificationTime {primary = SearchOrdering.valueLess(candidate.metadata.modificationTimeNanoseconds,worst.candidate.metadata.modificationTimeNanoseconds,direction:sort.direction)}
              if primary == false {return}
              if primary == nil {
                if sort.key != .name && candidate.rank != worst.candidate.rank {
                  if candidate.rank > worst.candidate.rank {return}
                } else if !name.elementsEqual(worst.foldedBytes) {
                  if name.contains(where:{$0 >= 128}) || worst.foldedBytes.contains(where:{$0 >= 128}) {
                    let text = String(decoding:name,as:UTF8.self)
                    if text != worst.folded {
                      let before = text < worst.folded
                      if sort.key == .name && sort.direction == .descending ? before : !before {return}
                    }
                  } else {
                    let before = name.lexicographicallyPrecedes(worst.foldedBytes)
                    if sort.key == .name && sort.direction == .descending ? before : !before {return}
                  }
                }
              }
            }
            let folded = String(decoding:name,as:UTF8.self)
            top.insert(.init(candidate:candidate,folded:folded,foldedBytes:Array(name),path:CandidatePath()))
          }
          if let failure { throw failure }
        }
      }
    }
    let result = top.sorted().map(\.candidate)
    if let failure { throw failure }
    try checkStorage()
    return result
  }
}
