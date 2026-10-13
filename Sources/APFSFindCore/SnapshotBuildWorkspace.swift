import Darwin
import Foundation

/// One pinned, exclusive workspace on the selected index-storage volume.
/// Only this object's fixed allowlist is removed; paths never redirect cleanup.
public final class SnapshotBuildWorkspace: @unchecked Sendable {
  static let sectionNames = ["owner-lock", "records", "original", "folded", "children", "sizes", "times", "validity", "listings", "sort", "namespace", "metadata"]
  let directoryFD: Int32
  private let parentFD: Int32
  let name: String
  public let path: String
  let store: SnapshotStore
  private var files: [String: BuildSection] = [:]
  public private(set) var peakTemporaryBytes: UInt64 = 0
  public private(set) var peakAllocatedBytes: UInt64 = 0
  public var logicalWrites: UInt64 { files.values.reduce(0) { $0 + $1.writtenBytes } }
  init(parentFD: Int32, directoryFD: Int32, name: String, store: SnapshotStore) throws {
    self.parentFD = parentFD; self.directoryFD = directoryFD; self.name = name
    self.store = store; path = store.directory + "/" + name
    do {
      for name in Self.sectionNames {
        let fd = openat(directoryFD, name, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SnapshotError.io("create build section", errno) }
        files[name] = BuildSection(fd: fd)
        if name == "owner-lock", flock(fd,LOCK_EX|LOCK_NB) != 0 {throw SnapshotError.io("lock build workspace",errno)}
        guard fchmod(fd, 0o600) == 0 else { throw SnapshotError.io("chmod build section", errno) }
      }
    } catch { cleanup(); throw error }
  }
  deinit { cleanup(); close(directoryFD); close(parentFD) }
  private func cleanup() {
    files.removeAll()
    for name in Self.sectionNames { _ = unlinkat(directoryFD, name, 0) }
    _ = unlinkat(parentFD, name, AT_REMOVEDIR)
  }
  func section(_ name: String) -> BuildSection { files[name]! }
  func checkIdentity() throws {
    var pinned = stat(), named = stat(), parent = stat()
    guard fstat(directoryFD, &pinned) == 0, fstat(parentFD, &parent) == 0,
      fstatat(parentFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
      pinned.st_dev == parent.st_dev, pinned.st_dev == named.st_dev,
      pinned.st_ino == named.st_ino, named.st_uid == geteuid(),
      named.st_mode & S_IFMT == S_IFDIR, named.st_mode & 0o7777 == 0o700
    else { throw SnapshotError.unsafePath("build workspace identity changed") }
    try store.checkBuildStorage()
  }
  func readOnly(_ name: String) throws -> Int32 {
    try checkIdentity()
    let fd = openat(directoryFD, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw SnapshotError.io("open sealed build section", errno) }
    return fd
  }
  func sampleDisk() throws {
    var logical: UInt64 = 0, allocated: UInt64 = 0
    for file in files.values {
      var st = stat()
      guard fstat(file.fd, &st) == 0, st.st_size >= 0 else { throw SnapshotError.io("stat build section", errno) }
      logical += UInt64(st.st_size) + UInt64(file.buffer.count)
      allocated += UInt64(max(0, st.st_blocks)) * 512
    }
    peakTemporaryBytes = max(peakTemporaryBytes, logical)
    peakAllocatedBytes = max(peakAllocatedBytes, allocated)
  }
  func shrinkBuffers() throws { for file in files.values { try file.flush(); file.buffer = Data(); file.bufferLimit = 16*1024 } }
  func flush() throws { for file in files.values { try file.flush() } }
}

/// Bounded append buffering; random backpatches never retain ordinal arrays.
final class BuildSection {
  let fd: Int32
  var buffer = Data()
  var bufferLimit = 64*1024
  private(set) var length: UInt64 = 0
  private(set) var writtenBytes: UInt64 = 0
  init(fd: Int32) { self.fd = fd }
  deinit { close(fd) }
  func append(_ data: Data) throws {
    guard length + UInt64(data.count) <= SnapshotFormat.maxFileBytes else { throw SnapshotError.invalid("build section limit") }
    buffer.append(data); length += UInt64(data.count)
    if buffer.count >= bufferLimit { try flush() }
  }
  func flush() throws {
    guard !buffer.isEmpty else { return }
    try snapshotWriteAll(fd, buffer, offset: Int64(length)-Int64(buffer.count))
    writtenBytes += UInt64(buffer.count); buffer.removeAll(keepingCapacity: true)
  }
  func patch(_ data: Data, at offset: UInt64) throws {
    guard offset <= length, UInt64(data.count) <= length-offset else { throw SnapshotError.invalid("build backpatch range") }
    try flush(); try snapshotWriteAll(fd, data, offset: Int64(offset)); writtenBytes += UInt64(data.count)
  }
  func reserve(_ count: UInt64) throws {
    try flush()
    guard length+count <= SnapshotFormat.maxFileBytes else { throw SnapshotError.invalid("build section limit") }
    guard ftruncate(fd, off_t(length+count)) == 0 else { throw SnapshotError.io("reserve build section", errno) }
    length += count
  }
  func reset() throws {
    buffer.removeAll(keepingCapacity: false); length = 0
    guard ftruncate(fd, 0) == 0 else { throw SnapshotError.io("truncate sort scratch", errno) }
  }
  func read(_ offset: UInt64, _ count: Int) throws -> Data {
    guard offset <= length, count >= 0, UInt64(count) <= length-offset else { throw SnapshotError.invalid("build read range") }
    var data = Data(repeating: 0, count: count)
    try data.withUnsafeMutableBytes { raw in
      var done = 0
      while done < count {
        let n = pread(fd, raw.baseAddress!.advanced(by: done), count-done, off_t(offset)+off_t(done))
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { throw SnapshotError.io("read build section", n < 0 ? errno : EIO) }
        done += n
      }
    }
    return data
  }
}
