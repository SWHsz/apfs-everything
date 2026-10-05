import Foundation

/// Runtime contract shared by the ephemeral reference and persistent hybrid.
public protocol NamespaceIndex: AnyObject, Sendable {
  var root: String { get }
  func apply(_ mutations: [IndexMutation])
  func entry(at path: String) -> NamespaceEntry?
  func children(of path: String) -> [NamespaceEntry]
  func snapshotPaths() -> Set<String>
  func snapshotEntries() -> [NamespaceEntry]
  func stats() -> IndexStats
  func captureSnapshotMetadata() -> SnapshotExportMetadata
  func replace(with replacement: FileIndex)
  func installSnapshot(_ replacement: any NamespaceIndex)
  func search(_ query: String, limit: Int) -> SearchResult
}
extension FileIndex: NamespaceIndex {
  public func installSnapshot(_ replacement: any NamespaceIndex) {
    guard let ram = replacement as? FileIndex else {
      preconditionFailure("RAM index requires RAM snapshot")
    }
    installSnapshot(ram)
  }
}
extension NamespaceIndex {
  public func search(_ query: String) -> SearchResult { search(query, limit: 50) }
}
public enum EntryRef: Hashable, Sendable {
  case base(UInt32)
  case delta(UInt32)
}
