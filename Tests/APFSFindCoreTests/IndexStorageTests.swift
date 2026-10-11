import Darwin
import Foundation
import XCTest
@testable import APFSFindCore

private struct StorageVolumes: IndexStorageVolumeProviding {
  let volumes: [IndexStorageVolume]
  func mountedStorageVolumes() throws -> [IndexStorageVolume] { volumes }
}
final class IndexStorageTests: XCTestCase {
  func testSourceInsideCacheIsRejectedAcrossDataFirmlinkAlias() throws {
    let tree = try TemporaryTree(cache:true)
    try tree.directory("source")
    let source = try VolumeIdentity.discover(root:tree.path("source"))
    let cache = "/System/Volumes/Data"+tree.root
    let resolved = try IndexStorageResolver(internalDirectory:cache).resolve(.defaultInternal,source:source)
    if case .unsafePath = resolved.state {} else {XCTFail("source nested inside physical cache alias was accepted")}
  }
  func testManagedStorageExcludesVerifiedDataAliasBeforeDirectoryExists() throws {
    let tree = try TemporaryTree()
    let path = tree.path("storage/not-created-yet"),physical = "/System/Volumes/Data"+path
    try tree.directory("storage")
    let source = try VolumeIdentity.discover(root:tree.root)
    let data = try VolumeIdentity.discover(root:"/System/Volumes/Data"+tree.root)
    XCTAssertEqual(source.deviceID,data.deviceID);XCTAssertEqual(source.rootFileID,data.rootFileID)
    let exclusions = ManagedIndexExclusions()
    exclusions.register(physical)
    XCTAssertTrue(exclusions.contains(path+"/namespace.apfsidx"))
    XCTAssertTrue(exclusions.contains(physical+"/metadata.apfsmeta"))
    XCTAssertFalse(exclusions.contains(tree.path("public-file")))
    ManagedIndexExclusions.shared.register(physical)
    try tree.directory("storage/not-created-yet");try tree.file("storage/not-created-yet/namespace.apfsidx")
    try tree.file("public-file")
    let scan = try BulkScanner(root:tree.root).scan()
    XCTAssertTrue(scan.entries.contains{$0.path == tree.path("public-file")})
    XCTAssertFalse(scan.entries.contains{$0.path.hasPrefix(path)})
  }
  func testDefaultInternalPreservesLegacyDirectoryAndLocalProviderIncludesHomeDevice() throws {
    let tree = try TemporaryTree(cache: true), identity = try VolumeIdentity.discover(root: tree.root)
    let volumes = try LocalIndexStorageVolumeProvider().mountedStorageVolumes()
    XCTAssertTrue(volumes.contains { $0.uuid == identity.volumeUUID })
    XCTAssertTrue(volumes.allSatisfy { $0.local && $0.filesystem == "apfs" })
    let resolved = try IndexStorageResolver(provider: StorageVolumes(volumes: volumes), internalDirectory: tree.root)
      .resolve(.defaultInternal, source: snapshotIdentity())
    XCTAssertEqual(resolved.state, .available)
    XCTAssertEqual(resolved.absoluteDirectory, tree.root)
    XCTAssertEqual(resolved.storageVolumeUUID, identity.volumeUUID)
    XCTAssertFalse(resolved.relativeDirectory.hasPrefix("/"))
  }
  func testLocatorRoundTripAndDistinctRootsOnSameSourceVolume() throws {
    let tree = try TemporaryTree(cache: true), store = try IndexStorageLocatorStore(directory: tree.root)
    let a = snapshotIdentity(root: "/a"), b = snapshotIdentity(root: "/b")
    let external = IndexStoragePolicy.volume(storageVolumeUUID: UUID(), relativeDirectory: "APFSFindIndexes")
    XCTAssertEqual(store.policy(for: a), .defaultInternal)
    try store.publish(.init(identity: a, policy: external))
    try store.publish(.init(identity: b, policy: .defaultInternal))
    XCTAssertEqual(try store.locations().count, 2)
    XCTAssertEqual(store.policy(for: a), external)
    XCTAssertEqual(store.policy(for: b), .defaultInternal)
    let otherInode = VolumeIdentity(root: a.root, deviceID: a.deviceID, rootFileID: a.rootFileID + 1,
      volumeUUID: a.volumeUUID, historyUUID: a.historyUUID, mountPoint: a.mountPoint, relativeRoot: a.relativeRoot)
    XCTAssertEqual(store.policy(for: otherInode), .defaultInternal)
    XCTAssertLessThan(try Data(contentsOf: URL(fileURLWithPath: tree.path("storage-locations.json"))).count, 2048)
  }
  func testAtomicFailurePreservesOldPolicyAndRemovesTemporaryFile() throws {
    let tree = try TemporaryTree(cache: true), store = try IndexStorageLocatorStore(directory: tree.root)
    let identity = snapshotIdentity(), original = IndexStoragePolicy.defaultInternal
    try store.publish(.init(identity: identity, policy: original))
    let path = tree.path("storage-locations.json"), before = try Data(contentsOf: URL(fileURLWithPath: path))
    XCTAssertThrowsError(try store.publish(.init(identity: identity,
      policy: .volume(storageVolumeUUID: UUID(), relativeDirectory: "indexes")), beforeRename: { throw POSIXError(.ENOSPC) }))
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
    XCTAssertEqual(store.policy(for: identity), original)
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: tree.root).contains { $0.hasSuffix(".tmp") })
  }
  func testCorruptionAndSymlinkFallbackNeverFollowTarget() throws {
    let tree = try TemporaryTree(cache: true), store = try IndexStorageLocatorStore(directory: tree.root)
    let path = tree.path("storage-locations.json")
    try Data("corrupt".utf8).write(to: URL(fileURLWithPath: path)); XCTAssertEqual(chmod(path, 0o600), 0)
    XCTAssertEqual(store.policy(for: snapshotIdentity()), .defaultInternal)
    XCTAssertThrowsError(try store.locations())
    try FileManager.default.removeItem(atPath: path)
    try tree.file("foreign")
    try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: tree.path("foreign"))
    XCTAssertEqual(store.policy(for: snapshotIdentity()), .defaultInternal)
    XCTAssertThrowsError(try store.publish(.init(identity: snapshotIdentity(), policy: .defaultInternal)))
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: tree.path("foreign"))).count, 0)
  }
  func testLocatorPermissionsAndUnsafePolicyRejection() throws {
    let tree = try TemporaryTree(cache: true), store = try IndexStorageLocatorStore(directory: tree.root)
    try store.publish(.init(identity: snapshotIdentity(), policy: .defaultInternal))
    for path in [tree.path("storage-locations.json"), tree.path("storage-locations.json.lock")] {
      var st = stat(); XCTAssertEqual(lstat(path, &st), 0); XCTAssertEqual(st.st_mode & 0o7777, 0o600)
    }
    for path in ["../escape", "/absolute", "a//b", "a/./b", "a/../b", "", "a\0b"] {
      XCTAssertThrowsError(try store.publish(.init(identity: snapshotIdentity(),
        policy: .volume(storageVolumeUUID: UUID(), relativeDirectory: path))))
    }
    XCTAssertEqual(chmod(tree.path("storage-locations.json"), 0o644), 0)
    XCTAssertEqual(store.policy(for: snapshotIdentity()), .defaultInternal)
    XCTAssertThrowsError(try store.locations())
  }
  func testSpaceFormulasAndArithmeticOverflow() throws {
    XCTAssertEqual(try IndexStorageSpace.requiredMigration(namespace: 100, metadata: 200, overhead: 0), 300 + 256*1024*1024)
    XCTAssertEqual(try IndexStorageSpace.requiredMigration(namespace: 3_000_000_001, metadata: 0, overhead: 0), 3_300_000_002)
    XCTAssertEqual(try IndexStorageSpace.requiredCompaction(currentFiles: 100, newNamespace: 200, newMetadata: 300), 600 + 256*1024*1024)
    XCTAssertThrowsError(try IndexStorageSpace.requiredMigration(namespace: UInt64.max, metadata: 1))
  }
  func testResolverUUIDRemountPathAndSourceStorageSeparation() throws {
    let a = try TemporaryTree(cache: true), b = try TemporaryTree(cache: true)
    let storage = try VolumeIdentity.discover(root: a.root), source = snapshotIdentity()
    func resolve(_ mount: String) throws -> ResolvedIndexStorage {
      let provider = StorageVolumes(volumes: [.init(uuid: storage.volumeUUID, mountPath: mount,
        deviceID: storage.deviceID, availableBytes: 1_000_000_000)])
      return try IndexStorageResolver(provider: provider).resolve(
        .volume(storageVolumeUUID: storage.volumeUUID, relativeDirectory: "APFSFindIndexes"), source: source)
    }
    let first = try resolve(a.root), remounted = try resolve(b.root)
    XCTAssertEqual(first.state, .available); XCTAssertEqual(remounted.state, .available)
    XCTAssertEqual(first.storageVolumeUUID, remounted.storageVolumeUUID)
    XCTAssertEqual(first.sourceVolumeUUID, source.volumeUUID)
    XCTAssertNotEqual(first.sourceVolumeUUID, first.storageVolumeUUID)
    XCTAssertEqual(first.relativeDirectory, remounted.relativeDirectory)
    XCTAssertNotEqual(first.absoluteDirectory, remounted.absoluteDirectory)
  }
  func testResolverOfflineReadOnlyLowSpaceAndUnsafeFilesystem() throws {
    let tree = try TemporaryTree(cache: true), identity = try VolumeIdentity.discover(root: tree.root)
    let source = snapshotIdentity(), policy = IndexStoragePolicy.volume(storageVolumeUUID: identity.volumeUUID, relativeDirectory: "indexes")
    let offline = try IndexStorageResolver(provider: StorageVolumes(volumes: [])).resolve(policy, source: source)
    XCTAssertEqual(offline.state, .offline)
    for filesystem in ["nfs", "smbfs", "autofs", "exfat"] {
      let provider = StorageVolumes(volumes: [.init(uuid: identity.volumeUUID, mountPath: tree.root,
        deviceID: identity.deviceID, filesystem: filesystem, availableBytes: 1_000)])
      guard case .unsafePath = try IndexStorageResolver(provider: provider).resolve(policy, source: source).state else {
        XCTFail("unsafe filesystem accepted: \(filesystem)"); continue
      }
    }
    let readonly = StorageVolumes(volumes: [.init(uuid: identity.volumeUUID, mountPath: tree.root,
      deviceID: identity.deviceID, readOnly: true, availableBytes: 1_000)])
    XCTAssertEqual(try IndexStorageResolver(provider: readonly).resolve(policy, source: source).state, .readOnly)
    let low = StorageVolumes(volumes: [.init(uuid: identity.volumeUUID, mountPath: tree.root,
      deviceID: identity.deviceID, availableBytes: 1_000)])
    XCTAssertEqual(try IndexStorageResolver(provider: low).resolve(policy, source: source, requiredBytes: 2_000).state,
      .lowSpace(required: 2_000, available: 1_000))
  }
  func testResolverRejectsSymlinkAndChangedDevice() throws {
    let tree = try TemporaryTree(cache: true), identity = try VolumeIdentity.discover(root: tree.root), source = snapshotIdentity()
    try tree.directory("real")
    try FileManager.default.createSymbolicLink(atPath: tree.path("indexes"), withDestinationPath: tree.path("real"))
    let policy = IndexStoragePolicy.volume(storageVolumeUUID: identity.volumeUUID, relativeDirectory: "indexes")
    let provider = StorageVolumes(volumes: [.init(uuid: identity.volumeUUID, mountPath: tree.root,
      deviceID: identity.deviceID, availableBytes: 1_000)])
    guard case .unsafePath = try IndexStorageResolver(provider: provider).resolve(policy, source: source).state else {
      return XCTFail("symlink accepted")
    }
    let changed = StorageVolumes(volumes: [.init(uuid: identity.volumeUUID, mountPath: tree.root,
      deviceID: identity.deviceID + 1, availableBytes: 1_000)])
    XCTAssertEqual(try IndexStorageResolver(provider: changed).resolve(
      .volume(storageVolumeUUID: identity.volumeUUID, relativeDirectory: "new"), source: source).state, .identityChanged)
  }
}
