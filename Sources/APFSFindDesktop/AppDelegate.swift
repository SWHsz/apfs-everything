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
  private var workspaceObservers: [NSObjectProtocol] = []
  private var terminating = false
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular); installMenu()
    do {
      let preferences = try AppPreferences(arguments: Array(CommandLine.arguments.dropFirst()))
      let coordinator = try preferences.coordinator(); self.coordinator = coordinator
      let latest = LatestSearchController(coordinator: coordinator); self.latest = latest
      let actions = FileActionController(reconcile: { hit in await coordinator.reconcile(hit) })
      let model = SearchViewModel(service: latest, actions: actions); self.model = model
      settingsModel = VolumeSettingsViewModel(coordinator: coordinator)
      panel = SearchPanelController(model: model, rememberPosition: preferences.testRoots.isEmpty, reportFocus: !preferences.testRoots.isEmpty, settings: { [weak self] in self?.showSettings() })
      hotKey = GlobalHotKeyController(toggle: { [weak self] in self?.panel?.toggle() })
      do { try hotKey?.start() } catch { model.hotKeyWarning = String(describing: error) }
      panel?.show()
      stateTask = Task { [weak self] in
        await coordinator.start()
        for await snapshots in await coordinator.sessionsStream() {
          if Task.isCancelled { break }
          self?.model?.updateSessions(snapshots)
          await self?.settingsModel?.refresh(snapshots)
        }
      }
      for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { _ in
          Task { await coordinator.refreshMountedVolumes() }
        })
      }
    } catch {
      let alert = NSAlert(); alert.messageText = "APFSFind 无法启动"; alert.informativeText = String(describing: error); alert.runModal()
      NSApp.terminate(nil)
    }
  }
  private func installMenu() {
    let menu = NSMenu(), appMenu = NSMenu(), top = NSMenuItem()
    menu.addItem(top); top.submenu = appMenu
    let search = NSMenuItem(title: "显示搜索", action: #selector(showSearch), keyEquivalent: "f"); search.target = self; appMenu.addItem(search)
    let settings = NSMenuItem(title: "卷设置…", action: #selector(showSettings), keyEquivalent: ","); settings.target = self; appMenu.addItem(settings)
    appMenu.addItem(.separator()); appMenu.addItem(NSMenuItem(title: "退出 APFSFind", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    NSApp.mainMenu = menu
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { panel?.show(); return true }
  @objc private func showSearch() { panel?.show() }
  @objc private func showSettings() {
    guard let settingsModel else { return }
    if settingsWindow == nil {
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 430), styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.title = "APFSFind — 卷设置"; window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(rootView: VolumeSettingsView(model: settingsModel)); window.center(); settingsWindow = window
    }
    Task { await settingsModel.refresh() }; settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if terminating { return .terminateLater }; terminating = true
    hotKey?.stop(); panel?.stop(); stateTask?.cancel()
    for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }; workspaceObservers = []
    Task {
      await model?.cancel(); await coordinator?.stop(policy: .fast)
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
