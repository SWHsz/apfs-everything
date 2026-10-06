import APFSFindCore

/// Reports observed reads only. macOS does not expose a general FDA status check.
struct DirectoryAccessStatus {
  let incompleteReads: Int
  let permissionDeniedReads: Int
  let datalessSkips: Int
  var hasIssues: Bool { incompleteReads > 0 }
  var showsSettingsHelp: Bool { !hasIssues || permissionDeniedReads > 0 }
  var otherFailures: Int { max(0, incompleteReads - permissionDeniedReads - datalessSkips) }
  init(sessions: [VolumeSessionSnapshot]) {
    let active = sessions.filter { $0.state != .offline }
    incompleteReads = active.reduce(0) { $0 + $1.unreadableDirectories }
    permissionDeniedReads = active.reduce(0) { $0 + $1.permissionDeniedReads }
    datalessSkips = active.reduce(0) { $0 + $1.datalessSkips }
  }
  var title: String {
    hasIssues ? "本次运行累计 \(incompleteReads) 次读取未完成，部分结果可能不完整" : "目录访问设置"
  }
  var details: String {
    var reasons: [String] = []
    if permissionDeniedReads > 0 { reasons.append("权限或系统保护拒绝 \(permissionDeniedReads) 次") }
    if datalessSkips > 0 { reasons.append("为避免下载云端占位文件跳过 \(datalessSkips) 次") }
    if otherFailures > 0 { reasons.append("其他读取失败 \(otherFailures) 次") }
    return reasons.joined(separator: "；")
  }
  var guidance: String {
    if !hasIssues { return "可按需在系统设置中管理完全磁盘访问权限。" }
    if permissionDeniedReads > 0 {
      return "这些记录不代表未开启完全磁盘访问；普通文件权限和系统保护仍可能拒绝读取。修改授权后请退出并重新打开应用。"
    }
    if datalessSkips > 0 && otherFailures == 0 {
      return "跳过云端占位是为了避免自动下载，不需要调整完全磁盘访问权限。"
    }
    return "这些是本次运行的读取记录，不用于判断完全磁盘访问权限是否开启。"
  }
}
