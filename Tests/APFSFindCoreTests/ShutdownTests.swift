import CoreServices
import Foundation
import XCTest
@testable import APFSFindCore

final class ShutdownTests: XCTestCase, @unchecked Sendable {
  func testFastShutdownRecordsPhasesAndDrainsDeliveredNamespace() throws {
    let tree = try TemporaryTree(), cache = try TemporaryTree(cache:true)
    try tree.file("old")
    let c = try PersistentIndexCoordinator(root:tree.root,cacheDirectory:cache.root,maintenanceScheduler:.init(),
      replayStarter:{ [root=tree.root] id,sink in sink([.init(path:root,flags:UInt32(kFSEventStreamEventFlagHistoryDone),id:id)]) },fenceProvider:{ _ in 100 })
    try c.start(); XCTAssertTrue(c.waitUntilLive()); XCTAssertTrue(c.waitForCheckpoint())
    try tree.file("delivered")
    c.core.enqueue([.init(path:tree.path("delivered"),flags:UInt32(kFSEventStreamEventFlagItemCreated|kFSEventStreamEventFlagItemIsFile),id:101)])
    c.stop(policy:.fast)
    XCTAssertNotNil(c.index.entry(at:tree.path("delivered")))
    XCTAssertEqual(c.currentState,.stopped)
    let phases=c.shutdownMetrics.snapshot
    XCTAssertEqual(phases.count,10)
    XCTAssertTrue(phases.values.allSatisfy { $0>=0 })
    XCTAssertGreaterThan(phases["shutdown_total_ms",default:0],0)
    XCTAssertGreaterThan(phases["shutdown_namespace_drain_ms",default:0],0)
    c.stop(policy:.fast)
    XCTAssertEqual(c.shutdownMetrics.snapshot,phases)
  }
  private func coordinator(_ tree:TemporaryTree,_ cache:TemporaryTree,hook:ShutdownHook?=nil,metadata:Bool=false) throws -> PersistentIndexCoordinator {
    let fault: @Sendable (SnapshotFailurePoint) throws -> Void = {_ in hook?.checkpoint()}
    return try PersistentIndexCoordinator(root:tree.root,cacheDirectory:cache.root,
      metadataFault:metadata ? fault:nil,
      compactionFault:!metadata ? fault:nil,
      maintenanceScheduler:.init(),
      replayStarter:{[root=tree.root] id,sink in sink([.init(path:root,flags:UInt32(kFSEventStreamEventFlagHistoryDone),id:id)])},fenceProvider:{_ in 100})
  }
  func testRunningMetadataBootstrapCancelsWithoutDamagingOldBase() throws {
    let tree=try TemporaryTree(),cache=try TemporaryTree(cache:true),hook=ShutdownHook()
    for i in 0..<256 {try tree.file("f\(i)")}
    let c=try coordinator(tree,cache,hook:hook,metadata:true)
    try c.start();XCTAssertTrue(c.waitUntilLive());XCTAssertTrue(c.waitForCheckpoint());XCTAssertTrue(c.waitForMetadata())
    let store=try SnapshotStore(directory:cache.root,identity:VolumeIdentity.discover(root:tree.root))
    let old=try Data(contentsOf:URL(fileURLWithPath:store.metadataPath))
    hook.enable();c.rebuildMetadata()
    XCTAssertEqual(hook.entered.wait(timeout:.now()+5),.success)
    DispatchQueue.global().asyncAfter(deadline:.now()+0.05) {hook.proceed.signal()}
    let begin=ProcessInfo.processInfo.systemUptime;c.stop(policy:.fast)
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-begin,1)
    XCTAssertEqual(old,try Data(contentsOf:URL(fileURLWithPath:store.metadataPath)))
    c.stop(policy:.fast)
  }
  func testRunningNamespaceCompactionCancelsAndSmallOverlayReplays() throws {
    let tree=try TemporaryTree(),cache=try TemporaryTree(cache:true),hook=ShutdownHook()
    try tree.file("old")
    let c=try coordinator(tree,cache,hook:hook)
    try c.start();XCTAssertTrue(c.waitUntilLive());XCTAssertTrue(c.waitForCheckpoint())
    let store=try SnapshotStore(directory:cache.root,identity:VolumeIdentity.discover(root:tree.root))
    let old=try Data(contentsOf:URL(fileURLWithPath:store.path))
    try tree.file("new")
    let event=FileSystemEvent(path:tree.path("new"),flags:UInt32(kFSEventStreamEventFlagItemCreated|kFSEventStreamEventFlagItemIsFile),id:101)
    c.core.enqueue([event]);_ = c.core.flushEvents()
    hook.enable();XCTAssertTrue(c.compact())
    XCTAssertEqual(hook.entered.wait(timeout:.now()+5),.success)
    DispatchQueue.global().asyncAfter(deadline:.now()+0.05) {hook.proceed.signal()}
    let begin=ProcessInfo.processInfo.systemUptime;c.stop(policy:.fast)
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-begin,1)
    XCTAssertEqual(old,try Data(contentsOf:URL(fileURLWithPath:store.path)))
    let next=try PersistentIndexCoordinator(root:tree.root,cacheDirectory:cache.root,maintenanceScheduler:.init(),
      replayStarter:{[root=tree.root] _,sink in sink([event,.init(path:root,flags:UInt32(kFSEventStreamEventFlagHistoryDone),id:101)])},fenceProvider:{_ in 101})
    defer {next.stop(policy:.fast)}
    try next.start();XCTAssertTrue(next.waitUntilLive());XCTAssertNotNil(next.index.entry(at:tree.path("new")))
    XCTAssertEqual(next.metrics.snapshot()["full_scans",default:0],0)
    XCTAssertTrue(try next.core.verify().isConsistent)
  }
  func testPendingMetadataDebounceDoesNotAdvanceFenceOrTraverseAtExit() throws {
    let tree=try TemporaryTree(),cache=try TemporaryTree(cache:true)
    try tree.file("old")
    var policy=MetadataUpdatePolicy();policy.debounceSeconds=60
    let c=try PersistentIndexCoordinator(root:tree.root,cacheDirectory:cache.root,metadataUpdatePolicy:policy,
      maintenanceScheduler:.init(),replayStarter:{[root=tree.root] id,sink in sink([.init(path:root,flags:UInt32(kFSEventStreamEventFlagHistoryDone),id:id)])},fenceProvider:{_ in 100})
    try c.start();XCTAssertTrue(c.waitUntilLive());XCTAssertTrue(c.waitForCheckpoint());XCTAssertTrue(c.waitForMetadata())
    let oldCursor=c.metadata.processedCursor
    c.core.enqueue([.init(path:tree.path("old"),flags:UInt32(kFSEventStreamEventFlagItemModified|kFSEventStreamEventFlagItemIsFile),id:101)])
    _ = c.core.flushEvents()
    waitFor("pending metadata") {c.metrics.snapshot()["pending_metadata_lookups",default:0]>0}
    c.stop(policy:.fast)
    XCTAssertEqual(c.metadata.processedCursor,oldCursor)
    XCTAssertLessThan(c.shutdownMetrics.snapshot["shutdown_total_ms",default:1000],1000)
  }
  func testQueuedMetadataBootstrapCancelsWhileOtherLeaseRemainsRunning() async throws {
    let tree=try TemporaryTree(),cache=try TemporaryTree(cache:true),scheduler=MaintenanceScheduler()
    try tree.file("old")
    let c=try PersistentIndexCoordinator(root:tree.root,cacheDirectory:cache.root,maintenanceScheduler:scheduler,
      replayStarter:{[root=tree.root] id,sink in sink([.init(path:root,flags:UInt32(kFSEventStreamEventFlagHistoryDone),id:id)])},fenceProvider:{_ in 100})
    try c.start();XCTAssertTrue(c.waitUntilLive());XCTAssertTrue(c.waitForCheckpoint());XCTAssertTrue(c.waitForMetadata())
    let blocker=try await scheduler.acquire(volumeID:UUID(),kind:.rebuild,cancellation:.init())
    defer {blocker.release()}
    c.rebuildMetadata()
    var queued=false
    for _ in 0..<200 {if await scheduler.snapshot().contains(where:{$0.kind == .metadataBootstrap && $0.startedAt == nil}) {queued=true;break};try await Task.sleep(for:.milliseconds(2))}
    XCTAssertTrue(queued)
    let begin=ProcessInfo.processInfo.systemUptime;c.stop(policy:.fast)
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-begin,1)
    let remaining=await scheduler.snapshot();XCTAssertEqual(remaining.count,1);XCTAssertEqual(remaining.first?.id,blocker.id)
  }
  func testCoreShutdownCancelsActiveSearchAtChunkBoundary() throws {
    let tree=try TemporaryTree(),index=BlockingSearchIndex(root:tree.root)
    let c=try UpdateCoordinator(root:tree.root,index:index,maintenanceScheduler:.init(),
      replayStarter:{[root=tree.root] id,sink in sink([.init(path:root,flags:UInt32(kFSEventStreamEventFlagHistoryDone),id:id)])})
    try c.start();XCTAssertTrue(c.waitUntilLive())
    let token=SearchCancellationToken(),completed=DispatchSemaphore(value:0)
    DispatchQueue.global().async {_=c.search(.init(query:"blocked",cancellation:token));completed.signal()}
    XCTAssertEqual(index.entered.wait(timeout:.now()+2),.success)
    c.stop();XCTAssertEqual(completed.wait(timeout:.now()+1),.success);XCTAssertTrue(token.isCancelled)
  }
  func testTwoVolumeShutdownCancelsAnActiveQuery() async throws {
    let a=VolumeDescriptor(volumeUUID:UUID(),displayName:"A",mountPath:"/",isSystemVolume:true)
    let b=VolumeDescriptor(volumeUUID:UUID(),displayName:"B",mountPath:"/Volumes/B")
    let c=MultiVolumeCoordinator(provider:FakeVolumeProvider([a,b]),selectionStore:MemoryVolumeSelection([b.volumeUUID]),maintenance:.init(),factory:{volume,_ in FakeVolumeSession(volume,delay:5)})
    await c.start()
    let token=SearchCancellationToken(),query=Task {await c.search(.init(query:"match",cancellation:token))}
    try await Task.sleep(for:.milliseconds(30))
    await c.stop();let result=await query.value
    XCTAssertTrue(token.isCancelled);XCTAssertTrue(result.cancelled)
    let states=await c.sessionsSnapshot();XCTAssertTrue(states.allSatisfy{$0.state == .offline})
    await c.stop()
  }

}

