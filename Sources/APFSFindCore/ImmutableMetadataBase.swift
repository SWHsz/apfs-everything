import Foundation

public protocol ImmutableMetadataBase: AnyObject, Sendable {
  var header: MetadataHeader { get }
  var residentAfterValidation: UInt64 { get }
  var residentAfterRuntimeRemap: UInt64 { get }
  func value(at ordinal: UInt32) throws -> FileMetadataValue
  func checkStorage() throws
  @discardableResult func reclaimPages() -> Bool
}
extension MMapMetadataIndex: ImmutableMetadataBase {
  public func checkStorage() throws {}
}
