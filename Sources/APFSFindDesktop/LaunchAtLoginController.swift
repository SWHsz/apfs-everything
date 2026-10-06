import Combine
import Foundation
import ServiceManagement

@MainActor
protocol LoginItemService {
  var status: SMAppService.Status { get }
  func register() throws
  func unregister() throws
}
@MainActor
struct MainAppLoginItemService: LoginItemService {
  var status: SMAppService.Status { SMAppService.mainApp.status }
  func register() throws { try SMAppService.mainApp.register() }
  func unregister() throws { try SMAppService.mainApp.unregister() }
}
@MainActor
final class LaunchAtLoginController: ObservableObject {
  @Published private(set) var status: SMAppService.Status
  @Published private(set) var error: String?
  private let service: any LoginItemService
  init(service: any LoginItemService = MainAppLoginItemService()) {
    self.service = service; status = service.status
  }
  var enabled: Bool { status == .enabled || status == .requiresApproval }
  var description: String {
    if error != nil { return "注册失败" }
    switch status {
    case .enabled: return "已启用"
    case .notRegistered: return "未启用"
    case .requiresApproval: return "需要用户批准"
    case .notFound: return "注册失败：应用不可用"
    @unknown default: return "状态未知"
    }
  }
  func refresh() { status = service.status }
  func setEnabled(_ enabled: Bool) throws {
    refresh()
    do {
      if enabled && !self.enabled { try service.register() }
      else if !enabled && self.enabled { try service.unregister() }
      error = nil; refresh()
    } catch {
      self.error = String(describing: error); refresh(); throw error
    }
  }
}
@MainActor
final class DesktopLaunchPreferences: ObservableObject {
  @Published var hideOnColdStart: Bool {
    didSet { defaults.set(hideOnColdStart, forKey: "hideSearchOnColdStart") }
  }
  private let defaults: UserDefaults
  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults; hideOnColdStart = defaults.bool(forKey: "hideSearchOnColdStart")
  }
  var shouldShowAtColdStart: Bool { !hideOnColdStart }
  func handleReopen(show: () -> Void) { show() }
}
