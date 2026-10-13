import APFSFindCore
import CoreServices
import Darwin
import Foundation

/// Equivalent directory pages, not fabricated millions of filesystem files.
/// Both reference and production builder consume exactly this deterministic
/// source; actual getattrlistbulk/FSEvents behavior is tested separately.
struct SyntheticBuildSource:StreamingDirectorySource {
  let entries:Int
  var directories:Int {(entries-1+4096)/4097}
  var files:Int {entries-1-directories}
  static let time:Int64=1700000000000000000
  func rootEntry(identity:VolumeIdentity)throws->ScannedEntry {
    .init(namespace:.init(path:identity.root,kind:.directory,deviceID:identity.deviceID,fileID:identity.rootFileID),
          metadata:.init(modificationTimeNanoseconds:Self.time))
  }
  func pages(path:String,identity:VolumeIdentity,cancellation:CancellationToken,checkpoint:@escaping @Sendable ()throws->Void,visit:@escaping @Sendable ([ScannedEntry])throws->Void)throws {
    if path==identity.root {
      for start in stride(from:0,to:directories,by:4096) {
        try checkpoint();try visit((start..<min(start+4096,directories)).map {i in
          let id=directories-1-i
          return .init(namespace:.init(path:path+String(format:"/dir-%06d",id),kind:.directory,deviceID:identity.deviceID,fileID:UInt64(1000000000+id)),
                       metadata:.init(modificationTimeNanoseconds:Self.time+Int64(id)))
        })
      }
    } else {
      guard let dir=Int((path as NSString).lastPathComponent.dropFirst(4)),dir>=0,dir<directories else {throw CLIError.startupFailed("synthetic directory")}
      let start=dir*4096,end=min(start+4096,files)
      for offset in stride(from:start,to:end,by:1024) {
        try checkpoint();try visit((offset..<min(offset+1024,end)).map {i in
          let prefix=i%100 == 0 ? (i%200 == 0 ? "Café-" : "Cafe\u{301}-") : "File-"
          let name=prefix+String(format:"%010d.dat",i)
          return .init(namespace:.init(path:path+"/"+name,kind:.file,deviceID:identity.deviceID,fileID:UInt64(i+1)),metadata:Self.fileMetadata(i))
        })
      }
    }
  }
  static func fileMetadata(_ i:Int)->FileMetadataValue {.init(logicalSize:UInt64(i%65536+1),modificationTimeNanoseconds:time+Int64(i)*3)}
}
struct StreamingBuildBenchmarkRunner {
  let entries:Int,reference:Bool,recovery:Bool
  func run() throws -> Int32 {
    let root=try OwnedTemporaryDirectory(),cache=try OwnedTemporaryDirectory()
    defer {try? root.remove();try? cache.remove()}
    let identity=try VolumeIdentity.discover(root:root.url.path),source=SyntheticBuildSource(entries:entries)
    var report:[String:Any]=["benchmark":recovery ? "recovery-build" : "cold-build","version":"0.6.4","entries":entries,
      "source":"equivalent synthetic paged namespace, 4096-file directories; not real filesystem enumeration",
      "builder":reference ? "explicit RAM FileIndex + existing SnapshotV2Writer reference" : "production disk-backed streaming builder",
      "namespace_format":2,"metadata_format":1]
    let before=ProcessResourceSample.capture()
    if recovery {
      let rootPath=identity.root
      let c=try PersistentIndexCoordinator(root:rootPath,configuration:.init(fullRebuildMinInterval:0),cacheDirectory:cache.url.path,
        maintenanceScheduler:.init(),replayStarter:{id,deliver in deliver([.init(path:rootPath,flags:UInt32(kFSEventStreamEventFlagHistoryDone),id:id)])},
        fenceProvider:{_ in 7},streamingSource:source)
      defer {c.stop(policy:.fast)}
      try c.start();guard c.waitUntilLive(timeout:300) else {throw CLIError.startupFailed("synthetic cold start")}
      let old=(c.index as! HybridIndex).immutableBase!,oldUUID=old.header.snapshotUUID
      let rebuildBefore=ProcessResourceSample.capture()
      c.rebuild()
      var queryCount=0,queryFailures=0,maxQueryMS=0.0
      let deadline=ProcessInfo.processInfo.systemUptime+600
      while c.metrics.snapshot()["full_rebuilds",default:0]==0 && ProcessInfo.processInfo.systemUptime<deadline {
        let result=c.search("File-0000000001.dat",limit:5)
        queryCount+=1;if result.hits.count != 1 {queryFailures+=1};maxQueryMS=max(maxQueryMS,result.latencyMilliseconds)
        // Bounded sampling, rather than continuously pinning every CPU chunk.
        Thread.sleep(forTimeInterval:0.1)
      }
      guard c.waitUntilLive(timeout:30),c.metrics.snapshot()["full_rebuilds"]==1,queryFailures==0 else {throw CLIError.startupFailed("synthetic recovery/query continuity")}
      let current=(c.index as! HybridIndex).immutableBase!
      guard current.count==entries,current.header.snapshotUUID != oldUUID,try old.name(at:1).hasPrefix("dir-") else {throw CLIError.startupFailed("retained old base")}
      report["recovery_resources"]=ProcessResourceSample.capture().delta(since:rebuildBefore)
      report["old_base_queries"]=queryCount;report["old_base_query_failures"]=queryFailures;report["max_query_ms"]=maxQueryMS
      report["retained_old_base_valid"]=true;report["full_scans"]=c.metrics.snapshot()["full_scans",default:0]
      report["temporary_peak_bytes"]=c.metrics.snapshot()["streaming_temporary_peak_bytes",default:0]
      report["temporary_allocated_peak_bytes"]=c.metrics.snapshot()["streaming_temporary_allocated_peak_bytes",default:0]
      report["section_logical_writes_last_build"]=c.metrics.snapshot()["streaming_logical_writes",default:0]
      report["final_bytes"]=current.header.fileLength+c.metadata.capture().base!.header.fileLength
      report["materialized_file_entries"]=(c.index as! HybridIndex).hybridStats()["materialized_file_entries"]
      report["recovery_verified"]=true
    } else if reference {
      let store=try SnapshotStore(directory:cache.url.path,identity:identity),ram=FileIndex(root:identity.root),token=CancellationToken()
      let rootEntry=try source.rootEntry(identity:identity);ram.apply([.upsert(rootEntry.namespace)])
      let apply:@Sendable ([ScannedEntry])throws->Void={ram.apply($0.map { .upsert($0.namespace) })}
      try source.pages(path:identity.root,identity:identity,cancellation:token,checkpoint:{},visit:apply)
      for i in 0..<source.directories {try source.pages(path:identity.root+String(format:"/dir-%06d",i),identity:identity,cancellation:token,checkpoint:{},visit:apply)}
      let result=try SnapshotV2Writer.write(source:.ram(ram,ram.stats().generation),identity:identity,generation:1,cursor:7,store:store)
      let base=try store.reader(expectedIdentity:identity).immutableBase!
      let metadata=try MetadataWriter.write(store:store,base:result.header,cursor:7,value:{ordinal in
        if ordinal==0 {return rootEntry.metadata}
        let record=try base.record(at:ordinal)
        if record.kind == .directory {return .init(modificationTimeNanoseconds:SyntheticBuildSource.time+Int64(record.fileID-1000000000))}
        return SyntheticBuildSource.fileMetadata(Int(record.fileID-1))
      })
      report["final_bytes"]=result.header.fileLength+metadata.fileLength
      report["materialized_file_entries"]=ram.stats().liveEntries
      report["reference_limit"]="lower-bound old path: page batches fill RAM graph; does not additionally retain BulkScanner ScanResult array"
    } else {
      let store=try SnapshotStore(directory:cache.url.path,identity:identity),metrics=Metrics()
      let sealed=try DiskBackedNamespaceBuilder(identity:identity,store:store,source:source,metrics:metrics).build(generation:1,cursor:7)
      try sealed.publish()
      guard sealed.namespace.count==entries,try sealed.namespace.record(at:0).subtreeEnd==entries else {throw CLIError.startupFailed("streaming record count")}
      // Sample exact names/columns and child lookup, without a full RAM oracle.
      for id in [UInt32(1),UInt32(entries/2),UInt32(entries-1)] {
        let record=try sealed.namespace.record(at:id),value=try sealed.metadata.value(at:id)
        let expected=record.kind == .file ? SyntheticBuildSource.fileMetadata(Int(record.fileID-1)) : .init(modificationTimeNanoseconds:SyntheticBuildSource.time+Int64(record.fileID-1000000000))
        guard value==expected else {throw CLIError.startupFailed("synthetic exact metadata")}
      }
      report["temporary_peak_bytes"]=sealed.temporaryPeakBytes
      report["temporary_allocated_peak_bytes"]=sealed.temporaryAllocatedPeakBytes
      report["section_logical_writes"]=sealed.logicalWrites
      report["final_bytes"]=sealed.result.header.fileLength+sealed.metadata.header.fileLength
      report["materialized_file_entries"]=0;report["correctness_samples_passed"]=true
      report["metrics"]=metrics.snapshot()
    }
    let after=ProcessResourceSample.capture(),wall=after.uptime-before.uptime
    report["resources"]=after.delta(since:before);report["process"]=after.dictionary
    report["wall_seconds"]=wall;report["entries_per_second"]=Double(entries)/wall
    report["physical_peak_limit_bytes"]=500*1024*1024
    let passed=reference || (after.peakPhysicalFootprint.map {$0<=500*1024*1024} ?? false)
    report["physical_peak_gate_passed"]=passed
    print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),as:UTF8.self))
    return passed ? 0 : 1
  }
}
