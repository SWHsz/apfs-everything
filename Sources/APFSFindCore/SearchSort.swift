import Foundation

public enum SearchSortKey: String, Sendable, Codable, CaseIterable {
    case relevance, name, modificationTime, size
    public var defaultDirection: SortDirection { self == .size || self == .modificationTime ? .descending : .ascending }
    public var requiresMetadata: Bool { self == .size || self == .modificationTime }
}
public enum SortDirection: String, Sendable, Codable { case ascending, descending }
public struct SearchSortDescriptor: Sendable, Codable, Equatable {
    public let key: SearchSortKey
    public let direction: SortDirection
    public init(key: SearchSortKey = .relevance, direction: SortDirection? = nil) {
        self.key = key; self.direction = direction ?? key.defaultDirection
    }
}

/// A worst-first heap bounds memory to K and insertion to log K.
struct BoundedTopK<Element> {
    let limit: Int
    let less: (Element, Element) -> Bool
    private var heap: [Element] = []
    init(limit: Int, less: @escaping (Element,Element)->Bool) { self.limit = max(0,limit); self.less = less }
    mutating func insert(_ item: Element) {
        guard limit > 0 else { return }
        if heap.count < limit {
            heap.append(item); var i = heap.count-1
            while i > 0 {
                let p = (i-1)/2
                guard less(heap[p],heap[i]) else { break }
                heap.swapAt(p,i); i = p
            }
        } else {
            guard less(item,heap[0]) else { return }
            heap[0] = item; var i = 0
            while i*2+1 < heap.count {
                var child = i*2+1
                if child+1 < heap.count && less(heap[child],heap[child+1]) { child += 1 }
                guard less(heap[i],heap[child]) else { break }
                heap.swapAt(i,child); i = child
            }
        }
    }
    func sorted() -> [Element] { heap.sorted(by:less) }
}
extension SearchOrdering {
    /// nil means tied; unknown always follows known, independent of direction.
    static func valueLess<T: Comparable>(_ a:T?,_ b:T?,direction:SortDirection)->Bool? {
        switch (a,b) {
        case (nil,nil): return nil
        case (nil,_): return false
        case (_,nil): return true
        case (let x?,let y?): return x == y ? nil : (direction == .ascending ? x < y : y < x)
        }
    }
    public static func less(_ a:SearchHit,_ b:SearchHit,sort:SearchSortDescriptor) -> Bool {
        switch sort.key {
        case .relevance: break
        case .name:
            let aa = URL(fileURLWithPath:a.path).lastPathComponent, bb = URL(fileURLWithPath:b.path).lastPathComponent
            let x = FileEntry.fold(aa), y = FileEntry.fold(bb)
            if x != y { return sort.direction == .ascending ? x < y : y < x }
            if aa != bb { return sort.direction == .ascending ? aa < bb : bb < aa }
            return a.path < b.path
        case .size:
            if let v = valueLess(a.logicalSize,b.logicalSize,direction:sort.direction) { return v }
        case .modificationTime:
            if let v = valueLess(a.modificationTimeNanoseconds,b.modificationTimeNanoseconds,direction:sort.direction) { return v }
        }
        return less(a.matchRank.rawValue,a.path,b.matchRank.rawValue,b.path)
    }
}
