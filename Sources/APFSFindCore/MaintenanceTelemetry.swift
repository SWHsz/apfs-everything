import Foundation

/// Samples are process-wide intervals, and can overlap work on other queues.
/// Never sum these as exclusive task CPU attribution.
public final class MaintenanceTelemetry: @unchecked Sendable {
  private struct Active {
    let info:MaintenanceTaskSnapshot, sample:ProcessResourceSample, counters:[String:Int], metrics:Metrics?
    var peak:UInt64=0, checkpoints=0, reason="released_without_completion_marker"
    var lastSample=0.0
  }
  private let lock=NSLock()
  private var sources:[UUID:Metrics]=[:], active:[UUID:Active]=[:]
  private var records:[[String:Any]]=[]
  private var attempts:[String:Int]=[:]
  private var previousProgress:[String:Int]=[:]
  public init() {}
  public func register(volume:UUID,metrics:Metrics) { lock.withLock { sources[volume]=metrics } }
  public func unregister(volume:UUID) { _ = lock.withLock { sources.removeValue(forKey:volume) } }
  private func key(_ t:MaintenanceTaskSnapshot)->String { t.volumeID.uuidString+":"+t.kind.rawValue }
  func start(_ info:MaintenanceTaskSnapshot) {
    let sample=ProcessResourceSample.capture()
    lock.withLock {
      let source=sources[info.volumeID]
      active[info.id]=Active(info:info,sample:sample,counters:source?.snapshot() ?? [:],metrics:source,peak:sample.physicalFootprint ?? 0)
    }
  }
  func checkpoint(_ id:UUID) {
    let now=ProcessInfo.processInfo.systemUptime
    let sampleNow=lock.withLock { ()->Bool in
      guard var a=active[id] else {return false}; a.checkpoints += 1
      let sampleNow=now-a.lastSample>=0.1
      if sampleNow {a.lastSample=now}; active[id]=a; return sampleNow
    }
    if sampleNow { let sample=ProcessResourceSample.capture(); lock.withLock { if var a=active[id] {a.peak=max(a.peak,sample.physicalFootprint ?? 0);active[id]=a} } }
  }
  func reason(_ id:UUID,_ reason:String) { lock.withLock { if var a=active[id] {a.reason=reason;active[id]=a} } }
  /// Backoff follows retryable yields only; completed work clears its retry history.
  func finish(_ id:UUID)->(key:String,delay:Double)? {
    let sample=ProcessResourceSample.capture()
    return lock.withLock {
      guard let a=active.removeValue(forKey:id) else{return nil}
      let taskKey=key(a.info), counters=a.metrics?.snapshot() ?? [:]
      let recordsProcessed=max(0,counters["scanner_entries",default:0]-a.counters["scanner_entries",default:0])
      var data=sample.delta(since:a.sample)
      let retry=a.reason.hasPrefix("yield:")
      let restart=attempts[taskKey,default:0]
      let noProgress=retry && recordsProcessed<=previousProgress[taskKey,default:0]
      if retry { attempts[taskKey]=restart+1;previousProgress[taskKey]=recordsProcessed }
      else if a.reason=="completed" { attempts[taskKey]=0;previousProgress.removeValue(forKey:taskKey) }
      data.merge(["id":id.uuidString,"volume":a.info.volumeID.uuidString,"kind":a.info.kind.rawValue,
        "urgency":String(describing:a.info.urgency),"queued_ms":((a.info.startedAt ?? sample.uptime)-a.info.queuedAt)*1000,
        "running_ms":(sample.uptime-(a.info.startedAt ?? sample.uptime))*1000,"yield_count":retry ? 1:0,
        "restart_count":restart,"records_processed":recordsProcessed,
        "directories_processed":max(0,counters["scanner_directories",default:0]-a.counters["scanner_directories",default:0]),
        "events_replayed":max(0,counters["fsevents_processed",default:0]-a.counters["fsevents_processed",default:0]),
        "peak_physical_footprint":max(a.peak,sample.physicalFootprint ?? 0),"checkpoints":a.checkpoints,
        "termination_reason":a.reason,"no_progress":noProgress,
        "resource_scope":"overlapping process interval; counters include concurrent same-volume work"],uniquingKeysWith:{$1})
      records.append(data); if records.count>128 {records.removeFirst(records.count-128)}
      return (taskKey,retry ? Self.retryDelay(attempt:restart+1):0)
    }
  }
  func cancelledWhileQueued(_ info:MaintenanceTaskSnapshot) {
    lock.withLock {
      records.append(["id":info.id.uuidString,"volume":info.volumeID.uuidString,"kind":info.kind.rawValue,"urgency":String(describing:info.urgency),"queued_ms":(ProcessInfo.processInfo.systemUptime-info.queuedAt)*1000,"running_ms":0,"yield_count":0,"restart_count":attempts[key(info),default:0],"records_processed":0,"directories_processed":0,"events_replayed":0,"user_cpu_seconds":0,"system_cpu_seconds":0,"disk_bytes_read":0,"disk_bytes_written":0,"peak_physical_footprint":0,"termination_reason":"cancelled_while_queued","resource_scope":"no execution interval"])
      if records.count>128 {records.removeFirst(records.count-128)}
    }
  }
  public static func retryDelay(attempt:Int)->Double { min(30,pow(2,Double(max(0,min(attempt-1,5))))) }
  public var snapshot:[[String:Any]] {lock.withLock {records}}
}
