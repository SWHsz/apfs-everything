# APFSFind — v0.6.2 Reconciliation Convergence

APFSFind 是一个 macOS 本地文件名搜索工具。按 Option+Space 打开搜索窗口，搜索系统卷与自己选择的本地卷。
Swift 6 / macOS 14+，无第三方 Swift package；目前是可运行的桌面 Alpha。

> 截图位置预留。尚未提供 notarized 安装包，请在本机从源码构建。

v0.6 删除 namespace 和 metadata 两份全量目录路径表，改为按路径组件查找 mmap 中的父子关系。每份热目录缓存默认最多 8192 项，范围 1024–16384；内存压力下会缩小，不会永久记住全部目录。mmap 的文件大小不代表所有页面常驻 RAM。

后台扫描、压缩和元数据重建会根据 CPU、内存、热状态、低电量模式及搜索交互让路。系统繁忙时普通维护可能延迟；搜索和实时小更新继续工作。达到更新层安全上限时会保留回放游标并进入恢复，不会无限增加 RAM。外置索引存储留到 Issue #3 收敛验收完成后（v0.6.3 / Issue #2）。

Issue #1 已关闭：有界 resolver 与内存结构的目标已完成。Issue #3 的 v0.6.2 收敛验收进行中，完成全部门槛前不创建 v0.6 release tag。局部 reconciliation 的资源让步保留 frontier 和安全游标，稍后继续；不会把让步升级为全盘重建。资源诊断和复现命令见 [资源调度](docs/resource-scheduling.md)、[路径解析](docs/path-resolution.md)、[本轮验证记录](docs/v062-validation.md)、[v0.6.1 记录](docs/v061-validation.md) 、[v0.6 记录](docs/v06-validation.md) 和 [STATUS](STATUS.md)。`residency-bench` 只读打开现有缓存；真实 live/桌面 soak 单独记录，二者不可混称。

## 构建与运行

在仓库根目录运行：

```bash
bash scripts/build_app.sh
open dist/APFSFind.app
# 或：bash scripts/run_app.sh
```

产物为 `dist/APFSFind.app`，脚本完成本地 ad-hoc 签名，无需 Apple Developer 账号。
首次启动默认显示窗口，后台开始索引系统根目录 `/`；开启隐藏启动设置后，每次冷启动先在后台运行。首次扫描可能耗时并占用较多内存。
有缓存时校验并映射 base 后立即开放搜索；“正在更新索引”表示仍在 replay，结果可能短暂陈旧。
打开或在 Finder 显示前会检查目标是否仍存在；失效结果会移除并修复对应父目录。

## 常驻后台

关闭搜索窗口后应用继续维护索引。菜单栏图标可显示搜索、查看各卷状态、暂停/恢复全部或单个卷、打开设置和退出。
暂停保留已有结果并显示“结果可能不是最新”；恢复会回放暂停期间的变更。全局恢复不会解除单卷暂停，睡眠唤醒不会解除用户暂停。
菜单通过索引状态通知更新，没有后台定时轮询。Command+Q 和菜单栏退出均走 fast shutdown。

设置页和菜单栏的“登录时启动”使用系统登录项服务，并显示已启用、未启用、需要批准或注册失败。
“登录启动时隐藏搜索窗口”开启后，**每次冷启动都隐藏窗口**；从 Finder/Dock 再次打开运行中的应用或按 Option+Space 会显示窗口。
程序不推测本次启动来源。关闭该设置后启动即显示窗口。

后台验收入口：`.build/release/apfsfind background-bench`（默认 60 秒 idle，随后测 namespace 延迟和暂停 1000 项后的回放）。

## 搜索与快捷键

大小写不敏感文件名子串搜索；默认按 exact、prefix、substring 相关性排序。点击名称、修改时间、大小列头切换全局升降序，相关性按钮恢复默认。排序覆盖所有匹配项和全部所选在线卷，分页保持顺序；上次排序会保存。

文件大小为 logical size，目录不计算递归大小，目录与 symlink 的大小显示“—”；修改时间按本机区域格式显示。旧缓存缺少元数据时，文件名搜索立即可用，后台建立元数据后启用大小/时间排序；更新中显示提示，未知值始终排末尾。

桌面首先显示 50 条，存在更多匹配时明确提示，列表底部可每次加载更多 50 条。CLI 显示最多 50 条。空输入不扫描索引。

| 操作 | 快捷键 |
| --- | --- |
| 显示／隐藏窗口 | Option+Space |
| 选择结果 | ↑ / ↓ |
| 打开 | Enter 或双击 |
| 在 Finder 中显示 | Command+Enter |
| 复制完整路径 | Command+C |
| 隐藏窗口 | Escape |
| 正常退出 | Command+Q |

热键不要求辅助功能权限。注册冲突会在窗口提示；本版固定 Option+Space。
窗口使用普通层级：显示时激活并聚焦输入，切换到其他应用后不会强制置顶。

## 卷与权限

齿轮按钮打开卷设置：系统 `/` 默认开启；其他本地卷只有勾选后才索引。
选择按卷 UUID 保存；卸载后保留离线状态与缓存，重新挂载后恢复。取消选择停止该卷，不删除缓存。
系统 Data 的重叠视图、辅助 APFS 卷、网络卷和 autofs 不作为额外卷索引。

