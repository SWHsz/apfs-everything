import Foundation

public struct IndexStorageError: Error, Sendable, CustomStringConvertible {
  public let state: IndexStorageState
  public static func reading(_ error: Error) -> IndexStorageError {
    if let value = error as? IndexStorageError { return value }
    if case IndexBackingError.storageIO = error { return .init(.offline) }
    if case SnapshotError.io(_,let code) = error, [5,6,19].contains(code) { return .init(.offline) }
    return .init(.failed(String(describing:error)))
  }
  public init(_ state: IndexStorageState) { self.state = state }
  public var description: String { "Index storage: \(state)" }
}

/// One mount incarnation only. Reconnection creates new readers and replays the
/// durable cursor; a cached page must never resurrect an unavailable store.
public final class IndexStorageMonitor: @unchecked Sendable {
  public let resolved: ResolvedIndexStorage
  public let usePRead: Bool
  private let provider: any IndexStorageVolumeProviding
  private let expectedDevice: UInt64
  private let lock = NSLock()
  private var dependent:IndexStorageMonitor?
  func bindValidatedReaderMonitor(_ monitor:IndexStorageMonitor) throws {
    guard resolved == monitor.resolved else {throw IndexStorageError(.identityChanged)}
    lock.withLock {dependent = monitor}
  }
  private var current: IndexStorageState = .available
  public var state: IndexStorageState { lock.withLock { current } }
  public init(resolved: ResolvedIndexStorage, provider: any IndexStorageVolumeProviding) throws {
    guard resolved.state == .available else { throw IndexStorageError(resolved.state) }
    guard let volume = try provider.mountedStorageVolumes().first(where: { $0.uuid == resolved.storageVolumeUUID })
      else { throw IndexStorageError(.offline) }
    self.resolved = resolved; self.provider = provider; expectedDevice = volume.deviceID
    usePRead = volume.removable
  }
  public func invalidate(_ state: IndexStorageState) {
    let reader = lock.withLock { if current == .available {current = state};return dependent }
    reader?.invalidate(state)
  }
  /// Cheap check at every owned byte-window access, including cache hits.
  public func check() throws { let value = state; guard value == .available else { throw IndexStorageError(value) } }
  /// Mount-table validation is performed at transaction boundaries, never once
  /// per record. No polling thread is required while the application is idle.
  public func validate(requiredBytes: UInt64 = 0) throws {
    try check()
    do {
      guard let volume = try provider.mountedStorageVolumes().first(where: { $0.uuid == resolved.storageVolumeUUID })
        else { throw IndexStorageError(.offline) }
      guard volume.mountPath == resolved.storageMountPath, volume.deviceID == expectedDevice else {
        throw IndexStorageError(.identityChanged)
      }
      guard volume.local, volume.filesystem == "apfs" else { throw IndexStorageError(.unsafePath("local APFS required")) }
      guard !volume.readOnly else { throw IndexStorageError(.readOnly) }
      guard volume.availableBytes >= requiredBytes else {
        throw IndexStorageError(.lowSpace(required:requiredBytes,available:volume.availableBytes))
      }
    } catch {
      invalidate((error as? IndexStorageError)?.state ?? .failed(String(describing:error)))
      throw error
    }
  }
}
