import Foundation

public enum IndexReadiness: String, Sendable {
  case opening, scanning, baseReady, catchingUp, live, rebuildingUsingOldBase, paused, offline, failed, stopped
}
public struct IndexReadinessSnapshot: Sendable {
  public let state: IndexReadiness
  public let searchAvailable: Bool
  public let resultsMayBeStale: Bool
  public let startupMode: StartupMode?
  public let indexedEntries: Int
  public let replayReceived: Int
  public let replayProcessed: Int
  public let replayPending: Int
  public let error: String?
  public var freshness: SearchFreshness {
    switch state {
    case .live: .live
    case .paused: .pausedStale
    case .catchingUp: .catchingUp
    case .rebuildingUsingOldBase: .rebuilding
    default: .baseSnapshot
    }
  }
}
/// Notifications never call client code while holding a producer lock.
final class SnapshotObservation<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]
  func stream(initial: Value) -> AsyncStream<Value> {
    let id = UUID()
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      lock.withLock { continuations[id] = continuation }
      continuation.yield(initial)
      continuation.onTermination = { [weak self] _ in
        _ = self?.lock.withLock { self?.continuations.removeValue(forKey: id) }
      }
    }
  }
  func send(_ value: Value) {
    let clients = lock.withLock { Array(continuations.values) }
    for client in clients { client.yield(value) }
  }
}
public enum ShutdownPolicy: Sendable { case fast, compactIfThresholdReached, forceCompact }
