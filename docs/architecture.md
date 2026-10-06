# v0.4 engine and desktop architecture

## v0.4.1 Background Lifecycle

StatusBarController 订阅 session observation，图标/菜单按通知更新；无循环动画或周期 timer。
LaunchAtLoginController 包装 SMAppService.mainApp，CI 使用 fake，不修改 runner 登录项。
隐藏启动设置是明确的冷启动策略，applicationShouldHandleReopen 和热键仍显示窗口。
WorkspaceLifecycleController 顺序处理 sleep/wake/mount 通知，wake 先发现卷，再移除 systemSleep。
每个 session 的 userGlobal/userVolume/systemSleep reason set 独立；不清除其他暂停来源。
暂停 flush callback → stop stream → drain writer，内存 fence 与 namespace overlay 保留；恢复验证 identity 并 replay。
history/device/root identity 改变走现有 recovery。暂停取消尚未执行的 compaction，不强制写全量 base。
状态栏退出与 Command+Q 共用 fast shutdown；关闭最后一个窗口不退出。

`APFSFindDesktop`（AppKit / SwiftUI / Carbon）与 `APFSFindCore` 在同一进程。
UI 只在 MainActor 更新视图与调用 NSWorkspace；扫描、映射校验、查询、replay 和 compaction 在后台。
`CAPFSShim` 只封装 Darwin 目录枚举、元数据和 best-effort I/O policy。

## Readiness 与查询

Warm：opening → baseReady → catchingUp → live。Cold：scanning → 发布 v2 → baseReady → catchingUp → live。
失效时合法旧 base 保持可搜索，状态为 rebuildingUsingOldBase；失败/卸载/停止则不参与查询。
AsyncStream 使用最新值缓冲，SwiftUI 不轮询内部锁。baseReady 允许搜索，但 replay 完成前结果可能短暂陈旧。

SearchRequest 带 request ID 和取消 token；每 4096 records 检查取消。
HybridIndex 在短锁内捕获 base 强引用、COW 位图与 delta，随后在锁外扫描。
LatestSearchController 取消上个请求，并拒绝发布已过期的结果；UI 加 40 ms debounce。
排序为 exact、prefix、substring，同级 folded basename、完整 path、卷名、UUID。
桌面按 50 条递增展示，每次查询额外获取 1 条判断是否还有结果；加载更多扩大有界 top-k，
保留选中项，更改查询恢复第一页。加载请求同样使用取消 token / latest ID，旧分页不能覆盖新查询。

## Replay 与持久 cursor

FullHistory 保留。初始 replay 中仅已证明安全的普通事件且可靠 ID <= replay floor 才跳过；
HistoryDone、MustScanSubDirs、Dropped、Wrapped、RootChanged、mount/unmount、未知事件或不可靠 ID 永远不跳过。
Floor 来自完全匹配的 state、否则 header、冷扫描的 scan-before E0。
**durable cursor 不能跨过尚未进入对应持久 base 的 namespace mutation。**
state 绑定 snapshot UUID、generation、length、payload CRC、volume/history UUID；不匹配则回退 header。
FSEvents 继续 per-device stream / history UUID；时间基准保持目标 SDK 的 1970，未改成 2001。

## 维护与退出

CompactionScheduler 是单次 work item；达到普通阈值等待 quiet period，后续 mutation 重排；
safety threshold 立即触发，失败退避，无 mutation 时不产生周期唤醒。
MaintenanceScheduler 在所有卷间串行 cold scan、rebuild、compaction；在线更新、查询和 state-only 写入可以并行。
支持 FIFO、可配置优先级、取消排队任务和运行任务的安全取消。

桌面与 CLI :quit 使用 .fast：停 watcher、drain 已交付事件；namespace 与 base 一致才推进 128-byte state。
小 overlay 保留在 RAM 至退出，不重写 base，不越过未持久 namespace；下次从保守 cursor replay。
显式 :compact / forceCompact 保留完整持久化能力。旧 stop(saveCheckpoint:) convenience 保留兼容行为。

## 多卷与桌面

