import Foundation
import Darwin
import CoreServices
import XCTest
@testable import APFSFindCore

final class LiveUpdateIntegrationTests: XCTestCase {
    func testCapturedSocketMetadataHintReconcilesRealDirectoryEntries() throws {
        try requireFSEvents()
        let tree = try OwnedBenchmarkDirectory(parent: "/private/tmp", prefix: "apfsfind-real-bench-")
        defer { try? tree.remove() }
        let coordinator = try UpdateCoordinator(root: tree.path, maintenanceScheduler: .init())
        defer { coordinator.stop() }
        try coordinator.start()
        XCTAssertTrue(coordinator.waitUntilLive())
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let path = tree.path + "/local.sock", bytes = Array(path.utf8) + [UInt8(0)]
        var address = sockaddr_un()
        XCTAssertLessThanOrEqual(bytes.count, MemoryLayout.size(ofValue: address.sun_path))
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return }
        address.sun_family = sa_family_t(AF_UNIX)
        let length = socklen_t(2 + bytes.count)
        address.sun_len = UInt8(length)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { destination.copyMemory(from: $0) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) }
        }
        XCTAssertEqual(bound, 0)
        guard bound == 0 else { return }
        // macOS 27 emitted precisely this hint for bind; macOS 15 CI emitted
        // no socket event in the observation window. Inject the captured hint
        // to test classification + actual bulk metadata independently of OS
        // notification support. Ordinary-file watcher tests remain native.
        coordinator.enqueue([.init(path: path, flags: UInt32(kFSEventStreamEventFlagItemXattrMod))])
        waitFor("socket visible") { coordinator.index.entry(at: path)?.kind == .other }
        XCTAssertEqual(unlink(path), 0)
        coordinator.enqueue([.init(path: path, flags: UInt32(kFSEventStreamEventFlagItemXattrMod))])
        waitFor("socket removed") { coordinator.index.entry(at: path) == nil }
        XCTAssertTrue(coordinator.flushEvents())
        XCTAssertTrue(try coordinator.verify().isConsistent)
    }
    func testStopRequestedInsideCallbackDoesNotSyncOntoItsOwnQueue() throws {
        try requireFSEvents()
        let tree = try TemporaryTree(), identity = try VolumeIdentity.discover(root: tree.root)
        let watcher = FSEventsWatcher(), called = DispatchSemaphore(value: 0)
        defer { watcher.stop() }
        try watcher.start(root: tree.root, since: identity.currentEventID(), latencyMilliseconds: 1,
                          identity: identity) { [weak watcher] _ in
            watcher?.stop()
            called.signal()
        }
        XCTAssertEqual(called.wait(timeout: .now() + 5), .success)
        watcher.stop()
    }
    func testWatcherImmediateTeardownDrainsCallbacksAndReleasesContext() throws {
        try requireFSEvents()
        let tree = try TemporaryTree()
        let identity = try VolumeIdentity.discover(root: tree.root)
        for i in 0..<100 {
            let watcher = FSEventsWatcher()
            try watcher.start(root: tree.root, since: identity.currentEventID(),
                              latencyMilliseconds: 1, identity: identity) { _ in }
            try tree.file("teardown-\(i)")
            watcher.stop()
            watcher.stop()
        }
    }
    func testInitialCreateDeleteAndBothRenameForms() throws {
        try requireFSEvents()
        let tree = try TemporaryTree()
        try tree.file("seed")
        try tree.directory("a")
        try tree.directory("b")
        let coordinator = try UpdateCoordinator(root: tree.root, maintenanceScheduler: .init())
        defer { coordinator.stop() }
        try coordinator.start()
        XCTAssertTrue(coordinator.waitUntilLive())
        XCTAssertNotNil(coordinator.index.entry(at: tree.path("seed")))
        try tree.file("a/created")
        waitFor("create visible") { coordinator.index.search("created").hits.contains { $0.path == tree.path("a/created") } }
        try FileManager.default.moveItem(atPath: tree.path("a/created"), toPath: tree.path("a/renamed"))
        waitFor("same-directory rename") {
            coordinator.index.entry(at: tree.path("a/created")) == nil && coordinator.index.entry(at: tree.path("a/renamed")) != nil
        }
        try FileManager.default.moveItem(atPath: tree.path("a/renamed"), toPath: tree.path("b/moved"))
        waitFor("cross-directory rename") {
            coordinator.index.entry(at: tree.path("a/renamed")) == nil && coordinator.index.entry(at: tree.path("b/moved")) != nil
        }
        try FileManager.default.removeItem(atPath: tree.path("b/moved"))
        waitFor("delete disappears") { coordinator.index.entry(at: tree.path("b/moved")) == nil }
        XCTAssertTrue(coordinator.flushEvents())
        XCTAssertTrue(try coordinator.verify().isConsistent)
    }

    func testNewNonemptyDirectoryAndSubtreeDelete() throws {
        try requireFSEvents()
        let tree = try TemporaryTree()
        let outside = try TemporaryTree()
        try outside.directory("incoming/deep")
        try outside.file("incoming/deep/child")
        let coordinator = try UpdateCoordinator(root: tree.root, maintenanceScheduler: .init())
        defer { coordinator.stop() }
        try coordinator.start()
        XCTAssertTrue(coordinator.waitUntilLive())
        try FileManager.default.moveItem(atPath: outside.path("incoming"), toPath: tree.path("incoming"))
        waitFor("populated directory scans subtree") { coordinator.index.entry(at: tree.path("incoming/deep/child")) != nil }
        try FileManager.default.removeItem(atPath: tree.path("incoming"))
        waitFor("no ghost descendants") { coordinator.index.snapshotPaths() == [tree.root] }
    }

    func testReplayClosesScanToWatcherGap() throws {
        try requireFSEvents()
        let tree = try TemporaryTree()
        try tree.file("seed")
        let root = tree.root
        let coordinator = try UpdateCoordinator(root: root, maintenanceScheduler: .init())
        defer { coordinator.stop() }
        // This path is created after the scan result is installed, before starting
        // the watcher. It can only be found by replaying from the pre-scan E0.
        try coordinator.start { message in
            if message.contains("Scan complete") {
                let ok = FileManager.default.createFile(atPath: root + "/gap-file", contents: Data())
                precondition(ok)
            }
        }
        XCTAssertTrue(coordinator.waitUntilLive())
        waitFor("replay catches gap file") { coordinator.index.entry(at: tree.path("gap-file")) != nil }
        XCTAssertTrue(try coordinator.verify().isConsistent)
    }

    func testContentWriteDoesNotMutateOrReconcileNamespace() throws {
        try requireFSEvents()
        let tree = try TemporaryTree()
        try tree.file("content")
        let coordinator = try UpdateCoordinator(root: tree.root, maintenanceScheduler: .init())
        defer { coordinator.stop() }
        try coordinator.start()
        XCTAssertTrue(coordinator.waitUntilLive())
        XCTAssertTrue(coordinator.flushEvents())
        coordinator.measureContentEvents(at: tree.path("content"))
        let before = coordinator.index.stats(), metrics = coordinator.metrics.snapshot()
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: tree.path("content")))
        for _ in 0..<1000 { try handle.seek(toOffset: 0); try handle.write(contentsOf: Data([42])) }
        try handle.close()
        // Device-relative streams can publish the kernel journal after a flush
        // of already-queued events. Observe actual processing, not elapsed time.
        waitFor("content event processed") {
            coordinator.metrics.snapshot()["ignored_content_events", default: 0] >
                metrics["ignored_content_events", default: 0]
        }
        XCTAssertTrue(coordinator.flushEvents())
        XCTAssertEqual(coordinator.index.stats().liveEntries, before.liveEntries)
        XCTAssertEqual(coordinator.index.stats().generation, before.generation)
        XCTAssertEqual(coordinator.metrics.snapshot()["directory_reconciles", default: 0], metrics["directory_reconciles", default: 0])
        XCTAssertGreaterThan(coordinator.metrics.snapshot()["ignored_content_events", default: 0], metrics["ignored_content_events", default: 0])
        XCTAssertGreaterThan(coordinator.metrics.snapshot()["content_probe_events", default: 0], metrics["content_probe_events", default: 0])
    }

    func testInjectedInvalidationRecoversWithoutBlockingQueries() throws {
        try requireFSEvents()
        let tree = try TemporaryTree()
        try tree.file("seed")
        let coordinator = try UpdateCoordinator(root: tree.root, configuration: .init(fullRebuildMinInterval: 0), maintenanceScheduler: .init())
        defer { coordinator.stop() }
        try coordinator.start()
        XCTAssertTrue(coordinator.waitUntilLive())
        coordinator.index.apply([.upsert(.init(path: tree.path("ghost"), kind: .file))])
        coordinator.enqueue([.init(path: tree.root, flags: UInt32(kFSEventStreamEventFlagKernelDropped))])
        XCTAssertNotNil(coordinator.index.search("seed").hits.first)
        waitFor("rebuild restores state", timeout: 5) {
            coordinator.metrics.snapshot()["full_rebuilds", default: 0] > 0 && coordinator.index.entry(at: tree.path("ghost")) == nil
        }
        XCTAssertTrue(coordinator.waitUntilLive())
        XCTAssertTrue(try coordinator.verify().isConsistent)
    }

    func testFailedRebuildSuspendsRetriesAndManualRebuildRecovers() throws {
        try requireFSEvents()
        let tree = try TemporaryTree()
        try tree.file("old-seed")
        let coordinator = try UpdateCoordinator(root: tree.root, configuration: .init(
            fullRebuildMinInterval: 0, maxConsecutiveRebuildFailures: 1), maintenanceScheduler: .init())
        defer { coordinator.stop() }
        try coordinator.start()
        XCTAssertTrue(coordinator.waitUntilLive())
        try FileManager.default.removeItem(atPath: tree.root)
        coordinator.enqueue([.init(path: tree.root, flags: UInt32(kFSEventStreamEventFlagKernelDropped))])
        waitFor("failed root rebuild suspends automatic retry", timeout: 5) {
            coordinator.metrics.snapshot()["automatic_rebuild_suspended"] == 1
        }
        XCTAssertEqual(coordinator.currentState, .dirty)
        XCTAssertNotNil(coordinator.index.search("old-seed").hits.first)
        try FileManager.default.createDirectory(atPath: tree.root, withIntermediateDirectories: false)
        try tree.file("new-seed")
        coordinator.rebuild()
        waitFor("manual rebuild restores root", timeout: 5) {
            coordinator.index.entry(at: tree.path("new-seed")) != nil && coordinator.index.entry(at: tree.path("old-seed")) == nil
        }
        XCTAssertTrue(coordinator.waitUntilLive())
        XCTAssertTrue(try coordinator.verify().isConsistent)
    }

    func testHistoryDoneDuringRecoveryIsNotMistakenForLiveOrFailure() throws {
        try requireFSEvents()
        let tree = try TemporaryTree()
        try tree.file("seed")
        let coordinator = try UpdateCoordinator(root: tree.root, configuration: .init(
            fullRebuildMinInterval: 0, rebuildDebounceMilliseconds: 250), maintenanceScheduler: .init())
        defer { coordinator.stop() }
        try coordinator.start()
        XCTAssertTrue(coordinator.waitUntilLive())
        coordinator.index.apply([.upsert(.init(path: tree.path("ghost"), kind: .file))])
        coordinator.enqueue([
            .init(path: tree.root, flags: UInt32(kFSEventStreamEventFlagUserDropped)),
            .init(path: tree.root, flags: UInt32(kFSEventStreamEventFlagHistoryDone))
        ])
        waitFor("history complete while waiting for recovery") {
            let status = coordinator.startupStatus()
            return status.historyDone && status.state == .dirty && status.recoveryReason == "stream_invalidated"
        }
        XCTAssertFalse(coordinator.waitUntilLive(timeout: 0.01))
        XCTAssertFalse(coordinator.startupStatus().automaticRebuildSuspended)
        // A bounded caller may time out while work remains healthy. Another
        // wait must observe the actual successful recovery rather than failure.
        XCTAssertTrue(coordinator.waitUntilLive(timeout: 5))
        let status = coordinator.startupStatus()
        XCTAssertTrue(status.historyDone)
        XCTAssertGreaterThanOrEqual(status.rebuilds, 1)
        XCTAssertNil(status.lastError)
        XCTAssertNil(status.recoveryReason)
        XCTAssertNil(coordinator.index.entry(at: tree.path("ghost")))
        XCTAssertTrue(try coordinator.verify().isConsistent)
    }
}
