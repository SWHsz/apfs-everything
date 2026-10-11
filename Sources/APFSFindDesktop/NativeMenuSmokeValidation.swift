import APFSFindCore
import Darwin
import Foundation

/// Only the independently owned smoke bundle invokes this verifier. It reads
/// directory names and metadata, never the contents of source files.
@MainActor
enum NativeMenuSmokeValidation {
  struct Fixture {
    let path: String
    let values: [String: (UInt64, Int64)]
    let device: dev_t
    let inode: ino_t
    var sameDirectory: Bool {
      var current = stat()
      return lstat(path, &current) == 0 && current.st_dev == device && current.st_ino == inode
    }
    func matches(_ result: MultiVolumeSearchResult) -> Bool {
      let hits = result.hits.filter { $0.path.hasPrefix(path + "/") }
      return sameDirectory && hits.count == values.count
        && Set(hits.map(\.path)) == Set(values.keys) && hits.allSatisfy { hit in
          guard let value = values[hit.path] else { return false }
          return hit.kind == .file && hit.logicalSize == value.0 && hit.modificationTimeNanoseconds == value.1
        }
    }
  }
  static func captureFixture() throws -> Fixture {
    guard Bundle.main.bundleIdentifier?.hasPrefix("local.apfsfind.desktop.smoke.") == true,
      let path = Bundle.main.object(forInfoDictionaryKey: "APFSFindOwnedFixture") as? String,
      PathCanonicalizer.parent(of: path) == "/Volumes/Data 1/everything/.build",
      let token = path.split(separator: "/").last, token.hasPrefix("apfsfind-fixture-"),
      UUID(uuidString: String(token.dropFirst("apfsfind-fixture-".count))) != nil else {
      throw SnapshotError.unsafePath("owned fixture configuration")
    }
    let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw SnapshotError.io("open owned fixture", errno) }
    defer { close(fd) }
    var directory = stat()
    guard fstat(fd, &directory) == 0, directory.st_uid == getuid() else {
      throw SnapshotError.unsafePath("owned fixture owner")
    }
    let names = try FileManager.default.contentsOfDirectory(atPath: path)
    guard names.count == 12, names.allSatisfy({ $0.hasPrefix("apfsfindv062fixture-") }) else {
      throw SnapshotError.invalid("owned fixture must contain twelve generated entries")
    }
    var values: [String: (UInt64, Int64)] = [:]
    for name in names {
      var st = stat()
      guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0,
        st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid() else {
        throw SnapshotError.unsafePath("owned fixture entry")
      }
      values[path + "/" + name] = (UInt64(st.st_size),
        Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec))
    }
    return Fixture(path: path, values: values, device: directory.st_dev, inode: directory.st_ino)
  }
  static func fixtureIsSynchronized(_ coordinator: MultiVolumeCoordinator) async -> Bool {
    guard let fixture = try? captureFixture() else { return false }
    let result = await coordinator.search(.init(query: "apfsfindv062fixture-", limit: 100, sort: .init(key: .size)))
    return result.metadataComplete && fixture.matches(result)
  }
  private static var baselines: [String: ActiveLiveSample] = [:]
  static func observe(_ coordinator: MultiVolumeCoordinator, stage: String, paused: Bool,
    actionStarted: Double) async {
    guard Bundle.main.bundleIdentifier?.hasPrefix("local.apfsfind.desktop.smoke.") == true else { return }
    if paused {
      baselines[stage] = try? await ActiveLiveSmoke.sample(coordinator)
      if stage == "menu_volume" {
        let result = await coordinator.search(.init(query: "SystemVersion.plist", limit: 100))
        let ids = Set(await coordinator.sessionsSnapshot().filter { $0.volume.isSystemVolume }.map(\.id))
        let system = result.hits.filter { ids.contains($0.volumeUUID) }
        NativeSmokeActions.emit(stage + "_system_search", ["count": system.count,
          "all_live": !system.isEmpty && system.allSatisfy { $0.freshness == .live },
          "query_ms": result.latencyMilliseconds])
      }
      return
    }
    guard let before = baselines.removeValue(forKey: stage) else {
      NativeSmokeActions.emit(stage + "_verify_error", ["reason": "missing pause baseline"])
      return
    }
    do {
      let prefix = "apfsfindv062fixture-"
      let fixture = try captureFixture(), path = fixture.path
      let pressure = Task {
        while !Task.isCancelled {
          _ = await coordinator.search(.init(query: "f", limit: 51))
          await Task.yield()
        }
      }
      defer { pressure.cancel() }
      var actual = 0, correct = false, complete = false, queryMS = 0.0
      repeat {
        let result = await coordinator.search(.init(query: prefix, limit: 100, sort: .init(key: .size)))
        let hits = result.hits.filter { $0.path.hasPrefix(path + "/") }
        actual = hits.count; complete = result.metadataComplete; queryMS = result.latencyMilliseconds
        correct = fixture.matches(result)
        if correct && complete { break }
        try await Task.sleep(for: .milliseconds(100))
      } while ProcessInfo.processInfo.systemUptime - actionStarted < 30
      let after = try await ActiveLiveSmoke.sample(coordinator)
      let seconds = ProcessInfo.processInfo.systemUptime - actionStarted
      NativeSmokeActions.emit(stage + "_fixture_verify", ["passed": correct && complete
        && fixture.sameDirectory && seconds <= 30 && before.fullScans == after.fullScans
        && before.resourceYieldRebuilds == after.resourceYieldRebuilds,
        "expected": fixture.values.count, "actual": actual, "metadata_size_mtime_correct": correct,
        "metadata_complete": complete, "seconds": seconds, "query_ms": queryMS,
        "full_scans_delta": after.fullScans - before.fullScans,
        "resource_yield_rebuild_delta": after.resourceYieldRebuilds - before.resourceYieldRebuilds,
        "scope": "owned fixture; timer starts before real menu resume action"])
    } catch {
      NativeSmokeActions.emit(stage + "_verify_error", ["reason": String(describing: error)])
    }
  }
}
