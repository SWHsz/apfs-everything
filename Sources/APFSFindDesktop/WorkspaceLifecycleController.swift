import APFSFindCore
import AppKit

enum WorkspaceLifecycleEvent: Sendable { case sleep, wake, volumesChanged }
@MainActor
protocol WorkspaceLifecycleProviding {
  func start(_ handler: @escaping @MainActor @Sendable (WorkspaceLifecycleEvent) -> Void)
  func stop()
}
@MainActor
final class WorkspaceLifecycleProvider: WorkspaceLifecycleProviding {
  private var observers: [NSObjectProtocol] = []
  func start(_ handler: @escaping @MainActor @Sendable (WorkspaceLifecycleEvent) -> Void) {
    stop()
    for (name, event) in [(NSWorkspace.willSleepNotification, WorkspaceLifecycleEvent.sleep),
                           (NSWorkspace.didWakeNotification, .wake),
                           (NSWorkspace.didMountNotification, .volumesChanged),
                           (NSWorkspace.didUnmountNotification, .volumesChanged)] {
      observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { handler(event) }
      })
    }
  }
  func stop() {
    for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    observers = []
  }
}
/// Serialize notification actions so a wake cannot overtake a sleep teardown.
@MainActor
final class WorkspaceLifecycleController {
  private let coordinator: MultiVolumeCoordinator
  private let provider: any WorkspaceLifecycleProviding
  private var task: Task<Void, Never>?
  private var stopped = false
  init(coordinator: MultiVolumeCoordinator, provider: any WorkspaceLifecycleProviding = WorkspaceLifecycleProvider()) {
    self.coordinator = coordinator; self.provider = provider
  }
  func start() {
    stopped = false
    provider.start { [weak self] event in self?.receive(event) }
  }
  private func receive(_ event: WorkspaceLifecycleEvent) {
    guard !stopped else { return }
    let previous = task, coordinator = coordinator
    task = Task {
      await previous?.value
      guard !Task.isCancelled else { return }
      switch event {
      case .sleep: await coordinator.setAllPaused(.systemSleep, enabled: true)
      case .wake:
        await coordinator.refreshMountedVolumes()
        await coordinator.setAllPaused(.systemSleep, enabled: false)
      case .volumesChanged: await coordinator.refreshMountedVolumes()
      }
    }
  }
  func waitForPendingActions() async { await task?.value }
  func stop() { stopped = true; provider.stop(); task?.cancel() }
}
