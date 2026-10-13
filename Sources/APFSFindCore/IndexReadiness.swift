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
  private var revision: UInt64 = 0
  func stream(initial: @autoclosure () -> Value) -> AsyncStream<Value> {
    let id = UUID()
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      continuation.onTermination = { [weak self] _ in
        _ = self?.lock.withLock { self?.continuations.removeValue(forKey: id) }
      }
      // Subscribe before reading the producer. If an update arrives during
      // that read, it has already supplied a newer value to this subscriber.
      // A stale initial value must not overwrite it in the one-element buffer.
      let subscribedRevision = lock.withLock { continuations[id] = continuation; return revision }
      let value = initial()
      lock.withLock {
        if revision == subscribedRevision { continuation.yield(value) }
      }
    }
  }
  func send(_ value: Value) {
    // AsyncStream.yield enqueues a value; it does not invoke consumer code.
    // Serialize delivery with registration so an initial value cannot win a
    // race with the final Live notification.
    lock.withLock {
      revision &+= 1
      for client in continuations.values { client.yield(value) }
    }
  }
}
public enum ShutdownPolicy: Sendable { case fast, compactIfThresholdReached, forceCompact }
