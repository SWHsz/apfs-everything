import CAPFSShim
import Darwin
import Foundation

public struct IndexStorageVolume: Sendable, Equatable {
  public let uuid: UUID
  public let mountPath: String
  public let deviceID: UInt64
  public let filesystem: String
  public let local: Bool
  public let readOnly: Bool
  public let removable: Bool
  public let availableBytes: UInt64
  public init(uuid: UUID, mountPath: String, deviceID: UInt64, filesystem: String = "apfs",
    local: Bool = true, readOnly: Bool = false, removable: Bool = false, availableBytes: UInt64) {
    self.uuid = uuid; self.mountPath = mountPath; self.deviceID = deviceID
    self.filesystem = filesystem; self.local = local; self.readOnly = readOnly
    self.removable = removable; self.availableBytes = availableBytes
  }
}
public protocol IndexStorageVolumeProviding: Sendable {
  func mountedStorageVolumes() throws -> [IndexStorageVolume]
}
public final class LocalIndexStorageVolumeProvider: IndexStorageVolumeProviding, Sendable {
  public init() {}
  public func mountedStorageVolumes() throws -> [IndexStorageVolume] {
    let count = getfsstat(nil, 0, MNT_NOWAIT)
    guard count >= 0 else { throw SnapshotError.io("storage mount table", errno) }
    var table: [statfs] = Array(repeating: statfs(), count: Int(count) + 16)
    let bufferSize = Int32(table.count * MemoryLayout<statfs>.stride)
    let read = table.withUnsafeMutableBufferPointer {
      getfsstat($0.baseAddress, bufferSize, MNT_NOWAIT)
    }
    guard read >= 0, read <= table.count else { throw SnapshotError.io("storage mount table changed", EAGAIN) }
    var result: [IndexStorageVolume] = []
    for fs in table.prefix(Int(read)) {
      let type = withUnsafeBytes(of: fs.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
      // Never perform metadata/URL queries on a network or autofs mount.
      guard type == "apfs", fs.f_flags & UInt32(MNT_LOCAL) != 0 else { continue }
      let path = withUnsafeBytes(of: fs.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
      var info = APFSVolumeInfo()
      guard apfs_volume_info(path, &info) == 0 else { continue }
      let uuid = withUnsafeBytes(of: info.volume_uuid) { UUID(bytes: Array($0)) }
      let size = UInt64(fs.f_bsize), available = UInt64(fs.f_bavail)
      let (bytes, overflow) = size.multipliedReportingOverflow(by: available)
      let media = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsEjectableKey, .volumeIsRemovableKey])
      // A USB/Thunderbolt SSD can report fixed (non-removable) media while
      // still being physically disconnectable. Unknown identities use pread.
      let removable = media?.volumeIsInternal != true || media?.volumeIsEjectable == true || media?.volumeIsRemovable == true
      result.append(.init(uuid: uuid, mountPath: path, deviceID: info.device_id,
        readOnly: fs.f_flags & UInt32(MNT_RDONLY) != 0, removable: removable, availableBytes: overflow ? UInt64.max : bytes))
    }
    return result
  }
}

