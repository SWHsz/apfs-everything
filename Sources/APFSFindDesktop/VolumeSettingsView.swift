import APFSFindCore
import AppKit
import SwiftUI

@MainActor
final class VolumeSettingsViewModel: ObservableObject {
  @Published private(set) var volumes: [VolumeDescriptor] = []
  @Published private(set) var selected: Set<UUID> = []
  @Published private(set) var sessions: [VolumeSessionSnapshot] = []
  private let coordinator: MultiVolumeCoordinator
  init(coordinator: MultiVolumeCoordinator) { self.coordinator = coordinator }
  var accessStatus: DirectoryAccessStatus { .init(sessions: sessions) }
  func refresh(_ states: [VolumeSessionSnapshot]? = nil) async {
    let mounted = await coordinator.mountedVolumes()
    let values: [VolumeSessionSnapshot]
    if let states { values = states } else { values = await coordinator.sessionsSnapshot() }
    let ids = await coordinator.selectedVolumes()
    var known = Dictionary(uniqueKeysWithValues: mounted.map { ($0.volumeUUID, $0) })
    for value in values { known[value.id] = value.volume }
    volumes = known.values.sorted { $0.isSystemVolume != $1.isSystemVolume ? $0.isSystemVolume : $0.displayName < $1.displayName }
    selected = ids; sessions = values
  }
  func setSelected(_ id: UUID, enabled: Bool) async { await coordinator.setVolumeSelected(id, selected: enabled); await refresh() }
}
struct VolumeSettingsView: View {
  @ObservedObject var model: VolumeSettingsViewModel
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("索引卷").font(.title2)
      Text("系统卷默认启用。其他本地卷只有在你选择后才会建立索引。离线卷的缓存会保留。")
        .font(.callout).foregroundStyle(.secondary)
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          ForEach(model.volumes, id: \.volumeUUID) { volume in
            let status = model.sessions.first { $0.id == volume.volumeUUID }
            VStack(alignment: .leading, spacing: 4) {
              Toggle(isOn: Binding(get: { volume.isSystemVolume || model.selected.contains(volume.volumeUUID) },
                                   set: { enabled in Task { await model.setSelected(volume.volumeUUID, enabled: enabled) } })) {
                Text(volume.displayName + (volume.isSystemVolume ? "（系统卷）" : ""))
              }.disabled(volume.isSystemVolume)
              Text(volume.mountPath).font(.caption).foregroundStyle(.secondary)
              if let status {
                Text("\(status.state.description) · \(status.indexedEntries) 项 · \(Double(status.snapshotBytes) / 1_000_000, specifier: "%.1f") MB")
                  .font(.caption)
                if status.state != .offline && status.unreadableDirectories > 0 {
                  Text("本次运行累计 \(status.unreadableDirectories) 次读取未完成").font(.caption).foregroundStyle(.orange)
                }
              } else { Text("未启用").font(.caption).foregroundStyle(.secondary) }
            }
            Divider()
          }
        }
      }
      PermissionStatusView(status: model.accessStatus)
    }.padding(22).frame(width: 600, height: 430).task { await model.refresh() }
  }
}
struct PermissionStatusView: View {
  let status: DirectoryAccessStatus
  var body: some View {
    HStack(alignment: .top) {
      Image(systemName: status.hasIssues ? "exclamationmark.triangle" : "info.circle")
        .foregroundStyle(status.hasIssues ? Color.orange : Color.secondary)
      VStack(alignment: .leading) {
        Text(status.title)
        if status.hasIssues { Text(status.details).foregroundStyle(.secondary) }
        Text(status.guidance).foregroundStyle(.secondary)
        if status.showsSettingsHelp {
          Text("系统设置 → 隐私与安全性 → 完全磁盘访问权限").foregroundStyle(.secondary)
        }
      }.font(.caption)
      Spacer()
      if status.showsSettingsHelp {
        Button("打开系统设置") {
          if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"), NSWorkspace.shared.open(url) { return }
          NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }.controlSize(.small)
      }
    }.padding(10)
  }
}
