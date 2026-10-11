import Darwin
import Foundation

public enum IndexBackingError: Error, Sendable, Equatable {
  case closed, cancelled, invalidRange
  case storageIO(Int32)
}

/// Owned bytes only: a mapped or cached pointer never escapes this interface.
/// Readers validate index formats separately; this layer bounds storage I/O.
public protocol ReadOnlyIndexBacking: AnyObject, Sendable {
  var length: Int { get }
  func read(offset: Int, count: Int, cancellation: SearchCancellationToken?) throws -> Data
  func reclaimPages()
  func close()
}

/// Removable storage. Closing waits only for the bounded current pread block;
/// returned Data is independent of the descriptor and remains safe after eject.
public final class PReadBacking: ReadOnlyIndexBacking, @unchecked Sendable {
  public let length: Int
  public let maximumCacheBytes: Int
  public static let maximumReadBytes = 1024 * 1024
  private let blockSize = 64 * 1024
  private let lock = NSLock()
  private var descriptor: Int32
  private var cache: [Int: Data] = [:]
  private var access: [Int: UInt64] = [:]
  private var clock: UInt64 = 0
  private var cached = 0
  private var terminalError: Error?
  private let validateStorage: @Sendable () throws -> Void
  /// Takes ownership even if validation fails. Callers open relative to a pinned,
  /// verified storage directory; this API never resolves arbitrary file paths.
  public init(fileDescriptor: Int32, maximumCacheBytes: Int = 4 * 1024 * 1024,
    validateStorage: @escaping @Sendable () throws -> Void = {}) throws {
    var st = stat()
    guard fileDescriptor >= 0, maximumCacheBytes >= 0, maximumCacheBytes <= 16 * 1024 * 1024,
      fcntl(fileDescriptor, F_GETFL) & O_ACCMODE == O_RDONLY,
      fstat(fileDescriptor, &st) == 0, st.st_mode & S_IFMT == S_IFREG,
      st.st_uid == geteuid(), st.st_mode & 0o7777 == 0o600,
      st.st_size >= 0, UInt64(st.st_size) <= SnapshotFormat.maxFileBytes else {
      Darwin.close(fileDescriptor); throw SnapshotError.unsafePath("pread backing owner/type/mode/size")
    }
    descriptor = fileDescriptor; length = Int(st.st_size)
    self.maximumCacheBytes = maximumCacheBytes; self.validateStorage = validateStorage
  }
  deinit { close() }
  public var cachedBytes: Int { lock.withLock { cached } }
  public func reclaimPages() { lock.withLock { cache.removeAll(); access.removeAll(); cached = 0 } }
  public func close() {
    lock.withLock {
      if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
      cache.removeAll(); access.removeAll(); cached = 0
    }
  }
  public func read(offset: Int, count: Int, cancellation: SearchCancellationToken? = nil) throws -> Data {
    guard offset >= 0, count >= 0, count <= Self.maximumReadBytes,
      offset <= length, count <= length - offset else { throw IndexBackingError.invalidRange }
    var output = Data(); output.reserveCapacity(count)
    var position = offset
    while position < offset + count {
      if cancellation?.isCancelled == true { throw IndexBackingError.cancelled }
      let block = position / blockSize
      let data: Data = try lock.withLock {
        guard descriptor >= 0 else { throw IndexBackingError.closed }
        if let terminalError { throw terminalError }
        // Check before cache hits too: cached pages must not make an offline
        // session appear available or hide a replacement storage UUID.
        do { try validateStorage() } catch { terminalError = error; throw error }
        clock &+= 1
        if let data = cache[block] { access[block] = clock; return data }
        let start = block * blockSize, wanted = min(blockSize, length - start)
        var bytes = Data(repeating: 0, count: wanted)
        try bytes.withUnsafeMutableBytes { buffer in
          var read = 0
          while read < wanted {
            if cancellation?.isCancelled == true { throw IndexBackingError.cancelled }
            let n = pread(descriptor, buffer.baseAddress!.advanced(by: read), wanted - read, off_t(start + read))
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else {
              let error = IndexBackingError.storageIO(n == 0 ? EIO : errno)
              terminalError = error; throw error
            }
            read += n
          }
        }
        if wanted <= maximumCacheBytes {
          while cached + wanted > maximumCacheBytes, let oldest = access.min(by: { $0.value < $1.value })?.key {
            cached -= cache.removeValue(forKey: oldest)?.count ?? 0; access.removeValue(forKey: oldest)
          }
          cache[block] = bytes; access[block] = clock; cached += bytes.count
        }
        return bytes
      }
      let first = position % blockSize, take = min(data.count - first, offset + count - position)
      output.append(data[first..<(first + take)]); position += take
    }
    if cancellation?.isCancelled == true { throw IndexBackingError.cancelled }
    if count == 0 { try lock.withLock {
      guard descriptor >= 0 else { throw IndexBackingError.closed }
      if let terminalError { throw terminalError }
      do { try validateStorage() } catch { terminalError = error; throw error }
    } }
    return output
  }
}
