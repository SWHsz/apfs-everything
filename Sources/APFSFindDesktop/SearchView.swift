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
      if model.warningCount > 0 { PermissionStatusView() }
      if let warning = model.hotKeyWarning { Text(warning).font(.caption).foregroundStyle(.orange).padding(8) }
      if let message = model.message { Text(message).font(.caption).foregroundStyle(.orange).padding(8) }
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
          }.padding(8)
        }.onChange(of: model.selectedIndex) { _, _ in if let hit = model.selectedHit { reader.scrollTo(hit.id) } }
      }
      if model.hits.isEmpty {
        Text(model.query.isEmpty ? "输入文件名开始搜索" : (model.pending ? "正在搜索…" : "没有匹配结果"))
          .font(.callout).foregroundStyle(.secondary).padding(10)
      }
      Divider()
      HStack {
        Text("\(model.hits.count) 条 · \(model.latency, specifier: "%.1f") ms")
        Spacer()
        Text("↑↓ 选择   ↵ 打开   ⌘↵ Finder   ⌘C 路径   Esc 隐藏")
      }.font(.caption2).foregroundStyle(.secondary).padding(10)
    }.frame(minWidth: 720, minHeight: 450)
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
      VStack(alignment: .leading, spacing: 3) {
        Text(URL(fileURLWithPath: hit.path).lastPathComponent).font(.body).lineLimit(1)
        Text(PathCanonicalizer.parent(of: hit.path)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
      }
      Spacer(minLength: 8)
      VStack(alignment: .trailing) {
        Text(hit.volumeName).font(.caption)
        if hit.freshness != .live { Text("正在更新").font(.caption2).foregroundStyle(.orange) }
      }
    }.padding(10).background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
      .clipShape(RoundedRectangle(cornerRadius: 6))
  }
}