VolumeIndexSession 独立包装 PersistentIndexCoordinator。MultiVolumeCoordinator 按 UUID 维护 session、
并行扇出查询并合并 global top 50，按 UUID + canonical path 去重，部分失败仍返回其他卷结果。
生产卷发现使用 getfsstat 的本地挂载表；排除网络、autofs、辅助 APFS、Data 重叠视图。
系统 / 默认启用，其余必须用户选择；UserDefaults 保存 selectedVolumeUUIDs。
NSWorkspace mount/unmount 通知重新枚举：卸载停止 watcher、取消维护并进入 offline，重新挂载恢复缓存。

NSPanel 承载 SwiftUI，Carbon RegisterEventHotKey 注册 Option+Space，无 CGEventTap。
搜索面板使用 normal level / 非 floating panel，热键显示时移动到当前 Space；不常驻其他应用之上。
访问提示来自 session 的累计读取计数，单独提供 permission denied / dataless skips；排除 offline session 的历史失败。
零失败只显示中性设置帮助，不将读取失败映射为 FDA 未授权状态。
打开/Finder 前后台 lstat；不存在则移除当前结果并请求父目录 scoped reconcile。
复制路径允许历史路径。使用 SF Symbols，无逐行同步真实图标读取。

## Snapshot v2 与原有引擎细节

### 格式与恢复

~~~text
<root + volume UUID 的 SHA256>.apfsidx         immutable namespace base
<同名>.apfsidx.state                         128-byte durable cursor
<同名>.apfsidx.lock                          zero-byte publisher lock
~~~

缓存文件为 0600，包含文件名元数据。snapshot v2 使用显式 little-endian 的 256-byte header、
40-byte record、原名/折叠名 blob、child ordinal table 和 footer CRC；仅 root 保存完整路径。
reader 校验 owner/type/mode、大小、CRC、所有 section、UTF-8/fold、父子/子树/排序及卷/root/history 身份。
有效 v1 会显示 `startup_mode=format_migration_rebuild`，执行一次扫描写 v2，后续直接映射。
损坏或身份不匹配的快照走 `rebuild_fallback`。

state 只有 UUID、generation、length、payload CRC、volume/history 完全匹配时生效。
损坏/旧 state 被忽略并退回 header cursor，基础索引保持可用。
内存 namespace 还未持久化时，state 不能越过那些变化；内容事件可以只推进 state。

冷启动：设备 E0 → 全量扫描 → 发布 v2 → 映射 → 从 E0 replay → HistoryDone → live。
warm：校验并映射 v2 → 目录映射/空 overlay → 从匹配 state 或 header cursor replay → live。
FSEvents 使用 per-device stream，绑定 history UUID。时间参数保持目标 SDK 要求的 **1970 epoch**；
通过可注入 CF 时钟在 API 边界转换，本机已经实测验证。

普通在线更新不写索引、state、WAL 或日志文件。
后台 compaction 达到阈值并安静一段时间后，捕获 base/overlay/G/C/epoch，继续处理并缓冲事件，
在后台合并生成 v2、fsync、只读映射并校验，然后短暂在 writer 上确认身份/epoch、原子发布和切换，
重放缓冲事件。缓冲的 namespace 仍留在 overlay，header cursor 保持捕获时的保守值。
掉事件、overflow、取消、身份/epoch 改变或写入/校验失败保留原 final 与当前内存状态，退避后重试。
发布阶段 rename/目录 fsync 在 writer barrier 中；完整生成和校验在后台。

| 默认 compaction 策略 | 值 |
| --- | --- |
| live overlay / estimated bytes | 50,000 / 64 MiB |
| base tombstone count / ratio | 50,000 / 5% |
| overlay/base ratio | 5% |
| quiet window / estimated memory safety trigger | 2 s / 128 MiB |

`CompactionPolicy` 可注入较低阈值用于测试。delta 删除立即回收记录，整数槽复用；合并清空位图与 overlay。
存储持续不可写时不能保证阈值内存上限，错误/重试状态会显示在 stats。
