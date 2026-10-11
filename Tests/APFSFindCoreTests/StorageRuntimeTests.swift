import CoreServices
import Darwin
import Foundation
import XCTest
@testable import APFSFindCore

final class MutableStorageVolumes: IndexStorageVolumeProviding, @unchecked Sendable {
  private let lock = NSLock()
  private var values:[IndexStorageVolume]
  init(_ values:[IndexStorageVolume]) { self.values = values }
  func set(_ values:[IndexStorageVolume]) { lock.withLock { self.values = values } }
  func mountedStorageVolumes() throws -> [IndexStorageVolume] { lock.withLock { values } }
}
final class StorageRuntimeTests:XCTestCase {
  private final class CountingVolumes:IndexStorageVolumeProviding,@unchecked Sendable {
    let value:IndexStorageVolume
    private let lock = NSLock();private var reads = 0
    init(_ value:IndexStorageVolume) {self.value = value}
    func mountedStorageVolumes() throws -> [IndexStorageVolume] {lock.withLock {reads += 1};return [value]}
    var count:Int {lock.withLock {reads}}
  }
  func testCompactionValidatesMountAtTransactionsRatherThanEveryDirectory() throws {
    let tree = try TemporaryTree(),cache = try TemporaryTree(cache:true)
    for i in 0..<200 {try tree.directory("directory-\(i)");try tree.file("directory-\(i)/file")}
    let identity = try VolumeIdentity.discover(root:cache.root),root = tree.root
    let provider = CountingVolumes(.init(uuid:identity.volumeUUID,mountPath:cache.root,deviceID:identity.deviceID,
      removable:false,availableBytes:UInt64.max))
    let c = try PersistentIndexCoordinator(root:root,cacheDirectory:cache.root,maintenanceScheduler:.init(),
      replayStarter:{id,deliver in deliver([.init(path:root,flags:UInt32(kFSEventStreamEventFlagHistoryDone),id:id)])},
      fenceProvider:{_ in 100},storageProvider:provider)
    defer {c.stop(policy:.fast)}
    try c.start();XCTAssertTrue(c.waitUntilLive());XCTAssertTrue(c.waitForCheckpoint());XCTAssertTrue(c.waitForMetadata())
    let before = provider.count
    XCTAssertTrue(c.compact());XCTAssertTrue(c.waitForCheckpoint())
    XCTAssertEqual(c.metrics.snapshot()["compactions",default:0],1)
    XCTAssertLessThan(provider.count-before,100,"mount enumeration must not scale with directory count")
    XCTAssertEqual(c.search("file",limit:500).hits.count,200)
  }
  func testRemovableMetadataBuildScratchDoesNotMapStorage() throws {
    let root = try TemporaryTree(cache:true)
    let scratch = try MetadataBuildBuffer(count:10,directory:root.root,temporaryInMemory:true)
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:root.root).isEmpty)
    try FileManager.default.removeItem(atPath:root.root)
    scratch.update(.init(logicalSize:42,modificationTimeNanoseconds:77),at:3)
    XCTAssertEqual(scratch.value(3).logicalSize,42)
    XCTAssertEqual(scratch.value(3).modificationTimeNanoseconds,77)
    XCTAssertEqual(scratch.unknownSizes,9)
  }
  func testMetadataReadErrorAbortsPublicationWithoutReplacingOldColumns() throws {
    let cache = try TemporaryTree(cache:true),id = snapshotIdentity(),store = try SnapshotStore(directory:cache.root,identity:id,usePRead:true)
    _ = try SnapshotV2Writer.write(source:.ram(sampleSnapshotIndex(),1),identity:id,generation:1,cursor:100,store:store)
    let header = try store.reader(expectedIdentity:id).header
    _ = try MetadataWriter.write(store:store,base:header,cursor:100,value:{.init(logicalSize:UInt64($0))})
    let old = try Data(contentsOf:URL(fileURLWithPath:store.metadataPath))
    XCTAssertThrowsError(try MetadataWriter.write(store:store,base:header,cursor:200,value:{ id in
      if id == 2 {throw IndexBackingError.storageIO(EIO)}
      return .init(logicalSize:999)
    }))
    XCTAssertEqual(old,try Data(contentsOf:URL(fileURLWithPath:store.metadataPath)))
    XCTAssertEqual(try store.immutableMetadataReader(base:header).header.cursor,100)
  }
  func testMonitorLatchedOfflineIdentityReadOnlyAndSpace() throws {
    let uuid = UUID(), original = IndexStorageVolume(uuid:uuid,mountPath:"/Volumes/OwnedStorage",deviceID:7,removable:true,availableBytes:999)
    for replacement in [[],[IndexStorageVolume(uuid:uuid,mountPath:"/Volumes/Remounted",deviceID:8,availableBytes:999)],
      [IndexStorageVolume(uuid:uuid,mountPath:original.mountPath,deviceID:7,readOnly:true,availableBytes:999)]] {
      let provider = MutableStorageVolumes([original])
      let monitor = try IndexStorageMonitor(resolved:.init(sourceVolumeUUID:UUID(),storageVolumeUUID:uuid,
        storageMountPath:original.mountPath,relativeDirectory:"indexes",absoluteDirectory:original.mountPath+"/indexes",state:.available),provider:provider)
      XCTAssertTrue(monitor.usePRead)
      provider.set(replacement); XCTAssertThrowsError(try monitor.validate())
      provider.set([original]); XCTAssertThrowsError(try monitor.check(),"same reader must stay quarantined")
    }
    let provider = MutableStorageVolumes([original])
    let monitor = try IndexStorageMonitor(resolved:.init(sourceVolumeUUID:UUID(),storageVolumeUUID:uuid,
      storageMountPath:original.mountPath,relativeDirectory:"indexes",absoluteDirectory:original.mountPath+"/indexes",state:.available),provider:provider)
    XCTAssertThrowsError(try monitor.validate(requiredBytes:1000))
    XCTAssertEqual(monitor.state,.lowSpace(required:1000,available:999))
  }
  func testProductionExternalUsesPReadAndDisconnectPreservesBasesAndCursor() throws {
    let tree = try TemporaryTree(), storage = try TemporaryTree(cache:true), locatorRoot = try TemporaryTree(cache:true)
    try tree.file("searchable")
    let source = try VolumeIdentity.discover(root:tree.root), device = try VolumeIdentity.discover(root:storage.root)
    let volume = IndexStorageVolume(uuid:device.volumeUUID,mountPath:storage.root,deviceID:device.deviceID,removable:true,availableBytes:UInt64.max)
    let provider = MutableStorageVolumes([volume]), policy = IndexStoragePolicy.volume(storageVolumeUUID:volume.uuid,relativeDirectory:"Indexes")
    let locator = try IndexStorageLocatorStore(directory:locatorRoot.root)
    try locator.publish(.init(identity:source,policy:policy))
    let root = tree.root
    func make() throws -> PersistentIndexCoordinator {
      try .init(root:tree.root,maintenanceScheduler:.init(),replayStarter:{ id,deliver in
        deliver([.init(path:root,flags:UInt32(kFSEventStreamEventFlagHistoryDone),id:id)])
      },fenceProvider:{_ in 100},storageProvider:provider,locatorStore:locator)
    }
    let cold = try make(); try cold.start(); XCTAssertTrue(cold.waitUntilLive())
    XCTAssertTrue(cold.waitForCheckpoint()); cold.stop(policy:.fast)
    let c = try make(); defer { c.stop(policy:.fast) }; try c.start(); XCTAssertTrue(c.waitUntilLive())
    let hybrid = try XCTUnwrap(c.index as? HybridIndex)
    XCTAssertTrue(hybrid.immutableBase is PReadNamespaceIndex); XCTAssertNil(hybrid.mappedBase)
    XCTAssertTrue(c.metadata.capture().base is PReadMetadataIndex)
    XCTAssertEqual(c.search("searchable").hits.count,1)
    let status = try c.storageStatus()
    XCTAssertEqual(status.resolved.storageMountPath,storage.root)
    XCTAssertEqual(status.availableBytes,UInt64.max)
    let before = c.cursorDiagnostics
    let files = try FileManager.default.contentsOfDirectory(atPath:c.cacheDirectory).filter { !$0.hasSuffix(".lock") }
    let bytes = try files.map { try Data(contentsOf:URL(fileURLWithPath:c.cacheDirectory+"/"+$0)) }
    provider.set([])
    let failed = c.search("searchable")
    XCTAssertTrue(failed.hits.isEmpty); XCTAssertEqual(failed.storageError?.state,.offline)
    waitFor("storage teardown",timeout:5) { hybrid.immutableBase == nil }
    XCTAssertEqual(c.storageState,.offline)
    XCTAssertEqual(c.cursorDiagnostics["namespace_durable"],before["namespace_durable"])
    XCTAssertEqual(try files.map { try Data(contentsOf:URL(fileURLWithPath:c.cacheDirectory+"/"+$0)) },bytes)
    provider.set([volume]); XCTAssertThrowsError(try c.validateStorage())
    let restored = try make(); defer { restored.stop(policy:.fast) }; try restored.start(); XCTAssertTrue(restored.waitUntilLive())
    XCTAssertEqual(restored.search("searchable").hits.count,1)
    XCTAssertEqual(restored.stats().dictionary["startup_mode"] as? String,"warm_snapshot")
    XCTAssertEqual(restored.metrics.snapshot()["full_scans",default:0],0)
  }
  func testPublisherRefusesOfflineAndPreservesOldFinal() throws {
    let cache = try TemporaryTree(cache:true), id = snapshotIdentity(), gate = MutableStorageVolumes([])
    let online = IndexStorageVolume(uuid:UUID(),mountPath:cache.root,deviceID:1,availableBytes:999)
    gate.set([online])
    let store = try SnapshotStore(directory:cache.root,identity:id,usePRead:true,beforeTransaction:{
      if try gate.mountedStorageVolumes().isEmpty { throw IndexStorageError(.offline) }
    })
    _ = try SnapshotV2Writer.write(source:.ram(sampleSnapshotIndex(),1),identity:id,generation:1,cursor:100,store:store)
    let before = try Data(contentsOf:URL(fileURLWithPath:store.path))
    gate.set([])
    XCTAssertThrowsError(try store.writeState(header:store.reader(expectedIdentity:id).header,cursor:200,beforePublish:{}))
    XCTAssertEqual(try Data(contentsOf:URL(fileURLWithPath:store.path)),before)
    XCTAssertFalse(FileManager.default.fileExists(atPath:store.statePath))
  }
}
