import APFSFindCore
import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var coordinator: MultiVolumeCoordinator?
  private var latest: LatestSearchController?
  private var model: SearchViewModel?
  private var panel: SearchPanelController?
  private var hotKey: GlobalHotKeyController?
  private var settingsModel: VolumeSettingsViewModel?
  private var settingsWindow: NSWindow?
  private var stateTask: Task<Void, Never>?
  private var lifecycle: WorkspaceLifecycleController?
  private var statusBar: StatusBarController?
  private let login = LaunchAtLoginController()
  private let launchPreferences = DesktopLaunchPreferences()
  private var terminating = false
  private var resourceSmokeTask: Task<Void,Never>?
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular); installMenu()
    do {
      let preferences = try AppPreferences(arguments: Array(CommandLine.arguments.dropFirst()))
      if !preferences.testRoots.isEmpty {
        FileHandle.standardOutput.write(Data("[smoke] login_status=\(login.description)\n".utf8))
      }
      let coordinator = try preferences.coordinator(); self.coordinator = coordinator
      let latest = LatestSearchController(coordinator: coordinator); self.latest = latest
      let actions = FileActionController(reconcile: { hit in await coordinator.reconcile(hit) })
      let model = SearchViewModel(service: latest, actions: actions); self.model = model
      settingsModel = VolumeSettingsViewModel(coordinator: coordinator)
      panel = SearchPanelController(model: model, rememberPosition: preferences.testRoots.isEmpty, reportFocus: !preferences.testRoots.isEmpty, settings: { [weak self] in self?.showSettings() })
      hotKey = GlobalHotKeyController(toggle: { [weak self] in self?.panel?.toggle() })
      do { try hotKey?.start() } catch { model.hotKeyWarning = String(describing: error) }
      if launchPreferences.shouldShowAtColdStart { panel?.show() }
      statusBar = StatusBarController(coordinator: coordinator, login: login,
        show: { [weak self] in self?.panel?.show() }, settings: { [weak self] in self?.showSettings() },
        quit: { NSApp.terminate(nil) })
      lifecycle = WorkspaceLifecycleController(coordinator: coordinator); lifecycle?.start()
      stateTask = Task { [weak self] in
        await coordinator.start()
        self?.startResourceSmoke(coordinator)
        for await snapshots in await coordinator.sessionsStream() {
          if Task.isCancelled { break }
          self?.model?.updateSessions(snapshots)
          self?.statusBar?.update(snapshots, globalPaused: await coordinator.isGloballyPausedByUser)
          await self?.settingsModel?.refresh(snapshots)
        }
      }
    } catch {
      let alert = NSAlert(); alert.messageText = "APFSFind 无法启动"; alert.informativeText = String(describing: error); alert.runModal()
      NSApp.terminate(nil)
    }
  }
  private func startResourceSmoke(_ coordinator:MultiVolumeCoordinator) {
    guard Bundle.main.bundleIdentifier?.hasPrefix("local.apfsfind.desktop.smoke.") == true,
      Bundle.main.object(forInfoDictionaryKey:"APFSFindResourceSmoke") as? Bool == true else { return }
    resourceSmokeTask = Task { [weak self] in
      self?.panel?.hide()
      let deadline = ProcessInfo.processInfo.systemUptime+1800
      var nextReport = ProcessInfo.processInfo.systemUptime+30
      while ProcessInfo.processInfo.systemUptime < deadline {
        if ProcessInfo.processInfo.systemUptime >= nextReport {
          if let data = try? await coordinator.resourceDiagnosticsJSON() { Self.smoke("startup_progress",data:data) }
          nextReport += 30
        }
        let states = await coordinator.sessionsSnapshot()
        if states.count == 2 && states.allSatisfy({$0.state == .live && $0.metadataAvailable}) {
          do { try await Task.sleep(for:.seconds(2)) } catch { return }
          let settled = await coordinator.sessionsSnapshot()
          if settled.count == 2 && settled.allSatisfy({$0.state == .live && $0.metadataAvailable}) { break }
        }
        do { try await Task.sleep(for:.milliseconds(250)) } catch { return }
      }
      let states = await coordinator.sessionsSnapshot()
      guard states.count == 2, states.allSatisfy({$0.state == .live && $0.metadataAvailable}) else { Self.smoke("live_timeout",data:Data("{}".utf8)); return }
      // Measure a busy live system too, and explicitly distinguish it from a
      // no-work idle gate. Do not force resource signals to normal to settle it.
      let quiet = states.allSatisfy({$0.maintenanceStatus == nil}) && !SystemResourceSignals.shared.isSampling
      Self.smoke("quiet_start_condition",data:Data(("{\"satisfied\":"+(quiet ? "true" : "false")+"}").utf8))
      self?.panel?.hide()
      if let data = try? await coordinator.resourceDiagnosticsJSON() { Self.smoke("hidden_idle_start",data:data) }
      try? FileHandle.standardOutput.synchronize()
      let before = ProcessResourceSample.capture()
      do { try await Task.sleep(for:.seconds(600)) } catch { return }
      let after = ProcessResourceSample.capture()
      if let data = try? await coordinator.resourceDiagnosticsJSON() { Self.smoke("hidden_idle_600",data:data) }
      if let data = try? JSONSerialization.data(withJSONObject:after.delta(since:before),options:[.sortedKeys]) { Self.smoke("idle_delta",data:data) }
      let originalPressure = SystemResourceSignals.shared.current().memoryPressure
      SystemResourceSignals.shared.simulateMemoryPressureForTesting(.warning)
      do { try await Task.sleep(for:.milliseconds(100)) } catch { return }
      if let data = try? await coordinator.resourceDiagnosticsJSON() { Self.smoke("memory_warning",data:data) }
      SystemResourceSignals.shared.simulateMemoryPressureForTesting(originalPressure)
      Self.smoke("resource_smoke_complete",data:Data("{}".utf8))
    }
  }
  private static func smoke(_ stage:String,data:Data) { FileHandle.standardOutput.write(Data(("[resource-smoke] "+stage+" "+String(decoding:data,as:UTF8.self)+"\n").utf8)) }
  private func installMenu() {
    let menu = NSMenu(), appMenu = NSMenu(), top = NSMenuItem()
    menu.addItem(top); top.submenu = appMenu
    let search = NSMenuItem(title: "显示搜索", action: #selector(showSearch), keyEquivalent: "f"); search.target = self; appMenu.addItem(search)
    let settings = NSMenuItem(title: "卷设置…", action: #selector(showSettings), keyEquivalent: ","); settings.target = self; appMenu.addItem(settings)
    appMenu.addItem(.separator()); appMenu.addItem(NSMenuItem(title: "退出 APFSFind", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    NSApp.mainMenu = menu
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    launchPreferences.handleReopen { panel?.show() }; return true
  }
  @objc private func showSearch() { panel?.show() }
  @objc private func showSettings() {
    guard let settingsModel else { return }
    if settingsWindow == nil {
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 530), styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.title = "APFSFind — 卷设置"; window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(rootView: VolumeSettingsView(model: settingsModel, login: login, launchPreferences: launchPreferences)); window.center(); settingsWindow = window
    }
    Task { await settingsModel.refresh() }; settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if terminating { return .terminateLater }; terminating = true
    resourceSmokeTask?.cancel(); statusBar?.stop(); lifecycle?.stop(); hotKey?.stop(); panel?.stop(); stateTask?.cancel()
    Task {
      await model?.cancel(); await coordinator?.stop(policy: .fast)
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
