import CAPFSShim
import Darwin
import Foundation

public struct IndexStorageMigrationProgress:Sendable {
  public let copiedBytes:UInt64, totalBytes:UInt64
  public let file:String, phase:String
}
public struct IndexStorageMigrationReceipt:Sendable {
  public let sourceIdentity:VolumeIdentity
  public let oldPolicy:IndexStoragePolicy, newPolicy:IndexStoragePolicy
  public let oldDirectory:String, newDirectory:String
  public let bytes:UInt64, milliseconds:Double
  public let snapshotUUID:UUID
  private let transfer:ValidatedIndexStorageTransfer
  init(sourceIdentity:VolumeIdentity,oldPolicy:IndexStoragePolicy,newPolicy:IndexStoragePolicy,
    oldDirectory:String,newDirectory:String,bytes:UInt64,milliseconds:Double,snapshotUUID:UUID,
    validated:ValidatedIndexStorage?) {
    self.sourceIdentity = sourceIdentity; self.oldPolicy = oldPolicy; self.newPolicy = newPolicy
    self.oldDirectory = oldDirectory; self.newDirectory = newDirectory
    self.bytes = bytes; self.milliseconds = milliseconds; self.snapshotUUID = snapshotUUID
    transfer = .init(validated)
  }
  func takeValidatedStorage() throws -> ValidatedIndexStorage {try transfer.take()}
  var hasValidatedStorage:Bool {transfer.hasValue}
}

