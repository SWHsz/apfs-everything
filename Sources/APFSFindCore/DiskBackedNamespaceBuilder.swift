import Darwin
import Foundation

public enum StreamingBuildFailurePoint: Sendable {case afterSections, beforeValidation, afterValidation}
public final class SealedStreamingSnapshot: @unchecked Sendable {
  public let namespace: any ImmutableNamespaceBase
  public let metadata: any ImmutableMetadataBase
  public let result: SnapshotWriteResult
  public let temporaryPeakBytes: UInt64, temporaryAllocatedPeakBytes: UInt64, logicalWrites: UInt64
  public let unreadableDirectories: Int
  let workspace: SnapshotBuildWorkspace
  init(namespace:any ImmutableNamespaceBase,metadata:any ImmutableMetadataBase,workspace:SnapshotBuildWorkspace,
       milliseconds:Double,unreadable:Int) {
    self.namespace=namespace;self.metadata=metadata;self.workspace=workspace;unreadableDirectories=unreadable
    result = .init(header:namespace.header,durationMilliseconds:milliseconds,peakResidentBytes:ProcessResourceSample.capture().peakRSSBytes)
    temporaryPeakBytes=workspace.peakTemporaryBytes;temporaryAllocatedPeakBytes=workspace.peakAllocatedBytes;logicalWrites=workspace.logicalWrites
  }
  /// Readers retain the sealed inodes across rename. No file copying, CRC walk
  /// or whole-tree lock is needed in the runtime's final writer transaction.
  public func publish(beforePublish:()throws->Void = {},fault:((SnapshotFailurePoint)throws->Void)? = nil) throws {
    try workspace.store.publishBuild(workspace,beforePublish:beforePublish,fault:fault)
  }
}

