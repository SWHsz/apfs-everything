import APFSFindCore
import Combine
import Foundation

protocol DesktopSearching: Sendable {
  func submit(_ request: SearchRequest) async -> MultiVolumeSearchResult?
  func cancel() async
}
extension LatestSearchController: DesktopSearching {}

@MainActor
final class SearchViewModel: ObservableObject {
  @Published var query = "" { didSet { if oldValue != query { scheduleQuery() } } }
  @Published private(set) var hits: [VolumeSearchHit] = []
  @Published var selectedIndex = 0
  @Published private(set) var sessions: [VolumeSessionSnapshot] = []
  @Published private(set) var searching = false
  @Published private(set) var pending = false
  @Published private(set) var latency = 0.0
  @Published var message: String?
  @Published var hotKeyWarning: String?
  @Published var focusToken = 0
  private let service: any DesktopSearching
  private let actions: FileActionController
  private var task: Task<Void, Never>?, spinner: Task<Void, Never>?
  private var cancellation = SearchCancellationToken()
  private var latestID: UInt64 = 0
  private let debounce: Duration
  var hide: () -> Void = {}
  init(service: any DesktopSearching, actions: FileActionController, debounce: Duration = .milliseconds(40)) {
    self.service = service; self.actions = actions; self.debounce = debounce
  }
  var selectedHit: VolumeSearchHit? { hits.indices.contains(selectedIndex) ? hits[selectedIndex] : nil }
  var warningCount: Int { sessions.reduce(0) { $0 + $1.unreadableDirectories } }
  var indexedVolumes: Int { sessions.filter(\.searchAvailable).count }
  var catchingUpVolumes: Int { sessions.filter { $0.searchAvailable && $0.freshness != .live }.count }
  var offlineVolumes: Int { sessions.filter { $0.state == .offline }.count }
  func updateSessions(_ values: [VolumeSessionSnapshot]) {
    let old = Set(sessions.filter(\.searchAvailable).map(\.id))
    sessions = values
    // A newly searchable/remounted volume refreshes the existing query.
    if old != Set(values.filter(\.searchAvailable).map(\.id)), !query.isEmpty { scheduleQuery() }
    let available = Set(values.filter(\.searchAvailable).map(\.id))
    hits.removeAll { !available.contains($0.volumeUUID) }; clampSelection()
  }
  private func scheduleQuery() {
    latestID &+= 1; let id = latestID, text = query
    cancellation.cancel(); task?.cancel(); spinner?.cancel()
    cancellation = SearchCancellationToken(); let token = cancellation
    searching = false; pending = !text.isEmpty; message = nil
    if text.isEmpty {
      hits = []; selectedIndex = 0; latency = 0
      Task { await service.cancel() }; return
    }
    task = Task { [weak self] in
      guard let self else { return }
      do { try await Task.sleep(for: debounce) } catch { return }
      guard id == latestID, !Task.isCancelled else { return }
      spinner = Task { [weak self] in
        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        if self?.latestID == id { self?.searching = true }
      }
      let result = await service.submit(.init(id: id, query: text, limit: 50, cancellation: token))
      guard latestID == id, !Task.isCancelled, !token.isCancelled else { return }
      spinner?.cancel(); searching = false; pending = false
      guard let result, result.requestID == id, !result.cancelled else { return }
      hits = result.hits; selectedIndex = 0; latency = result.latencyMilliseconds
    }
  }
  func moveSelection(_ delta: Int) { selectedIndex += delta; clampSelection() }
  private func clampSelection() { selectedIndex = max(0, min(selectedIndex, max(0, hits.count - 1))) }
  func perform(_ action: FileAction, hit: VolumeSearchHit? = nil) async {
    guard let hit = hit ?? selectedHit else { return }
    switch await actions.perform(action, hit: hit) {
    case .success:
      if action == .copyPath { message = hit.freshness == .live ? "路径已复制" : "路径已复制；该结果可能已变更" }
      else { hide() }
    case .missing:
      hits.removeAll { $0.id == hit.id }; clampSelection(); message = "该项目已移动或删除"
    case .failed: message = "无法打开该项目"
    }
  }
  func cancel() async {
    latestID &+= 1; cancellation.cancel(); task?.cancel(); spinner?.cancel()
    await service.cancel(); pending = false; searching = false
  }
}
