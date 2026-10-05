import AppKit
import Carbon

@MainActor
protocol HotKeyRegistering: AnyObject {
  func register(_ action: @escaping @MainActor () -> Void) throws
  func unregister()
}
enum HotKeyError: Error, CustomStringConvertible {
  case registration(OSStatus)
  var description: String { switch self { case .registration(let code): return "Option+Space 注册失败（\(code)）；快捷键可能已被占用。可从菜单打开搜索。" } }
}
@MainActor
final class CarbonHotKeyRegistrar: HotKeyRegistering {
  private var hotKey: EventHotKeyRef?
  private var handler: EventHandlerRef?
  private var action: (@MainActor () -> Void)?
  func register(_ action: @escaping @MainActor () -> Void) throws {
    guard hotKey == nil else { return }
    self.action = action
    var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let opaque = Unmanaged.passUnretained(self).toOpaque()
    let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
      guard let data, let event else { return OSStatus(eventNotHandledErr) }
      var key = EventHotKeyID()
      guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &key) == noErr,
            key.signature == 0x41504653, key.id == 1 else { return OSStatus(eventNotHandledErr) }
      MainActor.assumeIsolated { Unmanaged<CarbonHotKeyRegistrar>.fromOpaque(data).takeUnretainedValue().action?() }
      return noErr
    }, 1, &type, opaque, &handler)
    guard installed == noErr else { self.action = nil; throw HotKeyError.registration(installed) }
    let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), EventHotKeyID(signature: 0x41504653, id: 1),
                                     GetApplicationEventTarget(), 0, &hotKey)
    guard status == noErr else { unregister(); throw HotKeyError.registration(status) }
  }
  func unregister() {
    if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil
    if let handler { RemoveEventHandler(handler) }; handler = nil; action = nil
  }
}
@MainActor
final class GlobalHotKeyController {
  private let registrar: any HotKeyRegistering
  private let toggle: @MainActor () -> Void
  private(set) var registered = false
  init(registrar: any HotKeyRegistering = CarbonHotKeyRegistrar(), toggle: @escaping @MainActor () -> Void) {
    self.registrar = registrar; self.toggle = toggle
  }
  func start() throws { guard !registered else { return }; try registrar.register(toggle); registered = true }
  func stop() { guard registered else { return }; registrar.unregister(); registered = false }
}
