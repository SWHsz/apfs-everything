import APFSFindCore
import Foundation

/// Opt-in native benchmark. External namespace generations may change; the
/// production app has no polling timer and the controlled quiet gate is intact.
@MainActor
enum ActiveLiveSmoke {
  static func sample(_ coordinator: MultiVolumeCoordinator) async throws -> ActiveLiveSample {
    let data = try await coordinator.resourceDiagnosticsJSON()
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let volumes = json["volumes"] as! [[String: Any]]
    func count(_ key: String) -> Int {
      volumes.reduce(0) { $0 + (($1["core_metrics"] as? [String: Int])?[key] ?? 0) }
    }
    let states = await coordinator.quietVolumeStates()
    return .init(received: count("fsevents_received"), processed: count("fsevents_processed"),
      eventBacklog: states.reduce(0) { $0 + $1.namespaceEvents },
      dirtyBacklog: states.reduce(0) { $0 + $1.dirtyDirectories },
      fullScans: count("full_scans"), resourceYieldRebuilds: count("rebuild_requests_resource_yield"),
      recoveryYields: count("recovery_epoch_yields"),
      physicalBytes: ProcessResourceSample.capture().physicalFootprint ?? UInt64.max)
  }
  static func diagnostics(_ stage: String, _ coordinator: MultiVolumeCoordinator) async {
    if let data = try? await coordinator.resourceDiagnosticsJSON(),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      NativeSmokeActions.emit(stage, json)
    }
  }
  static func run(_ coordinator: MultiVolumeCoordinator) async {
    let deadline = ProcessInfo.processInfo.systemUptime + 1200
    while ProcessInfo.processInfo.systemUptime < deadline {
      let states = await coordinator.sessionsSnapshot()
      if states.count == 2 && states.allSatisfy({ $0.state == .live && $0.metadataAvailable }) { break }
      do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
    }
    let states = await coordinator.sessionsSnapshot()
    guard states.count == 2 && states.allSatisfy({ $0.state == .live && $0.metadataAvailable }),
          let baseline = try? await sample(coordinator) else {
      await diagnostics("active_live_unavailable", coordinator); return
    }
    await diagnostics("active_live_start", coordinator)
    let before = ProcessResourceSample.capture(), start = before.uptime
    var gate = ActiveLiveConvergenceGate(baseline: baseline), samples = 0
    let prior = await coordinator.maintenance.telemetry.snapshot
    let priorIDs = Set(prior.compactMap { $0["id"] as? String })
    var maintenanceFailures = Set<String>()
    while ProcessInfo.processInfo.systemUptime - start < 1200 {
      do { try await Task.sleep(for: .seconds(5)) } catch { return }
      guard let next = try? await sample(coordinator) else {
        NativeSmokeActions.emit("active_live_error", ["reason": "diagnostics unavailable"]); return
      }
      gate.observe(next); samples += 1
      let history = await coordinator.maintenance.telemetry.snapshot
      for record in history where !priorIDs.contains(record["id"] as? String ?? "") {
        if (record["restart_count"] as? Int ?? 0) >= 3 {
          maintenanceFailures.insert("maintenance restart loop")
        }
        if (record["peak_physical_footprint"] as? UInt64 ?? 0) > 150 * 1024 * 1024 {
          maintenanceFailures.insert("maintenance physical footprint limit")
        }
      }
      if samples % 6 == 0 { await diagnostics("active_live_progress", coordinator) }
    }
    let tasks = await coordinator.maintenance.snapshot()
    var blockers = gate.blockers + maintenanceFailures.sorted()
    if !tasks.isEmpty { blockers.append("maintenance unfinished at deadline") }
    NativeSmokeActions.emit("active_live_gate", ["passed": blockers.isEmpty, "blockers": blockers,
      "samples": samples, "seconds": ProcessInfo.processInfo.systemUptime - start,
      "resource_delta": ProcessResourceSample.capture().delta(since: before)])
    await diagnostics("active_live_end", coordinator)
    await NativeSmokeActions.run(coordinator)
  }
}
