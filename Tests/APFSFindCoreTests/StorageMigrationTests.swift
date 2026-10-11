import Darwin
import Foundation
import XCTest
@testable import APFSFindCore

final class StorageMigrationTests:XCTestCase {
  private func fixture() throws -> (TemporaryTree,TemporaryTree,TemporaryTree,SnapshotStore,VolumeIdentity,MutableStorageVolumes,IndexStorageLocatorStore,IndexStorageResolver) {
    let old = try TemporaryTree(cache:true), target = try TemporaryTree(cache:true), config = try TemporaryTree(cache:true)
    let id = snapshotIdentity(), actual = try VolumeIdentity.discover(root:target.root)
    let provider = MutableStorageVolumes([.init(uuid:actual.volumeUUID,mountPath:target.root,deviceID:actual.deviceID,removable:true,availableBytes:UInt64.max)])
    let source = try SnapshotStore(directory:old.root,identity:id)
    _ = try SnapshotV2Writer.write(source:.ram(sampleSnapshotIndex(),1),identity:id,generation:1,cursor:100,store:source)
    let h = try source.reader(expectedIdentity:id).header
    _ = try MetadataWriter.write(store:source,base:h,cursor:100,value:{.init(logicalSize:UInt64($0),modificationTimeNanoseconds:Int64($0))})
    let locator = try IndexStorageLocatorStore(directory:config.root)
    try locator.publish(.init(identity:id,policy:.defaultInternal))
    return (old,target,config,source,id,provider,locator,IndexStorageResolver(provider:provider,internalDirectory:old.root))
  }
  func testRoundTripAndQueriesContinueDuringCopyWithoutMovingOldFiles() throws {
    let (old,target,config,source,id,provider,locator,resolver) = try fixture()
    defer { withExtendedLifetime((old,target,config)) {} }
    let uuid = try XCTUnwrap(provider.mountedStorageVolumes().first?.uuid)
    let policy = IndexStoragePolicy.volume(storageVolumeUUID:uuid,relativeDirectory:"Indexes")
    let migration = IndexStorageMigrationCoordinator(provider:provider,locator:locator,resolver:resolver,scheduler:.init())
    let before = try Data(contentsOf:URL(fileURLWithPath:source.path)), base = try XCTUnwrap(source.reader(expectedIdentity:id).immutableBase)
    let query = HybridIndex(base:base)
    let receipt = try migration.migrate(source:source,identity:id,oldPolicy:.defaultInternal,to:policy,progress:{ _ in
      XCTAssertEqual(query.search("Café",limit:50).hits.count,2)
    })
    XCTAssertGreaterThan(receipt.bytes,0); XCTAssertEqual(locator.policy(for:id),policy)
    XCTAssertFalse(receipt.hasValidatedStorage,"public migration receipts do not retain external descriptors")
    XCTAssertEqual(before,try Data(contentsOf:URL(fileURLWithPath:source.path)))
    let moved = try SnapshotStore(directory:receipt.newDirectory,identity:id,usePRead:true,stableFilename:true)
    let loaded = try moved.reader(expectedIdentity:id)
    XCTAssertTrue(loaded.immutableBase is PReadNamespaceIndex); XCTAssertEqual(loaded.header.snapshotUUID,base.header.snapshotUUID)
    XCTAssertEqual(try moved.immutableMetadataReader(base:loaded.header).value(at:1).logicalSize,1)
    let back = try migration.migrate(source:moved,identity:id,oldPolicy:policy,to:.defaultInternal)
    XCTAssertEqual(back.newDirectory,old.root); XCTAssertEqual(locator.policy(for:id),.defaultInternal)
    XCTAssertEqual(before,try Data(contentsOf:URL(fileURLWithPath:source.path)))
    XCTAssertTrue(FileManager.default.fileExists(atPath:moved.path),"rollback copy remains after return migration")
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:moved.directory).contains { $0.hasPrefix(".migration-") })
  }
  func testCancelAndInjectedENOSPCLeaveSourceAndLocatorIntact() throws {
    for cancelled in [false,true] {
      let (old,target,config,source,id,provider,locator,resolver) = try fixture()
      defer { withExtendedLifetime((old,target,config)) {} }
      let uuid = try XCTUnwrap(provider.mountedStorageVolumes().first?.uuid), policy = IndexStoragePolicy.volume(storageVolumeUUID:uuid,relativeDirectory:"Indexes")
      let before = try Data(contentsOf:URL(fileURLWithPath:source.path)), token = CancellationToken()
      let migration = IndexStorageMigrationCoordinator(provider:provider,locator:locator,resolver:resolver,scheduler:.init())
      XCTAssertThrowsError(try migration.migrate(source:source,identity:id,oldPolicy:.defaultInternal,to:policy,cancellation:token,
        checkpoint:{ if !cancelled { throw POSIXError(.ENOSPC) } },progress:{ _ in if cancelled { token.cancel() } }))
      XCTAssertEqual(locator.policy(for:id),.defaultInternal)
      XCTAssertEqual(before,try Data(contentsOf:URL(fileURLWithPath:source.path)))
      let resolved = try resolver.resolve(policy,source:id)
      XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:resolved.absoluteDirectory).contains { $0.hasPrefix(".migration-") })
      XCTAssertFalse(FileManager.default.fileExists(atPath:resolved.absoluteDirectory+"/namespace.apfsidx"))
    }
  }
  func testValidationAndLocatorFailureRollbackExistingTarget() throws {
    for badMetadata in [false,true] {
      let (old,target,config,source,id,provider,locator,resolver) = try fixture()
      defer { withExtendedLifetime((old,target,config)) {} }
      let uuid = try XCTUnwrap(provider.mountedStorageVolumes().first?.uuid), policy = IndexStoragePolicy.volume(storageVolumeUUID:uuid,relativeDirectory:"Indexes")
      let resolved = try resolver.resolve(policy,source:id)
      let existing = try SnapshotStore(directory:resolved.absoluteDirectory,identity:id,usePRead:true,stableFilename:true)
      _ = try SnapshotV2Writer.write(source:.ram(sampleSnapshotIndex(),1),identity:id,generation:2,cursor:90,store:existing)
      let previous = try Data(contentsOf:URL(fileURLWithPath:existing.path))
      if badMetadata {
        var bytes = try Data(contentsOf:URL(fileURLWithPath:source.metadataPath)); bytes[0] ^= 1
        try bytes.write(to:URL(fileURLWithPath:source.metadataPath))
      } else {
        try Data("broken locator".utf8).write(to:URL(fileURLWithPath:config.path("storage-locations.json")))
      }
      let migration = IndexStorageMigrationCoordinator(provider:provider,locator:locator,resolver:resolver,scheduler:.init())
      XCTAssertThrowsError(try migration.migrate(source:source,identity:id,oldPolicy:.defaultInternal,to:policy))
      XCTAssertEqual(previous,try Data(contentsOf:URL(fileURLWithPath:existing.path)))
      XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:existing.directory).contains { $0.hasPrefix(".migration-") })
    }
  }
  func testInterruptedStagingCleanupKeepsActiveAndUnknownDirectories() throws {
    let root = try TemporaryTree(cache:true),id = snapshotIdentity(),target = try SnapshotStore(directory:root.root,identity:id)
    let stage = try SnapshotStore(directory:target.createMigrationStaging(),identity:id)
    try stage.lockMigrationStaging()
    target.cleanupAbandonedMigrations()
    XCTAssertTrue(FileManager.default.fileExists(atPath:stage.directory),"live publisher is retained")
    stage.unlockMigrationStaging();target.cleanupAbandonedMigrations()
    XCTAssertFalse(FileManager.default.fileExists(atPath:stage.directory))
    let unknown = try SnapshotStore(directory:target.createMigrationStaging(),identity:id)
    let file = unknown.directory+"/user-file"
    try Data([99]).write(to:URL(fileURLWithPath:file))
    target.cleanupAbandonedMigrations()
    XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:file)),Data([99]))
  }
  func testPreflightInsufficientSpaceCreatesNoStagingAndRemountUsesLocatorRootBinding() throws {
    let (old,target,config,source,id,provider,locator,resolver) = try fixture()
    defer { withExtendedLifetime((old,target,config)) {} }
    let v = try XCTUnwrap(provider.mountedStorageVolumes().first)
    provider.set([.init(uuid:v.uuid,mountPath:v.mountPath,deviceID:v.deviceID,removable:true,availableBytes:0)])
    let migration = IndexStorageMigrationCoordinator(provider:provider,locator:locator,resolver:resolver,scheduler:.init())
    let policy = IndexStoragePolicy.volume(storageVolumeUUID:v.uuid,relativeDirectory:"Indexes")
    XCTAssertThrowsError(try migration.migrate(source:source,identity:id,oldPolicy:.defaultInternal,to:policy))
    XCTAssertEqual(locator.policy(for:id),.defaultInternal)
    let remounted = VolumeIdentity(root:"/Volumes/ChangedName",deviceID:800,rootFileID:id.rootFileID,volumeUUID:id.volumeUUID,
      historyUUID:id.historyUUID,mountPoint:"/Volumes/ChangedName",relativeRoot:id.relativeRoot)
    let fd = open(source.path,O_RDONLY|O_CLOEXEC|O_NOFOLLOW)
    let rebound = try PReadNamespaceIndex(fileDescriptor:fd,identity:remounted,allowRootRebinding:true)
    XCTAssertEqual(rebound.root,remounted.root); XCTAssertEqual(rebound.header.rootDeviceID,800)
    XCTAssertTrue(try rebound.reconstructPath(1).hasPrefix(remounted.root+"/"))
    XCTAssertThrowsError(try PReadNamespaceIndex(fileDescriptor:open(source.path,O_RDONLY|O_CLOEXEC|O_NOFOLLOW),identity:remounted))
  }
}
