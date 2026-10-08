import CoreServices
import Darwin
import Foundation
import XCTest
@testable import APFSFindCore

private final class InjectedParents: DirectoryReading, @unchecked Sendable {
    let root: String
    private let lock = NSLock()
    private var reads = 0
    private var yielded = false
    init(root: String) { self.root = root }
    func readDirectory(_ path: String, rootDeviceID: UInt64, cancellation: CancellationToken) throws -> [NamespaceEntry] {
        let yield = lock.withLock {
            reads += 1
            if reads == 100 && !yielded { yielded = true; return true }
            return false
        }
        if yield { throw MaintenanceYield(reason: "injected after 99 parents") }
        return [.init(path: path + "/new", kind: .file, deviceID: rootDeviceID)]
    }
}

final class DeferredReconcileTests: XCTestCase {
    func testRepeatedAncestorInputDoesNotPreemptUnfinishedFrontier() throws {
        var queue = DeferredReconcileQueue()
        XCTAssertTrue(queue.insert(.init(root: "/owned", reason: .event, minimumCursor: 10,
            generation: 1, subtree: true, frontier: [.init(path: "/owned/unfinished") ])))
        for _ in 0..<100 {
            XCTAssertTrue(queue.insert(.init(root: "/owned", reason: .event, minimumCursor: 20, generation: 2, subtree: true)))
        }
        let work = try XCTUnwrap(queue.popReady(now: 0))
        XCTAssertEqual(work.frontier.last?.path, "/owned/unfinished")
        XCTAssertEqual(work.frontier.count, 2)
        XCTAssertEqual(work.minimumCursor, 10)
    }
    func testQueueMergesAncestorsRetainsFrontierAndOldestCursor() {
        var queue = DeferredReconcileQueue(capacity: 2)
        XCTAssertTrue(queue.insert(.init(root: "/test/a/b", reason: .event, minimumCursor: 7, generation: 1)))
        XCTAssertTrue(queue.insert(.init(root: "/test/a", reason: .event, minimumCursor: 9, generation: 2, subtree: true)))
        XCTAssertEqual(queue.count, 1); XCTAssertEqual(queue.minimumCursor, 7)
        let work = queue.popReady(now: 1)!
        XCTAssertEqual(Set(work.frontier.map(\.path)), ["/test/a", "/test/a/b"])
        XCTAssertTrue(work.subtree); XCTAssertEqual(work.generation, 2)
        XCTAssertTrue(queue.insert(.init(root: "/test/x", reason: .event, minimumCursor: 1, generation: 1)))
        XCTAssertTrue(queue.insert(.init(root: "/test/y", reason: .event, minimumCursor: 2, generation: 1)))
        XCTAssertFalse(queue.insert(.init(root: "/test/z", reason: .event, minimumCursor: 3, generation: 1)))
        XCTAssertEqual(queue.count, 2)
        queue.removeAll(); XCTAssertEqual(queue.frontierCount, 0)
    }

