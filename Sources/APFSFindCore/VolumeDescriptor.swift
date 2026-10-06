import Darwin
import Foundation

public struct VolumeDescriptor: Sendable, Hashable {
  public let volumeUUID: UUID
  public let displayName: String
  public let mountPath: String
  public let isSystemVolume: Bool
  public let isRemovable: Bool
  public let isReadOnly: Bool
  public let deviceID: UInt64
  public init(volumeUUID: UUID, displayName: String, mountPath: String,
              isSystemVolume: Bool = false, isRemovable: Bool = false, isReadOnly: Bool = false, deviceID: UInt64 = 0) {
    self.volumeUUID = volumeUUID; self.displayName = displayName; self.mountPath = mountPath
    self.isSystemVolume = isSystemVolume; self.isRemovable = isRemovable; self.isReadOnly = isReadOnly
    self.deviceID = deviceID
  }
}
public protocol MountedVolumeProvider: Sendable { func mountedVolumes() throws -> [VolumeDescriptor] }
public struct LocalMountedVolumeProvider: MountedVolumeProvider {
  public init() {}
  public static func includes(path: String, local: Bool, filesystem: String) -> Bool {
    guard local, filesystem != "autofs", filesystem != "smbfs", filesystem != "nfs" else { return false }
    if path == "/" { return true }
    guard PathCanonicalizer.parent(of: path) == "/Volumes" else { return false }
    let name = String(path.split(separator: "/").last ?? "")
    return !["Preboot", "Recovery", "VM", "Update"].contains(name) && !name.hasPrefix(".")
  }
  public func mountedVolumes() throws -> [VolumeDescriptor] {
    // Cached mount table: never ask a network mount for URL resource values.
    let count = getfsstat(nil, 0, MNT_NOWAIT)
    guard count >= 0 else { throw POSIXError(.EIO) }
    var table: [statfs] = Array(repeating: statfs(), count: Int(count) + 16)
    let read = table.withUnsafeMutableBufferPointer { getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<statfs>.stride), MNT_NOWAIT) }
    guard read >= 0 else { throw POSIXError(.EIO) }
    var volumes: [VolumeDescriptor] = [], seen = Set<UUID>()
    for fs in table.prefix(Int(read)) {
      let path = withUnsafeBytes(of: fs.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
      let type = withUnsafeBytes(of: fs.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
      guard Self.includes(path: path, local: fs.f_flags & UInt32(MNT_LOCAL) != 0, filesystem: type),
            let identity = try? VolumeIdentity.discover(root: path), seen.insert(identity.volumeUUID).inserted else { continue }
      let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeNameKey, .volumeIsRemovableKey])
      volumes.append(.init(volumeUUID: identity.volumeUUID, displayName: values?.volumeName ?? (path == "/" ? "System" : String(path.split(separator: "/").last!)), mountPath: path,
                           isSystemVolume: path == "/", isRemovable: values?.volumeIsRemovable ?? false,
                           isReadOnly: fs.f_flags & UInt32(MNT_RDONLY) != 0, deviceID: identity.deviceID))
    }
    return volumes.sorted { $0.isSystemVolume != $1.isSystemVolume ? $0.isSystemVolume : $0.displayName < $1.displayName }
  }
}
public protocol VolumeSelectionStore: Sendable {
  func load() -> Set<UUID>
  func save(_ ids: Set<UUID>)
}
public final class DefaultsVolumeSelectionStore: VolumeSelectionStore, @unchecked Sendable {
  private let defaults: UserDefaults
  private let lock = NSLock()
  public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
  public func load() -> Set<UUID> { lock.withLock { Set((defaults.stringArray(forKey: "selectedVolumeUUIDs") ?? []).compactMap(UUID.init(uuidString:))) } }
  public func save(_ ids: Set<UUID>) { lock.withLock { defaults.set(ids.map(\.uuidString).sorted(), forKey: "selectedVolumeUUIDs") } }
}
