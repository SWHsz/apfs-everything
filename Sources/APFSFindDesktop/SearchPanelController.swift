import AppKit
import Carbon
import SwiftUI

@MainActor
final class SearchPanelController: NSObject, NSWindowDelegate {
  let panel: NSPanel
  private let model: SearchViewModel
  private var keyMonitor: Any?
  private(set) var lastShowToFocusMilliseconds: Double?
  private var showStarted: Double?
  private var focusObserver: NSObjectProtocol?
  private let reportFocus: Bool
  init(model: SearchViewModel, rememberPosition: Bool = true, reportFocus: Bool = false, settings: @escaping () -> Void) {
    self.model = model; self.reportFocus = reportFocus
    panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 780, height: 550),
                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    super.init()
    panel.title = "APFSFind"; panel.isReleasedWhenClosed = false; panel.isFloatingPanel = false
    panel.hidesOnDeactivate = false; panel.level = .normal
    panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    panel.contentView = NSHostingView(rootView: SearchView(model: model, settings: settings)); panel.delegate = self
    if rememberPosition {
      panel.setFrameAutosaveName("APFSFindSearchPanel")
      if !panel.setFrameUsingName("APFSFindSearchPanel") { panel.center() }
    } else { panel.center() }
    model.hide = { [weak self] in self?.hide() }
    focusObserver = NotificationCenter.default.addObserver(forName: NSControl.textDidBeginEditingNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.recordFocus() }
    }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      let handled = MainActor.assumeIsolated {
        guard let self, NSApp.keyWindow === self.panel else { return false }
        switch event.keyCode {
        case UInt16(kVK_UpArrow): self.model.moveSelection(-1)
        case UInt16(kVK_DownArrow): self.model.moveSelection(1)
        case UInt16(kVK_Escape): self.hide()
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter):
          let action: FileAction = event.modifierFlags.contains(.command) ? .reveal : .open
          Task { await self.model.perform(action) }
        case UInt16(kVK_ANSI_C) where event.modifierFlags.contains(.command): Task { await self.model.perform(.copyPath) }
        default: return false
        }
        return true
      }
      return handled ? nil : event
    }
  }
  func show() {
    showStarted = ProcessInfo.processInfo.systemUptime
    NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil); model.focusToken += 1
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.recordFocus()
    }
  }
  private func recordFocus() {
    guard panel.isKeyWindow, let editor = panel.firstResponder as? NSTextView, editor.isFieldEditor, let started = showStarted else { return }
    lastShowToFocusMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000; showStarted = nil
    if reportFocus { FileHandle.standardOutput.write(Data("[smoke] input_focus_ms=\(lastShowToFocusMilliseconds!)\n".utf8)) }
  }
  func hide() {
    let wasVisible = panel.isVisible; panel.orderOut(nil)
    if reportFocus && wasVisible { FileHandle.standardOutput.write(Data("[smoke] panel_hidden\n".utf8)) }
  }
  func toggle() { if panel.isVisible && panel.isKeyWindow { hide() } else { show() } }
  func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }
  func stop() { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil; if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }; focusObserver = nil; hide() }
}
