import APFSFindCore
import AppKit
import SwiftUI

@MainActor
final class VolumeSettingsViewModel: ObservableObject {
  @Published private(set) var volumes: [VolumeDescriptor] = []
  @Published private(set) var selected: Set<UUID> = []
  @Published private(set) var sessions: [VolumeSessionSnapshot] = []
  @Published private(set) var storage:[UUID:IndexStorageStatus] = [:]
  @Published private(set) var progress:[UUID:IndexStorageMigrationProgress] = [:]
  @Published private(set) var storageErrors:[UUID:String] = [:]
  private let coordinator: MultiVolumeCoordinator
  init(coordinator: MultiVolumeCoordinator) { self.coordinator = coordinator }
  var accessStatus: DirectoryAccessStatus { .init(sessions: sessions) }
  func storageDescription(_ id:UUID) -> String {
    switch sessions.first(where:{$0.id == id})?.state {
    case .indexStorageOffline: return "索引存储离线"
    case .indexStorageReadOnly: return "索引存储只读"
    case .indexStorageLowSpace: return "索引存储空间不足"
    case .migratingStorage: return "正在迁移索引"
    default: break
    }
    switch storage[id]?.state {
    case .available: return "可用"
    case .migrating: return "正在迁移索引"
    case .offline: return "索引存储离线"
    case .readOnly: return "索引存储只读"
    case .lowSpace: return "索引存储空间不足"
    case .identityChanged: return "存储卷身份已变化"
    case .unsafePath: return "存储路径不安全"
    case .failed: return "存储访问失败"
    case nil: return "正在检查"
    }
  }
  func refresh(_ states: [VolumeSessionSnapshot]? = nil) async {
    let mounted = await coordinator.mountedVolumes()
    let values: [VolumeSessionSnapshot]
    if let states { values = states } else { values = await coordinator.sessionsSnapshot() }
    let ids = await coordinator.selectedVolumes()
    var known = Dictionary(uniqueKeysWithValues: mounted.map { ($0.volumeUUID, $0) })
    for value in values { known[value.id] = value.volume }
    volumes = known.values.sorted { $0.isSystemVolume != $1.isSystemVolume ? $0.isSystemVolume : $0.displayName < $1.displayName }
    selected = ids; sessions = values
    progress = await coordinator.storageProgress()
    for state in values {
      if let value = try? await coordinator.storageStatus(state.id) { storage[state.id] = value }
    }
  }
  func chooseStorage(_ id:UUID) {
    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
    panel.prompt = "存放索引"; panel.message = "选择本地 APFS 卷或目录。索引会放入专用 APFSFindIndexes 目录。"
    panel.begin { [weak self] response in
      guard response == .OK,let path = panel.url?.path else { return }
      Task { @MainActor in
        do { let policy = try await Task.detached { try IndexStorageResolver().policy(for:path) }.value; await self?.move(id,to:policy) }
        catch { self?.storageErrors[id] = String(describing:error) }
      }
    }
  }
  func move(_ id:UUID,to policy:IndexStoragePolicy) async {
    storageErrors[id] = nil
    do {
      if StorageNativeSmokeValidation.enabled {
        _ = try await StorageNativeSmokeValidation.move(coordinator,id:id,policy:policy)
      } else {
        _ = try await coordinator.moveStorage(id,to:policy)
      }
    }
    catch { storageErrors[id] = String(describing:error) }
    await refresh()
  }
  func cancelMigration(_ id:UUID) async { await coordinator.cancelStorageMigration(id); await refresh() }
  func deleteOldCopy(_ id:UUID) async {
    do { try await coordinator.deleteOldIndexCopy(id) }
    catch { storageErrors[id] = String(describing:error) }
    await refresh()
  }
  func retryStorage() async { await coordinator.refreshMountedVolumes(); await refresh() }
  func setSelected(_ id: UUID, enabled: Bool) async { await coordinator.setVolumeSelected(id, selected: enabled); await refresh() }
}
struct VolumeSettingsView: View {
  @ObservedObject var model: VolumeSettingsViewModel
  @ObservedObject var login: LaunchAtLoginController
  @ObservedObject var launchPreferences: DesktopLaunchPreferences
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("索引卷").font(.title2)
      Toggle("登录时启动", isOn: Binding(get: { login.enabled }, set: { try? login.setEnabled($0) }))
      Text(login.error.map { "注册失败：" + $0 } ?? login.description).font(.caption).foregroundStyle(.secondary)
      Toggle("登录启动时隐藏搜索窗口", isOn: $launchPreferences.hideOnColdStart)
      Text("开启后每次冷启动隐藏窗口；再次打开应用或按 Option+Space 显示搜索。")
        .font(.caption).foregroundStyle(.secondary)
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
                Text("文件大小与修改时间：" + (status.metadataAvailable ? (status.metadataFreshness == .live ? "就绪" : "正在更新") : "正在建立索引"))
                  .font(.caption).foregroundStyle(.secondary)
                if let location = model.storage[volume.volumeUUID] {
                  Text("来源卷："+location.resolved.sourceVolumeUUID.uuidString).font(.caption).textSelection(.enabled)
                  Text("索引存储："+location.resolved.absoluteDirectory).font(.caption).textSelection(.enabled)
                  Text("存储卷："+location.resolved.storageVolumeUUID.uuidString).font(.caption).textSelection(.enabled)
                  Text("挂载点："+location.resolved.storageMountPath).font(.caption)
                  Text("存储状态："+model.storageDescription(volume.volumeUUID)).font(.caption)
                  Text("索引 \(ByteCountFormatter.string(fromByteCount:Int64(clamping:location.indexBytes),countStyle:.file)) · 迁移需要 \(ByteCountFormatter.string(fromByteCount:Int64(clamping:location.requiredMigrationBytes),countStyle:.file)) · 压缩需要 \(ByteCountFormatter.string(fromByteCount:Int64(clamping:location.requiredCompactionBytes),countStyle:.file)) · 可用 \(ByteCountFormatter.string(fromByteCount:Int64(clamping:location.availableBytes),countStyle:.file))").font(.caption)
                }
                HStack {
                  Button("移动索引…") { model.chooseStorage(volume.volumeUUID) }.disabled(!status.metadataAvailable || status.state == .migratingStorage)
                  Button("使用默认内部存储") { Task { await model.move(volume.volumeUUID,to:.defaultInternal) } }.disabled(!status.metadataAvailable || status.state == .migratingStorage)
                  Button("取消迁移") { Task { await model.cancelMigration(volume.volumeUUID) } }.disabled(status.state != .migratingStorage)
                  Button("删除旧索引副本") { Task { await model.deleteOldCopy(volume.volumeUUID) } }.disabled(status.state != .live)
                  Button("重试") { Task { await model.retryStorage() } }
                }.controlSize(.small)
                if let value = model.progress[volume.volumeUUID] {
                  Text("\(value.phase) · \(value.copiedBytes)/\(value.totalBytes) 字节 · \(value.file)").font(.caption)
                }
                if let error = model.storageErrors[volume.volumeUUID] { Text(error).font(.caption).foregroundStyle(.orange) }
                if let error = status.metadataError { Text(error).font(.caption).foregroundStyle(.orange) }
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
    }.padding(22).frame(width: 600, height: 530).task { login.refresh(); await model.refresh() }
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
