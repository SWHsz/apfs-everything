import CAPFSShim
import Darwin
import Foundation

/// A small configuration file only. Index bytes never enter this store.
/// The directory is pinned; all accesses are relative, no-follow, owner checked.
public final class IndexStorageLocatorStore: @unchecked Sendable {
  public static var defaultDirectory: String { NSHomeDirectory() + "/Library/Application Support/APFSFind" }
  public static let maximumBytes = 65_536
  private struct Document: Codable { let version: UInt32; var locations: [IndexStorageLocator] }
  private let directoryFD: Int32
  private let mutex = NSLock()
  private let filename = "storage-locations.json"
  public init(directory: String = IndexStorageLocatorStore.defaultDirectory) throws {
    let normalized = try SnapshotStore.normalizedDirectory(directory)
    let fd = apfs_open_cache_directory(normalized, 1)
    guard fd >= 0 else { throw SnapshotError.io("open storage locator directory", errno) }
    directoryFD = fd
  }
  deinit { close(directoryFD) }
  /// Missing/corrupt optional configuration preserves legacy internal placement.
  /// Permission/ownership/symlink failures also never redirect to an external path.
  public func policy(for identity: VolumeIdentity) -> IndexStoragePolicy {
    mutex.withLock { (try? read()).flatMap { $0.first { $0.matches(identity) } }?.policy ?? .defaultInternal }
  }
  public func locations() throws -> [IndexStorageLocator] { try mutex.withLock { try read() } }
  public func publish(_ locator: IndexStorageLocator, beforeRename: () throws -> Void = {}) throws {
    try mutex.withLock {
      guard Self.valid(locator) else { throw SnapshotError.invalid("storage locator") }
      let publisher = openat(directoryFD, filename + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard publisher >= 0 else { throw SnapshotError.io("open locator lock", errno) }
      defer { close(publisher) }
      try Self.check(publisher, maximum: nil)
      guard flock(publisher, LOCK_EX) == 0 else { throw SnapshotError.io("lock locator", errno) }
      defer { _ = flock(publisher, LOCK_UN) }
      // Do not silently discard other roots on a corrupt document. Explicit
      // repair is separate from safe read fallback.
      var values = try read()
      values.removeAll { $0.sourceVolumeUUID == locator.sourceVolumeUUID && $0.sourceRootFileID == locator.sourceRootFileID
        && $0.sourceRelativeRootHash == locator.sourceRelativeRootHash }
      values.append(locator)
      let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(Document(version: 1, locations: values))
      guard data.count <= Self.maximumBytes else { throw SnapshotError.invalid("locator size limit") }
      let temporary = filename + "." + UUID().uuidString + ".tmp"
      let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
      guard fd >= 0 else { throw SnapshotError.io("create locator temp", errno) }
      defer { close(fd); _ = unlinkat(directoryFD, temporary, 0) }
      try Self.check(fd, maximum: nil)
      try snapshotWriteAll(fd, data)
      guard fsync(fd) == 0 else { throw SnapshotError.io("fsync locator", errno) }
      try beforeRename()
      // Check existing file again under the cross-process publication lock.
      var old = stat()
      if fstatat(directoryFD, filename, &old, AT_SYMLINK_NOFOLLOW) == 0 {
        guard old.st_mode & S_IFMT == S_IFREG, old.st_uid == geteuid(), old.st_mode & 0o7777 == 0o600
        else { throw SnapshotError.unsafePath("locator owner/type/mode") }
      } else if errno != ENOENT { throw SnapshotError.io("stat locator", errno) }
      let backup = filename+".old."+UUID().uuidString+".tmp"
      var linked = false,renamed = false
      do {
        if fstatat(directoryFD,filename,&old,AT_SYMLINK_NOFOLLOW) == 0 {
          guard linkat(directoryFD,filename,directoryFD,backup,0) == 0 else {throw SnapshotError.io("backup locator",errno)}
          linked = true
        }
        guard renameat(directoryFD,temporary,directoryFD,filename) == 0 else {throw SnapshotError.io("rename locator",errno)}
        renamed = true
        guard fsync(directoryFD) == 0 else {throw SnapshotError.io("fsync locator parent",errno)}
        if linked {_ = unlinkat(directoryFD,backup,0)}
      } catch {
        if renamed {
          if linked {_ = renameat(directoryFD,backup,directoryFD,filename)}
          else {_ = unlinkat(directoryFD,filename,0)}
          _ = fsync(directoryFD)
        } else if linked {_ = unlinkat(directoryFD,backup,0)}
        throw error
      }
    }
  }
  private func read() throws -> [IndexStorageLocator] {
    let fd = openat(directoryFD, filename, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else {
      if errno == ENOENT { return [] }
      throw SnapshotError.io("open locator", errno)
    }
    defer { close(fd) }
    let size = try Self.check(fd, maximum: Self.maximumBytes)
    var bytes = Data(repeating: 0, count: size)
    try bytes.withUnsafeMutableBytes { buffer in
      var offset = 0
      while offset < size {
        let n = pread(fd, buffer.baseAddress!.advanced(by: offset), size - offset, off_t(offset))
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { throw SnapshotError.io("read locator", n == 0 ? EIO : errno) }
        offset += n
      }
    }
    let document = try JSONDecoder().decode(Document.self, from: bytes)
    guard document.version == 1, document.locations.allSatisfy(Self.valid) else { throw SnapshotError.invalid("locator schema") }
    var keys = Set<String>()
    for item in document.locations {
      let key = "\(item.sourceVolumeUUID):\(item.sourceRootFileID):\(item.sourceRelativeRootHash)"
      guard keys.insert(key).inserted else { throw SnapshotError.invalid("duplicate locator root") }
    }
    return document.locations
  }
  @discardableResult private static func check(_ fd: Int32, maximum: Int?) throws -> Int {
    var st = stat()
    guard fstat(fd, &st) == 0 else { throw SnapshotError.io("stat locator file", errno) }
    guard st.st_mode & S_IFMT == S_IFREG, st.st_uid == geteuid(), st.st_mode & 0o7777 == 0o600,
      st.st_size >= 0, maximum.map({ st.st_size <= $0 }) ?? true else { throw SnapshotError.unsafePath("locator owner/type/mode/size") }
    return Int(st.st_size)
  }
  private static func valid(_ locator: IndexStorageLocator) -> Bool {
    guard locator.version == 1, locator.sourceRelativeRootHash.count == 64,
      locator.sourceRelativeRootHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
    if case .volume(_, let relative) = locator.policy { return IndexStorageResolver.safeRelativeDirectory(relative) }
    return true
  }
}
