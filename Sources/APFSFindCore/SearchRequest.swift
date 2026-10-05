import Foundation

public final class SearchCancellationToken: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  public init() {}
  public func cancel() { lock.withLock { cancelled = true } }
  public var isCancelled: Bool { lock.withLock { cancelled } }
}
public struct SearchRequest: Sendable {
  public let id: UInt64
  public let query: String
  public let limit: Int
  public let cancellation: SearchCancellationToken
  public init(id: UInt64 = 0, query: String, limit: Int = 50,
              cancellation: SearchCancellationToken = .init()) {
    self.id = id; self.query = query; self.limit = limit; self.cancellation = cancellation
  }
}
public enum MatchRank: Int, Sendable { case exact, prefix, substring }
public enum SearchFreshness: String, Sendable { case baseSnapshot, catchingUp, live, rebuilding }

public enum SearchOrdering {
  public static func foldedBasename(_ path: String) -> String {
    FileEntry.fold(String(path.split(separator: "/").last ?? "/"))
  }
  public static func less(_ rankA: Int, _ pathA: String, _ rankB: Int, _ pathB: String) -> Bool {
    if rankA != rankB { return rankA < rankB }
    let a = foldedBasename(pathA), b = foldedBasename(pathB)
    return a == b ? pathA < pathB : a < b
  }
}
