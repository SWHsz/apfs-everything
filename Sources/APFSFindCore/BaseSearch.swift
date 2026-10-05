import Foundation

extension MMapBaseIndex {
  public struct Candidate {
    public let id: UInt32
    public let rank: Int
  }
  private func pathLess(_ a: UInt32, _ b: UInt32) -> Bool {
    var aa: [UInt32] = []
    var bb: [UInt32] = []
    var x = a
    var y = b
    while x != 0 {
      aa.append(x)
      x = record(at: x).parent
    }
    while y != 0 {
      bb.append(y)
      y = record(at: y).parent
    }
    for (i, j) in zip(aa.reversed(), bb.reversed()) where i != j {
      let p = originalNameBytes(at: i)
      let q = originalNameBytes(at: j)
      let aTerminal = i == a
      let bTerminal = j == b
      if p.contains(where: { $0 >= 128 }) || q.contains(where: { $0 >= 128 }) {
        let ps = String(decoding: p, as: UTF8.self)
        let qs = String(decoding: q, as: UTF8.self)
        if ps == qs { continue }
        return ps + (aTerminal ? "" : "/") < qs + (bTerminal ? "" : "/")
      }
      for k in 0..<min(p.count, q.count) where p[k] != q[k] { return p[k] < q[k] }
      if p.count != q.count {
        if p.count < q.count { return aTerminal || UInt8(47) < q[p.count] }
        return !bTerminal && p[q.count] < UInt8(47)
      }
    }
    return aa.count < bb.count
  }
  private func nameLess(_ a: UInt32, _ b: UInt32) -> Bool {
    let x = foldedBytes(at: a), y = foldedBytes(at: b)
    if x.elementsEqual(y) { return pathLess(a, b) }
    return x.lexicographicallyPrecedes(y)
  }
  /// Bounded top-k ordinals; full paths are reconstructed only after selection.
  public func searchBase(_ query: [UInt8], limit: Int, cancellation: SearchCancellationToken? = nil, scanned: ((Int) -> Void)? = nil, deleted: (UInt32) -> Bool) -> [Candidate] {
    guard !query.isEmpty, limit > 0 else { return [] }
    var hits: [Candidate] = []
    hits.reserveCapacity(limit)
    func less(_ a: Candidate, _ b: Candidate) -> Bool {
      a.rank == b.rank ? nameLess(a.id, b.id) : a.rank < b.rank
    }
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
      let hit = Candidate(id: id, rank: bytes.count == query.count ? 0 : (match == 0 ? 1 : 2))
      if hits.count == limit, let last = hits.last, !less(hit, last) { continue }
      var lo = 0
      var hi = hits.count
      while lo < hi {
        let mid = (lo + hi) / 2
        if less(hit, hits[mid]) { hi = mid } else { lo = mid + 1 }
      }
      hits.insert(hit, at: lo)
      if hits.count > limit { hits.removeLast() }
    }
    return hits
  }
}
