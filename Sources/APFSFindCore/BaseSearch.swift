import Foundation

extension MMapBaseIndex {
  public struct Candidate {
    public let id: UInt32
    public let rank: Int
    public var metadata: FileMetadataValue = .unknown
  }
  private func pathLess(_ a: UInt32, _ b: UInt32) -> Bool {
    // A validated path is < PATH_MAX bytes; each non-root level costs >= 2 bytes.
    // Temporary stack storage avoids heap allocations for duplicate-basename ties.
    withUnsafeTemporaryAllocation(of:UInt32.self,capacity:2048) { aa in
      withUnsafeTemporaryAllocation(of:UInt32.self,capacity:2048) { bb in
        var x = a, y = b, ac = 0, bc = 0
        while x != 0 { aa[ac] = x; ac += 1; x = record(at:x).parent }
        while y != 0 { bb[bc] = y; bc += 1; y = record(at:y).parent }
        for offset in 0..<min(ac,bc) {
          let i = aa[ac-1-offset], j = bb[bc-1-offset]
          if i == j { continue }
          let p = originalNameBytes(at:i), q = originalNameBytes(at:j)
          let aTerminal = i == a, bTerminal = j == b
          if p.contains(where:{$0 >= 128}) || q.contains(where:{$0 >= 128}) {
            let ps = String(decoding:p,as:UTF8.self), qs = String(decoding:q,as:UTF8.self)
            if ps == qs { continue }
            return ps+(aTerminal ? "" : "/") < qs+(bTerminal ? "" : "/")
          }
          for k in 0..<min(p.count,q.count) where p[k] != q[k] { return p[k] < q[k] }
          if p.count != q.count {
            if p.count < q.count { return aTerminal || UInt8(47) < q[p.count] }
            return !bTerminal && p[q.count] < UInt8(47)
          }
        }
        return ac < bc
      }
    }
  }
  private func nameLess(_ a: UInt32, _ b: UInt32) -> Bool {
    let x = foldedBytes(at: a), y = foldedBytes(at: b)
    if x.elementsEqual(y) { return pathLess(a, b) }
    return x.lexicographicallyPrecedes(y)
  }
  /// Bounded top-k ordinals; full paths are reconstructed only after selection.
  public func searchBase(_ query: [UInt8], limit: Int, cancellation: SearchCancellationToken? = nil, scanned: ((Int) -> Void)? = nil, sort: SearchSortDescriptor = .init(), metadata: (UInt32) -> FileMetadataValue = { _ in .unknown }, deleted: (UInt32) -> Bool) -> [Candidate] {
    guard !query.isEmpty, limit > 0 else { return [] }
    func less(_ a: Candidate, _ b: Candidate) -> Bool {
      switch sort.key {
      case .relevance: break
      case .name:
        let x = foldedBytes(at:a.id), y = foldedBytes(at:b.id)
        if !x.elementsEqual(y) { return sort.direction == .ascending ? x.lexicographicallyPrecedes(y) : y.lexicographicallyPrecedes(x) }
        let xx = originalNameBytes(at:a.id), yy = originalNameBytes(at:b.id)
        if !xx.elementsEqual(yy) { return sort.direction == .ascending ? xx.lexicographicallyPrecedes(yy) : yy.lexicographicallyPrecedes(xx) }
        return pathLess(a.id,b.id)
      case .size:
        if let result = SearchOrdering.valueLess(a.metadata.logicalSize,b.metadata.logicalSize,direction:sort.direction) { return result }
      case .modificationTime:
        if let result = SearchOrdering.valueLess(a.metadata.modificationTimeNanoseconds,b.metadata.modificationTimeNanoseconds,direction:sort.direction) { return result }
      }
      return a.rank == b.rank ? nameLess(a.id, b.id) : a.rank < b.rank
    }
    var hits = BoundedTopK<Candidate>(limit:limit,less:less)
    var visited = 0
    defer { scanned?(visited) }
    for ordinal in 1..<count {
      if ordinal % 4096 == 1, cancellation?.isCancelled == true { break }
      visited += 1
      let id = UInt32(ordinal)
      if deleted(id) { continue }
      let bytes = foldedBytes(at: id)
      guard bytes.count >= query.count else { continue }
      var match: Int?
      for pos in 0...(bytes.count - query.count) where bytes[pos] == query[0] {
        var equal = true
        for j in 1..<query.count where bytes[pos + j] != query[j] {
          equal = false
          break
        }
        if equal {
          match = pos
          break
        }
      }
      guard let match else { continue }
      var hit = Candidate(id: id, rank: bytes.count == query.count ? 0 : (match == 0 ? 1 : 2))
      if sort.key.requiresMetadata {
        hit.metadata = metadata(id)
        // A metadata-only checkpoint can be ahead of namespace type replay.
        // Non-regular namespace candidates must remain unknown before top-K,
        // rather than merely hiding their size after winners are selected.
        if sort.key == .size, hit.metadata.logicalSize != nil, record(at:id).kind != .file {
          hit.metadata = .init(modificationTimeNanoseconds:hit.metadata.modificationTimeNanoseconds)
        }
      }
      hits.insert(hit)
    }
    return hits.sorted()
  }
}