/// Chunked migration leaves the live source backing in place. A caller holds
/// the short switch barrier; locator publication is the final durable operation.
struct ValidatedIndexStorage:Sendable {
  let namespace:any ImmutableNamespaceBase
  let metadata:any ImmutableMetadataBase
  let monitor:IndexStorageMonitor
}
/// Receipt copies share one handoff. Keeping a receipt for rollback must not
/// keep the external readers (and their file descriptors) alive after adoption.
private final class ValidatedIndexStorageTransfer:@unchecked Sendable {
  private let lock = NSLock()
  private var value:ValidatedIndexStorage?
  init(_ value:ValidatedIndexStorage?) {self.value = value}
  var hasValue:Bool {lock.withLock {value != nil}}
  func take() throws -> ValidatedIndexStorage {
    try lock.withLock {
      guard let result = value else {throw SnapshotError.busy}
      value = nil
      return result
    }
  }
}
public final class IndexStorageMigrationCoordinator:Sendable {
  private let provider:any IndexStorageVolumeProviding
  private let locator:IndexStorageLocatorStore
  private let resolver:IndexStorageResolver
  private let scheduler:MaintenanceScheduler
  public init(provider:any IndexStorageVolumeProviding = LocalIndexStorageVolumeProvider(),
    locator:IndexStorageLocatorStore,resolver:IndexStorageResolver = .init(), scheduler:MaintenanceScheduler = .shared) {
    self.provider = provider; self.locator = locator; self.resolver = resolver; self.scheduler = scheduler
  }
  public func migrate(source:SnapshotStore,identity:VolumeIdentity,oldPolicy:IndexStoragePolicy,
    to policy:IndexStoragePolicy,cancellation:CancellationToken = .init(),
    checkpoint:@escaping ()throws->Void = {},
    progress:@escaping (IndexStorageMigrationProgress)->Void = {_ in},
    withSwitchBarrier:((()throws->Void)throws->Void) = {try $0()}) throws -> IndexStorageMigrationReceipt {
    try migrate(source:source,identity:identity,oldPolicy:oldPolicy,to:policy,cancellation:cancellation,
      retainValidatedReaders:false,checkpoint:checkpoint,progress:progress,withSwitchBarrier:withSwitchBarrier)
  }
  // Only the session owner can retain a one-shot validated-reader handoff.
  func migrate(source:SnapshotStore,identity:VolumeIdentity,oldPolicy:IndexStoragePolicy,
    to policy:IndexStoragePolicy,cancellation:CancellationToken = .init(),
    retainValidatedReaders:Bool,
    checkpoint:@escaping ()throws->Void = {},
    progress:@escaping (IndexStorageMigrationProgress)->Void = {_ in},
    withSwitchBarrier:((()throws->Void)throws->Void) = { try $0() }) throws -> IndexStorageMigrationReceipt {
    let began = ProcessInfo.processInfo.systemUptime
    let total = try source.indexFileBytes()
    let required = try IndexStorageSpace.requiredMigration(namespace:total,metadata:0)
    let resolved = try resolver.resolve(policy,source:identity,requiredBytes:required)
    let monitor = try IndexStorageMonitor(resolved:resolved,provider:provider)
    guard resolved.absoluteDirectory != source.directory else { throw SnapshotError.invalid("storage already selected") }
    ManagedIndexExclusions.shared.register(resolved.absoluteDirectory)
    let target = try SnapshotStore(directory:resolved.absoluteDirectory,identity:identity,usePRead:monitor.usePRead,
      stableFilename:policy != .defaultInternal,validateStorage:{try monitor.check()},beforeTransaction:{try monitor.validate()})
    target.cleanupAbandonedMigrations()
    let stageDirectory = try target.createMigrationStaging()
    // This directory was created exclusively by this attempt, under the pinned
    // target. Only its known files are ever copied; cleanup cannot touch old data.

    let staging = try SnapshotStore(directory:stageDirectory,identity:identity,usePRead:monitor.usePRead,
      stableFilename:policy != .defaultInternal,validateStorage:{try monitor.check()},beforeTransaction:{try monitor.validate()})
    try staging.lockMigrationStaging()
    defer { staging.unlockMigrationStaging();target.cleanupMigrationStaging(staging) }
    var lease = try scheduler.acquireBlocking(volumeID:identity.volumeUUID,kind:.storageMigration,cancellation:cancellation)
    defer { lease.release() }
    let original = try source.reader(expectedIdentity:identity).header
    var copied:UInt64 = 0
    try source.copyMigrationFiles(to:staging,cancellation:cancellation,checkpoint:{
      while true {
        do { try lease.checkpoint(); break }
        catch is MaintenanceYield {
          lease.release()
          lease = try self.scheduler.acquireBlocking(volumeID:identity.volumeUUID,kind:.storageMigration,cancellation:cancellation)
        }
      }
      try checkpoint()
      try monitor.validate(requiredBytes:(total > copied ? total-copied : 0)+IndexStorageSpace.minimumMargin)
    },progress:{ bytes,file in
      copied = bytes; progress(.init(copiedBytes:bytes,totalBytes:total,file:file,phase:"copying"))
    })
    progress(.init(copiedBytes:copied,totalBytes:total,file:"",phase:"validating"))
    let base = try staging.reader(expectedIdentity:identity)
    guard base.header.snapshotUUID == original.snapshotUUID else { throw SnapshotError.generationChanged }
    let validatedMetadata = try staging.immutableMetadataReader(base:base.header)
    if cancellation.isCancelled { throw SnapshotError.cancelled }
    lease.recordCompletion(); lease.release()
    try withSwitchBarrier {
      try checkpoint(); try monitor.validate()
      guard try source.migrationSnapshotIdentifier() == original.snapshotUUID else { throw SnapshotError.generationChanged }
      progress(.init(copiedBytes:copied,totalBytes:total,file:"",phase:"switching"))
      try target.installMigration(from:staging) {
        try base.immutableBase?.checkStorage(); try validatedMetadata.checkStorage()
        guard try target.migrationSnapshotIdentifier() == original.snapshotUUID else {throw SnapshotError.generationChanged}
        if cancellation.isCancelled { throw SnapshotError.cancelled }
        try monitor.validate()
        try locator.publish(.init(identity:identity,policy:policy),beforeRename:{try monitor.validate();try checkpoint()})
      }
    }
    progress(.init(copiedBytes:copied,totalBytes:total,file:"",phase:"completed"))
    return .init(sourceIdentity:identity,oldPolicy:oldPolicy,newPolicy:policy,oldDirectory:source.directory,
      newDirectory:target.directory,bytes:copied,milliseconds:(ProcessInfo.processInfo.systemUptime-began)*1000,
      snapshotUUID:original.snapshotUUID!,validated:retainValidatedReaders
        ? .init(namespace:base.immutableBase!,metadata:validatedMetadata,monitor:monitor) : nil)
  }
}
