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
  @Published private(set) var sort: SearchSortDescriptor
  private let defaults: UserDefaults
  private var searchVisible = true
  private var deferredSort: SearchSortDescriptor?
  @Published var query = "" { didSet { if oldValue != query { scheduleQuery() } } }
  @Published private(set) var hits: [VolumeSearchHit] = []
  @Published var selectedIndex = 0
  @Published private(set) var sessions: [VolumeSessionSnapshot] = []
  @Published private(set) var searching = false
  @Published private(set) var pending = false
  @Published private(set) var hasMoreResults = false
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
  private static let pageSize = 50
  private var resultLimit = SearchViewModel.pageSize
  var hide: () -> Void = {}
  init(service: any DesktopSearching, actions: FileActionController, debounce: Duration = .milliseconds(40), defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let key = defaults.string(forKey:"lastSortKey").flatMap(SearchSortKey.init(rawValue:)) ?? .relevance
    let direction = defaults.string(forKey:"lastSortDirection").flatMap(SortDirection.init(rawValue:))
    sort = .init(key:key,direction:direction)
    deferredSort = nil
    self.service = service; self.actions = actions; self.debounce = debounce
  }
  var metadataAvailable: Bool { !sessions.filter(\.searchAvailable).isEmpty && sessions.filter(\.searchAvailable).allSatisfy(\.metadataAvailable) }
  var metadataWarning: String? {
    if !metadataAvailable { return "正在建立文件大小与修改时间索引" }
    if sessions.contains(where: { $0.searchAvailable && $0.metadataFreshness == .catchingUp }) { return "元数据正在更新，顺序可能短暂变化" }
    return nil
  }
  func selectSort(_ key: SearchSortKey) {
    guard !key.requiresMetadata || metadataAvailable else { return }
    deferredSort = nil
    let direction:SortDirection = key == .relevance ? .ascending : (sort.key == key ? (sort.direction == .ascending ? .descending : .ascending) : key.defaultDirection)
    sort = .init(key:key,direction:direction)
    defaults.set(key.rawValue,forKey:"lastSortKey"); defaults.set(direction.rawValue,forKey:"lastSortDirection")
    scheduleQuery()
  }
  func sortTitle(_ key:SearchSortKey,_ title:String)->String { sort.key == key ? title + (sort.direction == .ascending ? " ↑" : " ↓") : title }
  func setSearchVisible(_ visible:Bool) {
    searchVisible = visible
    if !visible {
      latestID &+= 1; cancellation.cancel(); task?.cancel(); spinner?.cancel()
      pending = false; searching = false
    }
  }
  var selectedHit: VolumeSearchHit? { hits.indices.contains(selectedIndex) ? hits[selectedIndex] : nil }
  var accessStatus: DirectoryAccessStatus { .init(sessions: sessions) }
  var warningCount: Int { accessStatus.incompleteReads }
  var indexedVolumes: Int { sessions.filter(\.searchAvailable).count }
  var catchingUpVolumes: Int { sessions.filter { $0.searchAvailable && $0.freshness != .live }.count }
  var offlineVolumes: Int { sessions.filter { $0.state == .offline }.count }
  func updateSessions(_ values: [VolumeSessionSnapshot]) {
    let oldMetadata = sessions.map { "\($0.id):\($0.metadataAvailable):\($0.metadataFreshness):\($0.metadataGeneration)" }
    let old = Set(sessions.filter(\.searchAvailable).map(\.id))
    sessions = values
    if sort.key.requiresMetadata && !metadataAvailable {
      deferredSort = sort; sort = .init(); if !query.isEmpty { scheduleQuery() }
    } else if metadataAvailable, let preferred = deferredSort {
      sort = preferred; deferredSort = nil; if !query.isEmpty { scheduleQuery() }
    } else if oldMetadata != values.map({ "\($0.id):\($0.metadataAvailable):\($0.metadataFreshness):\($0.metadataGeneration)" }), !query.isEmpty { scheduleQuery(resetLimit:false) }
    // A newly searchable/remounted volume refreshes the existing query.
    if old != Set(values.filter(\.searchAvailable).map(\.id)), !query.isEmpty { scheduleQuery() }
    let available = Set(values.filter(\.searchAvailable).map(\.id))
    hits.removeAll { !available.contains($0.volumeUUID) }; clampSelection()
  }
  func loadMore() {
    guard hasMoreResults, !pending, !query.isEmpty else { return }
    resultLimit += Self.pageSize
    scheduleQuery(resetLimit: false)
  }
  func refreshQuery() { if !query.isEmpty { scheduleQuery(resetLimit: false) } }
  private func scheduleQuery(resetLimit: Bool = true) {
    if resetLimit {
      resultLimit = Self.pageSize; hasMoreResults = false
      hits = []; selectedIndex = 0
    }
    guard searchVisible else { return }
    latestID &+= 1; let id = latestID, text = query
    let order = sort
    let limit = resultLimit, selectedID = selectedHit?.id
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
      // One extra hit distinguishes exactly one full page from truncated results.
      let result = await service.submit(.init(id: id, query: text, limit: limit + 1, cancellation: token, sort:order))
      guard latestID == id, !Task.isCancelled, !token.isCancelled else { return }
      spinner?.cancel(); searching = false; pending = false
      guard let result, result.requestID == id, !result.cancelled else { return }
      hasMoreResults = result.hasMore || result.hits.count > limit
      hits = Array(result.hits.prefix(limit))
      selectedIndex = selectedID.flatMap { id in hits.firstIndex { $0.id == id } } ?? 0
      latency = result.latencyMilliseconds
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
