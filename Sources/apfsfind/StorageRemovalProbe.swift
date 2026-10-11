import APFSFindCore
import Darwin
import Dispatch
import Foundation

/// Isolated child-process validation against parent-owned APFS images only.
/// No signal recovery handler is installed; SIGBUS is a genuine test failure.
enum StorageRemovalProbe {
  static func emit(_ value:[String:Any]) throws {
    let bytes = try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])
    FileHandle.standardOutput.write(bytes+Data([10]))
  }
  static func run(_ args:[String]) throws -> Int32 {
    if args.first == "actor" {return try actor(args)}
    guard args.count == 3 else { throw CLIError.usage("Invalid storage probe arguments") }
    let identity = try VolumeIdentity.discover(root:args[1])
    if args[0] == "prepare" {
      let store = try SnapshotStore(directory:args[2],identity:identity,usePRead:true)
      let index = FileIndex(root:identity.root)
      index.apply((0..<65_536).map { .upsert(.init(path:identity.root+"/probe-file-\($0)",kind:.file)) })
      _ = try SnapshotV2Writer.write(source:.ram(index,index.stats().generation),identity:identity,
        generation:index.stats().generation,cursor:identity.currentEventID(),store:store)
      let base = try store.reader(expectedIdentity:identity).immutableBase!
      _ = try MetadataWriter.write(store:store,base:base.header,cursor:identity.currentEventID(),
        value:{.init(logicalSize:UInt64($0),modificationTimeNanoseconds:Int64($0))})
      try emit(["prepared":true,"namespace_records":base.count]); return 0
    }
    if ["metadata","bootstrap","compaction"].contains(args[0]) {return try writing(args,identity:identity)}
    guard args[0] == "query" else { throw CLIError.usage("Unknown storage probe mode") }
    let c = try PersistentIndexCoordinator(root:identity.root,cacheDirectory:args[2],maintenanceScheduler:.init())
    try c.start(); guard c.waitUntilLive(timeout:30) else { throw CLIError.startupFailed("storage probe replay failed") }
    guard (c.index as? HybridIndex)?.immutableBase is PReadNamespaceIndex,
      c.metadata.capture().base is PReadMetadataIndex else { throw CLIError.startupFailed("production reader selected an unsafe backing") }
    let drain = CancellationToken()
    signal(SIGUSR1,SIG_IGN)
    let notification = DispatchSource.makeSignalSource(signal:SIGUSR1,queue:.global(qos:.utility))
    notification.setEventHandler { drain.cancel(); c.storageWillUnmount() }
    notification.resume()
    defer { notification.cancel(); c.stop(policy:.fast) }
    try emit(["ready":true,"production_backing":"pread","full_scans":c.metrics.snapshot()["full_scans",default:0]])
    while !drain.isCancelled {
      let result = autoreleasepool { () -> SearchResult in
        _ = (c.index as? HybridIndex)?.immutableBase?.reclaimPages()
        _ = c.metadata.capture().base?.reclaimPages()
        return c.search(.init(query:"probe-file",limit:50,sort:.init(key:.size)))
      }
      if let error = result.storageError {
        c.storageWillUnmount()
        if drain.isCancelled { try emit(["storage_drained":true,"state":String(describing:c.storageState)]); return 0 }
        try emit(["structured_io_error":error.description,"query_hits":result.hits.count,
          "state":String(describing:c.storageState),"full_scans":c.metrics.snapshot()["full_scans",default:0]])
        return 0
      }
      try emit(["query_hits":result.hits.count,"metadata_known":result.hits.allSatisfy{$0.logicalSize != nil},
        "query_ms":result.latencyMilliseconds])
    }
    c.storageWillUnmount()
    try emit(["storage_drained":true,"state":String(describing:c.storageState)])
    return 0
  }
  private struct ProbeVolumes:MountedVolumeProvider {
    let value:VolumeDescriptor
    func mountedVolumes() throws -> [VolumeDescriptor] {[value]}
  }
  private struct ProbeSelection:VolumeSelectionStore {
    func load() -> Set<UUID> {[]}
    func save(_ ids:Set<UUID>) {}
  }
  private static func actor(_ args:[String]) throws -> Int32 {
    guard args.count == 5 else {throw CLIError.usage("actor SOURCE OWNED_CACHE TARGET OWNED_LOCATOR")}
    return try runAsyncCLI {
      let identity = try VolumeIdentity.discover(root:args[1])
      let volume = VolumeDescriptor(volumeUUID:identity.volumeUUID,displayName:"Owned source",mountPath:identity.root,isSystemVolume:true)
      let provider = LocalIndexStorageVolumeProvider(),locator = try IndexStorageLocatorStore(directory:args[4])
      let resolver = IndexStorageResolver(provider:provider,internalDirectory:args[2])
      let policy = try resolver.policy(for:args[3]),target = try resolver.resolve(policy,source:identity)
      let c = MultiVolumeCoordinator(provider:ProbeVolumes(value:volume),selectionStore:ProbeSelection(),maintenance:.init(),
        storageProvider:provider,storageResolver:resolver,storageLocator:locator,factory:{ descriptor,scheduler in
          let persistent = try PersistentIndexCoordinator(root:identity.root,cacheDirectory:args[2],maintenanceScheduler:scheduler,
            storagePolicy:locator.policy(for:identity),storageProvider:provider,locatorStore:locator)
          return VolumeIndexSession(volume:descriptor,coordinator:persistent)
        })
      await c.start()
      func ready() async throws {
        let until = ProcessInfo.processInfo.systemUptime+60
        while ProcessInfo.processInfo.systemUptime < until {
          if await c.sessionsSnapshot().contains(where:{$0.state == .live && $0.metadataAvailable}) {return}
          try await Task.sleep(for:.milliseconds(20))
        }
        throw CLIError.startupFailed("actor source did not become live")
      }
      do {
        try await ready()
        let receipt = try await c.moveStorage(identity.volumeUUID,to:policy)
        try await ready()
        let drain = CancellationToken()
        signal(SIGUSR1,SIG_IGN)
        let notification = DispatchSource.makeSignalSource(signal:SIGUSR1,queue:.global(qos:.utility))
        notification.setEventHandler {drain.cancel()};notification.resume()
        defer {notification.cancel()}
        try emit(["ready":true,"production_backing":"actor-migration-pread","migration_bytes":receipt.bytes])
        while !drain.isCancelled {
          let result = await c.search(.init(query:"probe-file",limit:50,sort:.init(key:.size)))
          let storageOffline = await c.sessionsSnapshot().contains(where:{$0.state == .indexStorageOffline})
          if !result.failedVolumes.isEmpty || result.offlineVolumes != 0 || storageOffline {
            await c.storageWillUnmount(path:target.storageMountPath)
            try emit(["structured_io_error":"index storage offline","query_hits":result.hits.count])
            await c.stop()
            return "{}"
          }
          try emit(["query_hits":result.hits.count,"metadata_known":result.hits.allSatisfy{$0.logicalSize != nil},"query_ms":result.latencyMilliseconds])
          try await Task.sleep(for:.milliseconds(20))
        }
        await c.storageWillUnmount(path:target.storageMountPath)
        // Retain the public receipt until after drain: rollback metadata must
        // not retain the readers and prevent a normal unmount.
        try emit(["storage_drained":true,"receipt_retained":receipt.bytes > 0])
        await c.stop()
        return "{}"
      } catch {await c.stop();throw error}
    }
  }
  private static func writing(_ args:[String],identity:VolumeIdentity) throws -> Int32 {
    let fault:@Sendable (SnapshotFailurePoint)throws->Void = { point in
      if point == .beforeFileSync {
        try emit(["writer_before_sync":true])
        Thread.sleep(forTimeInterval:0.75)
      }
    }
    let c = try PersistentIndexCoordinator(root:identity.root,cacheDirectory:args[2],
      metadataFault:args[0] != "compaction" ? fault : nil,compactionFault:args[0] == "compaction" ? fault : nil,maintenanceScheduler:.init())
    defer {c.stop(policy:.fast)}
    try c.start();guard c.waitUntilLive(timeout:30) else {throw CLIError.startupFailed("write probe startup failed")}
    try emit(["ready":true,"writer_mode":args[0]])
    if args[0] == "metadata" {
      c.metadata.update(path:identity.root+"/probe-file-7",value:.init(logicalSize:777,modificationTimeNanoseconds:777))
      c.checkpointMetadata()
    } else if args[0] == "bootstrap" {c.rebuildMetadata()} else {_ = c.compact()}
    let until = ProcessInfo.processInfo.systemUptime+30
    while ProcessInfo.processInfo.systemUptime < until {
      do {try c.validateStorage()}
      catch {
        c.storageWillUnmount();try emit(["structured_io_error":String(describing:error),"writer_mode":args[0],"full_scans":c.metrics.snapshot()["full_scans",default:0]])
        return 0
      }
      Thread.sleep(forTimeInterval:0.02)
    }
    throw CLIError.startupFailed("write probe did not observe removal")
  }

}
