import Foundation

/// Only the opt-in benchmark polls this value. Production remains event-driven.
public struct QuietVolumeState: Sendable {
  public let volumeID:UUID
  public var state:VolumeSessionState, metadataFreshness:MetadataFreshness, metadataAvailable:Bool
  public var namespaceGeneration:UInt64, metadataGeneration:UInt64
  public var namespaceEvents=0, metadataPending=0, dirtyDirectories=0
  public var compactionScheduled=false, metadataMaintenanceScheduled=false
  public init(volumeID:UUID,state:VolumeSessionState,metadataFreshness:MetadataFreshness,metadataAvailable:Bool,
              namespaceGeneration:UInt64,metadataGeneration:UInt64) {
    self.volumeID=volumeID;self.state=state;self.metadataFreshness=metadataFreshness;self.metadataAvailable=metadataAvailable
    self.namespaceGeneration=namespaceGeneration;self.metadataGeneration=metadataGeneration
  }
}
public struct QuietGateResult: Sendable {
  public let quiet:Bool, stableSeconds:Double, blockers:[String]
  public init(quiet:Bool,stableSeconds:Double,blockers:[String]) {self.quiet=quiet;self.stableSeconds=stableSeconds;self.blockers=blockers}
}
public struct QuietStateGate: Sendable {
  private var candidateSince:Double?
  private var generations:[UUID:[UInt64]]=[:]
  public init() {}
  public mutating func observe(_ volumes:[QuietVolumeState],tasks:[MaintenanceTaskSnapshot],now:Double) -> QuietGateResult {
    var blockers:[String]=[];var current:[UUID:[UInt64]]=[:]
    if volumes.isEmpty { blockers.append("no sessions") }
    for v in volumes {
      let id=v.volumeID.uuidString
      current[v.volumeID]=[v.namespaceGeneration,v.metadataGeneration]
      if v.state != .live { blockers.append(id+": namespace "+v.state.description) }
      if !v.metadataAvailable || v.metadataFreshness != .live { blockers.append(id+": metadata "+v.metadataFreshness.rawValue) }
      if v.namespaceEvents>0 { blockers.append(id+": namespace events \(v.namespaceEvents)") }
      if v.metadataPending>0 { blockers.append(id+": metadata pending \(v.metadataPending)") }
      if v.dirtyDirectories>0 { blockers.append(id+": dirty directories \(v.dirtyDirectories)") }
      if v.compactionScheduled { blockers.append(id+": compaction scheduled") }
      if v.metadataMaintenanceScheduled { blockers.append(id+": metadata maintenance scheduled") }
    }
    for t in tasks { blockers.append(t.volumeID.uuidString+": "+t.kind.rawValue+" "+(t.startedAt == nil ? "queued" : "running")) }
    let changed=current != generations
    generations=current
    if !blockers.isEmpty { candidateSince=nil }
    else if changed || candidateSince == nil { candidateSince=now }
    let stable=candidateSince.map { max(0,now-$0) } ?? 0
    return .init(quiet:blockers.isEmpty && stable>=30,stableSeconds:stable,blockers:blockers)
  }
}
