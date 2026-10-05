import APFSFindCore
import Darwin
import Dispatch
import Foundation

private enum BenchmarkError: Error, CustomStringConvertible {
    case unsafeTemporaryPath(String)
    case fileOperation(String, Int32)
    case seedNotIndexed

    var description: String {
        switch self {
        case .unsafeTemporaryPath(let path): return "Refusing benchmark cleanup outside its owned temporary directory: \(path)"
        case .fileOperation(let operation, let code): return "\(operation): \(String(cString: strerror(code)))"
        case .seedNotIndexed: return "Benchmark seed files were not indexed after initial scan and replay."
        }
    }
}

/// Cleanup requires an exact, process-created child of the system temporary directory.
private struct OwnedTemporaryDirectory {
    let parent: URL
    let url: URL
    let name: String

    init() throws {
        parent = URL(fileURLWithPath: try PathCanonicalizer.canonicalRoot(FileManager.default.temporaryDirectory.path),
                     isDirectory: true)
        name = "apfsfind-bench-" + UUID().uuidString
        url = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    func remove() throws {
        // Foundation may normalize /private/var back to /var. Preserve the
        // exact realpath-based parent chosen when this directory was created.
        let candidate = url
        guard candidate.lastPathComponent == name,
              name.hasPrefix("apfsfind-bench-"),
              candidate.deletingLastPathComponent().path == parent.path,
              candidate.pathComponents.count == parent.pathComponents.count + 1 else {
            throw BenchmarkError.unsafeTemporaryPath(url.path)
        }
        var metadata = stat()
        guard lstat(candidate.path, &metadata) == 0 else {
            if errno == ENOENT { return }
            throw BenchmarkError.fileOperation("Check benchmark directory before cleanup", errno)
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw BenchmarkError.unsafeTemporaryPath(url.path)
        }
        guard try PathCanonicalizer.canonicalRoot(candidate.path) == candidate.path else {
            throw BenchmarkError.unsafeTemporaryPath(url.path)
        }
        try FileManager.default.removeItem(at: candidate)
    }
}

private struct LatencySamples {
    let name: String
    var values: [Double] = []
    var timeouts = 0

    func percentile(_ fraction: Double) -> Double? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        let rank = max(0, min(sorted.count - 1, Int(ceil(fraction * Double(sorted.count))) - 1))
        return sorted[rank]
    }

    var dictionary: [String: Any] {
        ["samples": values.count, "timeouts": timeouts,
         "min_ms": values.min().map { $0 as Any } ?? NSNull(),
         "median_ms": percentile(0.5).map { $0 as Any } ?? NSNull(),
         "p90_ms": percentile(0.9).map { $0 as Any } ?? NSNull(),
         "p95_ms": percentile(0.95).map { $0 as Any } ?? NSNull(),
         "p99_ms": percentile(0.99).map { $0 as Any } ?? NSNull(),
         "max_ms": values.max().map { $0 as Any } ?? NSNull()]
    }

    var passes: Bool { values.count == 100 && timeouts == 0 && (percentile(0.95) ?? .infinity) < 500 }

    func printSummary() {
        guard let minimum = values.min(), let median = percentile(0.5), let p90 = percentile(0.9),
              let p95 = percentile(0.95), let p99 = percentile(0.99), let maximum = values.max() else {
            print("\(name): no completed samples, \(timeouts) timeouts")
            return
        }
        print(String(format: "%@: samples=%d timeouts=%d min=%.2f median=%.2f p90=%.2f p95=%.2f p99=%.2f max=%.2f ms",
                     name, values.count, timeouts, minimum, median, p90, p95, p99, maximum))
    }
}

struct BenchmarkRunner {
    let files: Int
    let latencyMilliseconds: Double
    private let visibilityTimeout = 2.0