public final class IndexStorageResolver: Sendable {
  private let provider: any IndexStorageVolumeProviding
  private let internalDirectory: String
  public init(provider: any IndexStorageVolumeProviding = LocalIndexStorageVolumeProvider(),
    internalDirectory: String = SnapshotStore.defaultDirectory) {
    self.provider = provider; self.internalDirectory = internalDirectory
  }
  public func policy(for directory:String) throws -> IndexStoragePolicy {
    let normalized = try SnapshotStore.normalizedDirectory(directory)
    let volumes = try provider.mountedStorageVolumes()
    // Resolve the identity before traversing the selected directory. Providers
    // contain only local APFS mounts, so no network metadata request is made.
    var info = APFSVolumeInfo()
    guard apfs_volume_info(normalized,&info) == 0 else { throw SnapshotError.io("chosen storage directory",errno) }
    let uuid = withUnsafeBytes(of:info.volume_uuid) { UUID(bytes:Array($0)) }
    guard let volume = volumes.first(where:{$0.uuid == uuid}),volume.local,volume.filesystem == "apfs",!volume.readOnly else {
      throw IndexStorageError(.unsafePath("choose a writable local APFS directory"))
    }
    let managed = normalized+"/APFSFindIndexes"
    let fd = apfs_open_cache_directory(managed,0)
    if fd >= 0 { close(fd) } else if errno != ENOENT { throw SnapshotError.unsafePath(managed) }
    let relative:String
    if volume.mountPath != "/",managed.hasPrefix(volume.mountPath+"/") {
      relative = String(managed.dropFirst(volume.mountPath.count+1))
    } else if volume.mountPath == "/" || managed.hasPrefix("/Users/") || managed.hasPrefix("/private/") {
      relative = String(managed.dropFirst()) // verified Data-volume firmlink
    } else { throw SnapshotError.unsafePath("directory is outside selected volume") }
    guard Self.safeRelativeDirectory(relative) else { throw SnapshotError.unsafePath(relative) }
    return .volume(storageVolumeUUID:uuid,relativeDirectory:relative)
  }
  public static func safeRelativeDirectory(_ path: String) -> Bool {
    guard !path.isEmpty, !path.hasPrefix("/"), path.utf8.count < PATH_MAX, !path.utf8.contains(0) else { return false }
    return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }
  public func resolve(_ policy: IndexStoragePolicy, source: VolumeIdentity, requiredBytes: UInt64 = 0) throws -> ResolvedIndexStorage {
    let volumes = try provider.mountedStorageVolumes()
    let uuid: UUID, relative: String, directory: String, selected: IndexStorageVolume?
    switch policy {
    case .defaultInternal:
      directory = try SnapshotStore.normalizedDirectory(internalDirectory)
      // Legacy flat filenames and location stay intact; no automatic migration.
      var ancestor = directory, info = APFSVolumeInfo()
      while apfs_volume_info(ancestor, &info) != 0 {
        let parent = PathCanonicalizer.parent(of: ancestor)
        guard parent != ancestor else { throw SnapshotError.unsafePath(directory) }
        ancestor = parent
      }
      uuid = withUnsafeBytes(of: info.volume_uuid) { UUID(bytes: Array($0)) }
      selected = volumes.first { $0.uuid == uuid }
      if let volume = selected, volume.mountPath != "/", directory.hasPrefix(volume.mountPath + "/") {
        relative = String(directory.dropFirst(volume.mountPath.count + 1))
      } else { relative = String(directory.dropFirst()) } // verified macOS Data-volume alias
    case .volume(let id, let prefix):
      uuid = id
      selected = volumes.first { $0.uuid == id }
      relative = prefix + "/v1/" + source.volumeUUID.uuidString.lowercased() + "/"
        + String(source.rootFileID) + "-" + IndexStorageLocator.rootHash(source.relativeRoot)
      let mount = selected?.mountPath ?? ""
      directory = mount.isEmpty ? "" : (mount == "/" ? "" : mount) + "/" + relative
      guard Self.safeRelativeDirectory(prefix) else {
        return result(source, uuid, selected?.mountPath ?? "", relative, directory, .unsafePath(prefix))
      }
    }
    guard let volume = selected else { return result(source, uuid, "", relative, directory, .offline) }
    guard volume.local, volume.filesystem == "apfs" else {
      return result(source, uuid, volume.mountPath, relative, directory, .unsafePath("storage must be local APFS"))
    }
    guard !volume.readOnly else { return result(source, uuid, volume.mountPath, relative, directory, .readOnly) }
    let physicalSource = (source.mountPoint == "/" ? "" : source.mountPoint)+"/"+source.relativeRoot
    let physicalStorage = (volume.mountPath == "/" ? "" : volume.mountPath)+"/"+relative
    guard directory != "/", !PathCanonicalizer.isWithin(source.root, root: directory),
      !PathCanonicalizer.isWithin(physicalSource,root:physicalStorage) else {
      return result(source, uuid, volume.mountPath, relative, directory, .unsafePath("source nested in index storage"))
    }
    let fd = apfs_open_cache_directory(directory, 0)
    if fd >= 0 {
      defer { close(fd) }
      var st = stat()
      guard fstat(fd, &st) == 0, UInt64(truncatingIfNeeded: st.st_dev) == volume.deviceID else {
        return result(source, uuid, volume.mountPath, relative, directory, .identityChanged)
      }
    } else if errno != ENOENT {
      return result(source, uuid, volume.mountPath, relative, directory, .unsafePath("unsafe cache directory (errno \(errno))"))
    }
    // ENOENT does not prove that the selected mount has the declared identity.
    var info = APFSVolumeInfo()
    guard apfs_volume_info(volume.mountPath, &info) == 0, info.device_id == volume.deviceID,
      withUnsafeBytes(of: info.volume_uuid, { UUID(bytes: Array($0)) }) == volume.uuid else {
      return result(source, uuid, volume.mountPath, relative, directory, .identityChanged)
    }
    let state: IndexStorageState = volume.availableBytes < requiredBytes
      ? .lowSpace(required: requiredBytes, available: volume.availableBytes) : .available
    return result(source, uuid, volume.mountPath, relative, directory, state)
  }
  private func result(_ source: VolumeIdentity, _ uuid: UUID, _ mount: String, _ relative: String,
    _ absolute: String, _ state: IndexStorageState) -> ResolvedIndexStorage {
    .init(sourceVolumeUUID: source.volumeUUID, storageVolumeUUID: uuid, storageMountPath: mount,
      relativeDirectory: relative, absoluteDirectory: absolute, state: state)
  }
}
