import APFSFindCore
import Darwin
import Foundation

private enum PersistenceBenchmarkError: Error {
    case failed(String)
}

struct PersistenceBenchmarkRunner {
    let entries: Int
    let cacheDirectory: String?
    let latencyMilliseconds: Double

    func run() throws -> Int32 {
        let tree = try OwnedTemporaryDirectory()
        let cache = try OwnedTemporaryDirectory(parentPath: cacheDirectory)
        defer {
            do { try tree.remove(); try cache.remove() }
            catch { TerminalOutput.error("Persistence benchmark cleanup failed: \(error)") }
        }
        let root = tree.url.path
        for i in 0..<100 {
            try FileManager.default.createDirectory(atPath: root + String(format: "/d%02d", i), withIntermediateDirectories: false)
        }
        for i in 0..<(entries - 101) {
            try create(root + String(format: "/d%02d/f%06d", i % 100, i))
        }
        let configuration = APFSFindConfiguration(latencyMilliseconds: latencyMilliseconds)
        func controller() throws -> PersistentIndexCoordinator {
            try PersistentIndexCoordinator(root: root, configuration: configuration, cacheDirectory: cache.url.path)
        }
        func ready(_ c: PersistentIndexCoordinator) throws {
            guard c.waitUntilLive(timeout: 120) else { throw PersistenceBenchmarkError.failed("Startup: \(c.startupStatus())") }
        }
        var cold: PersistentIndexCoordinator? = try controller()
        defer { cold?.stop(saveCheckpoint: false) }
        let coldStarted = now()
        try cold!.start { TerminalOutput.info($0) }
        try ready(cold!)
        let coldLiveMS = elapsed(coldStarted)
        guard cold!.waitForCheckpoint(timeout: 120) else { throw PersistenceBenchmarkError.failed("Cold checkpoint timed out") }
        let coldStats = cold!.stats().dictionary
        let identity = try VolumeIdentity.discover(root: root)
        let store = try SnapshotStore(directory: cache.url.path, identity: identity)
        let header = try store.reader(expectedIdentity: identity).header
        guard header.recordCount == entries else { throw PersistenceBenchmarkError.failed("Unexpected cold record count") }
        cold!.stop(saveCheckpoint: false)
        cold = nil

        let warm = try controller()
        defer { warm.stop(saveCheckpoint: false) }
        let warmStarted = now()
        try warm.start { TerminalOutput.info($0) }
        try ready(warm)
        let warmLiveMS = elapsed(warmStarted)
        let warmStats = warm.stats().dictionary
        let verification = try warm.verify()
        let stampBefore = try SnapshotStamp(store.path)
        let generationBefore = warm.index.stats().generation
        let workloadStarted = now(), cpuBefore = Metrics.processUsage()
        for i in 0..<1000 { try create(root + "/d00/new-\(i)") }
        try converge { (0..<1000).allSatisfy { warm.index.entry(at: root + "/d00/new-\($0)") != nil } }
        for i in 0..<1000 { try FileManager.default.removeItem(atPath: root + "/d00/new-\(i)") }
        try converge { (0..<1000).allSatisfy { warm.index.entry(at: root + "/d00/new-\($0)") == nil } }
        let content = root + "/d00/f000000"
        let beforeContent = warm.metrics.snapshot()
        let contentGeneration = warm.index.stats().generation
        let fd = open(content, O_WRONLY | O_CLOEXEC)
        guard fd >= 0 else { throw PersistenceBenchmarkError.failed("Open content fixture") }
        var byte: UInt8 = 1
        for _ in 0..<10_000 {
            guard pwrite(fd, &byte, 1, 0) == 1 else { close(fd); throw PersistenceBenchmarkError.failed("Content write") }
        }
        close(fd)
        try converge { warm.metrics.snapshot()["ignored_content_events", default: 0] > beforeContent["ignored_content_events", default: 0] }
        let contentOnly = warm.index.stats().generation == contentGeneration
        let renameCount = min(100, (entries - 102) / 100 + 1)
        for i in 0..<renameCount {
            let old = root + String(format: "/d00/f%06d", i * 100)
            try FileManager.default.moveItem(atPath: old, toPath: old + "-renamed")
        }
        try converge {
            (0..<renameCount).allSatisfy {
                warm.index.entry(at: root + String(format: "/d00/f%06d-renamed", $0 * 100)) != nil
            }
        }
        guard warm.core.flushEvents() else { throw PersistenceBenchmarkError.failed("Workload drain") }
        let onlineVerification = try warm.verify()
        let unchanged = stampBefore == (try SnapshotStamp(store.path))
        let generationChanged = warm.index.stats().generation != generationBefore
        let cpuAfter = Metrics.processUsage(), workloadMS = elapsed(workloadStarted)
        let beforeExitCheckpoints = warm.metrics.snapshot()["snapshot_checkpoints", default: 0]
        warm.stop()
        let exitCheckpoint = warm.metrics.snapshot()["snapshot_checkpoints", default: 0] > beforeExitCheckpoints
        let afterExit = try store.reader(expectedIdentity: identity).header

        let next = try controller()
        defer { next.stop(saveCheckpoint: false) }
        try next.start()
        try ready(next)
        let nextVerification = try next.verify()
        let nextStats = next.stats().dictionary
        let nextSeesLatest = next.index.entry(at: root + "/d00/f000000-renamed") != nil &&
            next.index.entry(at: root + "/d00/f000000") == nil
        let accepted = verification.isConsistent && onlineVerification.isConsistent && nextVerification.isConsistent &&
            warmStats["startup_mode"] as? String == "warm_snapshot" &&
            (warmStats["full_scans"] as? Int ?? 0) == 0 && unchanged && contentOnly &&
            generationChanged && exitCheckpoint && nextSeesLatest &&
            nextStats["startup_mode"] as? String == "warm_snapshot" && (nextStats["full_scans"] as? Int ?? 0) == 0
        next.stop(saveCheckpoint: false)
        let report: [String: Any] = [
            "version": "0.5.0", "warm_fraction_of_cold":warmLiveMS/coldLiveMS, "warm_under_25_percent":warmLiveMS<coldLiveMS*0.25, "entries": entries, "cold_time_to_live_ms": coldLiveMS,
            "cold": coldStats, "warm": warmStats, "warm_time_to_live_ms": warmLiveMS,
            "record_table_bytes": header.recordTableLength, "name_blob_bytes": header.nameBlobLength,
            "snapshot_bytes": header.fileLength, "bytes_per_entry": Double(header.fileLength) / Double(header.recordCount),
            "warm_verify_missing": verification.missing.count, "warm_verify_extra": verification.extra.count,
            "online_verify_missing": onlineVerification.missing.count, "online_verify_extra": onlineVerification.extra.count,
            "snapshot_modified_during_online_workload": !unchanged, "content_generation_unchanged": contentOnly,
            "online_workload_ms": workloadMS,
            "online_user_cpu_seconds": cpuAfter.userCPUSeconds - cpuBefore.userCPUSeconds,
            "online_system_cpu_seconds": cpuAfter.systemCPUSeconds - cpuBefore.systemCPUSeconds,
            "exit_generation_changed": generationChanged, "exit_checkpoint_produced": exitCheckpoint,
            "exit_snapshot_generation": afterExit.indexGeneration, "next_warm_sees_latest": nextSeesLatest,
            "next_warm_full_scans": nextStats["full_scans"] as? Int ?? 0, "provisional_acceptance": accepted
        ]
        print(String(format: "Persistence: cold %.1f ms, warm %.1f ms; snapshot %llu bytes (%.3f bytes/entry)",
            coldLiveMS, warmLiveMS, header.fileLength, Double(header.fileLength) / Double(header.recordCount)))
        print("Warm verify: missing=\(verification.missing.count) extra=\(verification.extra.count); full_scans=\(warmStats["full_scans"] ?? 0)")
        print("Online snapshot unchanged=\(unchanged); exit checkpoint=\(exitCheckpoint); next warm sees latest=\(nextSeesLatest)")
        print("Provisional acceptance: \(accepted ? "PASS" : "FAIL")")
        let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: json, as: UTF8.self))
        return accepted ? 0 : 1
    }

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    private func elapsed(_ start: TimeInterval) -> Double { (now() - start) * 1000 }
    private func converge(_ condition: () -> Bool) throws {
        let deadline = now() + 30
        while !condition() {
            guard now() < deadline else { throw PersistenceBenchmarkError.failed("Visibility condition timed out") }
            usleep(1000)
        }
    }
    private func create(_ path: String) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw PersistenceBenchmarkError.failed("Create fixture: \(errno)") }
        guard close(fd) == 0 else { throw PersistenceBenchmarkError.failed("Close fixture: \(errno)") }
    }
}

private struct SnapshotStamp: Equatable {
    let inode: UInt64, size: Int64, seconds: Int, nanoseconds: Int
    init(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw PersistenceBenchmarkError.failed("Snapshot stat: \(errno)") }
        inode = info.st_ino; size = info.st_size
        seconds = info.st_mtimespec.tv_sec; nanoseconds = info.st_mtimespec.tv_nsec
    }
}
