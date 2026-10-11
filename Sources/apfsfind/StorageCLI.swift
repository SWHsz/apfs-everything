import APFSFindCore
import Foundation

enum StorageCLI {
  static func run(_ arguments:[String]) throws -> Int32 {
    let command = arguments.first ?? "status"
    var sourceUUID:UUID?, targetUUID:UUID?, relative = "APFSFindIndexes", root:String?
    var cursor = 1
    while cursor < arguments.count {
      let flag = arguments[cursor]; cursor += 1
      guard cursor < arguments.count else { throw CLIError.usage("Missing value for \(flag)") }
      let value = arguments[cursor]; cursor += 1
      switch flag {
      case "--source-volume": guard let id = UUID(uuidString:value) else { throw CLIError.usage("Invalid source UUID") }; sourceUUID = id
      case "--to-volume": guard let id = UUID(uuidString:value) else { throw CLIError.usage("Invalid storage UUID") }; targetUUID = id
      case "--relative-directory": relative = value
      case "--root": root = value
      default: throw CLIError.usage("Unknown storage option: \(flag)")
      }
    }
    let provider = LocalIndexStorageVolumeProvider(), resolver = IndexStorageResolver(provider:provider)
    let locator = try IndexStorageLocatorStore(), mounted = try LocalMountedVolumeProvider().mountedVolumes()
    if command == "list" {
      let values = try provider.mountedStorageVolumes().map { ["storage_volume_uuid":$0.uuid.uuidString,
        "mount_path":$0.mountPath,"available_bytes":$0.availableBytes,"read_only":$0.readOnly,
        "backing":$0.removable ? "pread" : "mmap"] as [String:Any] }
      print(String(decoding:try JSONSerialization.data(withJSONObject:values,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self)); return 0
    }
    let sources = mounted.filter { sourceUUID == nil || $0.volumeUUID == sourceUUID }
    guard !sources.isEmpty else { throw CLIError.usage("Source volume is not mounted") }
    if command == "status" {
      let values = try sources.map { volume -> [String:Any] in
        let identity = try VolumeIdentity.discover(root:root ?? volume.mountPath)
        let policy = locator.policy(for:identity), resolved = try resolver.resolve(policy,source:identity)
        return ["source_volume_uuid":identity.volumeUUID.uuidString,"source_root":identity.root,
          "storage_volume_uuid":resolved.storageVolumeUUID.uuidString,"storage_mount_path":resolved.storageMountPath,
          "directory":resolved.absoluteDirectory,"state":String(describing:resolved.state)]
      }
      print(String(decoding:try JSONSerialization.data(withJSONObject:values,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self)); return 0
    }
    guard ["move","use-default"].contains(command),let sourceUUID,
      let volume = sources.first(where:{$0.volumeUUID == sourceUUID}) else {
      throw CLIError.usage("storage move/use-default requires --source-volume UUID")
    }
    let identity = try VolumeIdentity.discover(root:root ?? volume.mountPath)
    guard identity.volumeUUID == sourceUUID else { throw CLIError.usage("--root does not belong to source volume") }
    let oldPolicy = locator.policy(for:identity), old = try resolver.resolve(oldPolicy,source:identity)
    guard old.state == .available else { throw IndexStorageError(old.state) }
    let storage = try IndexStorageMonitor(resolved:old,provider:provider)
    let source = try SnapshotStore(directory:old.absoluteDirectory,identity:identity,usePRead:storage.usePRead,
      stableFilename:oldPolicy != .defaultInternal,validateStorage:{try storage.check()},beforeTransaction:{try storage.validate()})
    let policy:IndexStoragePolicy
    if command == "use-default" { policy = .defaultInternal }
    else {
      guard let targetUUID,IndexStorageResolver.safeRelativeDirectory(relative) else { throw CLIError.usage("move requires --to-volume UUID and a safe relative directory") }
      policy = .volume(storageVolumeUUID:targetUUID,relativeDirectory:relative)
    }
    let token = CancellationToken(), signal = ShutdownSignal { token.cancel() }
    defer { withExtendedLifetime(signal) {} }
    let receipt = try IndexStorageMigrationCoordinator(provider:provider,locator:locator,resolver:resolver).migrate(
      source:source,identity:identity,oldPolicy:oldPolicy,to:policy,cancellation:token,
      checkpoint:{ guard try VolumeIdentity.discover(root:identity.root) == identity else { throw SnapshotError.identity("source changed during migration") } },
      progress:{ TerminalOutput.info("Storage migration: \($0.phase), \($0.copiedBytes)/\($0.totalBytes) bytes") })
    print("Migrated \(receipt.bytes) bytes in \(String(format:"%.1f",receipt.milliseconds)) ms. Old copy retained. Reopen this source session to use the new storage.")
    return 0
  }
}
