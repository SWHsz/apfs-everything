import XCTest
@testable import APFSFindCore

private struct FixtureDirectoryReader: DirectoryReading {
    let children: [String: [NamespaceEntry]]
    func readDirectory(_ path: String, rootDeviceID: UInt64,
                       cancellation: CancellationToken) throws -> [NamespaceEntry] {
        children[path] ?? []
    }
}

final class MountIdentityTests: XCTestCase {
    func testMountUnmountAndCompoundTransitionsWithSameInode() throws {
        let root = "/mount-fixture", path = root + "/dir"
        let normal = NamespaceEntry(path: path, kind: .directory, deviceID: 1, fileID: 7)
        let boundary = NamespaceEntry(path: path, kind: .directory, deviceID: 2, fileID: 7, isMountPoint: true)
        let child = NamespaceEntry(path: path + "/child", kind: .file, deviceID: 1, fileID: 8)
        let ram = FileIndex(root: root)
        ram.apply([.upsert(normal), .upsert(child)])
        let cache = try TemporaryTree(cache: true), identity = snapshotIdentity(root: root, device: 1)
        let store = try SnapshotStore(directory: cache.root, identity: identity)
        _ = try SnapshotV2Writer.write(source: .ram(ram, ram.stats().generation), identity: identity,
                                      generation: ram.stats().generation, cursor: 7, store: store)
        let mapped = HybridIndex(base: try MMapBaseIndex(path: store.path, identity: identity))
        for index: any NamespaceIndex in [ram, mapped] {
        func reconcile(_ directory: NamespaceEntry, _ descendants: [NamespaceEntry]) {
            let fixture = FixtureDirectoryReader(children: [root: [directory], path: descendants])
            let reconciler = DirectoryReconciler(scanner: fixture, index: index,
                                                rootDeviceID: 1, metrics: Metrics())
            index.apply(reconciler.prepare(root, force: true).mutations)
            let fresh = FileIndex(root: root)
            fresh.apply([.upsert(directory)])
            if BulkScanner.shouldTraverse(entry: directory, rootDeviceID: 1) {
                fresh.apply(descendants.map { .upsert($0) })
            }
            XCTAssertEqual(index.snapshotPaths(), fresh.snapshotPaths())
            XCTAssertEqual(index.entry(at: path), directory)
        }
        reconcile(boundary, [child]) // Hidden descendants must disappear.
        XCTAssertNil(index.entry(at: child.path))
        reconcile(normal, [child]) // Same inode: unmount still rescans.
        XCTAssertNotNil(index.entry(at: child.path))
        reconcile(boundary, [])
        reconcile(normal, [child])
        }
    }

    func testMountFlagAndDeviceChangesAreIndependentIdentityChanges() {
        let old = NamespaceEntry(path: "/x/d", kind: .directory, deviceID: 1, fileID: 7)
        for changed in [
            NamespaceEntry(path: old.path, kind: .directory, deviceID: 2, fileID: 7),
            NamespaceEntry(path: old.path, kind: .directory, deviceID: 1, fileID: 7, isMountPoint: true),
            NamespaceEntry(path: old.path, kind: .directory, deviceID: 1, fileID: 8),
            NamespaceEntry(path: old.path, kind: .file, deviceID: 1, fileID: 7)
        ] {
            XCTAssertFalse(old.hasSameDirectoryIdentity(as: changed))
            let index = FileIndex(root: "/x")
            index.apply([.upsert(old), .upsert(.init(path: "/x/d/ghost", kind: .file))])
            index.apply([.upsert(changed)])
            XCTAssertNil(index.entry(at: "/x/d/ghost"))
        }
    }
}