    func testThousandDirtyParentsYieldAndConvergeDuringBroadQueriesWithoutScan() throws {
        let tree = try TemporaryTree(), ram = FileIndex(root: tree.root)
        var entries: [NamespaceEntry] = []
        for parent in 0..<1000 {
            let path = tree.path("parent-\(parent)")
            entries.append(.init(path: path, kind: .directory))
            entries += (0..<99).map { .init(path: path + "/old-\($0)", kind: .file) }
        }
        ram.apply(entries.map { .upsert($0) })
        let cache = try TemporaryTree(cache: true), identity = try VolumeIdentity.discover(root: tree.root)
        let store = try SnapshotStore(directory: cache.root, identity: identity)
        _ = try SnapshotV2Writer.write(source: .ram(ram, ram.stats().generation), identity: identity,
            generation: ram.stats().generation, cursor: 10, store: store)
        let index = HybridIndex(base: try XCTUnwrap(store.reader(expectedIdentity: identity).mappedBase))
        XCTAssertEqual(index.stats().liveEntries, 100_001)
        let root = tree.root, reader = InjectedParents(root: root)
        let core = try UpdateCoordinator(root: root, index: index, fenceProvider: { _ in 10 },
            maintenanceScheduler: .init(), reconcileReader: reader, replayStarter: { _, deliver in
                deliver([.init(path: root, flags: UInt32(kFSEventStreamEventFlagHistoryDone), id: 10)])
            })
        defer { core.stop() }
        try core.start(restored: index, cursor: 10); XCTAssertTrue(core.waitUntilLive())
        let querying = CancellationToken(), queryFinished = DispatchSemaphore(value: 0), queryMetrics = Metrics()
        DispatchQueue.global().async {
            while !querying.isCancelled {
                let result = core.search(.init(query: "old", limit: 50))
                if !result.cancelled { queryMetrics.record("queries") }
            }
            queryFinished.signal()
        }
        defer { querying.cancel(); XCTAssertEqual(queryFinished.wait(timeout: .now()+5), .success) }
        let flags = UInt32(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsFile)
        core.enqueue((0..<1000).map { .init(path: tree.path("parent-\($0)/new"), flags: flags, id: UInt64($0+11)) })
        waitFor("deferred work retains safe cursor", timeout: 10) { core.metrics.snapshot()["deferred_reconcile_roots", default: 0] > 0 }
        XCTAssertEqual(core.stats().dictionary["last_processed_event_id"] as? UInt64, 10)
        waitFor("all parents converge under queries", timeout: 30) {
            core.metrics.snapshot()["deferred_reconcile_roots", default: 0] == 0 && core.index.stats().liveEntries == 2001
        }
        for parent in 0..<1000 { XCTAssertNotNil(index.entry(at: tree.path("parent-\(parent)/new"))) }
        XCTAssertEqual(core.metrics.snapshot()["reconcile_resource_yields"], 1)
        XCTAssertEqual(core.metrics.snapshot()["full_scans", default: 0], 0)
        XCTAssertEqual(core.metrics.snapshot()["rebuild_requests_resource_yield", default: 0], 0)
        XCTAssertEqual(core.metrics.snapshot()["full_rebuilds", default: 0], 0)
        XCTAssertEqual(core.metrics.snapshot()["deferred_reconcile_timer"], 0)
        XCTAssertEqual(core.stats().dictionary["last_processed_event_id"] as? UInt64, 1010)
        XCTAssertGreaterThan(queryMetrics.snapshot()["queries", default: 0], 0)
    }
}

private final class AlwaysYieldReader: DirectoryReading {
    func readDirectory(_ path: String, rootDeviceID: UInt64, cancellation: CancellationToken) throws -> [NamespaceEntry] {
        throw MaintenanceYield(reason: "held local work for exit")
    }
}

final class ReconciliationConvergenceIntegrationTests: XCTestCase {
    func testTenPauseResumeRoundsConvergeNamespaceSizeAndMtimeDuringQueries() throws {
        try requireFSEvents()
        let tree = try TemporaryTree(), cache = try TemporaryTree(cache: true)
        try tree.file("convergence-mutable"); try tree.file("convergence-moving"); try tree.file("convergence-remove")
        let c = try PersistentIndexCoordinator(root: tree.root, cacheDirectory: cache.root, maintenanceScheduler: .init())
        defer { c.stop(policy: .fast) }
        try c.start(); XCTAssertTrue(c.waitUntilLive()); XCTAssertTrue(c.waitForMetadata()); c.flushMetadata()
        let initialScans = c.metrics.snapshot()["full_scans", default: 0]
        let token = CancellationToken(), finished = DispatchSemaphore(value: 0), metrics = Metrics()
        DispatchQueue.global().async {
            while !token.isCancelled {
                let result = c.search(.init(query: "convergence", limit: 50, sort: .init(key: .size)))
                if !result.cancelled { metrics.record("queries") }
            }
            finished.signal()
        }
        defer { token.cancel(); XCTAssertEqual(finished.wait(timeout: .now()+5), .success) }
        var moving = "convergence-moving", removing = "convergence-remove"
        for round in 1...10 {
            c.pause()
            let created = "convergence-created-\(round)", renamed = "convergence-renamed-\(round)"
            try Data(repeating: UInt8(round), count: 37+round).write(to: URL(fileURLWithPath: tree.path(created)))
            try FileManager.default.removeItem(atPath: tree.path(removing))
            try FileManager.default.moveItem(atPath: tree.path(moving), toPath: tree.path(renamed))
            try Data(repeating: 1, count: 100+round).write(to: URL(fileURLWithPath: tree.path("convergence-mutable")))
            let expected = try BulkScanner(root: tree.root).scan()
            let paths = Set(expected.entries.map(\.path))
            let metadata = expected.scannedEntries.filter { $0.namespace.kind == .file }
            try c.resume(); XCTAssertTrue(c.core.flushEvents())
            waitFor("round \(round) converges while queries continue", timeout: 30) {
                guard c.index.snapshotPaths() == paths else { return false }
                let values = c.metadata.capture()
                return metadata.allSatisfy { values.value(path: $0.namespace.path) == $0.metadata }
            }
            XCTAssertEqual(c.metrics.snapshot()["full_scans", default: 0], initialScans)
            XCTAssertEqual(c.metrics.snapshot()["rebuild_requests_resource_yield", default: 0], 0)
            XCTAssertEqual(c.metrics.snapshot()["full_rebuilds", default: 0], 0)
            moving = renamed; removing = created
        }
        XCTAssertGreaterThan(metrics.snapshot()["queries", default: 0], 10)
    }

