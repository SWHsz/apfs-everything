import CAPFSShim
import Darwin
import Foundation

/// Inputs must deliver bounded pages. Production delegates to the existing
/// no-follow bulk reader; synthetic sources are explicit benchmark/test oracles.
public protocol StreamingDirectorySource: Sendable {
  func rootEntry(identity: VolumeIdentity) throws -> ScannedEntry
  func pages(path: String, identity: VolumeIdentity, cancellation: CancellationToken,
             checkpoint: @escaping @Sendable () throws -> Void,
             visit: @escaping @Sendable ([ScannedEntry]) throws -> Void) throws
}
public struct BulkStreamingDirectorySource: StreamingDirectorySource {
  public let excludedRoots: [String]
  public let metrics: Metrics
  public init(excludedRoots:[String] = [], metrics:Metrics = .init()) {self.excludedRoots=excludedRoots;self.metrics=metrics}
  public func rootEntry(identity:VolumeIdentity) throws -> ScannedEntry {
    _ = apfs_deny_dataless_materialization()
    guard let stamp=BulkScanner.directoryStamp(identity.root) else {throw ScannerError(path:identity.root,code:errno)}
    return .init(namespace:.init(path:identity.root,kind:.directory,deviceID:identity.deviceID,fileID:identity.rootFileID),
      metadata:.init(modificationTimeNanoseconds:FileMetadataValue.unixNanoseconds(seconds:stamp.seconds,nanoseconds:stamp.nanoseconds)))
  }
  public func pages(path:String,identity:VolumeIdentity,cancellation:CancellationToken,
                    checkpoint:@escaping @Sendable ()throws->Void,
                    visit:@escaping @Sendable ([ScannedEntry])throws->Void) throws {
    let scanner=BulkScanner(root:identity.root,workerCount:1,metrics:metrics,excludedRoots:excludedRoots,checkpoint:checkpoint)
    _ = try scanner.readScannedDirectory(path,rootDeviceID:identity.deviceID,cancellation:cancellation,
      collectEntries:false,collectDirectories:false,visitThrowing:visit)
    guard !cancellation.isCancelled else {throw SnapshotError.cancelled}
  }
}

