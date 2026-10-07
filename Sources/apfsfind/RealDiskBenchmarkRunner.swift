import APFSFindCore
import Darwin
import Foundation

private enum RealDiskBenchmarkError: Error {
    case failed(String)
}

private final class RealQuerySamples: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Double] = []
    func add(_ value: Double) { lock.withLock { samples.append(value) } }
    var summary: [String: Any] {
        let values = lock.withLock { samples.sorted() }
        func p(_ f: Double) -> Double {
            values.isEmpty ? 0 : values[min(values.count - 1, max(0, Int(ceil(f * Double(values.count))) - 1))]
        }
        return ["samples": values.count, "p50_ms": p(0.5), "p90_ms": p(0.9),
                "p95_ms": p(0.95), "p99_ms": p(0.99), "max_ms": values.last ?? 0]
    }
}

/// Each phase is a new process. Fixture writes are child-process workloads, so
/// index-process I/O counters never include the benchmark's synthetic writes.
struct RealDiskBenchmarkRunner {
    let root: String
    let cacheDirectory: String?
    let idleSeconds: Double

    func run() throws -> Int32 {
        let canonical = try PathCanonicalizer.canonicalRoot(root)
        let cache: OwnedBenchmarkDirectory
        if let cacheDirectory {
            cache = try OwnedBenchmarkDirectory(newPath: cacheDirectory, parent: "/private/tmp", prefix: "apfsfind-real-cache-")
        } else {
            cache = try OwnedBenchmarkDirectory(parent: "/private/tmp", prefix: "apfsfind-real-cache-")
        }
        var mutation: OwnedBenchmarkDirectory?
        var report: [String: Any] = ["version": "0.5.0", "root": canonical,
            "cache": cache.path, "snapshot_format_version": 2,
            "resource_api": "proc_pid_rusage RUSAGE_INFO_V4; getrusage; mach_task_basic_info; TASK_VM_INFO",
            "logical_bytes_read_available": false,
            "compressed_bytes_available": ProcessResourceSample.capture().compressedBytes != nil,
            "filesystem_metadata_overhead_separately_available": false]
        do {
            let fixture = try OwnedBenchmarkDirectory(parent: canonical == "/" ? "/private/tmp" : canonical,
                                                       prefix: "apfsfind-real-bench-")
            mutation = fixture
            let inode = try fixtureInode(fixture.path)
            _ = try child(["mutate", fixture.path, String(inode), "seed"])
            report["mutation_root"] = fixture.path
            TerminalOutput.info("Real-disk benchmark: cold process, \(canonical)")
            report["cold"] = try child(["cold", canonical, cache.path, "0", fixture.path, String(inode)])
            TerminalOutput.info("Real-disk benchmark: independent warm process, idle \(idleSeconds)s, queries and compaction")
            report["warm"] = try child(["warm", canonical, cache.path, String(idleSeconds), fixture.path, String(inode)])
            try fixture.remove()
            TerminalOutput.info("Real-disk benchmark: fixture removed; independent warm replay and final verification")
            report["cleanup_recovery"] = try child(["final", canonical, cache.path, "0", fixture.path, String(inode)])
            try cache.remove()
            report["cleanup_completed"] = true
            let warm = report["warm"] as? [String: Any]
            let mutationReport = warm?["mutation"] as? [String: Any]
            let final = report["cleanup_recovery"] as? [String: Any]
            let checks = [mutationReport?["verification"], final?["verification"]]
            let valid = checks.allSatisfy {
                guard let v = $0 as? [String: Any] else { return false }
                return v["missing"] as? Int == 0 && v["extra"] as? Int == 0
            }
            report["validation_passed"] = valid
            let cold = report["cold"] as? [String: Any]
            let coldStats = cold?["live_stats"] as? [String: Any]
            let coldFile = cold?["snapshot_file"] as? [String: Any]
            let warmLive = warm?["live"] as? [String: Any]
            func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
            print(String(format: "Records: %.0f; snapshot: %.2f MB; cold/live: %.1f ms; warm/live: %.1f ms; warm RSS: %.2f MB; verify: %@.",
                         number(coldStats?["base_records"]), number(coldFile?["logical_bytes"]) / 1_000_000,
                         number(cold?["time_to_live_ms"]), number(warm?["time_to_live_ms"]),
                         number(warmLive?["rss_bytes"]) / 1_000_000, valid ? "PASS" : "FAIL"))
            print("Real-disk benchmark completed: \(canonical). Owned cache and mutation directory removed.")
            printJSON(report)
            return valid ? 0 : 1
        } catch {
            report["error"] = String(describing: error)
            var errors: [String] = []
            do { try mutation?.remove() } catch { errors.append(String(describing: error)) }
            do { try cache.remove() } catch { errors.append(String(describing: error)) }
            report["cleanup_completed"] = errors.isEmpty
            report["cleanup_errors"] = errors
            printJSON(report)
            throw error
        }
    }

