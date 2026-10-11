import APFSFindCore
import Foundation

/// Uses explicitly supplied owned caches and locator; never the user's settings.
enum StorageMigrationProbe {
  static func refresh(_ args:[String]) throws -> Int32 {
    guard args.count == 2 else {throw CLIError.usage("owned storage refresh requires SOURCE OWNED_CACHE")}
    let c = try PersistentIndexCoordinator(root:args[0],rebuildIndex:true,cacheDirectory:args[1],maintenanceScheduler:.init())
    defer {c.stop(policy:.fast)}
    try c.start(progress:{TerminalOutput.info($0)})
    guard c.waitUntilLive(timeout:1200),c.waitForCheckpoint(timeout:120),c.waitForMetadata(timeout:120) else {throw CLIError.startupFailed("owned source preparation failed")}
    c.flushMetadata()
    // A busy real root keeps changing generation during export. Use the
    // existing quiesced shutdown checkpoint for this preparation-only step.
    c.stop(saveCheckpoint:true)
    try StorageRemovalProbe.emit(["prepared":true,"records":c.index.stats().liveEntries,"full_scans":c.metrics.snapshot()["full_scans",default:0],"cursors":c.cursorDiagnostics])
    return 0
  }
  static func run(_ args:[String]) throws -> Int32 {
    guard [5,6].contains(args.count),["roundtrip","detach"].contains(args[0]) else {
      throw CLIError.usage("storage migration probe: roundtrip|detach SOURCE OWNED_CACHE TARGET_DIRECTORY OWNED_LOCATOR")
    }
    let identity = try VolumeIdentity.discover(root:args[1]),provider = LocalIndexStorageVolumeProvider()
    let resolver = IndexStorageResolver(provider:provider,internalDirectory:args[2])
    let locator = try IndexStorageLocatorStore(directory:args[4])
    let source = try SnapshotStore(directory:args[2],identity:identity,usePRead:true)
    let policy = try resolver.policy(for:args[3])
    let before = ProcessResourceSample.capture()
    let migrate = IndexStorageMigrationCoordinator(provider:provider,locator:locator,resolver:resolver,scheduler:.init())
    let old = try source.reader(expectedIdentity:identity).immutableBase!
    let oldMeta = try source.immutableMetadataReader(base:old.header)
    func digest(_ base:any ImmutableNamespaceBase,_ meta:any ImmutableMetadataBase)throws -> [[String:Any]] {
      let values = MetadataIndexCoordinator();values.bind(namespace:base,mapped:meta,cursor:meta.header.cursor)
      let index = HybridIndex(base:base);index.setMetadataSource(values)
      return try SearchSortKey.allCases.map { key in
        let result = index.search(.init(query:"netforensic",limit:50,sort:.init(key:key)))
        if let error = result.storageError {throw error}
        return ["sort":key.rawValue,"hits":result.hits.map { ["path":$0.path,"size":$0.logicalSize as Any? ?? NSNull(),"mtime":$0.modificationTimeNanoseconds as Any? ?? NSNull()] }]
      }
    }
    let expected = try JSONSerialization.data(withJSONObject:digest(old,oldMeta),options:[.sortedKeys])
    var marked = false
    do {
      let moved = try migrate.migrate(source:source,identity:identity,oldPolicy:.defaultInternal,to:policy,
        progress:{ p in
          if args[0] == "detach",!marked,p.phase == "copying" {
            marked = true;try? StorageRemovalProbe.emit(["migration_copying":true]);Thread.sleep(forTimeInterval:0.75)
          }
        })
      guard args[0] != "detach" else {throw CLIError.startupFailed("migration survived without observing requested removal")}
      let target = try SnapshotStore(directory:moved.newDirectory,identity:identity,usePRead:true,stableFilename:true)
      let targetBase = try target.reader(expectedIdentity:identity).immutableBase!,targetMeta = try target.immutableMetadataReader(base:targetBase.header)
      let actual = try JSONSerialization.data(withJSONObject:digest(targetBase,targetMeta),options:[.sortedKeys])
      guard actual == expected else {throw SnapshotError.invalid("migration query/metadata mismatch")}
      let startup = ProcessInfo.processInfo.systemUptime
      let live = try PersistentIndexCoordinator(root:identity.root,cacheDirectory:args[2],storagePolicy:policy,locatorStore:locator)
      try live.start(progress:{TerminalOutput.info($0)})
      let deadline = ProcessInfo.processInfo.systemUptime+180
      while live.currentState != .live && ProcessInfo.processInfo.systemUptime < deadline {
        if live.currentState == .rebuilding {break}
        Thread.sleep(forTimeInterval:0.05)
      }
      guard live.currentState == .live,live.metrics.snapshot()["full_scans",default:0] == 0 else {
        TerminalOutput.info("Migration startup recovery: \(live.core.startupStatus().recoveryReason ?? "none"); \(live.currentState)")
        live.stop(policy:.fast);throw CLIError.startupFailed("migration warm replay required a scan or timed out")
      }
      let warmMS = (ProcessInfo.processInfo.systemUptime-startup)*1000
      live.stop(policy:.fast)
      var returnSource = target,returnPolicy = policy,betweenMS:Double = 0
      if args.count == 6 {
        let secondPolicy = try resolver.policy(for:args[5])
        let between = try migrate.migrate(source:target,identity:identity,oldPolicy:policy,to:secondPolicy)
        returnSource = try SnapshotStore(directory:between.newDirectory,identity:identity,usePRead:true,stableFilename:true)
        returnPolicy = secondPolicy;betweenMS = between.milliseconds
      }
      let back = try migrate.migrate(source:returnSource,identity:identity,oldPolicy:returnPolicy,to:.defaultInternal)
      let restored = try source.reader(expectedIdentity:identity).immutableBase!,restoredMeta = try source.immutableMetadataReader(base:restored.header)
      guard try JSONSerialization.data(withJSONObject:digest(restored,restoredMeta),options:[.sortedKeys]) == expected else {throw SnapshotError.invalid("return migration mismatch")}
      let locatorBytes = try FileManager.default.attributesOfItem(atPath:args[4]+"/storage-locations.json")[.size] as? NSNumber
      try StorageRemovalProbe.emit(["passed":true,"namespace_records":old.count,"bytes":moved.bytes,
        "outbound_ms":moved.milliseconds,"external_to_external_ms":betweenMS,"return_ms":back.milliseconds,"warm_live_ms":warmMS,"full_scans":0,
        "query_metadata_equal":true,"rollback_copy_retained":FileManager.default.fileExists(atPath:moved.oldDirectory),
        "locator_bytes":locatorBytes?.uint64Value ?? 0,"source_volume_uuid":identity.volumeUUID.uuidString,
        "storage_policy":String(describing:policy),"resources":ProcessResourceSample.capture().delta(since:before)])
      return 0
    } catch {
      if args[0] == "detach",marked,locator.policy(for:identity) == .defaultInternal {
        // Re-read the intact old base, proving rollback leaves it usable.
        let remaining = try source.reader(expectedIdentity:identity).immutableBase!
        guard remaining.header.snapshotUUID == old.header.snapshotUUID else {throw SnapshotError.generationChanged}
        try StorageRemovalProbe.emit(["structured_io_error":String(describing:error),"old_index_usable":true,"locator_unchanged":true]);return 0
      }
      throw error
    }
  }
}
