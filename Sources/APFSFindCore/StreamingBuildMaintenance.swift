import Foundation

/// A yielded builder retains its workspace and pre-enumeration fence. Only the
/// scheduler lease is released/reacquired; no enumeration or recovery restarts.
final class StreamingBuildMaintenance: @unchecked Sendable {
  private let scheduler:MaintenanceScheduler,volume:UUID,kind:MaintenanceKind
  private let token=CancellationToken(),outer:CancellationToken
  private let identityCheck:@Sendable ()throws->Void
  private let changed:@Sendable (MaintenanceLease?)->Void
  private let metrics:Metrics,urgency:MaintenanceUrgency
  private var lease:MaintenanceLease?
  private var cancelObserver:UUID?,pressureObserver:UUID?
  init(scheduler:MaintenanceScheduler,volume:UUID,kind:MaintenanceKind,cancellation:CancellationToken,
       metrics:Metrics,urgency:MaintenanceUrgency = .required,identityCheck:@escaping @Sendable ()throws->Void,
       changed:@escaping @Sendable (MaintenanceLease?)->Void) throws {
    self.scheduler=scheduler;self.volume=volume;self.kind=kind;outer=cancellation;self.metrics=metrics;self.urgency=urgency
    self.identityCheck=identityCheck;self.changed=changed
    cancelObserver=cancellation.onCancel {[token] in token.cancel()}
    pressureObserver=scheduler.signals?.observe {[token] value in if value.memoryPressure == .critical {token.cancel()}}
    if cancellation.isCancelled || scheduler.signals?.current().memoryPressure == .critical {token.cancel()}
    do {try acquire()} catch {
      if let cancelObserver {outer.removeCancellationHandler(cancelObserver);self.cancelObserver=nil}
      if let pressureObserver {scheduler.signals?.removeObserver(pressureObserver);self.pressureObserver=nil}
      throw error
    }
  }
  private func acquire() throws {
    try waitForQueriesAndThermal()
    let next=try scheduler.acquireBlocking(volumeID:volume,kind:kind,urgency:urgency,cancellation:token)
    next.validateIdentity(identityCheck);lease=next;changed(next)
  }
  private func waitForQueriesAndThermal() throws {
    guard let provider=scheduler.signals else {return}
    let wake=DispatchSemaphore(value:0)
    let observer=provider.observe {_ in wake.signal()}
    let cancelled=token.onCancel {wake.signal()}
    defer {provider.removeObserver(observer);token.removeCancellationHandler(cancelled)}
    while true {
      if token.isCancelled {throw SnapshotError.cancelled}
      let s=provider.current()
      if s.memoryPressure == .critical {throw SnapshotError.cancelled}
      if s.thermalState != .serious && s.thermalState != .critical && s.activeQueries==0 {return}
      // Notification-driven wait, only for an active job; no idle timer.
      wake.wait()
    }
  }
  func checkpoint() throws {
    while true {
      if token.isCancelled {throw SnapshotError.cancelled}
      do {
        let signal=scheduler.signals?.current()
        if signal?.thermalState == .serious || signal?.thermalState == .critical || (signal?.activeQueries ?? 0)>0 {throw MaintenanceYield(reason:"streaming query/thermal")}
        try lease?.checkpoint();return
      } catch is MaintenanceYield {
        metrics.record("maintenance_yields");metrics.record("streaming_build_resumes")
        lease?.release();lease=nil;changed(nil)
        try acquire()
      }
    }
  }
  func release() {lease?.release();lease=nil;changed(nil)}
  deinit {
    release()
    if let cancelObserver {outer.removeCancellationHandler(cancelObserver)}
    if let pressureObserver {scheduler.signals?.removeObserver(pressureObserver)}
  }
}

/// Core owns the publication point; persistence supplies a sealed pair, not a
/// temporary RAM namespace. The retained lease spans final cursor installation.
final class PreparedStreamingBuild: @unchecked Sendable {
  let install:@Sendable ()throws->Void
  let identity:VolumeIdentity,fence:UInt64
  var maintenance:StreamingBuildMaintenance?
  init(identity:VolumeIdentity,fence:UInt64,install:@escaping @Sendable ()throws->Void) {self.identity=identity;self.fence=fence;self.install=install}
  func release() {maintenance?.release();maintenance=nil}
  deinit {release()}
}