    func run() throws -> Int32 {
        let temporary = try OwnedTemporaryDirectory()
        var cleanupAttempted = false
        defer {
            if !cleanupAttempted {
                do { try temporary.remove() }
                catch { TerminalOutput.error("Benchmark temporary directory was retained: \(error)") }
            }
        }
        let root = temporary.url.path
        let directoryA = temporary.url.appendingPathComponent("a", isDirectory: true)
        let directoryB = temporary.url.appendingPathComponent("b", isDirectory: true)
        let stormDirectory = temporary.url.appendingPathComponent("storm", isDirectory: true)
        for directory in [directoryA, directoryB, stormDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        let content = temporary.url.appendingPathComponent("content-write.bin")
        let sameLeft = directoryA.appendingPathComponent("rename-same-left")
        let sameRight = directoryA.appendingPathComponent("rename-same-right")
        let crossA = directoryA.appendingPathComponent("rename-cross")
        let crossB = directoryB.appendingPathComponent("rename-cross")
        for file in [content, sameLeft, crossA] { try createEmptyFile(file.path) }

        let coordinator = try UpdateCoordinator(root: root, configuration: .init(latencyMilliseconds: latencyMilliseconds))
        let shutdown = ShutdownSignal { coordinator.stop() }
        defer { coordinator.stop(); withExtendedLifetime(shutdown) {} }
        let initialStart = now()
        try coordinator.start { TerminalOutput.info($0) }
        guard coordinator.waitUntilLive(timeout: 10) else {
            if shutdown.isCancelled { throw CLIError.interrupted }
            throw CLIError.replayTimedOut
        }
        guard queryContains(content.path, coordinator), queryContains(sameLeft.path, coordinator),
              queryContains(crossA.path, coordinator) else { throw BenchmarkError.seedNotIndexed }
        let initialMilliseconds = milliseconds(since: initialStart)
        print("Benchmark: \(files) storm files, FSEvents latency \(latencyMilliseconds) ms, temporary root \(root)")
        print(String(format: "Initial scan + replay: %.2f ms", initialMilliseconds))

        var creates = LatencySamples(name: "create")
        var deletes = LatencySamples(name: "delete")
        var sameRenames = LatencySamples(name: "same-directory rename")
        var crossRenames = LatencySamples(name: "cross-directory rename")
        var samplePaths: [String] = []
        for number in 0..<100 {
            try checkCancellation(shutdown)
            let path = temporary.url.appendingPathComponent(String(format: "sample-create-%03d", number)).path
            try createEmptyFile(path)
            let completed = now()
            record(&creates, started: completed, shutdown: shutdown) { queryContains(path, coordinator) }
            samplePaths.append(path)
        }
        for path in samplePaths {
            try checkCancellation(shutdown)
            try FileManager.default.removeItem(atPath: path)
            let completed = now()
            record(&deletes, started: completed, shutdown: shutdown) { !queryContains(path, coordinator) }
        }
        for number in 0..<100 {
            try checkCancellation(shutdown)
            let old = number.isMultiple(of: 2) ? sameLeft.path : sameRight.path
            let new = number.isMultiple(of: 2) ? sameRight.path : sameLeft.path
            try FileManager.default.moveItem(atPath: old, toPath: new)
            let completed = now()
            record(&sameRenames, started: completed, shutdown: shutdown) {
                !queryContains(old, coordinator) && queryContains(new, coordinator)
            }
        }
        for number in 0..<100 {
            try checkCancellation(shutdown)
            let old = number.isMultiple(of: 2) ? crossA.path : crossB.path
            let new = number.isMultiple(of: 2) ? crossB.path : crossA.path
            try FileManager.default.moveItem(atPath: old, toPath: new)
            let completed = now()
            record(&crossRenames, started: completed, shutdown: shutdown) {
                !queryContains(old, coordinator) && queryContains(new, coordinator)
            }
        }
        for samples in [creates, deletes, sameRenames, crossRenames] { samples.printSummary() }
        try checkCancellation(shutdown)

        // Flush only between workloads, never while measuring single-operation visibility.
        let preContentDrained = coordinator.flushEvents(timeout: visibilityTimeout)
        let contentBefore = coordinator.index.stats()
        let metricsBeforeWrites = coordinator.metrics.snapshot()
        let cpuBeforeWrites = Metrics.processUsage()
        let writeStart = now()
        try writeRepeatedly(content.path, count: 10_000, shutdown: shutdown)
        let writeLoopMilliseconds = milliseconds(since: writeStart)
        // FlushSync does not force the OS to publish its journal immediately.
        // Observe a processed content event before claiming that writes were ignored.
        let contentEventsObserved = waitUntil(timeout: visibilityTimeout, shutdown: shutdown) {
            coordinator.metrics.snapshot()["ignored_content_events", default: 0] >
                metricsBeforeWrites["ignored_content_events", default: 0]
        }
        let contentDrained = coordinator.flushEvents(timeout: visibilityTimeout)
        let writeWallMilliseconds = milliseconds(since: writeStart)
        let cpuAfterWrites = Metrics.processUsage()
        let metricsAfterWrites = coordinator.metrics.snapshot()
        let contentAfter = coordinator.index.stats()
        let contentUnchanged = contentBefore.totalEntries == contentAfter.totalEntries &&
            contentBefore.liveEntries == contentAfter.liveEntries && contentBefore.generation == contentAfter.generation
        let contentMetrics = metricDeltas(before: metricsBeforeWrites, after: metricsAfterWrites)
        let contentNamespaceWorkIgnored = ["direct_patches", "directory_reconciles", "subtree_reconciles", "full_rebuilds"]
            .allSatisfy { contentMetrics[$0, default: 0] == 0 }
        let contentCPU = cpuDelta(cpuBeforeWrites, cpuAfterWrites)
        let contentReport: [String: Any] = [
            "writes": 10_000, "wall_ms": writeWallMilliseconds, "write_loop_ms": writeLoopMilliseconds,
            "entries_before": contentBefore.totalEntries, "entries_after": contentAfter.totalEntries,
            "live_entries_before": contentBefore.liveEntries, "live_entries_after": contentAfter.liveEntries,
            "namespace_unchanged": contentUnchanged,
            "generation_before": contentBefore.generation, "generation_after": contentAfter.generation,
            "no_namespace_work": contentNamespaceWorkIgnored,
            "content_events_observed": contentEventsObserved,
            "events_drained": preContentDrained && contentDrained,
            "metric_deltas": contentMetrics, "cpu": contentCPU
        ]
        print(String(format: "content-write: 10000 writes, loop=%.2f ms total=%.2f ms, entries %d → %d, events=%d ignored=%d reconciles=%d, user CPU=%.4f s system CPU=%.4f s",
                     writeLoopMilliseconds, writeWallMilliseconds, contentBefore.totalEntries, contentAfter.totalEntries,
                     contentMetrics["fsevents_received", default: 0], contentMetrics["ignored_content_events", default: 0],
                     contentMetrics["directory_reconciles", default: 0] + contentMetrics["subtree_reconciles", default: 0],
                     contentCPU["user_seconds", default: 0], contentCPU["system_seconds", default: 0]))
        print("content-write namespace: generation \(contentBefore.generation) → \(contentAfter.generation), unchanged=\(contentUnchanged), no namespace work=\(contentNamespaceWorkIgnored), content event observed=\(contentEventsObserved)")
        try checkCancellation(shutdown)

        let baselinePaths = Set(coordinator.index.snapshotPaths())
        let stormPaths = (0..<files).map { stormDirectory.appendingPathComponent(String(format: "storm-%08d", $0)).path }
        let stormTimeout = max(15.0, min(90.0, Double(files) / 250.0 + 15.0))
        let createStormMetricsBefore = coordinator.metrics.snapshot()
        let createStormCPUBefore = Metrics.processUsage()
        let createStormStart = now()
        for path in stormPaths {
            try checkCancellation(shutdown)
            try createEmptyFile(path)
        }
        let createdPaths = baselinePaths.union(stormPaths)
        let createConverged = waitUntil(timeout: stormTimeout, shutdown: shutdown) {
            Set(coordinator.index.snapshotPaths()) == createdPaths
        }
        let createDrained = coordinator.flushEvents(timeout: visibilityTimeout)
        let createStormWall = milliseconds(since: createStormStart)
        let createCPU = cpuDelta(createStormCPUBefore, Metrics.processUsage())
        let createMetrics = metricDeltas(before: createStormMetricsBefore, after: coordinator.metrics.snapshot())
        let createVerification = try coordinator.verify()
        let createReport = stormReport(wallMilliseconds: createStormWall, cpu: createCPU, metrics: createMetrics,
                                       converged: createConverged, drained: createDrained, verification: createVerification)
        printStorm("create storm", report: createReport)
        try checkCancellation(shutdown)

        let deleteStormMetricsBefore = coordinator.metrics.snapshot()
        let deleteStormCPUBefore = Metrics.processUsage()
        let deleteStormStart = now()
        for path in stormPaths {
            try checkCancellation(shutdown)
            try FileManager.default.removeItem(atPath: path)
        }
        let deleteConverged = waitUntil(timeout: stormTimeout, shutdown: shutdown) {
            Set(coordinator.index.snapshotPaths()) == baselinePaths
        }
        let deleteDrained = coordinator.flushEvents(timeout: visibilityTimeout)
        let deleteStormWall = milliseconds(since: deleteStormStart)
        let deleteCPU = cpuDelta(deleteStormCPUBefore, Metrics.processUsage())
        let deleteMetrics = metricDeltas(before: deleteStormMetricsBefore, after: coordinator.metrics.snapshot())
        let deleteVerification = try coordinator.verify()
        let deleteReport = stormReport(wallMilliseconds: deleteStormWall, cpu: deleteCPU, metrics: deleteMetrics,
                                       converged: deleteConverged, drained: deleteDrained, verification: deleteVerification)
        printStorm("delete storm", report: deleteReport)
        try checkCancellation(shutdown)

        let finalStats = coordinator.stats().dictionary
        coordinator.stop()
        cleanupAttempted = true
        var cleanupCompleted = false
        do { try temporary.remove(); cleanupCompleted = true }
        catch { TerminalOutput.error("Benchmark temporary directory was retained: \(error)") }
        let accepted = cleanupCompleted && [creates, deletes, sameRenames, crossRenames].allSatisfy(\.passes) &&
            contentUnchanged && contentNamespaceWorkIgnored && contentEventsObserved && preContentDrained && contentDrained &&
            createConverged && createDrained && createVerification.isConsistent &&
            deleteConverged && deleteDrained && deleteVerification.isConsistent
        print("Provisional acceptance: \(accepted ? "PASS" : "FAIL") (100 samples per latency workload; p95 < 500 ms; 2 s hard timeout; both storms verified)")
        let report: [String: Any] = [
            "version": "0.1.0", "files": files, "latency_ms": latencyMilliseconds,
            "visibility_timeout_ms": visibilityTimeout * 1000,
            "storm_timeout_ms": stormTimeout * 1000, "initial_scan_and_replay_ms": initialMilliseconds,
            "create": creates.dictionary, "delete": deletes.dictionary,
            "rename_same_directory": sameRenames.dictionary, "rename_cross_directory": crossRenames.dictionary,
            "content_write": contentReport, "create_storm": createReport, "delete_storm": deleteReport,
            "final_stats": finalStats, "cleanup_completed": cleanupCompleted, "provisional_acceptance": accepted
        ]
        let encoded = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: encoded, as: UTF8.self))
        return accepted ? 0 : 1
    }

    private func record(_ samples: inout LatencySamples, started: UInt64,
                        shutdown: ShutdownSignal, predicate: () -> Bool) {
        if waitUntil(timeout: visibilityTimeout, started: started, shutdown: shutdown, predicate: predicate) {
            samples.values.append(milliseconds(since: started))
        } else { samples.timeouts += 1 }
    }

    private func waitUntil(timeout: Double, started: UInt64? = nil,
                           shutdown: ShutdownSignal, predicate: () -> Bool) -> Bool {
        let beginning = started ?? now()
        while !shutdown.isCancelled {
            let observation = now()
            if Double(observation - beginning) / 1_000_000_000 >= timeout { return false }
            if predicate() { return Double(now() - beginning) / 1_000_000_000 < timeout }
            usleep(1_000)
        }
        return false
    }

    private func queryContains(_ path: String, _ coordinator: UpdateCoordinator) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return coordinator.index.search(name, limit: 50).hits.contains { $0.path == path }
    }

    private func createEmptyFile(_ path: String) throws {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw BenchmarkError.fileOperation("Create \(path)", errno) }
        guard close(descriptor) == 0 else { throw BenchmarkError.fileOperation("Close \(path)", errno) }
    }

    private func writeRepeatedly(_ path: String, count: Int, shutdown: ShutdownSignal) throws {
        let descriptor = open(path, O_WRONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw BenchmarkError.fileOperation("Open content-write fixture", errno) }
        defer { if close(descriptor) != 0 { TerminalOutput.error("Close content-write fixture failed: \(String(cString: strerror(errno)))") } }
        var byte: UInt8 = 97
        for number in 0..<count {
            if number.isMultiple(of: 256) { try checkCancellation(shutdown) }
            var written: Int
            repeat { written = pwrite(descriptor, &byte, 1, 0) } while written < 0 && errno == EINTR
            guard written == 1 else { throw BenchmarkError.fileOperation("Write content-write fixture", written < 0 ? errno : EIO) }
            byte = byte == 97 ? 98 : 97
        }
    }

    private func checkCancellation(_ shutdown: ShutdownSignal) throws {
        if shutdown.isCancelled { throw CLIError.interrupted }
    }

    private func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private func milliseconds(since beginning: UInt64) -> Double { Double(now() - beginning) / 1_000_000 }

    private func metricDeltas(before: [String: Int], after: [String: Int]) -> [String: Int] {
        var deltas: [String: Int] = [:]
        // These two values are gauges, not counters; final_stats reports them.
        for key in Set(before.keys).union(after.keys) where key != "last_batch_size" && key != "event_queue_high_watermark" {
            deltas[key] = after[key, default: 0] - before[key, default: 0]
        }
        return deltas
    }

    private func cpuDelta(_ before: ProcessUsage, _ after: ProcessUsage) -> [String: Double] {
        ["user_seconds": max(0, after.userCPUSeconds - before.userCPUSeconds),
         "system_seconds": max(0, after.systemCPUSeconds - before.systemCPUSeconds)]
    }

    private func stormReport(wallMilliseconds: Double, cpu: [String: Double], metrics: [String: Int],
                             converged: Bool, drained: Bool, verification: VerificationResult) -> [String: Any] {
        ["files": files, "wall_ms": wallMilliseconds, "cpu": cpu, "metric_deltas": metrics,
         "converged": converged, "events_drained": drained,
         "verify_missing": verification.missing.count, "verify_extra": verification.extra.count,
         "verify_consistent": verification.isConsistent]
    }

    private func printStorm(_ name: String, report: [String: Any]) {
        let metrics = report["metric_deltas"] as? [String: Int] ?? [:]
        let cpu = report["cpu"] as? [String: Double] ?? [:]
        print(String(format: "%@: %.2f ms, user CPU=%.4f s system CPU=%.4f s, patches=%d dirty dirs=%d directory reconciles=%d subtree reconciles=%d; converged=%@ verify missing=%d extra=%d",
                     name, report["wall_ms"] as? Double ?? 0, cpu["user_seconds", default: 0], cpu["system_seconds", default: 0],
                     metrics["direct_patches", default: 0], metrics["dirty_directories", default: 0],
                     metrics["directory_reconciles", default: 0], metrics["subtree_reconciles", default: 0],
                     String(describing: report["converged"] ?? false), report["verify_missing"] as? Int ?? -1,
                     report["verify_extra"] as? Int ?? -1))
    }
}
