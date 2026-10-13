import CoreServices
import Foundation
import XCTest
@testable import APFSFindCore

private final class StorageFactoryCount:@unchecked Sendable {
  private let lock = NSLock(); private var count:[UUID:Int] = [:]
  func record(_ id:UUID) { lock.withLock { count[id,default:0] += 1 } }
  func value(_ id:UUID) -> Int { lock.withLock { count[id,default:0] } }
}
final class StorageMultiVolumeTests:XCTestCase,@unchecked Sendable {
  func testSharedStorageDisconnectDrainsBothSourcesAndLeavesIndependentSourceLive() async throws {
    let a = try TemporaryTree(),b = try TemporaryTree(),storage = try TemporaryTree(cache:true),config = try TemporaryTree(cache:true)
    try a.file("shared-storage-a");try b.file("shared-storage-b")
    let aid = UUID(),bid = UUID(),independent = UUID()
    let descriptors = [VolumeDescriptor(volumeUUID:aid,displayName:"A",mountPath:a.root,isSystemVolume:true),
      VolumeDescriptor(volumeUUID:bid,displayName:"B",mountPath:b.root),VolumeDescriptor(volumeUUID:independent,displayName:"C",mountPath:"/fixture")]
    var identities:[UUID:VolumeIdentity] = [:]
    for volume in descriptors.prefix(2) {
      let actual = try VolumeIdentity.discover(root:volume.mountPath)
      identities[volume.volumeUUID] = .init(root:actual.root,deviceID:actual.deviceID,rootFileID:actual.rootFileID,
        volumeUUID:volume.volumeUUID,historyUUID:actual.historyUUID,mountPoint:actual.mountPoint,relativeRoot:actual.relativeRoot)
    }
    let values = identities,actualStorage = try VolumeIdentity.discover(root:storage.root),root = storage.root
    let online = IndexStorageVolume(uuid:actualStorage.volumeUUID,mountPath:root,deviceID:actualStorage.deviceID,removable:true,availableBytes:UInt64.max)
    let provider = MutableStorageVolumes([online]),locator = try IndexStorageLocatorStore(directory:config.root),counts = StorageFactoryCount()
    let c = MultiVolumeCoordinator(provider:FakeVolumeProvider(descriptors),selectionStore:MemoryVolumeSelection([bid,independent]),maintenance:.init(),
      storageProvider:provider,storageLocator:locator,factory:{ volume,scheduler in
        counts.record(volume.volumeUUID)
        guard let identity = values[volume.volumeUUID] else {return FakeVolumeSession(volume)}
        let sourceRoot = volume.mountPath
        let index = try PersistentIndexCoordinator(root:sourceRoot,identityProvider:{_ in identity},maintenanceScheduler:scheduler,
          replayStarter:{id,deliver in deliver([.init(path:sourceRoot,flags:UInt32(kFSEventStreamEventFlagHistoryDone),id:id)])},fenceProvider:{_ in 100},
          storagePolicy:.volume(storageVolumeUUID:online.uuid,relativeDirectory:"Indexes"),storageProvider:provider,locatorStore:locator)
        return VolumeIndexSession(volume:volume,coordinator:index)
      })
    await c.start();try await ready(c,id:aid);try await ready(c,id:bid)
    let initial = await c.search(.init(query:"shared-storage"));XCTAssertEqual(initial.hits.count,2)
    provider.set([]);await c.storageWillUnmount(path:root)
    let states = await c.sessionsSnapshot()
    XCTAssertEqual(states.filter{$0.state == .indexStorageOffline}.count,2)
    XCTAssertEqual(states.first{$0.id == independent}?.state,.live)
    let other = await c.search(.init(query:"match"));XCTAssertFalse(other.hits.isEmpty)
    provider.set([online]);await c.refreshMountedVolumes();try await ready(c,id:aid);try await ready(c,id:bid)
    XCTAssertEqual(counts.value(aid),2);XCTAssertEqual(counts.value(bid),2);XCTAssertEqual(counts.value(independent),1)
    let restored = await c.search(.init(query:"shared-storage"));XCTAssertEqual(restored.hits.count,2)
    await c.stop();withExtendedLifetime((a,b,storage,config)) {}
  }
  func testMigrationWarmCleanupAndDisconnectOnlyAffectsDependentSession() async throws {
    try await exercise(failReplacement:false)
  }
  func testFailedReplacementRestoresLocatorAndOldSearchBeforeRetry() async throws {
    try await exercise(failReplacement:true)
  }
  private func exercise(failReplacement:Bool) async throws {
    let source = try TemporaryTree(),old = try TemporaryTree(cache:true),external = try TemporaryTree(cache:true),config = try TemporaryTree(cache:true)
    let sourceRoot = source.root,oldRoot = old.root
    try source.file("match-owned-source")
    let actual = try VolumeIdentity.discover(root:sourceRoot),sourceID = UUID(),otherID = UUID()
    let identity = VolumeIdentity(root:sourceRoot,deviceID:actual.deviceID,rootFileID:actual.rootFileID,volumeUUID:sourceID,
      historyUUID:actual.historyUUID,mountPoint:actual.mountPoint,relativeRoot:actual.relativeRoot)
    let storage = try VolumeIdentity.discover(root:external.root)
    let online = IndexStorageVolume(uuid:storage.volumeUUID,mountPath:external.root,deviceID:storage.deviceID,removable:true,availableBytes:UInt64.max)
    let provider = MutableStorageVolumes([online]),locator = try IndexStorageLocatorStore(directory:config.root)
    let a = VolumeDescriptor(volumeUUID:sourceID,displayName:"A",mountPath:sourceRoot,isSystemVolume:true)
    let b = VolumeDescriptor(volumeUUID:otherID,displayName:"B",mountPath:"/fixture")
    let counts = StorageFactoryCount(),resolver = IndexStorageResolver(provider:provider,internalDirectory:oldRoot)
    let c = MultiVolumeCoordinator(provider:FakeVolumeProvider([a,b]),selectionStore:MemoryVolumeSelection([otherID]),maintenance:.init(),
      storageProvider:provider,storageResolver:resolver,storageLocator:locator,factory:{ volume,scheduler in
        counts.record(volume.volumeUUID)
        if volume.volumeUUID == otherID {return FakeVolumeSession(volume)}
        let index = try PersistentIndexCoordinator(root:sourceRoot,cacheDirectory:oldRoot,identityProvider:{_ in identity},maintenanceScheduler:scheduler,
          replayStarter:{id,deliver in deliver([.init(path:sourceRoot,flags:UInt32(kFSEventStreamEventFlagHistoryDone),id:id)])},fenceProvider:{_ in 100},
          storagePolicy:failReplacement && counts.value(sourceID) == 2 ? .defaultInternal : locator.policy(for:identity),storageProvider:provider,locatorStore:locator)
        return VolumeIndexSession(volume:volume,coordinator:index)
      })
    await c.start()
    try await ready(c,id:sourceID)
    await c.setVolumePaused(sourceID,enabled:true)
    let policy = IndexStoragePolicy.volume(storageVolumeUUID:storage.volumeUUID,relativeDirectory:"Indexes")
    if failReplacement {
      do {_ = try await c.moveStorage(sourceID,to:policy);XCTFail("mismatched replacement was accepted")}
      catch {}
      XCTAssertEqual(locator.policy(for:identity),.defaultInternal)
      let retained = await c.search(.init(query:"match-owned-source"))
      XCTAssertEqual(retained.hits.count,1)
    }
    let receipt = try await c.moveStorage(sourceID,to:policy)
    let completed = await c.storageProgress()[sourceID]
    XCTAssertEqual(completed?.phase,"completed")
    XCTAssertEqual(completed?.copiedBytes,receipt.bytes)
    // Both the actor's rollback receipt and the public copy must relinquish
    // ownership of readers at handoff, before the storage volume is ejected.
    XCTAssertFalse(receipt.hasValidatedStorage)
    XCTAssertThrowsError(try receipt.takeValidatedStorage())
    let paused = await c.sessionsSnapshot().first{$0.id == sourceID}
    XCTAssertEqual(paused?.state,.paused)
    XCTAssertTrue(paused?.searchAvailable == true)
    await c.setVolumePaused(sourceID,enabled:false)
    try await ready(c,id:sourceID)
    XCTAssertEqual(counts.value(sourceID),failReplacement ? 3 : 2);XCTAssertEqual(counts.value(otherID),1)
    XCTAssertEqual(locator.policy(for:identity),policy)
    let loaded = await c.search(.init(query:"match-owned-source"));XCTAssertEqual(loaded.hits.count,1)
    XCTAssertTrue(FileManager.default.fileExists(atPath:receipt.oldDirectory))
    try await c.deleteOldIndexCopy(sourceID)
    XCTAssertFalse(FileManager.default.fileExists(atPath:try SnapshotStore(directory:oldRoot,identity:identity).path))
    provider.set([])
    await c.storageWillUnmount(path:external.root)
    let states = await c.sessionsSnapshot()
    XCTAssertEqual(states.first{$0.id == sourceID}?.state,.indexStorageOffline)
    XCTAssertEqual(states.first{$0.id == otherID}?.state,.live)
    let other = await c.search(.init(query:"match"));XCTAssertTrue(other.hits.allSatisfy{$0.volumeUUID == otherID});XCTAssertFalse(other.hits.isEmpty)
    provider.set([online]);await c.refreshMountedVolumes();try await ready(c,id:sourceID)
    XCTAssertEqual(counts.value(sourceID),failReplacement ? 4 : 3);XCTAssertEqual(counts.value(otherID),1)
    let restored = await c.search(.init(query:"match-owned-source"));XCTAssertEqual(restored.hits.count,1)
    await c.stop()
    withExtendedLifetime((source,old,external,config)) {}
  }
  private func ready(_ c:MultiVolumeCoordinator,id:UUID) async throws {
    let until = ProcessInfo.processInfo.systemUptime+15
    while ProcessInfo.processInfo.systemUptime < until {
      if await c.sessionsSnapshot().contains(where:{$0.id == id && $0.state == .live && $0.metadataAvailable}) {return}
      try await Task.sleep(for:.milliseconds(20))
    }
    let states = await c.sessionsSnapshot()
    let diagnostics = states.map { "\($0.id):\($0.state.description), metadata=\($0.metadataAvailable), error=\($0.metadataError ?? "none")" }
    XCTFail("source \(id) did not become live with metadata: \(diagnostics)")
  }
}
