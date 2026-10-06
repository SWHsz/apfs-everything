import Foundation

/// One-shot work only. A mutation resets the quiet deadline; idle has no timer.
public final class CompactionScheduler: @unchecked Sendable {
  public enum State: String, Sendable { case idle, scheduled, running, backoff, stopped }
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "apfsfind.compaction-schedule", qos: .utility)
  private var item: DispatchWorkItem?
  private var epoch: UInt64 = 0
  private var state: State = .idle
  public let metrics: Metrics
  public init(metrics: Metrics = .init()) { self.metrics = metrics }
  public var currentState: State { lock.withLock { state } }
  public func schedule(delay: Double, safety: Bool = false, backoff: Bool = false, action: @escaping @Sendable () -> Void) {
    lock.withLock {
      guard state != .stopped else { return }
      metrics.record("compaction_schedule_requests")
      if item != nil { item?.cancel(); metrics.record("compaction_schedule_reschedules") }
      epoch &+= 1
      let expected = epoch
      state = backoff ? .backoff : .scheduled
      if safety { metrics.record("compaction_safety_triggered") }
      let work = DispatchWorkItem { [weak self] in
        guard let self else { return }
        let execute = self.lock.withLock {
          guard self.epoch == expected, self.state != .stopped else { return false }
          self.item = nil; self.state = .running; return true
        }
        guard execute else { return }
        self.metrics.record("compaction_scheduler_wakeups")
        self.metrics.record("compaction_schedule_executed")
        action()
        self.lock.withLock { if self.epoch == expected, self.state != .stopped { self.state = .idle } }
      }
      item = work
      queue.asyncAfter(deadline: .now() + max(0, delay), execute: work)
    }
  }
  public func stop() {
    lock.withLock {
      epoch &+= 1
      if item != nil { metrics.record("compaction_schedule_cancelled") }
      item?.cancel(); item = nil; state = .stopped
    }
  }
  public func cancelPending() {
    lock.withLock {
      guard state != .stopped else { return }
      epoch &+= 1; item?.cancel(); item = nil; state = .idle
    }
  }
}
