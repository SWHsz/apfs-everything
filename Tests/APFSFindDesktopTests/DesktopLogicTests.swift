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
  func testDebounceAndLatestResultOnly() async throws {
    let service = FakeDesktopSearch(), model = SearchViewModel(service: service, actions: FileActionController())
    model.query = "x"; model.query = "y"; model.query = "slow"
    try await Task.sleep(for: .milliseconds(65)); model.query = "latest"
    try await Task.sleep(for: .milliseconds(250))
    let queries = await service.requests()
    XCTAssertEqual(queries, ["slow", "latest"])
    XCTAssertTrue(model.hits.allSatisfy { $0.path.contains("latest") })
    XCTAssertFalse(model.searching)
    model.query = ""; XCTAssertTrue(model.hits.isEmpty)
    await model.cancel()
  }
  func testKeyboardSelectionAndStaleHitRemoval() async throws {
    let routing = FakeFileRouting(), recorder = ReconcileRecorder()
    let actions = FileActionController(routing: routing, exists: { _ in false }, reconcile: { _ in await recorder.record() })
    let model = SearchViewModel(service: FakeDesktopSearch(), actions: actions, debounce: .milliseconds(1))
    model.query = "needle"; try await Task.sleep(for: .milliseconds(30))
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
}
