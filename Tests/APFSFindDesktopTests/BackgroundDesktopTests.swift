import APFSFindCore
import AppKit
import Combine
import Darwin
import Foundation
import ServiceManagement
import XCTest
@testable import APFSFindDesktop

@MainActor
private final class FakeLoginService: LoginItemService {
  var status: SMAppService.Status = .notRegistered
  var registerCalls = 0, unregisterCalls = 0
  var fails = false
  func register() throws { registerCalls += 1; if fails { throw CocoaError(.fileWriteNoPermission) }; status = .enabled }
  func unregister() throws { unregisterCalls += 1; if fails { throw CocoaError(.fileWriteNoPermission) }; status = .notRegistered }
}
@MainActor
private final class FakeWorkspace: WorkspaceLifecycleProviding {
  var handler: (@MainActor @Sendable (WorkspaceLifecycleEvent) -> Void)?
  func start(_ handler: @escaping @MainActor @Sendable (WorkspaceLifecycleEvent) -> Void) { self.handler = handler }
  func stop() { handler = nil }
}
private final class DesktopLifecycleSession: VolumeSearching, @unchecked Sendable {
  let volume: VolumeDescriptor
  let lock = NSLock()
  var reasons: Set<IndexPauseReason> = []
  var stopped = false
  init(_ volume: VolumeDescriptor) { self.volume = volume }
  func snapshot() -> VolumeSessionSnapshot {
    let (reasons, stopped) = lock.withLock { (self.reasons, self.stopped) }
    return .init(volume: volume, state: stopped ? .offline : (reasons.isEmpty ? .live : .paused),
      searchAvailable: !stopped, freshness: reasons.isEmpty ? .live : .pausedStale,
      indexedEntries: 1, snapshotBytes: 0, unreadableDirectories: 0, pendingReplayEvents: 0, pauseReasons: reasons)
  }
  func start() {}
  func stop(policy: ShutdownPolicy) async { lock.withLock { stopped = true } }
  func search(_ request: SearchRequest) -> SearchResult { .init(hits: [], latencyMilliseconds: 0, generation: 0) }
  func reconcileParent(of path: String) {}
  func changes() -> AsyncStream<VolumeSessionSnapshot> { AsyncStream { $0.yield(snapshot()) } }
  func setPauseReason(_ reason: IndexPauseReason, enabled: Bool) async {
    lock.withLock { if enabled { reasons.insert(reason) } else { reasons.remove(reason) } }
  }
}
private struct DesktopLifecycleVolumes: MountedVolumeProvider {
  let volume = VolumeDescriptor(volumeUUID: UUID(), displayName: "Fixture", mountPath: "/fixture", isSystemVolume: true)
  func mountedVolumes() throws -> [VolumeDescriptor] { [volume] }
}
@MainActor
final class BackgroundDesktopTests: XCTestCase {
  func testNativeFixtureCheckRejectsWrongSizeNanosecondTimeTypeAndDuplicateHits() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("apfsfind-menu-check-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    var st = stat(); XCTAssertEqual(lstat(directory.path, &st), 0)
    let path = directory.path + "/generated", volume = DesktopLifecycleVolumes().volume
    let fixture = NativeMenuSmokeValidation.Fixture(path: directory.path,
      values: [path: (257, 1_700_000_000_000_000_001)], device: st.st_dev, inode: st.st_ino)
    func result(size: UInt64? = 257, time: Int64? = 1_700_000_000_000_000_001,
      kind: EntryKind = .file, duplicate: Bool = false) -> MultiVolumeSearchResult {
      let hit = VolumeSearchHit(hit: .init(path: path, kind: kind, logicalSize: size,
        modificationTimeNanoseconds: time), volume: volume, freshness: .live)
      return .init(requestID: 1, hits: duplicate ? [hit, hit] : [hit], searchedVolumes: 1,
        catchingUpVolumes: 0, offlineVolumes: 0, failedVolumes: [], latencyMilliseconds: 0, cancelled: false)
    }
    XCTAssertTrue(fixture.matches(result()))
    XCTAssertFalse(fixture.matches(result(size: 173)))
    XCTAssertFalse(fixture.matches(result(time: 1_700_000_000_000_000_000)))
    XCTAssertFalse(fixture.matches(result(size: nil, time: nil)))
    XCTAssertFalse(fixture.matches(result(kind: .directory)))
    XCTAssertFalse(fixture.matches(result(duplicate: true)))
  }
  func testNativeGateRequiresExactFixtureSynchronizationWhileAllowingUnrelatedMetadataChurn() {
    let a = DesktopLifecycleVolumes().volume
    let b = VolumeDescriptor(volumeUUID: UUID(), displayName: "Second", mountPath: "/second")
    func snapshot(_ volume: VolumeDescriptor, _ freshness: MetadataFreshness,
      available: Bool = true) -> VolumeSessionSnapshot {
      .init(volume: volume, state: .live, searchAvailable: true, freshness: .live,
        indexedEntries: 12, snapshotBytes: 0, unreadableDirectories: 0, pendingReplayEvents: 0,
        metadataAvailable: available, metadataFreshness: freshness)
    }
    XCTAssertFalse(NativeSmokeActions.readyForFixtureValidation([snapshot(a, .live), snapshot(b, .live)], fixtureSynchronized: false))
    XCTAssertFalse(NativeSmokeActions.readyForFixtureValidation([snapshot(a, .live), snapshot(b, .live, available: false)], fixtureSynchronized: true))
    XCTAssertFalse(NativeSmokeActions.readyForFixtureValidation([snapshot(a, .live)], fixtureSynchronized: true))
    XCTAssertTrue(NativeSmokeActions.readyForFixtureValidation([snapshot(a, .catchingUp), snapshot(b, .live)], fixtureSynchronized: true))
  }
  func testOpenVolumeSubmenuSurvivesSnapshotAndLoginUpdates() async throws {
    let provider = DesktopLifecycleVolumes()
    let coordinator = MultiVolumeCoordinator(provider: provider, maintenance: .init(),
      factory: { v, _ in DesktopLifecycleSession(v) })
    await coordinator.start()
    let service = FakeLoginService(), login = LaunchAtLoginController(service: service)
    let bar = StatusBarController(coordinator: coordinator, login: login,
      show: {}, settings: {}, quit: {})
    defer { bar.stop() }
    bar.update(await coordinator.sessionsSnapshot(), globalPaused: false)
    let root = bar.menu
    let volumeItem = try XCTUnwrap(root.item(withTitle: "Fixture"))
    let child = try XCTUnwrap(volumeItem.submenu)
    let pauseItem = try XCTUnwrap(child.item(withTitle: "暂停索引"))
    bar.menuWillOpen(root)
    await coordinator.setAllPaused(.userGlobal, enabled: true)
    service.status = .enabled; login.refresh()
    let changed = await coordinator.sessionsSnapshot()
    for _ in 0..<100 {
      bar.update(changed, globalPaused: true)
      bar.menuNeedsUpdate(root)
      await Task.yield()
    }
    XCTAssertTrue(root.item(withTitle: "Fixture") === volumeItem)
    XCTAssertTrue(volumeItem.submenu === child)
    XCTAssertTrue(child.item(withTitle: "暂停索引") === pauseItem)
    // The original hovered item must still invoke the correct volume action.
    child.performActionForItem(at: child.index(of: pauseItem))
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    while !(await coordinator.sessionsSnapshot().first?.pauseReasons.contains(.userVolume) ?? false),
      ProcessInfo.processInfo.systemUptime < deadline { await Task.yield() }
    let paused = await coordinator.sessionsSnapshot()
    XCTAssertTrue(paused.first?.pauseReasons.contains(.userVolume) == true)
    bar.update(paused, globalPaused: true)
    bar.menuDidClose(root)
    while root.item(withTitle: "恢复所有索引") == nil,
      ProcessInfo.processInfo.systemUptime < deadline { await Task.yield() }
    XCTAssertNotNil(root.item(withTitle: "恢复所有索引"))
    XCTAssertNotNil(root.item(withTitle: "Fixture")?.submenu?.item(withTitle: "恢复索引"))
    XCTAssertNotNil(root.item(withTitle: "登录时启动（已启用）"))
    await coordinator.stop()
  }
  func testUnchangedPresentationPreservesMenuItemsAndLoginDoesNotRepublish() async throws {
    let provider = DesktopLifecycleVolumes()
    let coordinator = MultiVolumeCoordinator(provider: provider, maintenance: .init(),
      factory: { v, _ in DesktopLifecycleSession(v) })
    await coordinator.start()
    let login = LaunchAtLoginController(service: FakeLoginService())
    var notifications = 0
    let observation = login.objectWillChange.sink { notifications += 1 }
    defer { observation.cancel() }
    let bar = StatusBarController(coordinator: coordinator, login: login,
      show: {}, settings: {}, quit: {})
    defer { bar.stop() }
    let snapshots = await coordinator.sessionsSnapshot()
    bar.update(snapshots, globalPaused: false)
    let item = try XCTUnwrap(bar.menu.item(withTitle: "Fixture"))
    // Entry-count progress does not change any visible menu label or action.
    let progress = VolumeSessionSnapshot(volume: provider.volume, state: .live,
      searchAvailable: true, freshness: .live, indexedEntries: 999,
      snapshotBytes: 1024, unreadableDirectories: 0, pendingReplayEvents: 42)
    for _ in 0..<100 {
      bar.update([progress], globalPaused: false); bar.menuNeedsUpdate(bar.menu)
    }
    XCTAssertTrue(bar.menu.item(withTitle: "Fixture") === item)
    XCTAssertEqual(notifications, 0)
    await coordinator.stop()
  }
  func testStatusItemActionsRouteToLifecycleLoginAndQuit() async throws {
    let provider = DesktopLifecycleVolumes()
    let coordinator = MultiVolumeCoordinator(provider: provider, maintenance:.init(), factory: { v, _ in DesktopLifecycleSession(v) })
    await coordinator.start()
    let loginService = FakeLoginService(), login = LaunchAtLoginController(service: loginService)
    var shown = 0, settings = 0, quits = 0
    let bar = StatusBarController(coordinator: coordinator, login: login,
      show: { shown += 1 }, settings: { settings += 1 }, quit: { quits += 1 })
    defer { bar.stop() }
    bar.update(await coordinator.sessionsSnapshot(), globalPaused: false)
    bar.menu.performActionForItem(at: bar.menu.indexOfItem(withTitle: "显示搜索窗口"))
    bar.menu.performActionForItem(at: bar.menu.indexOfItem(withTitle: "卷设置…"))
    XCTAssertEqual(shown, 1); XCTAssertEqual(settings, 1)
    bar.menu.performActionForItem(at: bar.menu.indexOfItem(withTitle: "暂停所有索引"))
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    while !(await coordinator.isGloballyPausedByUser), ProcessInfo.processInfo.systemUptime < deadline { await Task.yield() }
    let snapshots = await coordinator.sessionsSnapshot()
    XCTAssertTrue(snapshots.first?.pauseReasons.contains(.userGlobal) == true)
    bar.update(snapshots, globalPaused: true)
    let child = try XCTUnwrap(bar.menu.item(withTitle: "Fixture")?.submenu)
    child.performActionForItem(at: 1)
    while !(await coordinator.sessionsSnapshot().first?.pauseReasons.contains(.userVolume) ?? false), ProcessInfo.processInfo.systemUptime < deadline { await Task.yield() }
    let loginIndex = bar.menu.items.firstIndex { $0.title.hasPrefix("登录时启动") }!
    bar.menu.performActionForItem(at: loginIndex)
    XCTAssertEqual(loginService.registerCalls, 1); try login.setEnabled(false)
    bar.menu.performActionForItem(at: bar.menu.indexOfItem(withTitle: "退出 APFSFind"))
    XCTAssertEqual(quits, 1)
    await coordinator.stop()
  }
  func testLoginServiceStatesAndIdempotence() throws {
    let service = FakeLoginService(), controller = LaunchAtLoginController(service: service)
    XCTAssertEqual(controller.description, "未启用")
    try controller.setEnabled(true); try controller.setEnabled(true)
    XCTAssertEqual(service.registerCalls, 1); XCTAssertEqual(controller.description, "已启用")
    service.status = .requiresApproval; controller.refresh()
    XCTAssertTrue(controller.enabled); XCTAssertEqual(controller.description, "需要用户批准")
    try controller.setEnabled(false); try controller.setEnabled(false)
    XCTAssertEqual(service.unregisterCalls, 1)
    service.status = .notFound; controller.refresh(); XCTAssertTrue(controller.description.contains("注册失败"))
  }
  func testLoginRegisterAndUnregisterErrorsAreVisible() throws {
    let service = FakeLoginService(), controller = LaunchAtLoginController(service: service)
    service.fails = true; XCTAssertThrowsError(try controller.setEnabled(true))
    XCTAssertEqual(controller.status, .notRegistered); XCTAssertNotNil(controller.error)
    service.fails = false; try controller.setEnabled(true); XCTAssertNil(controller.error)
    service.fails = true; XCTAssertThrowsError(try controller.setEnabled(false))
    XCTAssertEqual(controller.status, .enabled); XCTAssertNotNil(controller.error)
  }
  func testHiddenStartupPreferencePersistenceAndReopen() throws {
    let suite = "apfsfind-desktop-test-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = DesktopLaunchPreferences(defaults: defaults)
    XCTAssertTrue(preferences.shouldShowAtColdStart)
    preferences.hideOnColdStart = true
    XCTAssertFalse(DesktopLaunchPreferences(defaults: defaults).shouldShowAtColdStart)
    var shown = 0; preferences.handleReopen { shown += 1 }
    XCTAssertEqual(shown, 1)
    preferences.hideOnColdStart = false; XCTAssertTrue(preferences.shouldShowAtColdStart)
  }
  func testBackgroundMenuStatusPriorityAndPausedPresentation() {
    let volume = DesktopLifecycleVolumes().volume
    func snapshot(_ state: VolumeSessionState) -> VolumeSessionSnapshot {
      .init(volume: volume, state: state, searchAvailable: true, freshness: .live,
        indexedEntries: 1, snapshotBytes: 0, unreadableDirectories: 0, pendingReplayEvents: 0)
    }
    XCTAssertEqual(BackgroundStatusPresentation(sessions: [snapshot(.live)]).symbol, "magnifyingglass")
    XCTAssertEqual(BackgroundStatusPresentation(sessions: [snapshot(.paused)]).symbol, "pause.circle")
    for state: VolumeSessionState in [.opening, .queuedForInitialIndex, .scanning, .baseReady, .catchingUp, .rebuilding] {
      XCTAssertEqual(BackgroundStatusPresentation(sessions: [snapshot(state)]).symbol, "arrow.triangle.2.circlepath")
    }
    XCTAssertEqual(BackgroundStatusPresentation(sessions: [snapshot(.failed("error")), snapshot(.paused)]).symbol, "exclamationmark.triangle")
    XCTAssertEqual(BackgroundStatusPresentation(sessions: [snapshot(.offline)]).title, "暂无在线索引")
    XCTAssertFalse(AppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
  }
  func testRepeatedSleepWakePreservesUserPauseAndStopsObservation() async {
    let provider = DesktopLifecycleVolumes()
    let coordinator = MultiVolumeCoordinator(provider: provider, maintenance:.init(), factory: { v, _ in DesktopLifecycleSession(v) })
    await coordinator.start(); await coordinator.setVolumePaused(provider.volume.volumeUUID, enabled: true)
    let workspace = FakeWorkspace(), lifecycle = WorkspaceLifecycleController(coordinator: coordinator, provider: workspace)
    lifecycle.start(); workspace.handler?(.sleep); workspace.handler?(.sleep)
    await lifecycle.waitForPendingActions()
    var states = await coordinator.sessionsSnapshot()
    XCTAssertEqual(states.first?.pauseReasons, [.userVolume, .systemSleep])
    workspace.handler?(.wake); workspace.handler?(.wake); await lifecycle.waitForPendingActions()
    states = await coordinator.sessionsSnapshot()
    XCTAssertEqual(states.first?.pauseReasons, [.userVolume])
    lifecycle.stop(); XCTAssertNil(workspace.handler); await coordinator.stop()
  }
}
