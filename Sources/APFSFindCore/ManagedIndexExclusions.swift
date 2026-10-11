import CAPFSShim
import Darwin
import Foundation

/// A few managed storage directories shared by all source scanners. This is
/// configuration, never a map of indexed paths. Migration registers the target
/// before creating staging files, so another source cannot index that traffic.
public final class ManagedIndexExclusions:@unchecked Sendable {
  public static let shared = ManagedIndexExclusions()
  private let lock = NSLock()
  private var roots:Set<String> = []
  public init() {}
  public func register(_ path:String) {
    guard let path = PathCanonicalizer.normalize(path) else {return}
    let alias = verifiedDataAlias(path)
    lock.withLock { roots.insert(path);if let alias {roots.insert(alias)} }
  }
  /// A selected Data-volume cache can be resolved under /System/Volumes/Data
  /// while a Home or /private source enumerates its firmlink alias. Verify the
  /// nearest existing ancestor's device/inode once, before staging is created;
  /// never stat an indexed path during the contains/query fast path.
  private func verifiedDataAlias(_ path:String) -> String? {
    let data = "/System/Volumes/Data"
    let alias:String
    if path.hasPrefix(data+"/Users/") || path.hasPrefix(data+"/private/") {alias = String(path.dropFirst(data.count))}
    else if path.hasPrefix("/Users/") || path.hasPrefix("/private/") {alias = data+path}
    else {return nil}
    var original = path,candidate = alias
    while original != "/" {
      var a = APFSDirectoryInfo(),b = APFSDirectoryInfo()
      if apfs_directory_info(original,0,0,&a) == 0 {
        guard apfs_directory_info(candidate,a.device_id,1,&b) == 0,a.file_id == b.file_id else {return nil}
        return alias
      }
      guard errno == ENOENT else {return nil}
      original = PathCanonicalizer.parent(of:original);candidate = PathCanonicalizer.parent(of:candidate)
    }
    return nil
  }
  public func contains(_ path:String) -> Bool { lock.withLock { roots.contains { PathCanonicalizer.isWithin(path,root:$0) } } }
  public var paths:[String] { lock.withLock { Array(roots) } }
}