    static func worker(_ arguments: [String]) throws -> Int32 {
        guard let mode = arguments.first else { throw RealDiskBenchmarkError.failed("Missing worker phase") }
        if mode == "mutate" {
            guard arguments.count == 4, let inode = UInt64(arguments[2]) else {
                throw RealDiskBenchmarkError.failed("Invalid mutation arguments")
            }
            try validateFixture(arguments[1], inode: inode)
            try mutate(arguments[3], path: arguments[1])
            printJSON(["completed": true]); return 0
        }
        guard arguments.count == 6, let idle = Double(arguments[3]), let inode = UInt64(arguments[5]),
              ["cold", "warm", "final"].contains(mode) else {
            throw RealDiskBenchmarkError.failed("Invalid real-disk worker arguments")
        }
        let before = ProcessResourceSample.capture()
        let canonical = try PathCanonicalizer.canonicalRoot(arguments[1])
        var policy = CompactionPolicy()
        // Manual compaction is measured below; synthetic activity must not race
        // an automatic threshold. Timer wakeups remain measurable.
        policy.liveLimit = Int.max; policy.byteLimit = Int.max; policy.tombstoneLimit = Int.max
        policy.tombstoneRatio = 2; policy.overlayRatio = 2; policy.safetyByteLimit = Int.max
        let coordinator = try PersistentIndexCoordinator(root: canonical, cacheDirectory: arguments[2], compactionPolicy: policy)
        defer { coordinator.stop(saveCheckpoint: false) }
        let runner = RealDiskBenchmarkRunner(root: canonical, cacheDirectory: arguments[2], idleSeconds: idle)
        try coordinator.start { message in
            if !message.contains("[info] Scanning:") && !message.contains("Building memory index:") {
                TerminalOutput.info(message)
            }
        }
        guard coordinator.waitUntilLive(timeout: 1800) else {
            throw RealDiskBenchmarkError.failed("Startup failed: \(coordinator.startupStatus())")
        }
        let firstLive = ProcessResourceSample.capture()
        guard coordinator.waitForCheckpoint(timeout: 1800) else { throw RealDiskBenchmarkError.failed("Startup checkpoint timeout") }
        let live = ProcessResourceSample.capture()
        let liveStats = coordinator.stats().dictionary
        if mode != "cold" {
            guard liveStats["startup_mode"] as? String == "warm_snapshot",
                  liveStats["full_scans"] as? Int == nil || liveStats["full_scans"] as? Int == 0,
                  liveStats["base_materialized_file_entries"] as? Int == 0,
                  liveStats["materialized_file_entries"] as? Int == 0 else {
                throw RealDiskBenchmarkError.failed("Warm worker unexpectedly rebuilt or materialized the base")
            }
        }
        guard let hybrid = coordinator.index as? HybridIndex, let base = hybrid.mappedBase else {
            throw RealDiskBenchmarkError.failed("Missing v2 mapping")
        }
        var report: [String: Any] = ["pid": getpid(), "phase": mode,
            "process_start": before.dictionary, "live": live.dictionary,
            "time_to_live_ms": (firstLive.uptime - before.uptime) * 1000,
            "cpu_to_live": firstLive.delta(since: before),
            "startup": live.delta(since: before), "live_stats": liveStats,
            "layout": base.layoutStatistics(), "snapshot_file": try fileSize(arguments[2], coordinator: coordinator)]
        if mode == "warm" {
            let metricsBefore = coordinator.metrics.snapshot()
            let idleBefore = ProcessResourceSample.capture()
            Thread.sleep(forTimeInterval: idle)
            let idleAfter = ProcessResourceSample.capture()
            report["idle"] = idleAfter.delta(since: idleBefore)
            report["idle_seconds"] = idle
            report["idle_metrics"] = metricDelta(coordinator.metrics.snapshot(), metricsBefore)
            report["after_idle"] = idleAfter.dictionary
            report["queries"] = try queryMeasurements(hybrid)
            try validateFixture(arguments[4], inode: inode)
            report["mutation"] = try runner.mutationMeasurements(coordinator, fixture: arguments[4], inode: inode)
        } else if mode == "final" {
            try converge("cleanup replay") { coordinator.index.entry(at: arguments[4]) == nil }
            guard coordinator.core.flushEvents(timeout: 120) else { throw RealDiskBenchmarkError.failed("Cleanup flush") }
            let compactBefore = ProcessResourceSample.capture()
            try compact(coordinator)
            report["cleanup_compaction"] = ProcessResourceSample.capture().delta(since: compactBefore)
            report["verification"] = try verification(coordinator)
        }
        let exitBefore = ProcessResourceSample.capture()
        coordinator.stop()
        report["graceful_exit"] = ProcessResourceSample.capture().delta(since: exitBefore)
        report["final_stats"] = coordinator.stats().dictionary
        printJSON(report)
        return 0
    }