读取提示显示本次运行累计的未完成次数，并区分权限/系统保护拒绝、dataless 跳过与其他错误；
不会据此判断 Full Disk Access 是否开启。零失败时设置页只显示中性访问帮助，不显示橙色警告。
可通过按钮打开系统设置，在 **隐私与安全性 → 完全磁盘访问权限** 中自行添加 APFSFind；随后重启应用。
Full Disk Access 不会覆盖普通文件权限或所有系统保护；程序还会主动跳过需要下载的 dataless 目录。
当前 ad-hoc 构建的签名身份包含 binary 的 cdhash，重新构建后可能需要重新添加/授权该应用。
程序不会绕过权限或请求 root。

## 缓存与安全

默认缓存：`~/Library/Application Support/apfsfind/indexes/`。目录 0700，索引文件 0600；包含敏感文件名元数据。
每个 root + volume UUID 对应 immutable snapshot v2 和 128-byte cursor state。额外的独立 mmap `.apfsmeta` 与 160-byte state 存储大小/修改时间；损坏只重建元数据，文件名索引继续可用。约增加 16.25 bytes/entry；本机两卷 492 万条实测增加约 80.0 MB。
在线更新主要在内存中，达到阈值才后台合并。正常退出采用 fast：小变化不会重写几百 MB 的 base，
下次通过保守 cursor replay 恢复。无周期 compaction timer。

只读取目录项与元数据，不读文件内容，不访问 raw disk，不跟随 symlink 目录，默认不跨设备。
best-effort 禁止 dataless materialization；不联网、无 telemetry、无运行日志文件。
本机实盘测量与限制见 [STATUS.md](STATUS.md)，引擎和格式细节见 [architecture](docs/architecture.md) 与 [metadata-index](docs/metadata-index.md)。

```bash
swift build -c release
swift test
.build/release/apfsfind serve --root "$HOME"
.build/release/apfsfind metadata-bench --entries 100000
```

本机约 451 万条索引的两份 snapshot 合计 **404.89 MB**；warm search-ready 为系统盘 **3.53 s**、Data 1 **1.71 s**。
两次独立复测的两卷查询 p95 为 **55–65 ms**；首次 `config` 的 162.60 ms 尾延迟也完整记录在 STATUS。

## 已知限制

目前单进程、线性子串扫描、SF Symbols 图标；无 fuzzy、内容搜索、预览、后台 daemon 或缓存删除 UI。
未 notarize / App Sandbox；macOS 14、Intel、真实 iCloud dataless 和掉电耐久未专项实机验证。
活动系统目录可能短暂陈旧；特殊节点（例如 Unix socket）的事件交付随系统版本不同。
新扫描、rebuild、compaction 全局串行，以控制多卷维护的峰值内存。

## CLI 与测试（高级使用）

```bash
swift build -c release
swift test
swift test --sanitize=address
.build/release/apfsfind serve --root "$HOME"
.build/release/apfsfind bench --files 1000 --latency-ms 20
.build/release/apfsfind multivolume-bench --entries-per-volume 100000 --volumes 2
.build/release/apfsfind residency-bench --root / --second-root "/Volumes/Data 1" --idle-seconds 600
.build/release/apfsfind lightweight-bench --entries 1000000
.build/release/apfsfind usability-bench --root / --idle-seconds 60
.build/release/apfsfind usability-bench --root "/Volumes/Data 1" --idle-seconds 60
```

`serve` 默认 root 为 `$HOME`。输入文字搜索；`:stats`、`:verify`、`:rebuild`、`:checkpoint`、`:compact`、`:quit` 可用。
base ready 即可输入，catch-up 结果可能陈旧；`:quit` / EOF / 首次 Ctrl+C fast 退出，第二次 Ctrl+C 取消未发布写入。
`--workers 4`、`--latency-ms 20`、`--ephemeral`、`--rebuild-index`、`--cache-dir PATH` 保留。
serve 的 cache-dir 是精确缓存目录；已有目录必须是当前用户所有的 0700，无 symlink，不能位于 root 上方。

原 `persistence-bench`、`hybrid-bench`、`real-disk-bench` 均保留，参数见 `apfsfind --help`。
新 benchmark 最后一行输出 JSON。usability 默认创建并清理自己的 UUID 缓存与测试目录，
先独立冷进程准备 snapshot，再用独立 warm 进程测 search-ready、live、取消、60 秒 idle 和小 overlay fast exit。
`--cache-dir EXISTING_TEST_CACHE` 可测已有测试缓存，程序不会删除传入缓存；不要指向日用索引。
该测量关闭自动 compaction，以隔离退出与 idle 数据；生产应用仍使用默认阈值策略。
multivolume-bench 使用 synthetic mmap，报告两卷并行 global top 50 分位数，不冒充实盘事件延迟。

真实 FSEvents 测试默认运行；仅可选挂载烟测默认跳过：

```bash
APFSFIND_RUN_MOUNT_TESTS=1 swift test --filter NativeMountSmokeTests
```

CI 保留 deterministic、native integration、ASan，并新增桌面构建、bundle 和签名验证。
