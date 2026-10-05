import APFSFindCore
import AppKit
import Darwin

public enum FileAction: Sendable, Equatable { case open, reveal, copyPath }
public enum FileActionOutcome: Sendable, Equatable { case success, missing, failed }
@MainActor
protocol FileActionRouting {
  func open(_ path: String) -> Bool
  func reveal(_ path: String)
  func copy(_ path: String)
}
@MainActor
struct WorkspaceFileActionRouting: FileActionRouting {
  func open(_ path: String) -> Bool { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
  func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
  func copy(_ path: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string) }
}
@MainActor
final class FileActionController {
  private let routing: any FileActionRouting
  private let exists: @Sendable (String) -> Bool
  private let reconcile: @Sendable (VolumeSearchHit) async -> Void
  init(routing: any FileActionRouting = WorkspaceFileActionRouting(),
       exists: @escaping @Sendable (String) -> Bool = { path in var info = stat(); return lstat(path, &info) == 0 },
       reconcile: @escaping @Sendable (VolumeSearchHit) async -> Void = { _ in }) {
    self.routing = routing; self.exists = exists; self.reconcile = reconcile
  }
  func perform(_ action: FileAction, hit: VolumeSearchHit) async -> FileActionOutcome {
    if action == .copyPath { routing.copy(hit.path); return .success }
    let check = exists, path = hit.path
    guard await Task.detached(priority: .userInitiated, operation: { check(path) }).value else {
      await reconcile(hit); return .missing
    }
    if action == .reveal { routing.reveal(path); return .success }
    return routing.open(path) ? .success : .failed
  }
}