/// One worker. RAM is a page, binary merge heads, DFS frames and bounded section
/// buffers. There is no FileIndex, record array, reference array or path map.
public final class DiskBackedNamespaceBuilder: @unchecked Sendable {
  private let identity:VolumeIdentity,store:SnapshotStore,source:any StreamingDirectorySource
  private let metrics:Metrics,signals:(any ResourceSignalProviding)?
  private let cancellation:CancellationToken
  private let checkpoint:@Sendable ()throws->Void
  private let fault:(@Sendable (StreamingBuildFailurePoint,SnapshotBuildWorkspace)throws->Void)?
  private let metadataFault:(@Sendable (SnapshotFailurePoint)throws->Void)?
  private var workspace:SnapshotBuildWorkspace?
  private var count:UInt32=0,validityByte:UInt8=0,unreadable=0
  private var lastDiskSample=ProcessInfo.processInfo.systemUptime
  private var lastIdentityCheck = -Double.infinity
  public init(identity:VolumeIdentity,store:SnapshotStore,source:(any StreamingDirectorySource)? = nil,
              metrics:Metrics = .init(),signals:(any ResourceSignalProviding)? = nil,
              cancellation:CancellationToken = .init(),checkpoint:@escaping @Sendable ()throws->Void = {},
              fault:(@Sendable (StreamingBuildFailurePoint,SnapshotBuildWorkspace)throws->Void)? = nil,
              metadataFault:(@Sendable (SnapshotFailurePoint)throws->Void)? = nil) {
    self.identity=identity;self.store=store;self.source=source ?? BulkStreamingDirectorySource(excludedRoots:[store.directory],metrics:metrics)
    self.metadataFault=metadataFault;self.metrics=metrics;self.signals=signals;self.cancellation=cancellation;self.checkpoint=checkpoint;self.fault=fault
  }
  private func check() throws {
    guard !cancellation.isCancelled, signals?.current().memoryPressure != .critical else {throw SnapshotError.cancelled}
    try checkpoint()
    if let workspace {
      let now=ProcessInfo.processInfo.systemUptime
      if now-lastIdentityCheck>=0.1 {try workspace.checkIdentity();lastIdentityCheck=now}
      if signals?.current().memoryPressure == .warning {try workspace.shrinkBuffers()}
      if now-lastDiskSample>=0.1 {try workspace.sampleDisk();lastDiskSample=now}
    }
  }
  private func listing(_ path:String,isRoot:Bool) throws -> BuildRun {
    let w=workspace!,sorter=try BuildDirectorySorter(workspace:w,identity:identity,metrics:metrics,check:{[self] in try check()})
    do {
      try source.pages(path:path,identity:identity,cancellation:cancellation,checkpoint:{[self] in try check()},visit:{try sorter.page($0)})
    } catch let error as ScannerError {
      if isRoot {throw error}
      switch error.code {
      case ENOENT,ENOTDIR,ELOOP,EXDEV:metrics.record("scanner_races")
      case EACCES,EPERM:unreadable+=1;metrics.record("scanner_unreadable_directories");metrics.record("scanner_permission_denied")
      case ENODATA:unreadable+=1;metrics.record("scanner_unreadable_directories");metrics.record("scanner_dataless_skips")
      default:unreadable+=1;metrics.record("scanner_unreadable_directories");metrics.record("scanner_errors")
      }
      // A partial failed directory must never become a complete listing.
      return .init(start:w.section("listings").length,end:w.section("listings").length,count:0)
    }
    let run=try sorter.finish();try w.sampleDisk();return run
  }
  private final class Frame {
    let ordinal:UInt32,firstChild:UInt32,path:String,reader:BuildRunReader
    var child=0
    init(ordinal:UInt32,first:UInt32,path:String,reader:BuildRunReader) {self.ordinal=ordinal;firstChild=first;self.path=path;self.reader=reader}
  }
  private func append(_ item:BuildItem,parent:UInt32,path:String,slot:UInt64?) throws -> Frame? {
    let w=workspace!
    guard UInt64(count)<SnapshotFormat.maxRecords else {throw SnapshotError.invalid("streaming record limit")}
    let ordinal=count
    let run=item.kind == .directory && !item.boundary ? try listing(path,isRoot:ordinal==0) : nil
    let childCount=run?.count ?? 0,first=w.section("children").length/4
    guard first+UInt64(childCount)<=SnapshotFormat.maxRecords else {throw SnapshotError.invalid("streaming child limit")}
    try w.section("children").reserve(UInt64(childCount)*4)
    if let slot {var bytes=Data(repeating:0,count:4);bytes.put(ordinal,at:0);try w.section("children").patch(bytes,at:slot)}
    let name=w.section("original"),fold=w.section("folded")
    guard name.length<=UInt32.max,fold.length<=UInt32.max else {throw SnapshotError.invalid("streaming blob limit")}
    let r=BaseRecord(parent:parent,firstChild:UInt32(first),childCount:childCount,subtreeEnd:ordinal+1,
      nameOffset:UInt32(name.length),foldedOffset:UInt32(fold.length),nameLength:UInt16(item.name.utf8.count),foldedLength:UInt16(item.folded.utf8.count),
      kind:item.kind,flags:item.boundary ? 1 : 0,fileID:item.fileID)
    try w.section("records").append(r.encoded)
    try name.append(Data(item.name.utf8));try fold.append(Data(item.folded.utf8))
    var size=Data(repeating:0,count:8),time=Data(repeating:0,count:8)
    let knownSize=item.kind == .file ? item.metadata.logicalSize : nil
    size.put(knownSize ?? 0,at:0);time.put(item.metadata.modificationTimeNanoseconds ?? 0,at:0)
    try w.section("sizes").append(size);try w.section("times").append(time)
    let flags:UInt8=(knownSize == nil ? 0 : 1) | (item.metadata.modificationTimeNanoseconds == nil ? 0 : 2)
    validityByte |= flags << ((ordinal%4)*2)
    count+=1
    if count%4==0 {try w.section("validity").append(Data([validityByte]));validityByte=0}
    metrics.set("streaming_build_records",to:Int(count))
    if let run,run.count>0 {return Frame(ordinal:ordinal,first:UInt32(first),path:path,reader:BuildRunReader(w.section("listings"),run))}
    return nil
  }
  public func build(generation:UInt64,cursor:UInt64) throws -> SealedStreamingSnapshot {
    guard workspace==nil,count==0 else {throw SnapshotError.invalid("builder is single use")}
    let start=ProcessResourceSample.capture()
    let w=try store.createBuildWorkspace();workspace=w
    defer {workspace=nil}
    try check()
    let root=try BuildItem(source.rootEntry(identity:identity),identity:identity,root:true)
    var stack:[Frame]=[]
    if let frame=try append(root,parent:.max,path:identity.root,slot:nil) {stack.append(frame)}
    while !stack.isEmpty {
      try check()
      try autoreleasepool {
        for _ in 0..<4096 {
          guard let frame=stack.last else {break}
          if let item=try frame.reader.next() {
            let slot=UInt64(frame.firstChild)+UInt64(frame.child);frame.child+=1
            let path=(frame.path == "/" ? "" : frame.path)+"/"+item.name
            guard path.utf8.count<PATH_MAX else {throw SnapshotError.invalid("streaming path limit")}
            if let child=try append(item,parent:frame.ordinal,path:path,slot:slot*4) {stack.append(child)}
          } else {
            var end=Data(repeating:0,count:4);end.put(count,at:0)
            try w.section("records").patch(end,at:UInt64(frame.ordinal)*40+12)
            stack.removeLast()
          }
          metrics.maximum("streaming_dfs_depth_max",stack.count)
          // Directory pages already check. Also bound CPU-only leaf processing.
          if ProcessInfo.processInfo.systemUptime-lastDiskSample>=0.05 {try check()}
        }
      }
    }
    if count%4 != 0 {try w.section("validity").append(Data([validityByte]))}
    try w.flush();try w.sampleDisk();try fault?(.afterSections,w)
    let header=try assembleNamespace(w,generation:generation,cursor:cursor)
    try assembleMetadata(w,base:header,cursor:cursor)
    try w.flush();try w.sampleDisk();try fault?(.beforeValidation,w)
    for name in ["namespace","metadata"] {
      if name=="metadata" {try metadataFault?(.beforeFileSync)}
      guard fsync(w.section(name).fd)==0 else {throw SnapshotError.io("sync assembled build",errno)}
    }
    try check()
    // Production external storage never mmaps, even during full validation.
    let namespace=try store.immutableNamespaceReader(fileDescriptor:w.readOnly("namespace"),identity:identity,checkpoint:{[self] in try check()})
    let metadata=try store.immutableMetadataReader(fileDescriptor:w.readOnly("metadata"),base:header,checkpoint:{[self] in try check()})
    try check();try fault?(.afterValidation,w)
    metrics.record("streaming_builds");metrics.recordResources("streaming_build",since:start)
    metrics.maximum("streaming_temporary_peak_bytes",Int(clamping:w.peakTemporaryBytes))
    metrics.maximum("streaming_temporary_allocated_peak_bytes",Int(clamping:w.peakAllocatedBytes))
    metrics.set("streaming_logical_writes",to:Int(clamping:w.logicalWrites))
    return .init(namespace:namespace,metadata:metadata,workspace:w,milliseconds:(ProcessInfo.processInfo.systemUptime-start.uptime)*1000,unreadable:unreadable)
  }
  private func copy(_ section:BuildSection,to output:BuildSection,crc:inout UInt32) throws {
    var offset:UInt64=0
    while offset<section.length {
      try check();let bytes=try section.read(offset,min(signals?.current().memoryPressure == .warning ? 64*1024 : 1024*1024,Int(section.length-offset)))
      try output.append(bytes);crc=SnapshotFormat.crc(bytes,previous:crc);offset+=UInt64(bytes.count)
    }
  }
  private func assembleNamespace(_ w:SnapshotBuildWorkspace,generation:UInt64,cursor:UInt64) throws -> SnapshotHeader {
    let root=Data(identity.root.utf8),table=(UInt64(256+root.count)+7) & ~UInt64(7)
    let names=table+w.section("records").length,fold=names+w.section("original").length,children=fold+w.section("folded").length
    let length=children+w.section("children").length+16
    guard length<=SnapshotFormat.maxFileBytes,generation != .max,cursor != .max,
      w.section("original").length<=UInt32.max,w.section("folded").length<=UInt32.max else {throw SnapshotError.invalid("streaming layout limit")}
    var h=SnapshotHeader(recordCount:UInt64(count),recordTableOffset:table,recordTableLength:UInt64(count)*40,
      nameBlobOffset:names,nameBlobLength:w.section("original").length,rootPathOffset:256,rootPathLength:UInt64(root.count),
      createdAtUnixSeconds:UInt64(max(0,Date().timeIntervalSince1970)),indexGeneration:generation,lastProcessedEventID:cursor,
      rootDeviceID:identity.deviceID,volumeUUID:identity.volumeUUID,historyUUID:identity.historyUUID,payloadCRC32:0,fileLength:length,rootFileID:identity.rootFileID,snapshotUUID:UUID())
    let output=w.section("namespace");try output.append(Data(repeating:0,count:256))
    var crc:UInt32=0
    var prefix=root;prefix.append(Data(repeating:0,count:Int(table)-256-root.count))
    try output.append(prefix);crc=SnapshotFormat.crc(prefix,previous:crc)
    for name in ["records","original","folded","children"] {try copy(w.section(name),to:output,crc:&crc)}
    var footer=Data("APFSEND\0".utf8);footer.append(Data(repeating:0,count:8));footer.put(crc,at:8)
    try output.append(footer);crc=SnapshotFormat.crc(footer,previous:crc);h.payloadCRC32=crc
    var header=h.encoded();header.append(Data(repeating:0,count:64))
    header.put(UInt32(2),at:8);header.put(UInt32(256),at:12);header.put(UInt32(40),at:20)
    header.put(fold,at:192);header.put(w.section("folded").length,at:200)
    header.put(children,at:208);header.put(w.section("children").length,at:216)
    header.put(UInt32(0),at:148);header.put(SnapshotFormat.crc(header),at:148)
    try output.patch(header,at:0);return h
  }
  private func assembleMetadata(_ w:SnapshotBuildWorkspace,base:SnapshotHeader,cursor:UInt64) throws {
    let output=w.section("metadata");try output.append(Data(repeating:0,count:256));try metadataFault?(.afterHeader)
    var crc:UInt32=0
    for name in ["sizes","times","validity"] {try copy(w.section(name),to:output,crc:&crc)}
    let h=try MetadataHeader(base:base,cursor:cursor,payloadCRC:crc)
    var footer=Data("APFMTEND".utf8);footer.append(Data(repeating:0,count:8));footer.put(h.fileLength,at:8)
    try output.append(footer);try output.patch(h.encoded(),at:0)
  }
}
