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
        let index = FileIndex(root: root)
        index.apply([.upsert(normal), .upsert(child)])
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
