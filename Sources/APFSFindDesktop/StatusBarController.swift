import APFSFindCore
import AppKit
import Combine

struct BackgroundStatusPresentation {
  let symbol: String
  let title: String
  init(sessions: [VolumeSessionSnapshot]) {
    let online = sessions.filter { $0.state != .offline }
    if online.contains(where: { if case .failed = $0.state { return true }; return false }) {
      symbol = "exclamationmark.triangle"; title = "部分索引失败"
    } else if !online.isEmpty && online.allSatisfy({ $0.state == .paused }) {
      symbol = "pause.circle"; title = "索引已暂停，结果可能不是最新"
    } else if online.contains(where: { $0.state != .live && $0.state != .paused }) {
      symbol = "arrow.triangle.2.circlepath"; title = "索引正在更新"
    } else {
      symbol = "magnifyingglass"; title = online.isEmpty ? "暂无在线索引" : "索引正常运行"
    }
  }
}
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let coordinator: MultiVolumeCoordinator
  private let login: LaunchAtLoginController
  private let show: () -> Void, settings: () -> Void, quit: () -> Void
  private var sessions: [VolumeSessionSnapshot] = []
  private var globalPaused = false
  private var enabled = true
  private var observation: AnyCancellable?
  var menu: NSMenu { item.menu! }
  init(coordinator: MultiVolumeCoordinator, login: LaunchAtLoginController,
       show: @escaping () -> Void, settings: @escaping () -> Void, quit: @escaping () -> Void) {
    self.coordinator = coordinator; self.login = login
    self.show = show; self.settings = settings; self.quit = quit
    super.init()
    let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false; item.menu = menu
    observation = login.objectWillChange.sink { [weak self] in
      Task { @MainActor in self?.rebuildMenu() }
    }
    update([], globalPaused: false)
  }
  func update(_ snapshots: [VolumeSessionSnapshot], globalPaused: Bool) {
    sessions = snapshots; self.globalPaused = globalPaused
    let status = BackgroundStatusPresentation(sessions: snapshots)
    let image = NSImage(systemSymbolName: status.symbol, accessibilityDescription: status.title)
    image?.isTemplate = true; item.button?.image = image; item.button?.toolTip = status.title
    rebuildMenu()
  }
  func menuNeedsUpdate(_ menu: NSMenu) { login.refresh(); rebuildMenu() }
  private func add(_ title: String, _ selector: Selector?, to menu: NSMenu, value: Any? = nil, checked: Bool = false) {
    let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
    entry.target = self; entry.representedObject = value
    entry.isEnabled = enabled && selector != nil; entry.state = checked ? .on : .off
    menu.addItem(entry)
  }
  private func rebuildMenu() {
    guard let menu = item.menu else { return }; menu.removeAllItems()
    add("显示搜索窗口", #selector(showSearch), to: menu)
    add(BackgroundStatusPresentation(sessions: sessions).title, nil, to: menu)
    add(globalPaused ? "恢复所有索引" : "暂停所有索引", #selector(toggleGlobal), to: menu)
    menu.addItem(.separator())
    for session in sessions {
      let entry = NSMenuItem(title: session.volume.displayName, action: nil, keyEquivalent: "")
      let child = NSMenu(); child.autoenablesItems = false
      add(session.state.description, nil, to: child)
      let paused = session.pauseReasons.contains(.userVolume)
      add(paused ? "恢复索引" : "暂停索引", #selector(toggleVolume(_:)), to: child, value: session.id)
      entry.submenu = child; menu.addItem(entry)
    }
    menu.addItem(.separator())
    add("卷设置…", #selector(showSettings), to: menu)
    add("登录时启动（\(login.description)）", #selector(toggleLogin), to: menu, checked: login.enabled)
    if let error = login.error { add(error, nil, to: menu) }
    menu.addItem(.separator()); add("退出 APFSFind", #selector(quitApp), to: menu)
  }
  @objc private func showSearch() { show() }
  @objc private func showSettings() { settings() }
  @objc private func quitApp() { quit() }
  @objc private func toggleLogin() { try? login.setEnabled(!login.enabled) }
  @objc private func toggleGlobal() {
    let enabled = !globalPaused
    Task { await coordinator.setAllPaused(.userGlobal, enabled: enabled) }
  }
  @objc private func toggleVolume(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? UUID else { return }
    let paused = sessions.first { $0.id == id }?.pauseReasons.contains(.userVolume) ?? false
    Task { await coordinator.setVolumePaused(id, enabled: !paused) }
  }
  func stop() {
    enabled = false; observation?.cancel(); observation = nil
    item.menu?.cancelTracking(); NSStatusBar.system.removeStatusItem(item)
  }
}
