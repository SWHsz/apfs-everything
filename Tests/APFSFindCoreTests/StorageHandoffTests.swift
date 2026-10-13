import Foundation
import XCTest
@testable import APFSFindCore

private final class GatedStorageSearch: VolumeSearching, @unchecked Sendable {
  let inner: FakeVolumeSession
  let entered = DispatchSemaphore(value:0), release = DispatchSemaphore(value:0)
  init(_ volume:VolumeDescriptor) {inner = FakeVolumeSession(volume)}
  func waitForQuery()->Bool {entered.wait(timeout:.now()+3) == .success}
  var volume:VolumeDescriptor {inner.volume}
  func start() {inner.start()}
  func snapshot()->VolumeSessionSnapshot {inner.snapshot()}
  func changes()->AsyncStream<VolumeSessionSnapshot> {inner.changes()}
  func stop(policy:ShutdownPolicy) async {await inner.stop(policy:policy)}
  func search(_ request:SearchRequest)->SearchResult {
    entered.signal()
    _ = release.wait(timeout:.now()+10)
    return inner.search(request)
  }
  func reconcileParent(of path:String) {inner.reconcileParent(of:path)}
}
final class StorageHandoffTests:XCTestCase,@unchecked Sendable {
  func testReplacementServesQueriesWhileOldInFlightQueryDrains() async throws {
    try await exercise(cancelHandoff:false)
  }
  func testCancelledHandoffStillDrainsOldQueryWithoutBlockingReplacement() async throws {
    try await exercise(cancelHandoff:true)
  }
  private func exercise(cancelHandoff:Bool) async throws {
    let volume = VolumeDescriptor(volumeUUID:UUID(),displayName:"Owned",mountPath:"/fixture",isSystemVolume:true)
    let old = GatedStorageSearch(volume), replacement = FakeVolumeSession(volume)
    replacement.index.apply([.upsert(.init(path:"/fixture/match-replacement",kind:.file))])
    let coordinator = MultiVolumeCoordinator(provider:FakeVolumeProvider([volume]),selectionStore:MemoryVolumeSelection(),maintenance:.init(),factory:{_,_ in old})
    await coordinator.start()
    let inFlight = Task {await coordinator.search(.init(query:"match",limit:200))}
    let entered = await Task.detached {old.waitForQuery()}.value
    XCTAssertTrue(entered)
    let handoff = Task {await coordinator.replaceSessionForMigration(replacement,id:volume.volumeUUID,old:old)}
    let deadline = ProcessInfo.processInfo.systemUptime+3
    while await coordinator.sessionsSnapshot().first?.indexedEntries != replacement.index.stats().liveEntries,
      ProcessInfo.processInfo.systemUptime < deadline {try await Task.sleep(for:.milliseconds(5))}
    if cancelHandoff {handoff.cancel()}
    XCTAssertTrue(old.snapshot().searchAvailable,"old session must remain searchable until its reader finishes")
    let next = await coordinator.search(.init(query:"match",limit:200))
    XCTAssertEqual(next.hits.count,102,"new queries must select the replacement during drain")
    old.release.signal()
    let original = await inFlight.value
    XCTAssertEqual(original.hits.count,101,"handoff must not discard a dispatched query's result")
    await handoff.value
    XCTAssertFalse(old.snapshot().searchAvailable)
    await coordinator.stop()
  }
}
