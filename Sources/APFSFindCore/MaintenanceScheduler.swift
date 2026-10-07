import Foundation

public enum MaintenanceKind: String, Sendable { case coldScan, rebuild, compaction, metadataBootstrap, metadataCheckpoint }
public enum MaintenanceUrgency: Int, Sendable { case opportunistic, required, emergency }
public enum MaintenanceOperatingState: String, Sendable { case interactive, busy, opportunistic, maintaining, emergency, suspended }
public struct MaintenancePolicy: Sendable {
  public var startIdle = 0.60, yieldIdle = 0.30, forcedIdle = 0.15
  public var idleSeconds = 10.0, busySeconds = 2.0, quietSeconds = 10.0
  public init() {}
}
public struct InternalResourcePressure: Sendable {
  public var namespaceEntries = 0, namespaceBytes = 0, metadataEntries = 0, metadataBytes = 0
  public var tombstones = 0, tombstoneRatio = 0.0, pendingMetadata = 0, eventQueueDepth = 0, dirtyDirectories = 0
  public var cursorGap: UInt64 = 0
  public var storageError = false
  public init() {}
  public var emergency: Bool { namespaceEntries >= 500_000 || namespaceBytes >= 128*1024*1024 || metadataBytes >= 128*1024*1024 || pendingMetadata >= 100_000 || eventQueueDepth >= 100_000 || cursorGap > 1_000_000 }
}
public struct MaintenanceYield: Error, Sendable, CustomStringConvertible {
  public let reason: String
  public var description: String { "Maintenance deferred: \(reason)" }
}
public struct MaintenanceTaskSnapshot: Sendable {
  public let id: UUID, volumeID: UUID
  public let kind: MaintenanceKind
  public let queuedAt: Double, startedAt: Double?
  public let urgency: MaintenanceUrgency
}
private final class ResourceGate: @unchecked Sendable {
  let provider: (any ResourceSignalProviding)?
  let policy: MaintenancePolicy
  private let lock = NSLock()
  private var idleSince: Double?, busySince: Double?
  private var lastTimestamp = -Double.infinity
  private var pressures: [UUID: InternalResourcePressure] = [:]
  init(_ provider: (any ResourceSignalProviding)?, _ policy: MaintenancePolicy) { self.provider = provider; self.policy = policy }
  func update(_ snapshot: ResourceSnapshot) {
    lock.withLock {
      guard snapshot.timestamp >= lastTimestamp else { return }; lastTimestamp = snapshot.timestamp
      if (snapshot.cpuIdleEWMA ?? 0) >= policy.startIdle { idleSince = idleSince ?? snapshot.timestamp } else { idleSince = nil }
      if (snapshot.cpuIdleEWMA ?? 1) < policy.yieldIdle { busySince = busySince ?? snapshot.timestamp } else { busySince = nil }
    }
  }
  func pressure(_ value: InternalResourcePressure, volume: UUID) { lock.withLock { pressures[volume] = value } }
  func clear() { lock.withLock { idleSince = nil; busySince = nil } }
  func state(urgency: MaintenanceUrgency, volume: UUID, starting: Bool) -> MaintenanceOperatingState {
    guard let provider else { return urgency == .emergency ? .emergency : .opportunistic }
    let s = provider.current()
    return lock.withLock {
      let internalValue = pressures[volume] ?? .init()
      if urgency == .emergency || internalValue.emergency { return .emergency }
      if s.memoryPressure == .critical { return .suspended }
      if s.activeQueries > 0 || s.interactive || (urgency == .opportunistic && s.lastInteractionAge < policy.quietSeconds) { return .interactive }
      if urgency == .required { return .opportunistic }
      if s.memoryPressure != .normal || s.thermalState == .serious || s.thermalState == .critical || s.lowPowerMode || internalValue.eventQueueDepth > 64 || internalValue.dirtyDirectories > 16 || internalValue.storageError { return .busy }
      if starting {
        guard let since = idleSince, s.timestamp-since >= policy.idleSeconds, (s.cpuIdleEWMA ?? 0) >= policy.startIdle else { return .busy }
      } else if (s.cpuIdleEWMA ?? 1) < policy.forcedIdle || (busySince.map { s.timestamp-$0 >= policy.busySeconds } ?? false) { return .busy }
      return .opportunistic
    }
  }
}
public final class MaintenanceLease: @unchecked Sendable {
  private let lock = NSLock()
  private var released = false
  private var identityCheck: (@Sendable () throws -> Void)?
  private var lastIdentityCheck = -Double.infinity
  private let scheduler: MaintenanceScheduler
  private let token: CancellationToken
  private let observer: UUID
  private let gate: ResourceGate
  public let id: UUID, volumeID: UUID
  public let urgency: MaintenanceUrgency
  fileprivate init(id: UUID, volume: UUID, urgency: MaintenanceUrgency, scheduler: MaintenanceScheduler, token: CancellationToken, observer: UUID, gate: ResourceGate) {
    self.id = id; volumeID = volume; self.urgency = urgency; self.scheduler = scheduler; self.token = token; self.observer = observer; self.gate = gate
  }
  /// Called between bounded chunks on utility queues. A yielded job restarts
  /// from its last immutable base; its staging file never becomes visible.
  public func validateIdentity(_ check: @escaping @Sendable () throws -> Void) { lock.withLock { identityCheck = check } }
  public func checkpoint() throws {
    let check = lock.withLock { () -> (@Sendable () throws -> Void)? in
      let now = ProcessInfo.processInfo.systemUptime
      guard now-lastIdentityCheck >= 0.1 else { return nil }; lastIdentityCheck = now; return identityCheck
    }
    try check?()
    if token.isCancelled { throw SnapshotError.cancelled }
    let state = gate.state(urgency: urgency, volume: volumeID, starting: false)
    if state == .suspended || state == .interactive || (urgency == .opportunistic && state == .busy) {
      throw MaintenanceYield(reason: state.rawValue)
    }
    if state == .emergency { Thread.sleep(forTimeInterval: 0.001) }
  }
  public var workerLimit: Int {
    guard let s = gate.provider?.current() else { return 4 }
    return (s.cpuIdleEWMA ?? 0) >= gate.policy.startIdle && s.memoryPressure == .normal && !s.lowPowerMode && s.thermalState != .serious && s.thermalState != .critical ? 4 : 1
  }
  public func release() {
    guard lock.withLock({ if released { return false }; released = true; return true }) else { return }
    token.removeCancellationHandler(observer)
    let owner = scheduler, leaseID = id
    Task { await owner.release(leaseID) }
  }
  deinit { release() }
}
private final class LeaseResult: @unchecked Sendable {
  let lock = NSLock()
  var result: Result<MaintenanceLease, Error>?
  let semaphore = DispatchSemaphore(value: 0)
}
public actor MaintenanceScheduler {
  public static let shared = MaintenanceScheduler(signals: SystemResourceSignals.shared)
  private struct Pending {
    let info: MaintenanceTaskSnapshot
    let priority: Int
    let token: CancellationToken
    let observer: UUID
    let continuation: CheckedContinuation<MaintenanceLease, Error>
  }
  private let gate: ResourceGate
  nonisolated public let signals: (any ResourceSignalProviding)?
  private var signalObserver: UUID?
  private var pending: [Pending] = []
  private var running: MaintenanceTaskSnapshot?
  public let metrics = Metrics()
  /// Explicit jobs/tests can opt out of resource gating; production uses shared.
  public init(signals: (any ResourceSignalProviding)? = nil, policy: MaintenancePolicy = .init()) { self.signals = signals; gate = ResourceGate(signals, policy) }
  deinit { if let signalObserver { signals?.removeObserver(signalObserver) } }
  public func updatePressure(_ pressure: InternalResourcePressure, volumeID: UUID) { gate.pressure(pressure, volume: volumeID); pump() }
  public func acquire(volumeID: UUID, kind: MaintenanceKind, priority: Int = 0, urgency: MaintenanceUrgency = .required,
                      cancellation: CancellationToken) async throws -> MaintenanceLease {
    if signalObserver == nil, let provider = gate.provider {
      signalObserver = provider.observe { [weak self] s in Task { await self?.signal(s) } }
    }
    let id = UUID()
    return try await withCheckedThrowingContinuation { continuation in
      let observer = cancellation.onCancel { [weak self] in Task { await self?.cancel(id) } }
      pending.append(.init(info: .init(id: id, volumeID: volumeID, kind: kind, queuedAt: ProcessInfo.processInfo.systemUptime, startedAt: nil, urgency: urgency), priority: priority, token: cancellation, observer: observer, continuation: continuation))
      gate.provider?.setSamplingEnabled(true)
      if let value = gate.provider?.current() { gate.update(value) }
      pump()
    }
  }
  private func signal(_ value: ResourceSnapshot) { gate.update(value); pump() }
  public func cancelQueued(volumeID: UUID) { for id in pending.filter({ $0.info.volumeID == volumeID }).map(\.info.id) { cancel(id) } }
  private func cancel(_ id: UUID) {
    if let i = pending.firstIndex(where: { $0.info.id == id }) {
      let item = pending.remove(at: i); item.token.removeCancellationHandler(item.observer); item.continuation.resume(throwing: CocoaError(.userCancelled))
    }
    pump()
  }
  fileprivate func release(_ id: UUID) { guard running?.id == id else { return }; running = nil; pump() }
  private func pump() {
    if pending.isEmpty && running == nil { gate.provider?.setSamplingEnabled(false); gate.clear(); metrics.set("maintenance_pending",to:0); metrics.set("maintenance_running",to:0); return }
    metrics.set("maintenance_pending",to:pending.count); metrics.set("maintenance_running",to:running == nil ? 0 : 1)
    guard running == nil else { return }
    pending.sort { $0.info.urgency == $1.info.urgency ? ($0.priority == $1.priority ? $0.info.queuedAt < $1.info.queuedAt : $0.priority > $1.priority) : $0.info.urgency.rawValue > $1.info.urgency.rawValue }
    var i = 0
    while i < pending.count {
      let next = pending[i]
      if next.token.isCancelled { pending.remove(at:i); next.token.removeCancellationHandler(next.observer); next.continuation.resume(throwing:CocoaError(.userCancelled)); continue }
      let state = gate.state(urgency:next.info.urgency,volume:next.info.volumeID,starting:true)
      if state == .busy || state == .interactive || state == .suspended { metrics.record("maintenance_deferred"); i += 1; continue }
      pending.remove(at:i)
      running = .init(id:next.info.id,volumeID:next.info.volumeID,kind:next.info.kind,queuedAt:next.info.queuedAt,startedAt:ProcessInfo.processInfo.systemUptime,urgency:next.info.urgency)
      metrics.record(state == .emergency ? "maintenance_emergency_starts" : "maintenance_starts")
      next.continuation.resume(returning: MaintenanceLease(id:next.info.id,volume:next.info.volumeID,urgency:next.info.urgency,scheduler:self,token:next.token,observer:next.observer,gate:gate)); break
    }
    if pending.isEmpty && running == nil { gate.provider?.setSamplingEnabled(false); gate.clear() }
  }
  public func operatingState(volumeID: UUID) -> MaintenanceOperatingState {
    let urgency = running?.urgency ?? pending.first?.info.urgency ?? .opportunistic
    let value = gate.state(urgency:urgency,volume:volumeID,starting:running == nil)
    return running != nil && value == .opportunistic ? .maintaining : value
  }
  public func snapshot() -> [MaintenanceTaskSnapshot] { (running.map { [$0] } ?? []) + pending.map(\.info) }
  nonisolated public func acquireBlocking(volumeID: UUID, kind: MaintenanceKind, priority: Int = 0, urgency: MaintenanceUrgency = .required,
                                          cancellation: CancellationToken) throws -> MaintenanceLease {
    let box = LeaseResult()
    Task.detached {
      let result: Result<MaintenanceLease, Error>
      do { result = .success(try await self.acquire(volumeID:volumeID,kind:kind,priority:priority,urgency:urgency,cancellation:cancellation)) }
      catch { result = .failure(error) }
      box.lock.withLock { box.result = result }; box.semaphore.signal()
    }
    box.semaphore.wait()
    return try box.lock.withLock { try box.result!.get() }
  }
}
