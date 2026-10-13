import APFSFindCore
import Darwin
import Foundation

/// Read-only acceptance observer. Only an explicitly owned smoke bundle enables
/// it; migration remains driven by the real Settings buttons and NSOpenPanel.
@MainActor
enum StorageNativeSmokeValidation {
  static var enabled: Bool {
    Bundle.main.bundleIdentifier?.hasPrefix("local.apfsfind.desktop.smoke.") == true
      && Bundle.main.object(forInfoDictionaryKey: "APFSFindStorageSmoke") as? Bool == true
  }
  static func emit(_ stage: String, _ fields: [String: Any]) {
    guard enabled else { return }
    NativeSmokeActions.emit("storage_ui_" + stage, fields)
  }
  static func ready(_ coordinator: MultiVolumeCoordinator, stage: String) async {
    guard enabled else { return }
    let start = ProcessInfo.processInfo.systemUptime
    while !Task.isCancelled && ProcessInfo.processInfo.systemUptime - start < 120 {
      let states = await coordinator.sessionsSnapshot()
      if !states.isEmpty && states.allSatisfy({ $0.state == .live && $0.metadataAvailable && $0.metadataFreshness == .live }) {
        await verify(coordinator, stage: stage)
        await ActiveLiveSmoke.diagnostics("storage_ui_" + stage + "_diagnostics", coordinator)
        return
      }
      do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
    }
    emit(stage + "_timeout", [:])
  }
  static func verify(_ coordinator: MultiVolumeCoordinator, stage: String) async {
    guard enabled, let roots = Bundle.main.object(forInfoDictionaryKey: "APFSFindTestRoots") as? [String], roots.count == 1,
      roots[0].hasPrefix("/private/tmp/apfsfind-"),
      let names = try? FileManager.default.contentsOfDirectory(atPath: roots[0]),
      names.count == 12, names.allSatisfy({ $0.hasPrefix("apfsfind-storage-smoke-") }) else {
      emit(stage + "_fixture_error", [:]); return
    }
    var expected: [String: (UInt64, Int64)] = [:]
    for name in names {
      var st = stat(); let path = roots[0] + "/" + name
      guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid() else {
        emit(stage + "_fixture_error", [:]); return
      }
      expected[path] = (UInt64(st.st_size), Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec))
    }
    var sorts: [[String: Any]] = []
    for sort in [SearchSortDescriptor(), .init(key: .name), .init(key: .size), .init(key: .modificationTime)] {
      var times: [Double] = [], correct = true, complete = true, order: [String] = []
      for _ in 0..<5 {
        let result = await coordinator.search(.init(query: "apfsfind-storage-smoke-", limit: 100, sort: sort))
        times.append(result.latencyMilliseconds); complete = complete && result.metadataComplete
        correct = correct && result.hits.count == expected.count && Set(result.hits.map(\.path)) == Set(expected.keys)
          && result.hits.allSatisfy { hit in
            guard let e = expected[hit.path] else { return false }
            return hit.kind == .file && hit.logicalSize == e.0 && hit.modificationTimeNanoseconds == e.1
          }
        order = result.hits.map { URL(fileURLWithPath: $0.path).lastPathComponent }
        let expectedPaths = expected.keys.sorted { a, b in
          switch sort.key {
          case .size: return sort.direction == .ascending ? expected[a]!.0 < expected[b]!.0 : expected[a]!.0 > expected[b]!.0
          case .modificationTime: return sort.direction == .ascending ? expected[a]!.1 < expected[b]!.1 : expected[a]!.1 > expected[b]!.1
          default: return a < b
          }
        }
        correct = correct && result.hits.map(\.path) == expectedPaths
      }
      sorts.append(["sort": sort.key.rawValue, "correct": correct, "metadata_complete": complete,
        "p95_ms": times.sorted().last ?? 0, "order": order])
    }
    emit(stage + "_queries", ["expected": expected.count, "sorts": sorts])
  }
  static func move(_ coordinator: MultiVolumeCoordinator, id: UUID, policy: IndexStoragePolicy) async throws -> IndexStorageMigrationReceipt {
    emit("migration_begin", ["policy": String(describing: policy)])
    await ActiveLiveSmoke.diagnostics("storage_ui_migration_before", coordinator)
    let stream = await coordinator.sessionsStream()
    let observer = Task {
      for await states in stream {
        if Task.isCancelled { break }
        if let value = await coordinator.storageProgress()[id] {
          emit("progress", ["copied_bytes": value.copiedBytes, "total_bytes": value.totalBytes, "phase": value.phase])
        }
        if states.contains(where: { $0.id == id && $0.state == .migratingStorage }) {
          let result = await coordinator.search(.init(query: "apfsfind-storage-smoke-", limit: 100))
          emit("during_migration_query", ["count": result.hits.count, "metadata_complete": result.metadataComplete,
            "query_ms": result.latencyMilliseconds])
        }
      }
    }
    defer { observer.cancel() }
    do {
      let receipt = try await coordinator.moveStorage(id, to: policy)
      emit("migration_complete", ["bytes": receipt.bytes, "milliseconds": receipt.milliseconds,
        "old_directory": receipt.oldDirectory, "new_directory": receipt.newDirectory,
        "source_uuid": receipt.sourceIdentity.volumeUUID.uuidString])
      await ready(coordinator, stage: "after_migration")
      return receipt
    } catch {
      emit("migration_error", ["error": String(describing: error)])
      throw error
    }
  }
}