struct BuildItem {
  let name: String, folded: String
  let kind: EntryKind
  let boundary: Bool
  let fileID: UInt64
  let metadata: FileMetadataValue
  init(_ entry: ScannedEntry, identity: VolumeIdentity, root: Bool = false) throws {
    name = root ? "" : (entry.namespace.path as NSString).lastPathComponent
    folded = FileEntry.fold(name); kind = entry.namespace.kind
    boundary = !root && (entry.namespace.isMountPoint || entry.namespace.deviceID != identity.deviceID)
    fileID = entry.namespace.fileID ?? 0; metadata = entry.metadata
    guard name.utf8.count <= NAME_MAX, folded.utf8.count <= UInt16.max,
      root || (!name.isEmpty && name != "." && name != ".." && !name.utf8.contains(0) && !name.utf8.contains(47))
    else {throw SnapshotError.invalid("streaming basename limit")}
  }
  private init(name:String,folded:String,kind:EntryKind,boundary:Bool,fileID:UInt64,metadata:FileMetadataValue) {
    self.name=name;self.folded=folded;self.kind=kind;self.boundary=boundary;self.fileID=fileID;self.metadata=metadata
  }
  static func less(_ a:BuildItem,_ b:BuildItem)->Bool {
    MMapBaseIndex.less((a.folded,a.name,a.kind.snapshotCode),(b.folded,b.name,b.kind.snapshotCode))
  }
  var encoded:Data {
    var data=Data(repeating:0,count:32)
    data.put(UInt16(name.utf8.count),at:0);data.put(UInt16(folded.utf8.count),at:2)
    data[4]=kind.snapshotCode;data[5]=boundary ? 1 : 0
    data[6]=(metadata.logicalSize == nil ? 0 : 1) | (metadata.modificationTimeNanoseconds == nil ? 0 : 2)
    data.put(fileID,at:8);data.put(metadata.logicalSize ?? 0,at:16);data.put(metadata.modificationTimeNanoseconds ?? 0,at:24)
    data.append(contentsOf:name.utf8);data.append(contentsOf:folded.utf8);return data
  }
  static func decode(_ header:Data,_ strings:Data) throws -> BuildItem {
    func n<T:FixedWidthInteger>(_ offset:Int,_ type:T.Type)->T {header.withUnsafeBytes {T(littleEndian:$0.loadUnaligned(fromByteOffset:offset,as:type))}}
    let nameCount=Int(n(0,UInt16.self)),foldCount=Int(n(2,UInt16.self))
    guard strings.count==nameCount+foldCount,let kind=EntryKind(snapshotCode:header[4]),header[5]<=1,header[6]<=3,header[7]==0,
      let name=String(data:strings.prefix(nameCount),encoding:.utf8),let folded=String(data:strings.dropFirst(nameCount),encoding:.utf8)
    else {throw SnapshotError.invalid("directory sort scratch")}
    return .init(name:name,folded:folded,kind:kind,boundary:header[5] != 0,fileID:n(8,UInt64.self),
      metadata:.init(logicalSize:header[6]&1 != 0 ? n(16,UInt64.self) : nil,
                     modificationTimeNanoseconds:header[6]&2 != 0 ? n(24,Int64.self) : nil))
  }
}
struct BuildRun { let start:UInt64,end:UInt64,count:UInt32 }
/// A fixed-size read buffer; DFS frames keep cursor offsets, not listings.
final class BuildRunReader {
  private let section:BuildSection
  private let end:UInt64
  private var offset:UInt64
  private var buffer=Data(),position=0
  init(_ section:BuildSection,_ run:BuildRun) {self.section=section;offset=run.start;end=run.end}
  private func take(_ count:Int) throws -> Data {
    guard count>=0,UInt64(count)<=end-offset else {throw SnapshotError.invalid("sort scratch truncated")}
    var result=Data();result.reserveCapacity(count)
    while result.count<count {
      if position==buffer.count {
        buffer=try section.read(offset,min(16*1024,Int(end-offset)));position=0
      }
      let n=min(count-result.count,buffer.count-position)
      guard n>0 else {throw SnapshotError.invalid("sort scratch short read")}
      result.append(buffer[position..<position+n]);position+=n;offset+=UInt64(n)
    }
    return result
  }
  func next() throws -> BuildItem? {
    if offset==end {return nil}
    let h=try take(32)
    let length=h.withUnsafeBytes {Int(UInt16(littleEndian:$0.loadUnaligned(as:UInt16.self)))+Int(UInt16(littleEndian:$0.loadUnaligned(fromByteOffset:2,as:UInt16.self)))}
    return try BuildItem.decode(h, take(length))
  }
}
/// Binary run merging bounds descriptors to 64 regardless of directory width.
/// Scratch is recycled per directory; the shared DFS spool stores completed
/// listings on disk until the workspace is discarded, never in a path map.
final class BuildDirectorySorter: @unchecked Sendable {
  private let scratch:BuildSection, listings:BuildSection
  private let identity:VolumeIdentity
  private let check:@Sendable ()throws->Void
  private let metrics:Metrics
  private var levels=[BuildRun?](repeating:nil,count:64)
  init(workspace:SnapshotBuildWorkspace,identity:VolumeIdentity,metrics:Metrics,check:@escaping @Sendable ()throws->Void) throws {
    scratch=workspace.section("sort");listings=workspace.section("listings");self.identity=identity;self.check=check;self.metrics=metrics
    try scratch.reset()
  }
  func page(_ page:[ScannedEntry]) throws {
    for start in stride(from:0,to:page.count,by:4096) {
      try check()
      try autoreleasepool {
        let items=try page[start..<min(start+4096,page.count)].map {try BuildItem($0,identity:identity)}.sorted(by:BuildItem.less)
        metrics.maximum("streaming_listing_entries_max",items.count)
        let begin=scratch.length
        var unique:[BuildItem]=[]
        for item in items {
          if let previous=unique.last,previous.name.utf8.elementsEqual(item.name.utf8) {
            unique[unique.count-1]=item;metrics.record("streaming_duplicate_race_hints")
          } else {unique.append(item)}
        }
        for item in unique {try scratch.append(item.encoded)}
        try scratch.flush()
        var run=BuildRun(start:begin,end:scratch.length,count:UInt32(unique.count)),level=0
        while let old=levels[level] {
          levels[level]=nil;run=try merge(old,run);level+=1
          guard level<64 else {throw SnapshotError.invalid("directory sort run limit")}
        }
        levels[level]=run
      }
    }
  }
  private func merge(_ a:BuildRun,_ b:BuildRun) throws -> BuildRun {
    try scratch.flush()
    let begin=scratch.length, ar=BuildRunReader(scratch,a),br=BuildRunReader(scratch,b)
    var x=try ar.next(),y=try br.next(),count=0
    while x != nil || y != nil {
      if count%4096==0 {try check()}
      if let left=x,let right=y,left.name.utf8.elementsEqual(right.name.utf8) {
        try scratch.append(right.encoded);x=try ar.next();y=try br.next();metrics.record("streaming_duplicate_race_hints")
      } else if let left=x, y == nil || BuildItem.less(left,y!) {try scratch.append(left.encoded);x=try ar.next()}
      else if let right=y {try scratch.append(right.encoded);y=try br.next()}
      count+=1
    }
    try scratch.flush()
    guard UInt64(a.count)+UInt64(b.count)<=SnapshotFormat.maxRecords else {throw SnapshotError.invalid("directory entry limit")}
    return .init(start:begin,end:scratch.length,count:UInt32(count))
  }
  func finish() throws -> BuildRun {
    var merged:BuildRun?
    for run in levels.compactMap({$0}) {merged = try merged.map {try merge($0,run)} ?? run}
    let start=listings.length
    if let merged {
      var offset=merged.start
      while offset<merged.end {
        try check();let bytes=try scratch.read(offset,min(1024*1024,Int(merged.end-offset)))
        try listings.append(bytes);offset+=UInt64(bytes.count)
      }
    }
    try listings.flush()
    return .init(start:start,end:listings.length,count:merged?.count ?? 0)
  }
}