    private func mutationMeasurements(_ c: PersistentIndexCoordinator, fixture: String, inode: UInt64) throws -> [String: Any] {
        var result: [String: Any] = [:]
        // Establish a base matching the live namespace before the state-only
        // experiment. Root-wide unrelated changes can still invalidate that
        // precondition; record actual checkpoint type rather than mislabel it.
        let baselineBefore = ProcessResourceSample.capture()
        for _ in 0..<3 {
            try Self.compact(c)
            let stats = c.stats().dictionary
            if stats["current_generation"] as? UInt64 == stats["last_checkpoint_generation"] as? UInt64 { break }
        }
        result["baseline_compaction"] = ProcessResourceSample.capture().delta(since: baselineBefore)
        c.core.measureContentEvents(at: fixture + "/content")
        guard c.core.flushEvents(timeout: 120) else { throw RealDiskBenchmarkError.failed("Content probe setup") }
        let contentGeneration = c.index.stats().generation
        let contentMetrics = c.metrics.snapshot(), contentBefore = ProcessResourceSample.capture()
        _ = try child(["mutate", fixture, String(inode), "content"])
        try Self.converge("owned content event") { c.metrics.snapshot()["content_probe_events", default: 0] > contentMetrics["content_probe_events", default: 0] }
        guard c.core.flushEvents(timeout: 120) else { throw RealDiskBenchmarkError.failed("Content flush") }
        result["content_only"] = ProcessResourceSample.capture().delta(since: contentBefore)
        result["content_metrics"] = Self.metricDelta(c.metrics.snapshot(), contentMetrics)
        result["content_namespace_unchanged"] = c.index.stats().generation == contentGeneration
        result["content_generation_before"] = contentGeneration
        result["content_generation_after"] = c.index.stats().generation
        c.core.measureContentEvents(at: nil)
        let stateBefore = ProcessResourceSample.capture(), stateMetrics = c.metrics.snapshot()
        guard c.checkpoint(), c.waitForCheckpoint(timeout: 1800) else { throw RealDiskBenchmarkError.failed("State checkpoint") }
        result["state_checkpoint"] = ProcessResourceSample.capture().delta(since: stateBefore)
        result["state_checkpoint_metrics"] = Self.metricDelta(c.metrics.snapshot(), stateMetrics)
        result["state_only_checkpoint_observed"] = c.metrics.snapshot()["state_checkpoints", default: 0] > stateMetrics["state_checkpoints", default: 0]
            && c.metrics.snapshot()["compactions", default: 0] == stateMetrics["compactions", default: 0]
        let smallBefore = ProcessResourceSample.capture(), smallMetrics = c.metrics.snapshot()
        _ = try child(["mutate", fixture, String(inode), "small"])
        try Self.converge("small CRUD") { c.index.entry(at: fixture + "/small-renamed") != nil && c.index.entry(at: fixture + "/small-0") == nil }
        guard c.core.flushEvents(timeout: 120) else { throw RealDiskBenchmarkError.failed("Small CRUD flush") }
        result["small_crud"] = ProcessResourceSample.capture().delta(since: smallBefore)
        result["small_crud_metrics"] = Self.metricDelta(c.metrics.snapshot(), smallMetrics)
        let namespaceBefore = ProcessResourceSample.capture()
        _ = try child(["mutate", fixture, String(inode), "create"])
        try Self.converge("10k creates") { c.index.children(of: fixture).count == 10002 }
        _ = try child(["mutate", fixture, String(inode), "rename"])
        try Self.converge("2k renames") { c.index.entry(at: fixture + "/r01999") != nil && c.index.entry(at: fixture + "/f01999") == nil }
        _ = try child(["mutate", fixture, String(inode), "delete"])
        try Self.converge("5k deletes") { c.index.children(of: fixture).count == 5002 }
        guard c.core.flushEvents(timeout: 120) else { throw RealDiskBenchmarkError.failed("Namespace flush") }
        result["namespace_workload"] = ProcessResourceSample.capture().delta(since: namespaceBefore)
        result["before_compaction_stats"] = c.stats().dictionary
        result["old_base_bytes"] = (c.index as? HybridIndex)?.mappedBase?.mappedBytes ?? 0
        let token = CancellationToken(), group = DispatchGroup(), samples = RealQuerySamples()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            while !token.isCancelled { samples.add(c.index.search("apfsfind", limit: 50).latencyMilliseconds) }
            group.leave()
        }
        defer { token.cancel(); group.wait() }
        let compactBefore = ProcessResourceSample.capture()
        (c.index as? HybridIndex)?.resetWriterWaitMeasurements()
        let compactCount = c.metrics.snapshot()["compactions", default: 0]
        guard c.compact() else { throw RealDiskBenchmarkError.failed("Compaction already active") }
        _ = try child(["mutate", fixture, String(inode), "during"])
        guard c.waitForCheckpoint(timeout: 1800), c.metrics.snapshot()["compactions", default: 0] > compactCount else {
            throw RealDiskBenchmarkError.failed("Compaction failed or timed out")
        }
        token.cancel(); group.wait()
        result["compaction"] = ProcessResourceSample.capture().delta(since: compactBefore)
        result["query_during_compaction"] = samples.summary
        result["after_compaction_stats"] = c.stats().dictionary
        result["new_base_bytes"] = (c.index as? HybridIndex)?.mappedBase?.mappedBytes ?? 0
        try Self.converge("buffered compaction events") { c.index.children(of: fixture).count == 5102 }
        result["verification"] = try Self.verification(c)
        return result
    }

    private static func queryMeasurements(_ index: HybridIndex) throws -> [String: Any] {
        guard let base = index.mappedBase else { throw RealDiskBenchmarkError.failed("No query base") }
        // Choose an actual rare basename. The selection query is retained as
        // its first measured query, so it is not silently treated as warmup.
        var name = ""
        var exactFirst: SearchResult?
        var exactResources: [String: Any] = [:]
        for id in stride(from: 1, to: base.count, by: max(1, base.count / 10000)) where base.record(at: UInt32(id)).kind == .file {
            let candidate = base.name(at: UInt32(id))
            if candidate.count >= 20 && candidate.count <= 80 {
                let before = ProcessResourceSample.capture()
                let hit = index.search(candidate, limit: 50)
                let resources = ProcessResourceSample.capture().delta(since: before)
                if hit.hits.count == 1 { name = candidate; exactFirst = hit; exactResources = resources; break }
            }
        }
        guard !name.isEmpty else { throw RealDiskBenchmarkError.failed("No representative basename") }
        let queries = [("exact_basename", name), ("prefix", String(name.prefix(5))),
            ("substring", String(name.dropFirst(2).prefix(6))),
            ("no_match", "apfsfind-no-match-" + UUID().uuidString), ("one_character", "a"), ("two_character", "py")]
        var results: [String: Any] = [:]
        for (kind, query) in queries {
            let firstBefore = ProcessResourceSample.capture()
            let first = kind == "exact_basename" ? exactFirst! : index.search(query, limit: 50)
            let firstResources = kind == "exact_basename" ? exactResources : ProcessResourceSample.capture().delta(since: firstBefore)
            for _ in 0..<5 { _ = index.search(query, limit: 50) }
            let total = RealQuerySamples(), basePhase = RealQuerySamples(), overlay = RealQuerySamples(), paths = RealQuerySamples()
            let measuredBefore = ProcessResourceSample.capture()
            for _ in 0..<30 {
                let hit = index.search(query, limit: 50), m = index.metrics.snapshot()
                total.add(hit.latencyMilliseconds)
                basePhase.add(Double(m["query_base_scan_us", default: 0]) / 1000)
                overlay.add(Double(m["query_overlay_scan_us", default: 0]) / 1000)
                paths.add(Double(m["query_path_reconstruction_us", default: 0]) / 1000)
            }
            results[kind] = ["query": query, "limit": 50, "returned_results": first.hits.count,
                "result_count_is_capped": first.hits.count == 50,
                "first_query_ms": first.latencyMilliseconds, "first_query_resources": firstResources,
                "total": total.summary, "base_scan": basePhase.summary, "overlay_scan": overlay.summary,
                "path_reconstruction": paths.summary,
                "measured_resources": ProcessResourceSample.capture().delta(since: measuredBefore)]
        }
        return results
    }

    private static func verification(_ c: PersistentIndexCoordinator) throws -> [String: Any] {
        var last: [String: Any] = [:]
        var attempts: [[String: Any]] = []
        for attempt in 1...3 {
            guard c.core.flushEvents(timeout: 120) else { throw RealDiskBenchmarkError.failed("Verify flush") }
            let start = ProcessResourceSample.capture(), v = try c.verify()
            last = ["missing": v.missing.count, "extra": v.extra.count, "attempt": attempt,
                    "missing_sample": Array(v.missing.prefix(10)), "extra_sample": Array(v.extra.prefix(10)),
                    "raw_missing": v.rawMissing.count, "raw_extra": v.rawExtra.count, "raw_sets_agree": v.rawSetsAgree,
                    "raw_missing_sample": Array(v.rawMissing.prefix(10)), "raw_extra_sample": Array(v.rawExtra.prefix(10)),
                    "revalidated_races": v.racedPaths.count, "revalidated_race_sample": Array(v.racedPaths.prefix(10)),
                    "mode": "fresh_scan_then_current_directory_difference_revalidation",
                    "resources": ProcessResourceSample.capture().delta(since: start)]
            attempts.append(last)
            last["attempts"] = attempts
            if v.isConsistent { return last }
        }
        // The entire root can change during a metadata scan. Preserve raw
        // differences in the report; never discard live paths to claim 0/0.
        last["consistent"] = false
        return last
    }
    private static func compact(_ c: PersistentIndexCoordinator) throws {
        let before = c.metrics.snapshot()["compactions", default: 0]
        guard c.compact(), c.waitForCheckpoint(timeout: 1800),
              c.metrics.snapshot()["compactions", default: 0] > before else {
            throw RealDiskBenchmarkError.failed("Compaction failed: \(c.stats().dictionary["persistence_error"] ?? "unknown")")
        }
    }
    private static func converge(_ message: String, _ condition: () -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 120
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.02) }
        guard condition() else { throw RealDiskBenchmarkError.failed("Convergence timeout: \(message)") }
    }
    private static func metricDelta(_ after: [String: Int], _ before: [String: Int]) -> [String: Int] {
        after.mapValues { $0 }.reduce(into: [:]) { output, item in output[item.key] = item.value - before[item.key, default: 0] }
    }
    private static func fileSize(_ cache: String, coordinator: PersistentIndexCoordinator) throws -> [String: Any] {
        guard let path = coordinator.stats().dictionary["snapshot_path"] as? String else { throw RealDiskBenchmarkError.failed("No snapshot path") }
        var s = stat()
        guard lstat(path, &s) == 0 else { throw RealDiskBenchmarkError.failed("Snapshot stat") }
        var result: [String: Any] = ["logical_bytes": s.st_size, "allocated_bytes": Int64(s.st_blocks) * 512]
        var logical = Int64(s.st_size), allocated = Int64(s.st_blocks) * 512
        for suffix in [".state", ".lock"] {
            var other = stat()
            if lstat(path + suffix, &other) == 0 {
                result[suffix + "_logical_bytes"] = other.st_size
                result[suffix + "_allocated_bytes"] = Int64(other.st_blocks) * 512
                logical += Int64(other.st_size); allocated += Int64(other.st_blocks) * 512
            }
        }
        result["cache_logical_bytes"] = logical; result["cache_allocated_bytes"] = allocated
        return result
    }
    private func fixtureInode(_ path: String) throws -> UInt64 {
        var s = stat(); guard lstat(path, &s) == 0 else { throw RealDiskBenchmarkError.failed("Fixture stat") }
        return UInt64(s.st_ino)
    }
    private static func validateFixture(_ path: String, inode: UInt64) throws {
        let parent = PathCanonicalizer.parent(of: path), name = String(path.dropFirst(parent.count + 1))
        guard name.hasPrefix("apfsfind-real-bench-"), UUID(uuidString: String(name.dropFirst("apfsfind-real-bench-".count))) != nil,
              try PathCanonicalizer.canonicalRoot(path) == path else { throw RealDiskBenchmarkError.failed("Unsafe mutation directory") }
        var s = stat()
        guard lstat(path, &s) == 0, s.st_mode & S_IFMT == S_IFDIR, s.st_uid == geteuid(),
              UInt64(s.st_ino) == inode, s.st_mode & 0o7777 == 0o700 else { throw RealDiskBenchmarkError.failed("Replaced mutation directory") }
    }
    private static func mutate(_ operation: String, path: String) throws {
        func create(_ name: String) throws {
            let fd = open(path + "/" + name, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw RealDiskBenchmarkError.failed("Create \(name): \(errno)") }; close(fd)
        }
        switch operation {
        case "seed": try create("content")
        case "content":
            let fd = open(path + "/content", O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { throw RealDiskBenchmarkError.failed("Content fixture") }
            defer { close(fd) }; var byte: UInt8 = 42
            for _ in 0..<10000 { guard pwrite(fd, &byte, 1, 0) == 1 else { throw RealDiskBenchmarkError.failed("Content fixture write") } }
        case "small":
            for i in 0..<10 { try create("small-\(i)") }
            guard rename(path + "/small-0", path + "/small-renamed") == 0 else { throw RealDiskBenchmarkError.failed("Small rename") }
            for i in 1..<10 { guard unlink(path + "/small-\(i)") == 0 else { throw RealDiskBenchmarkError.failed("Small delete") } }
        case "create": for i in 0..<10000 { try create(String(format: "f%05d", i)) }
        case "rename":
            for i in 0..<2000 {
                guard rename(path + String(format: "/f%05d", i), path + String(format: "/r%05d", i)) == 0 else { throw RealDiskBenchmarkError.failed("Rename fixture") }
            }
        case "delete":
            for i in 4000..<9000 { guard unlink(path + String(format: "/f%05d", i)) == 0 else { throw RealDiskBenchmarkError.failed("Delete fixture") } }
        case "during": for i in 0..<100 { try create("during-\(i)") }
        default: throw RealDiskBenchmarkError.failed("Unknown fixture workload")
        }
    }
    private func child(_ arguments: [String]) throws -> [String: Any] {
        let process = Process(), output = Pipe(), errors = Pipe(), group = DispatchGroup()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["_real-disk-worker"] + arguments
        // Pipe progress through the parent: redirecting the harness's stderr
        // must not charge its log-file writes to the index worker's disk I/O.
        process.standardOutput = output; process.standardError = errors
        try process.run()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            while let bytes = try? errors.fileHandleForReading.read(upToCount: 4096), !bytes.isEmpty {
                FileHandle.standardError.write(bytes)
            }
            group.leave()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); group.wait()
        guard process.terminationStatus == 0, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RealDiskBenchmarkError.failed("Worker \(arguments.first ?? "") exited \(process.terminationStatus): \(String(decoding: data, as: UTF8.self).prefix(1000))")
        }
        return json
    }
    private static func printJSON(_ value: [String: Any]) {
        print(String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self))
    }
    private func printJSON(_ value: [String: Any]) { Self.printJSON(value) }
}
