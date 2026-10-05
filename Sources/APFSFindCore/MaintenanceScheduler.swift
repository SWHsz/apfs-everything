import Foundation

public enum MaintenanceKind: String, Sendable { case coldScan, rebuild, compaction }
public struct MaintenanceTaskSnapshot: Sendable {
  public let id: UUID
  public let volumeID: UUID
  public let kind: MaintenanceKind
  public let queuedAt: Double
  public let startedAt: Double?
}
public final class MaintenanceLease: @unchecked Sendable {
  private let lock = NSLock()
  private var released = false
  private let scheduler: MaintenanceScheduler
  private let token: CancellationToken
  private let observer: UUID
  public let id: UUID
  init(id: UUID, scheduler: MaintenanceScheduler, token: CancellationToken, observer: UUID) {
    self.id = id; self.scheduler = scheduler; self.token = token; self.observer = observer
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
  public static let shared = MaintenanceScheduler()
  private struct Pending {
    let info: MaintenanceTaskSnapshot
    let priority: Int
    let token: CancellationToken
    let observer: UUID
    let continuation: CheckedContinuation<MaintenanceLease, Error>
  }
  private var pending: [Pending] = []
  private var running: MaintenanceTaskSnapshot?
  public init() {}
  public func acquire(volumeID: UUID, kind: MaintenanceKind, priority: Int = 0,
                      cancellation: CancellationToken) async throws -> MaintenanceLease {
    let id = UUID()
    return try await withCheckedThrowingContinuation { continuation in
      let observer = cancellation.onCancel { [weak self] in Task { await self?.cancel(id) } }
      pending.append(.init(info: .init(id: id, volumeID: volumeID, kind: kind,
                                     queuedAt: ProcessInfo.processInfo.systemUptime, startedAt: nil),
                           priority: priority, token: cancellation, observer: observer, continuation: continuation))
      pump()
    }
  }
  public func cancelQueued(volumeID: UUID) {
    let ids = pending.filter { $0.info.volumeID == volumeID }.map { $0.info.id }
    for id in ids { cancel(id) }
  }
  private func cancel(_ id: UUID) {
    if let i = pending.firstIndex(where: { $0.info.id == id }) {
      let item = pending.remove(at: i); item.token.removeCancellationHandler(item.observer); item.continuation.resume(throwing: CocoaError(.userCancelled))
    }
  }
  fileprivate func release(_ id: UUID) {
    guard running?.id == id else { return }; running = nil; pump()
  }
  private func pump() {
    guard running == nil else { return }
    pending.sort { $0.priority == $1.priority ? $0.info.queuedAt < $1.info.queuedAt : $0.priority > $1.priority }
    while !pending.isEmpty {
      let next = pending.removeFirst()
      if next.token.isCancelled { next.token.removeCancellationHandler(next.observer); next.continuation.resume(throwing: CocoaError(.userCancelled)); continue }
      running = .init(id: next.info.id, volumeID: next.info.volumeID, kind: next.info.kind,
                      queuedAt: next.info.queuedAt, startedAt: ProcessInfo.processInfo.systemUptime)
      next.continuation.resume(returning: MaintenanceLease(id: next.info.id, scheduler: self, token: next.token, observer: next.observer)); break
    }
  }
  public func snapshot() -> [MaintenanceTaskSnapshot] { (running.map { [$0] } ?? []) + pending.map(\.info) }
  /// Bridge for existing dedicated scan/checkpoint queues, never the main thread.
  nonisolated public func acquireBlocking(volumeID: UUID, kind: MaintenanceKind, priority: Int = 0,
                                          cancellation: CancellationToken) throws -> MaintenanceLease {
    let box = LeaseResult()
    Task.detached {
      let result: Result<MaintenanceLease, Error>
      do { result = .success(try await self.acquire(volumeID: volumeID, kind: kind, priority: priority, cancellation: cancellation)) }
      catch { result = .failure(error) }
      box.lock.withLock { box.result = result }; box.semaphore.signal()
    }
    box.semaphore.wait()
    return try box.lock.withLock { try box.result!.get() }
  }
}