    func testDeferredLocalExitPinsCursorAndRestartRepairsWithoutFullScan() throws {
        let tree = try TemporaryTree(), cache = try TemporaryTree(cache: true); try tree.file("old")
        let root = tree.root
        let c = try PersistentIndexCoordinator(root: root, cacheDirectory: cache.root, maintenanceScheduler: .init(),
            reconcileReader: AlwaysYieldReader(), replayStarter: { cursor, sink in
                sink([.init(path: root, flags: UInt32(kFSEventStreamEventFlagHistoryDone), id: cursor)])
            }, fenceProvider: { _ in 100 })
        try c.start(); XCTAssertTrue(c.waitUntilLive()); c.flushMetadata()
        let identity = try VolumeIdentity.discover(root: root), store = try SnapshotStore(directory: cache.root, identity: identity)
        let oldBase = try Data(contentsOf: URL(fileURLWithPath: store.path))
        try tree.file("new")
        c.core.enqueue([.init(path: root, flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs), id: 110)])
        XCTAssertTrue(c.core.flushEvents())
        XCTAssertGreaterThan(c.metrics.snapshot()["deferred_reconcile_roots", default: 0], 0)
        XCTAssertEqual(c.core.stats().dictionary["last_processed_event_id"] as? UInt64, 100)
        c.stop(policy: .fast)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: store.path)), oldBase)
        XCTAssertEqual(store.effectiveCursor(for: try store.reader(expectedIdentity: identity).header).cursor, 100)
        let next = try PersistentIndexCoordinator(root: root, cacheDirectory: cache.root, maintenanceScheduler: .init(),
            replayStarter: { cursor, sink in
                XCTAssertEqual(cursor, 100)
                sink([.init(path: root, flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs), id: 110),
                      .init(path: root, flags: UInt32(kFSEventStreamEventFlagHistoryDone), id: 111)])
            })
        defer { next.stop(policy: .fast) }; try next.start(); XCTAssertTrue(next.waitUntilLive()); next.flushMetadata()
        XCTAssertNotNil(next.index.entry(at: tree.path("new")))
        XCTAssertEqual(next.metrics.snapshot()["full_scans", default: 0], 0)
        XCTAssertEqual(next.metrics.snapshot()["rebuild_requests_resource_yield", default: 0], 0)
    }
}

private final class ErrorScopeReader: DirectoryReading, @unchecked Sendable {
    let code: Int32
    let metrics = Metrics()
    init(_ code: Int32) { self.code = code }
    func readDirectory(_ path: String, rootDeviceID: UInt64, cancellation: CancellationToken) throws -> [NamespaceEntry] {
        metrics.record("reads"); throw ScannerError(path: path, code: code)
    }
}

