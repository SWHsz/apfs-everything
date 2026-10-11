import Foundation

/// The runtime depends on immutable records, not on a mapped address. Internal
/// files retain the existing mmap fast path; removable files expose throwing,
/// owned-byte reads. All I/O failures must cross the transaction/query boundary.
public protocol ImmutableNamespaceBase: AnyObject, Sendable {
  var header: SnapshotHeader { get }
  var root: String { get }
  var count: Int { get }
  var files: Int { get }
  var directories: Int { get }
  var mappedBytes: Int { get }
  var mmapMilliseconds: Double { get }
  var validationMilliseconds: Double { get }
  var residentAfterMmap: UInt64 { get }
  var residentAfterValidation: UInt64 { get }
  var residentAfterRuntimeRemap: UInt64 { get }
  func record(at ordinal: UInt32) throws -> BaseRecord
  func name(at ordinal: UInt32) throws -> String
  func foldedName(at ordinal: UInt32) throws -> String
  func directChildren(of ordinal: UInt32) throws -> [UInt32]
  func subtreeRange(of ordinal: UInt32) throws -> Range<UInt32>
  func lookupChild(parent: UInt32, name: String) throws -> UInt32?
  func reconstructPath(_ ordinal: UInt32) throws -> String
  func searchBase(_ query: [UInt8], limit: Int, cancellation: SearchCancellationToken?,
    scanned: ((Int) -> Void)?, sort: SearchSortDescriptor,
    metadata: (UInt32) throws -> FileMetadataValue,
    deleted: (UInt32) -> Bool) throws -> [MMapBaseIndex.Candidate]
  func checkStorage() throws
  @discardableResult func reclaimPages() -> Bool
}

extension MMapBaseIndex: ImmutableNamespaceBase {
  public func checkStorage() throws {}
  public func searchBase(_ query: [UInt8], limit: Int, cancellation: SearchCancellationToken?,
    scanned: ((Int) -> Void)?, sort: SearchSortDescriptor,
    metadata: (UInt32) throws -> FileMetadataValue,
    deleted: (UInt32) -> Bool) throws -> [Candidate] {
    // Keep the proven internal scan/comparator. A throwing metadata backing is
    // latched and rethrown; an incomplete result never reaches the caller.
    var failure: Error?
    let value: (UInt32) -> FileMetadataValue = { id in
      do { return try metadata(id) } catch { failure = error; return .unknown }
    }
    let result = searchBase(query, limit:limit, cancellation:cancellation,
      scanned:scanned, sort:sort, metadata:value, deleted:deleted)
    if let failure { throw failure }
    return result
  }
}
