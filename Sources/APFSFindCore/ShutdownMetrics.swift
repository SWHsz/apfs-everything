import Foundation

/// Bounded, in-memory exit diagnostics. No timer or runtime log file.
public final class ShutdownMetrics: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: Double] = Dictionary(uniqueKeysWithValues: [
    "shutdown_total_ms", "shutdown_cancel_queries_ms", "shutdown_stop_watcher_ms",
    "shutdown_namespace_drain_ms", "shutdown_metadata_updater_ms", "shutdown_cancel_maintenance_ms",
    "shutdown_wait_metadata_group_ms", "shutdown_wait_checkpoint_group_ms", "shutdown_state_write_ms",
    "shutdown_session_teardown_ms"
  ].map { ($0, 0) })
  public init() {}
  public func measure<T>(_ name: String, _ action: () throws -> T) rethrows -> T {
    let start = ProcessInfo.processInfo.systemUptime
    defer { record(name, milliseconds: (ProcessInfo.processInfo.systemUptime-start)*1000) }
    return try action()
  }
  public func record(_ name: String, milliseconds: Double) {
    lock.withLock { values[name, default: 0] += milliseconds }
  }
  public var snapshot: [String: Double] { lock.withLock { values } }
}