private final class ShutdownHook:@unchecked Sendable {
  let entered=DispatchSemaphore(value:0),proceed=DispatchSemaphore(value:0)
  private let lock=NSLock();private var enabled=false
  func enable(){lock.withLock{enabled=true}}
  func checkpoint(){
    let take=lock.withLock{if !enabled {return false};enabled=false;return true}
    if take {entered.signal();_ = proceed.wait(timeout:.now()+5)}
  }
}

private final class BlockingSearchIndex:NamespaceIndex,@unchecked Sendable {
  let root:String,ram:FileIndex,entered=DispatchSemaphore(value:0)
  init(root:String){self.root=root;ram=FileIndex(root:root)}
  func apply(_ v:[IndexMutation]){ram.apply(v)}
  func entry(at p:String)->NamespaceEntry?{ram.entry(at:p)}
  func children(of p:String)->[NamespaceEntry]{ram.children(of:p)}
  func snapshotPaths()->Set<String>{ram.snapshotPaths()}
  func snapshotEntries()->[NamespaceEntry]{ram.snapshotEntries()}
  func stats()->IndexStats{ram.stats()}
  func captureSnapshotMetadata()->SnapshotExportMetadata{ram.captureSnapshotMetadata()}
  func replace(with v:FileIndex){ram.replace(with:v)}
  func installSnapshot(_ v:any NamespaceIndex){ram.installSnapshot(v)}
  func search(_ q:String,limit:Int)->SearchResult{search(.init(query:q,limit:limit))}
  func search(_ r:SearchRequest)->SearchResult{
    entered.signal();let deadline=ProcessInfo.processInfo.systemUptime+3
    while !r.cancellation.isCancelled && ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.001)}
    return ram.search(r)
  }
}