extension DeferredReconcileTests {
    func testRootMustScanIsScopedRepairNotStreamInvalidation() throws {
        let tree = try TemporaryTree(); try tree.file("present")
        let index = FileIndex(root: tree.root)
        index.apply([.upsert(.init(path: tree.path("ghost"), kind: .file))])
        let core = try UpdateCoordinator(root: tree.root, index: index, maintenanceScheduler: .init(),
            replayStarter: { [root = tree.root] cursor, deliver in
                deliver([.init(path: root, flags: UInt32(kFSEventStreamEventFlagHistoryDone), id: cursor)])
            })
        defer { core.stop() }; try core.start(restored: index, cursor: 100); XCTAssertTrue(core.waitUntilLive())
        core.enqueue([.init(path: tree.root, flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs), id: 101)])
        XCTAssertTrue(core.flushEvents()); XCTAssertTrue(core.waitUntilLive())
        XCTAssertEqual(index.snapshotPaths(), [tree.root, tree.path("present")])
        XCTAssertEqual(core.metrics.snapshot()["full_scans", default: 0], 0)
        XCTAssertEqual(core.metrics.snapshot()["full_rebuilds", default: 0], 0)
    }

    func testRepeatedAuthoritativeIOTriggersOneRecoveryAndDuplicateInvalidationsCoalesce() throws {
        let tree = try TemporaryTree(); try tree.file("present")
        let index = FileIndex(root: tree.root), reader = ErrorScopeReader(EIO), scheduler = MaintenanceScheduler()
        index.apply([.upsert(.init(path: tree.path("ghost"), kind: .file))])
        let blocker = try scheduler.acquireBlocking(volumeID: UUID(), kind: .metadataBootstrap, cancellation: .init())
        defer { blocker.release() }
        let core = try UpdateCoordinator(root: tree.root, configuration: .init(fullRebuildMinInterval: 0), index: index,
            fenceProvider: { _ in 200 }, maintenanceScheduler: scheduler, reconcileReader: reader,
            replayStarter: { [root = tree.root] cursor, deliver in
                deliver([.init(path: root, flags: UInt32(kFSEventStreamEventFlagHistoryDone), id: cursor)])
            })
        defer { core.stop() }; try core.start(restored: index, cursor: 100); XCTAssertTrue(core.waitUntilLive())
        core.enqueue([.init(path: tree.root, flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs), id: 101)])
        waitFor("three failed local attempts start one recovery", timeout: 5) { core.currentState == .rebuilding }
        XCTAssertEqual(reader.metrics.snapshot()["reads"], 3)
        XCTAssertEqual(core.metrics.snapshot()["rebuild_requests_reconcile_repeated_io"], 1)
        for _ in 0..<10 { core.rebuild() }
        core.synchronizeWriter()
        XCTAssertGreaterThan(core.metrics.snapshot()["rebuild_requests_coalesced", default: 0], 0)
        blocker.release(); XCTAssertTrue(core.waitUntilLive(timeout: 10))
        XCTAssertEqual(core.metrics.snapshot()["full_scans"], 1)
        XCTAssertEqual(core.metrics.snapshot()["full_rebuilds"], 1)
        XCTAssertEqual(core.metrics.snapshot()["rebuild_requests_resource_yield", default: 0], 0)
        XCTAssertNil(index.entry(at: tree.path("ghost")))
    }

    func testFullRecoveryYieldRetriesSameEpochWithoutNewInvalidation() throws {
        let tree = try TemporaryTree(); try tree.file("present")
        let signals = FakeResourceSignals(.init(timestamp: 0, cpuIdleEWMA: 1))
        let scheduler = MaintenanceScheduler(signals: signals), index = FileIndex(root: tree.root), metrics = Metrics()
        index.apply([.upsert(.init(path: tree.path("old"), kind: .file))])
        let core = try UpdateCoordinator(root: tree.root, configuration: .init(fullRebuildMinInterval: 0), index: index,
            maintenanceScheduler: scheduler, replayStarter: { [root = tree.root] cursor, deliver in
                deliver([.init(path: root, flags: UInt32(kFSEventStreamEventFlagHistoryDone), id: cursor)])
            })
        defer { core.stop() }
        try core.start(restored: index, cursor: 100); XCTAssertTrue(core.waitUntilLive())
        core.setMetadataHandlers(scan: { _, _ in
            if metrics.snapshot()["injected", default: 0] == 0 {
                metrics.record("injected")
                signals.update(.init(timestamp: 1, cpuIdleEWMA: 1, activeQueries: 1))
            }
        }, events: { _ in })
        core.setBaseInstaller { [weak core] fresh, _, _ in
            try core?.maintenanceCheckpoint(); index.replace(with: fresh)
        }
        core.rebuild()
        waitFor("recovery epoch defers at publication", timeout: 5) { core.metrics.snapshot()["recovery_epoch_yields", default: 0] == 1 }
        XCTAssertNotNil(index.entry(at: tree.path("old")))
        XCTAssertEqual(core.metrics.snapshot()["rebuild_requests_manual"], 1)
        XCTAssertEqual(core.metrics.snapshot()["rebuild_requests_resource_yield", default: 0], 0)
        signals.update(.init(timestamp: 2, cpuIdleEWMA: 1))
        XCTAssertTrue(core.waitUntilLive(timeout: 10))
        XCTAssertEqual(core.metrics.snapshot()["full_rebuilds"], 1)
        XCTAssertNil(index.entry(at: tree.path("old")))
        XCTAssertNotNil(index.entry(at: tree.path("present")))
    }
}
