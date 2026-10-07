import APFSFindCore
import SwiftUI

struct SearchView: View {
  @ObservedObject var model: SearchViewModel
  let settings: () -> Void
  @FocusState private var inputFocused: Bool
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("搜索文件名", text: $model.query).textFieldStyle(.plain).font(.title2)
          .focused($inputFocused).accessibilityIdentifier("search-input")
        if !model.query.isEmpty { Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
        Button(action: settings) { Image(systemName: "gearshape") }.buttonStyle(.plain).help("卷设置")
      }.padding(18)
      HStack {
        Text("\(model.indexedVolumes) 个可搜索卷")
        if model.catchingUpVolumes > 0 { Text("\(model.catchingUpVolumes) 个正在更新") }
        if model.offlineVolumes > 0 { Text("\(model.offlineVolumes) 个离线") }
        Spacer()
        if model.searching { ProgressView().controlSize(.small); Text("搜索中") }
      }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.bottom, 10)
      if model.accessStatus.hasIssues { PermissionStatusView(status: model.accessStatus) }
      if model.sessions.contains(where: { $0.state == .paused }) {
        Text("索引已暂停，结果可能不是最新").font(.caption).foregroundStyle(.orange).padding(8)
      }
      if let warning = model.hotKeyWarning { Text(warning).font(.caption).foregroundStyle(.orange).padding(8) }
      if let message = model.message { Text(message).font(.caption).foregroundStyle(.orange).padding(8) }
      if let warning = model.metadataWarning { Text(warning).font(.caption).foregroundStyle(.secondary).padding(6) }
      HStack(spacing:12) {
        Button(model.sortTitle(.name,"名称")) { model.selectSort(.name) }.frame(width:190,alignment:.leading)
        Text("所在位置").frame(maxWidth:.infinity,alignment:.leading)
        Button(model.sortTitle(.modificationTime,"修改时间")) { model.selectSort(.modificationTime) }
          .disabled(!model.metadataAvailable).frame(width:140,alignment:.leading)
        Button(model.sortTitle(.size,"大小")) { model.selectSort(.size) }.disabled(!model.metadataAvailable).frame(width:90,alignment:.trailing)
        Text("卷").frame(width:70,alignment:.trailing)
        Button("相关性") { model.selectSort(.relevance) }
      }.font(.caption).buttonStyle(.plain).padding(.horizontal,18).padding(.vertical,8)
      Divider()
      ScrollViewReader { reader in
        ScrollView {
          LazyVStack(spacing: 2) {
            ForEach(Array(model.hits.enumerated()), id: \.element.id) { index, hit in
              SearchResultRow(hit: hit, selected: index == model.selectedIndex)
                .id(hit.id).contentShape(Rectangle())
                .onTapGesture(count: 2) { Task { await model.perform(.open, hit: hit) } }
                .onTapGesture { model.selectedIndex = index }
            }
            if model.hasMoreResults {
              Button(model.pending ? "正在加载…" : "加载更多结果") { model.loadMore() }
                .disabled(model.pending).padding(12)
                .accessibilityIdentifier("load-more-results")
            }
          }.padding(8)
        }.onChange(of: model.selectedIndex) { _, _ in if let hit = model.selectedHit { reader.scrollTo(hit.id) } }
      }
      if model.hits.isEmpty {
        Text(model.query.isEmpty ? "输入文件名开始搜索" : (model.pending ? "正在搜索…" : "没有匹配结果"))
          .font(.callout).foregroundStyle(.secondary).padding(10)
      }
      Divider()
      HStack {
        Text(model.hasMoreResults ? "已显示 \(model.hits.count) 条，仍有更多" : "\(model.hits.count) 条")
        Text("· \(model.latency, specifier: "%.1f") ms")
        Spacer()
        Text("↑↓ 选择   ↵ 打开   ⌘↵ Finder   ⌘C 路径   Esc 隐藏")
      }.font(.caption2).foregroundStyle(.secondary).padding(10)
    }.frame(minWidth: 940, minHeight: 450)
      .onAppear { inputFocused = true }
      .onChange(of: model.focusToken) { _, _ in inputFocused = true }
  }
}
struct SearchResultRow: View {
  let hit: VolumeSearchHit
  let selected: Bool
  private var symbol: String {
    switch hit.kind { case .file: "doc"; case .directory: "folder"; case .symlink: "link"; case .other: "questionmark.square" }
  }
  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: symbol).font(.title3).frame(width: 24)
      Text(URL(fileURLWithPath:hit.path).lastPathComponent).lineLimit(1).frame(width:154,alignment:.leading)
      Text(PathCanonicalizer.parent(of:hit.path)).font(.caption).foregroundStyle(.secondary)
        .lineLimit(1).truncationMode(.middle).frame(maxWidth:.infinity,alignment:.leading)
      Text(ResultFormatting.time(hit.modificationTimeNanoseconds)).font(.caption).frame(width:140,alignment:.leading)
      Text(ResultFormatting.size(hit.logicalSize)).font(.caption).frame(width:90,alignment:.trailing)
      VStack(alignment:.trailing) {
        Text(hit.volumeName).font(.caption).lineLimit(1)
        if hit.freshness != .live { Text(hit.freshness == .pausedStale ? "已暂停" : "正在更新").font(.caption2).foregroundStyle(.orange) }
      }.frame(width:70,alignment:.trailing)
      Spacer().frame(width:36)
    }.padding(10).background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
      .clipShape(RoundedRectangle(cornerRadius: 6))
  }
}
