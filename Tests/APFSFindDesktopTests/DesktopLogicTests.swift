import APFSFindCore
import Foundation
import XCTest
@testable import APFSFindDesktop

private actor FakeDesktopSearch: DesktopSearching {
  var queries: [String] = []
  func submit(_ request: SearchRequest) async -> MultiVolumeSearchResult? {
    queries.append(request.query)
    try? await Task.sleep(for: request.query == "slow" ? .milliseconds(180) : .milliseconds(5))
    let volume = VolumeDescriptor(volumeUUID: UUID(), displayName: "Test", mountPath: "/fixture")
    let hits = (0..<3).map { VolumeSearchHit(hit: .init(path: "/fixture/\(request.query)-\($0)", kind: .file), volume: volume, freshness: .live) }
    return .init(requestID: request.id, hits: hits, searchedVolumes: 1, catchingUpVolumes: 0,
                 offlineVolumes: 0, failedVolumes: [], latencyMilliseconds: 5, cancelled: false)
  }
  func cancel() {}
  func requests() -> [String] { queries }
}
private actor FilenameDesktopSearch: DesktopSearching {
  let index = FileIndex(root: "/fixture")
  var limits: [Int] = []
  let delayMore: Bool
  init(otherMatches: Int = 80, delayMore: Bool = false) {
    self.delayMore = delayMore
    index.apply((0..<otherMatches).map {
      .upsert(.init(path: String(format: "/fixture/net-%03d", $0), kind: .file))
    } + [.upsert(.init(path: "/fixture/NetForensics-Bench", kind: .directory))])
  }
  func submit(_ request: SearchRequest) async -> MultiVolumeSearchResult? {
    limits.append(request.limit)
    if delayMore && request.limit > 51 { try? await Task.sleep(for: .milliseconds(180)) }
    let result = index.search(request)
    let volume = VolumeDescriptor(volumeUUID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                                  displayName: "Test", mountPath: "/fixture")
    return .init(requestID: request.id,
      hits: result.hits.map { .init(hit: $0, volume: volume, freshness: .live) },
      searchedVolumes: 1, catchingUpVolumes: 0, offlineVolumes: 0, failedVolumes: [],
      latencyMilliseconds: result.latencyMilliseconds, cancelled: result.cancelled)
  }
  func cancel() {}
  func requestedLimits() -> [Int] { limits }
}
@MainActor
private final class FakeFileRouting: FileActionRouting {
  var opened: [String] = [], revealed: [String] = [], copied: [String] = []
  func open(_ path: String) -> Bool { opened.append(path); return true }
  func reveal(_ path: String) { revealed.append(path) }
  func copy(_ path: String) { copied.append(path) }
}
@MainActor
private final class FakeHotKey: HotKeyRegistering {
  var registrations = 0, unregistrations = 0
  var action: (@MainActor () -> Void)?
  var fail = false
  func register(_ action: @escaping @MainActor () -> Void) throws {
    if fail { throw HotKeyError.registration(-1) }; registrations += 1; self.action = action
  }
  func unregister() { unregistrations += 1; action = nil }
}
private actor ReconcileRecorder {
  var calls = 0
  func record() { calls += 1 }
  func count() -> Int { calls }
}
@MainActor
final class DesktopLogicTests: XCTestCase {
  private func eventually(_ condition: @MainActor () async -> Bool) async {
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    while !(await condition()), ProcessInfo.processInfo.systemUptime < deadline {
      try? await Task.sleep(for: .milliseconds(1))
    }
    let reached = await condition(); XCTAssertTrue(reached, "UI result was not published before deadline")
  }
  func testDebounceAndLatestResultOnly() async throws {
    let service = FakeDesktopSearch(), model = SearchViewModel(service: service, actions: FileActionController())
    model.query = "x"; model.query = "y"; model.query = "slow"
    await eventually { await service.requests().contains("slow") }
    model.query = "latest"
    await eventually { model.hits.count == 3 && model.hits.allSatisfy { $0.path.contains("latest") } && !model.searching }
    let queries = await service.requests()
    XCTAssertEqual(queries, ["slow", "latest"])
    XCTAssertTrue(model.hits.allSatisfy { $0.path.contains("latest") })
    XCTAssertFalse(model.searching)
    model.query = ""; XCTAssertTrue(model.hits.isEmpty)
    await model.cancel()
  }
  func testBroadMixedCaseQueryCanLoadTheNarrowQueryResult() async {
    let model = SearchViewModel(service: FilenameDesktopSearch(), actions: FileActionController(),
                                debounce: .milliseconds(1))
    model.query = "Net"
    await eventually { !model.pending && model.hits.count == 50 }
    XCTAssertTrue(model.hasMoreResults)
    XCTAssertFalse(model.hits.contains { $0.path.hasSuffix("NetForensics-Bench") })
    model.selectedIndex = 10
    let selected = model.selectedHit?.id
    model.loadMore()
    await eventually { !model.pending && model.hits.count == 81 }
    XCTAssertFalse(model.hasMoreResults)
    XCTAssertEqual(model.selectedHit?.id, selected)
    let broad = Set(model.hits.map(\.id))
    model.query = "netforensic"
    await eventually { !model.pending && model.hits.count == 1 }
    XCTAssertTrue(Set(model.hits.map(\.id)).isSubset(of: broad))
    XCTAssertEqual(model.hits.first?.path, "/fixture/NetForensics-Bench")
    model.query = "net"
    await eventually { !model.pending && model.hits.count == 50 }
    XCTAssertTrue(model.hasMoreResults, "A new query resets the display to the first page")
    await model.cancel()
  }
  func testExactlyFiftyMatchesDoesNotClaimThereAreMore() async {
    let model = SearchViewModel(service: FilenameDesktopSearch(otherMatches: 49),
                                actions: FileActionController(), debounce: .milliseconds(1))
    model.query = "NET"
    await eventually { !model.pending && model.hits.count == 50 }
    XCTAssertFalse(model.hasMoreResults)
    await model.cancel()
  }
  func testChangingQueryWhileLoadingMoreDoesNotPublishOldPage() async {
    let service = FilenameDesktopSearch(delayMore: true)
    let model = SearchViewModel(service: service, actions: FileActionController(), debounce: .milliseconds(1))
    model.query = "Net"
    await eventually { !model.pending && model.hasMoreResults }
    model.loadMore()
    await eventually { await service.requestedLimits().contains(101) }
    model.query = "netforensic"
    await eventually { !model.pending && model.hits.count == 1 }
    try? await Task.sleep(for: .milliseconds(220))
    XCTAssertEqual(model.hits.map(\.path), ["/fixture/NetForensics-Bench"])
    XCTAssertFalse(model.hasMoreResults)
    let limits = await service.requestedLimits()
    XCTAssertEqual(limits, [51, 101, 51])
    await model.cancel()
  }
  func testKeyboardSelectionAndStaleHitRemoval() async throws {
    let routing = FakeFileRouting(), recorder = ReconcileRecorder()
    let actions = FileActionController(routing: routing, exists: { _ in false }, reconcile: { _ in await recorder.record() })
    let model = SearchViewModel(service: FakeDesktopSearch(), actions: actions, debounce: .milliseconds(1))
    model.query = "needle"; await eventually { model.hits.count == 3 }
    model.moveSelection(100); XCTAssertEqual(model.selectedIndex, 2)
    model.moveSelection(-100); XCTAssertEqual(model.selectedIndex, 0)
    await model.perform(.copyPath); XCTAssertEqual(routing.copied.count, 1)
    await model.perform(.open); XCTAssertTrue(routing.opened.isEmpty)
    XCTAssertEqual(model.hits.count, 2); XCTAssertEqual(model.message, "该项目已移动或删除")
    let calls = await recorder.count(); XCTAssertEqual(calls, 1)
    await model.cancel()
  }
  func testOpenRevealCopyRoutingAndFreshness() async {
    let routing = FakeFileRouting(), actions = FileActionController(routing: routing, exists: { _ in true })
    let volume = VolumeDescriptor(volumeUUID: UUID(), displayName: "V", mountPath: "/")
    let hit = VolumeSearchHit(hit: .init(path: "/fixture/file", kind: .file), volume: volume, freshness: .catchingUp)
    let open = await actions.perform(.open, hit: hit), reveal = await actions.perform(.reveal, hit: hit), copy = await actions.perform(.copyPath, hit: hit)
    XCTAssertEqual(open, .success); XCTAssertEqual(reveal, .success); XCTAssertEqual(copy, .success)
    XCTAssertEqual(routing.opened, [hit.path]); XCTAssertEqual(routing.revealed, [hit.path]); XCTAssertEqual(routing.copied, [hit.path])
  }
  func testHotKeyIdempotentToggleConflictAndUnregister() async throws {
    let registrar = FakeHotKey(); var toggles = 0
    let controller = GlobalHotKeyController(registrar: registrar) { toggles += 1 }
    try controller.start(); try controller.start(); registrar.action?(); registrar.action?()
    XCTAssertEqual(toggles, 2); XCTAssertEqual(registrar.registrations, 1)
    controller.stop(); controller.stop(); XCTAssertEqual(registrar.unregistrations, 1)
    registrar.fail = true; XCTAssertThrowsError(try controller.start()); XCTAssertFalse(controller.registered)
  }
  func testSessionAggregationAndOfflineResultsRemoved() async throws {
    let model = SearchViewModel(service: FakeDesktopSearch(), actions: FileActionController())
    let volume = VolumeDescriptor(volumeUUID: UUID(), displayName: "V", mountPath: "/")
    model.updateSessions([.init(volume: volume, state: .catchingUp, searchAvailable: true, freshness: .catchingUp,
                               indexedEntries: 10, snapshotBytes: 100, unreadableDirectories: 2, pendingReplayEvents: 1)])
    XCTAssertEqual(model.indexedVolumes, 1); XCTAssertEqual(model.catchingUpVolumes, 1); XCTAssertEqual(model.warningCount, 2)
    model.updateSessions([.init(volume: volume, state: .offline, searchAvailable: false, freshness: .baseSnapshot,
                               indexedEntries: 0, snapshotBytes: 100, unreadableDirectories: 0, pendingReplayEvents: 0)])
    XCTAssertEqual(model.offlineVolumes, 1); XCTAssertEqual(model.indexedVolumes, 0)
    await model.cancel()
  }
  func testAccessHelpDoesNotWarnWithoutFailuresOrForOfflineHistory() async {
    let volume = VolumeDescriptor(volumeUUID: UUID(), displayName: "V", mountPath: "/")
    let clean = VolumeSessionSnapshot(volume: volume, state: .live, searchAvailable: true,
      freshness: .live, indexedEntries: 10, snapshotBytes: 100, unreadableDirectories: 0, pendingReplayEvents: 0)
    let offline = VolumeSessionSnapshot(volume: volume, state: .offline, searchAvailable: false,
      freshness: .baseSnapshot, indexedEntries: 10, snapshotBytes: 100, unreadableDirectories: 8,
      pendingReplayEvents: 0, permissionDeniedReads: 8)
    let status = DirectoryAccessStatus(sessions: [clean, offline])
    XCTAssertFalse(status.hasIssues); XCTAssertEqual(status.incompleteReads, 0)
    XCTAssertEqual(status.title, "目录访问设置"); XCTAssertEqual(status.details, "")
  }
  func testAccessFailuresAreCategorizedWithoutClaimingFDAIsOff() async {
    let volume = VolumeDescriptor(volumeUUID: UUID(), displayName: "V", mountPath: "/")
    let snapshot = VolumeSessionSnapshot(volume: volume, state: .live, searchAvailable: true,
      freshness: .live, indexedEntries: 10, snapshotBytes: 100, unreadableDirectories: 6,
      pendingReplayEvents: 0, permissionDeniedReads: 2, datalessSkips: 3)
    let status = DirectoryAccessStatus(sessions: [snapshot])
    XCTAssertTrue(status.hasIssues); XCTAssertEqual(status.permissionDeniedReads, 2)
    XCTAssertEqual(status.datalessSkips, 3); XCTAssertEqual(status.otherFailures, 1)
    XCTAssertTrue(status.title.contains("本次运行累计"))
    XCTAssertTrue(status.details.contains("系统保护")); XCTAssertTrue(status.details.contains("云端占位"))
    XCTAssertTrue(status.guidance.contains("不代表未开启完全磁盘访问"))
  }
  func testDatalessOnlySkipsDoNotSuggestChangingPermissions() async {
    let volume = VolumeDescriptor(volumeUUID: UUID(), displayName: "V", mountPath: "/")
    let snapshot = VolumeSessionSnapshot(volume: volume, state: .live, searchAvailable: true,
      freshness: .live, indexedEntries: 10, snapshotBytes: 100, unreadableDirectories: 3,
      pendingReplayEvents: 0, datalessSkips: 3)
    let status = DirectoryAccessStatus(sessions: [snapshot])
    XCTAssertFalse(status.showsSettingsHelp)
    XCTAssertTrue(status.guidance.contains("不需要调整完全磁盘访问权限"))
  }
}
