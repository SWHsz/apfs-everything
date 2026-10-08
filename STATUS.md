# v0.6.2 — Reconciliation Convergence（验收进行中）

从 `5588ec7e1305839a81473a535aaadb121d1da0ff` 开始，只处理 Issue #3；Issue #1 已按已有内存证据关闭，roadmap #12 已勾选。Issue #2 不开始，NSv2/metav1 和 cold namespace builder 不变。 `ceec3c7` 完整 275 项及报告提交 `01471da` 的四项 required CI 全绿；其真实双卷20分钟和10轮fixture功能收敛通过，资源gate因physical峰值约177.25MiB及deadline checkpoint未完成失败，最终UI/restart因锁屏待验证。最新候选继续将普通 metadata parent refresh 改为跨slice的bulk page，并拒绝 namespace 未索引的兄弟条目；277项完整ASan已通过，TSan/普通测试及新binary实盘正在验收，旧实盘结果不能替代新候选。

局部修复用有界、合并祖先路径的 `DeferredReconcileQueue` 保存 frontier 与 minimum cursor。每片最多 32 个目录 / 20 ms，查询中至少完成一个原子父目录；one-shot 重试，队列清空后才推进 namespace cursor。权限错误局部保留，反复权威 I/O 失败或 hard overflow 才恢复；真正 stream invalidation 合并为一次 active recovery。Full rebuild 的 yield 重试同一个 recovery epoch，保留旧 base、释放临时 graph，不产生 resource_yield rebuild。

Metadata 连续输入保持既有批次截止时间，subtree continuation 不进入每秒 lookup 限流。普通 metadata inbox 溢出以有界 watched-root traversal 修复，重复溢出在当前 frontier 完成后补偿一轮，游标不越过未完成工作；真正 stream invalidation 仍恢复。Bootstrap 在获准 maintenance lease 后才读取 base，避免排队期间 compaction 发布新 base 后误清空有效 metadata。退出保守保存 cursor，下一次 replay 继续修复。真实卷使用 active-live gate，受控 quiet gate 未放宽。测试与真实 binary 验收见 [v0.6.2 validation](docs/v062-validation.md)，当前 #3 OPEN、无 release tag。

---

# v0.6.1 — Release-Gate Closure（门槛未全部通过）

开始 HEAD `5caf5ce291d16f8b31606268f3d8e9ae13a99433`，最终 runtime 修复 `d962fcc`，测试/捕获工具产物 HEAD `6eb9cec7b0d07193c02d96786b0477fb3ad572fd`。完整提交、数据、复现见 [v0.6.1 validation](docs/v061-validation.md)。

- fast shutdown 在 barrier 前取消 queries/metadata/maintenance；记录十个阶段和每卷耗时，不 detach 后台工作，不发布 partial reconciliation，不推进未持久化 overlay 的 cursor。
- 子树删除走现有 child links；元数据目录局部 EPERM/消失/yield 不再触发整卷 bootstrap。任务记录 overlapping process resource spans、bounded history 和指数 one-shot backoff。
- warning/critical 更换 cache storage；16,384→2,048→1，actual capacity 24,576→3,072→1。独立进程 physical 48.31–48.53→31.38–31.45→31.49–31.55 MiB；旧引用释放，RSS 未立即下降。
- Controlled quiet 60 秒 CPU 0.000156s、disk/logical writes 0；create/delete/rename p95 21.51/21.48/21.66ms。只读 492 万 entries 600 秒 CPU 0.000247s、disk writes 0、logical writes 20,480 bytes、physical 7.50MiB。
- **最终原生 live 双卷 quiet 20 分钟失败**：generation 稳定窗口 0s，未启动 600 秒 idle。非 quiet 1169.955s 中 CPU 118.621s，disk/logical writes 0，末端 physical 44.86MiB/RSS107.03MiB；不能称真实 quiet gate 通过。
- 自动全局暂停/恢复状态通过；owned namespace 12/12，metadata-size verify 超时。reconciliation resource yield 仍升级整卷恢复，被高频验证查询重复打断；菜单单卷暂停/恢复未取得最终人工确认。失败数据保留，不用局部 UI 37-byte 文件观测替代完整 verify。
- 两次受控 restart 的 fixture verify 均通过，仍发生 full scan；第二次两卷 Live/live，query metadata_complete 全 true。两次正常 UI quit 引擎 6.80/109.35ms、exit=0，四个 base 哈希不变。恢复峰值 physical 2045.11MiB，终态88.42MiB；不是 quiet 测量，cold builder 峰值仍未解决。
- 普通/ASan/TSan 各 240 项（220 Core+20 Desktop），0 failures；默认可选 mount skip 单独 opt-in 后通过。release app 0.6.1/601 和签名通过。代码 [CI 37638402037](https://github.com/SWHsz/apfs-everything/actions/runs/37638402037) 四项全绿；报告提交的最终 HEAD CI 在 Issue #1/#3 记录并复核。

**#1/#3 保持 OPEN，没有创建 v0.6 release tag。** #2 外置索引存储未实现；NSv2/metav1 不变，cold namespace builder 未重写。下一步先解决局部 deferred reconciliation 与恢复最终收敛，再决定 #2。

---

# v0.6.0 — Lightweight Residency and Resource-Aware Maintenance

本轮实现与验收记录见 [v0.6 validation](docs/v06-validation.md)。开始 HEAD `9295470152dbb4dd309d2582611111f01ea2074b`，main、工作区干净；用户授权完成后推送并验证最终 CI。

- 删除 `HybridIndex.directoryPaths`、`MetadataIndexCoordinator.directories` 两份全量目录路径 Map。共享 component-walk resolver、parent-keyed overlay、锁外 capture 与旧 mmap 生命周期固定；warm 双 full-map entries=0。
- 四份有界 HotDirectoryCache 默认各 8192、最小 1024、最大 16384，warning 2048、critical root-only；重复目录探测命中约 66.6%，不是日常命中率。
- Metadata seed/bootstrap 使用 compact columns，writer 最大 64 KiB、增量 CRC、完整验证后独立 runtime remap。namespace v2 / metadata v1 格式不变。
- 资源状态机覆盖 CPU EWMA、memory、thermal、low-power 和交互。普通任务等稳定空闲；required 忙时单 worker、查询让路；emergency 保守 fence 和 bounded chunks。无任务 CPU sampler/timer 停止。
- 两卷同数据集 4,923,278 entries：v0.5 两份 Map 共估算 228.45 MiB；600 秒只读末端 physical 302.35 → 8.02 MiB。独立 private ledger unavailable；internal+compressed 仅代理。最终 query 5,031,012 entries、reclaim RSS 399.66 MiB，未达 250 MiB 软目标。
- 真实 1M 条目 metadata-only 新进程 peak RSS 110.25 MiB（通过 ≤400 MiB）；完整 cold namespace+metadata 855.13 MiB，尚未解决 cold FileIndex graph。
- 查询最差 p95 relevance/name 93.39/76.30 ms，size/mtime 124.26/74.66 ms。create/delete/rename p95 21.4–21.8 ms；persistent create/rename/delete 40.55/22.67/22.00 ms。
- 安静 root 60 秒 CPU 0.000238s、disk/logical writes 0、sampler inactive、maintenance timer wakeups 0。真实 CPU busy 0.322% idle 时普通维护延迟，恢复稳定空闲后继续。
- Fake warning/critical cache 5001→2048→1，overlay 保留、yield/old base/emergency 功能通过；系统 footprint 未下降，资源 gate 保持未通过。
- alias 深度 16 / 数量 64 / 估算保留 32 MiB；10k rename 与所有 sort 的 deterministic property tests 覆盖 Unicode/两卷/base/delta。

最终普通/ASan/TSan 各 220 项（200 Core + 20 Desktop），0 failures，1 可选挂载 skip；release app 0.6.0/600 构建、签名通过。原生两卷 live/meta 隐藏 600 秒已完成，末端 physical 138.06 MiB、RSS 265.88 MiB；期间有实际变更和维护，CPU 787.80s，不能当作安静 idle。代码 `ad04d6b` 的 [CI 37606991928](https://github.com/SWHsz/apfs-everything/actions/runs/37606991928) 四项 required jobs 全绿；完整报告及文档补记后的最终 HEAD CI 见 validation 与 Issue #1/#3 结束评论；UI 验收因 Mac 锁屏待验证。Issue #1/#3 按真实 release gates 保持 open；#2 外置索引存储未实现，scope 未改。未打 v0.6.0 release tag。

---

# v0.5.0 — Metadata Index and Sorting

本轮开始 HEAD：`712ede5814cae259cd24029dc92551144e8ac766`，main、起始工作区干净。Milestone A 独立提交 `1d6e9cd`（`feat: add background lifecycle controls`）；Milestone B 使用 `feat: add metadata indexing and result sorting` 独立提交。用户随后明确授权完成后 push；本机最终验收通过，用户授权推送 main；提交对应四个 required jobs 的结果以 GitHub Actions 为准。版本 0.5.0 / bundle build 500。

## 实现

- 菜单栏按 observation 更新，提供搜索、状态、全局/单卷暂停、登录项、设置及退出；无周期轮询。关闭窗口仍运行，隐藏时取消 UI 查询，重显刷新同一词。
- SMAppService.mainApp 包装真实登录项状态/错误；CI 用 fake。明确冷启动隐藏策略，Dock/Finder reopen 与 Option+Space 显示窗口。
- userGlobal/userVolume/systemSleep pause reason set；flush/drain 后停止 watcher，保留可搜索旧结果与 pausedStale。恢复验证卷身份、从安全 cursor replay；wake 先重新发现挂载，不解除用户暂停。
- Namespace snapshot v2 未改布局。独立 metadata v1：256-byte header、size/mtime 两列、两位 validity/entry、16-byte footer；160-byte state。Warm 使用 read-only mmap，不为每文件创建 metadata object。详见 [metadata-index](docs/metadata-index.md)。
- Cold getattrlistbulk 同时获取 size/mtime；旧 cache metadata 缺失或损坏时 namespace 立即可搜索，后台 bootstrap，不重写 namespace。Independent cursor 取 min 启动、不同 overlap floors；dirty overlay 不推进 durable cursor。
- Content/inode 事件 utility queue、200 ms debounce、device/fileID 去重；typed xattr/owner/Finder-only skip。大批次父目录 bulk，稀疏目录使用有界 64-name C microbatch。20k/s lookup 限速、overflow recovery；rename 复用并支持目录后代映射。
- Metadata-only checkpoint 不改写 namespace；namespace compaction 在发布前构建/验证 ordinal 匹配的 metadata tmp。两文件发布失败时新 namespace 保持可用，metadata 单独重建。
- Relevance、name、mtime、size 的全局 bounded top-K，多卷并行合并、unknown last、K+1 hasMore、分页与 cancellation 保留。桌面列头切换/箭头、排序偏好、元数据未就绪禁用、catch-up 提示、共享 formatter、目录大小“—”。

## 本机代码验收（2026-10-07）

原基线157项全部保留。最终普通测试 Core 176 + Desktop 20 = **196项**，0 failures，1项可选真实挂载测试 skip；完整 ASan、TSan 同196项全部通过，无 sanitizer 诊断。普通 Core/desktop 约60.0/0.9s，ASan约156.4/1.0s，TSan约207.4/1.1s。
新增检查覆盖歧义 old-ID、范围外目录移入、debounce 未完成即退出/重启及卷身份改变。歧义 old-ID 回归曾失败（3个断言），揭示 metadata overlap 过滤过宽；现已与 namespace 的可靠普通事件规则对齐。范围外目录后代 metadata、限速 pending 暂停 barrier、fast exit 保守 fence 和当前 namespace 身份校验均已补齐；目录大小在 top-K 候选阶段按 unknown 处理，避免与 namespace 类型不同步的 metadata 影响剪枝。
Release CLI/desktop 与 app 构建通过，Info.plist 0.5.0/500，本地 ad-hoc 签名验证通过；产物 `dist/APFSFind.app`。

## 真实两卷只读 metadata 测量

日用 namespace cache 全程只读，不 replay、不创建 publisher lock、不清理其 tmp；metadata 写在 owned scratch。已有 namespace 可能有 stale paths，匹配失败列为 unknown；此次不是新全盘 namespace freshness 验收。测量没有把真实文件名、查询词或单文件 metadata 写进报告。

| 根目录 | Cached entries | metadata bytes | bytes/entry | build s | CPU s | disk writes bytes | peak RSS MiB |
|---|---:|---:|---:|---:|---:|---:|---:|
| / | 3,308,277 | 53,759,774 | 16.25008 | 65.10 | 165.28 | 53,760,000 | 1060.5 |
| /Volumes/Data 1 | 1,615,001 | 26,244,039 | 16.25017 | 27.36 | 69.14 | 26,247,168 | 1295.3 |

两卷合计 **4,923,278 entries，80,003,813 bytes（80.004 MB / 76.298 MiB）**，小于20 bytes/entry目标。临时构建数组仅用于 bootstrap，不是 warm 查询常驻对象。第二卷 peak RSS 是同一进程累计高水位，不能相加。

每种 sort × exact/substring/one-character/no-result 各20次，limit=51。以下列出各 sort **p95 最慢分类**的分位数（ms）；全部分类原始聚合结果在 [metadata-real.json](docs/benchmarks/v0.5.0/metadata-real.json)。

| Sort | 最慢分类 | p50 | p95 | p99 | max |
|---|---|---:|---:|---:|---:|
| modificationTime_ascending | substring | 68.06 | 68.56 | 68.58 | 68.58 |
| modificationTime_descending | substring | 66.95 | 67.44 | 67.80 | 67.80 |
| name_ascending | substring | 69.52 | 72.34 | 83.22 | 83.22 |
| name_descending | one_character | 68.68 | 75.40 | 84.70 | 84.70 |
| relevance_ascending | substring | 69.05 | 70.58 | 71.61 | 71.61 |
| size_ascending | substring | 69.28 | 139.96 | 260.08 | 260.08 |
| size_descending | substring | 70.13 | 70.72 | 70.76 | 70.76 |

Relevance/name p95均<120ms，size/mtime均<150ms；最终发布构建复测 size ascending substring p95 **139.96ms**、max **260.08ms**，全部 outliers 保留；此前 exact p95 139.09ms 的结果保留在 [前次复测报告](docs/benchmarks/v0.5.0/metadata-real-before-final-kind-guard.json)。首轮 relevance substring p95 **165.56ms 未达标**：重复 basename 的 path tie comparison 分配了大量临时数组。改为 bounded temporary stack traversal，不引入 fast-sort arrays；前次复测该分类 p95 **69.16ms**，最终发布构建为 **70.58ms**。首轮数据也保留在 [优化前报告](docs/benchmarks/v0.5.0/metadata-real-before-path-optimization.json)。

## Owned 100k / 1M 文件与恢复

实际创建文件（100个父目录），不读取内容；写入使用 sparse ftruncate。Namespace compaction 阈值提高以隔离测量，metadata 使用生产阈值。Build为namespace+metadata全闭环，不等同于只写16MB列文件。

| Entries | cold s | metadata bytes | bytes/entry | build CPU s | peak RSS MiB | 10k files converge s | warm replay s |
|---|---:|---:|---:|---:|---:|---:|---:|
| 100,000 | 3.169 | 1,625,272 | 16.25272 | 3.982 | 108.4 | 0.912 | 0.754 |
| 1,000,000 | 37.609 | 16,250,272 | 16.25027 | 38.887 | 946.9 | 2.063 | 1.547 |

100k / 1M 的同文件10,000次写入均 **1 lookup**、namespace generation不变。普通单文件30次更新 p95 **240.94 / 241.60 ms**（目标<500ms）；查询全部28组合最慢p95 **3.71 / 30.21 ms**。Fast exit后 helper修改，重启均与fresh metadata scan一致，namespace full scan=0。

10k文件更新均10,000events、0重复、10,000metadata lookups、200parent microbatches、0parent bulk enumerations；百万fixture该阶段CPU约1.34s，收敛2.063s。稀疏microbatch前百万fixture大父目录bulk重复枚举耗时 **74.598s**（CPU12.56s、读2.60GB），warm replay52.142s。初次20秒 convergence deadline也曾失败；提高诊断超时后保留瓶颈数据，随后优化稀疏父目录访问，复测warm1.547s。详见 [百万优化前报告](docs/benchmarks/v0.5.0/metadata-1m-before-sparse-microbatch.json) 和最终 [100k](docs/benchmarks/v0.5.0/metadata-100k.json) / [1M](docs/benchmarks/v0.5.0/metadata-1m.json)。

## Namespace / idle / desktop smoke

`bench --files 1000 --latency-ms 20`：100次/操作、0timeouts。Create/delete/same-dir rename/cross-dir rename p95 **20.89 / 21.40 / 21.14 / 22.07ms**；1000create/delete storm约87.02/85.06ms，fresh verify missing=extra=0；10k内容写入不产生namespace工作。[报告](docs/benchmarks/v0.5.0/namespace.json)。

首轮 persistent background（30次/操作）p50约19–21ms、p95 **40.49/35.55/41.32ms**，outliers保留；随后persistent100次/操作复测p95 **create21.41 / rename22.89 / delete20.32ms**，与基线约20–25ms一致；create max429.92ms的首次outlier保留。复测60s idle CPU **0.000235s**、物理与逻辑写入0、两种scheduler wakes0，暂停1000项恢复135.55ms、verify通过。[复测报告](docs/benchmarks/v0.5.0/background.json)。60s idle CPU **0.000362s**、disk/logical writes=0、compaction/metadata scheduler wakes=0、periodic polling=0。暂停1000项后265.998ms收敛、stale保留和verify均通过。[首轮报告](docs/benchmarks/v0.5.0/background-first.json)。

独立UUID的 APFSFindMetadataSmoke 使用65个临时文件和独立cache。真实AX确认名称/大小升降序、mtime默认降序、最小项原不在前50仍能排首位、加载更多50→65且名称排序保持。关闭窗口后进程仍运行；helper新增文件并将原最小文件改为9MiB，重显结果66条，大小降序首项正确显示9.4MB及新mtime。测试不修改日用cache。

全局/单卷暂停、pause reason叠加、sleep/wake、挂载变化、login wrapper错误及菜单action均有单元/集成覆盖。用户已人工确认菜单全局/单卷暂停与恢复正常，登录项切换后恢复原设置；真实API设置页显示已启用及metadata就绪。Command+Q后自己的测试进程已退出。系统真实sleep/wake未操作，只通过fake生命周期测试，不将其写成物理睡眠验证通过。Option+Space此前用户已确认实际键盘显示/隐藏正常；自动化注入受焦点切换影响。

## 限制与安全

无snapshot v3、预排序数组、内容索引、root/rawdisk/网络/telemetry/WAL。只读目录项与metadata，nofollow/no-cross-device及dataless best-effort保留。长期checkpoint存储失败时无法保证overlay内存上限；报错并保守回放。旧namespace对应的metadata未知项排末尾；实时更新短暂陈旧有UI提示。系统真实睡眠和登录项权限仍依赖本机macOS用户设置。

---

# v0.4.1 — Background Lifecycle

本轮开始 HEAD：`712ede5814cae259cd24029dc92551144e8ac766`。Milestone A 独立验收记录；后续 Milestone B 完成情况见文首。

- 菜单栏入口、全局与单卷暂停、关闭窗口继续索引、开机启动与隐藏启动偏好已实现。
- 暂停原因分别保存用户全局、用户单卷和系统睡眠；唤醒先刷新挂载，再从内存 cursor 回放，不解除用户暂停。
- 暂停取消未执行的 compaction，已有结果标为 pausedStale；fast 退出不为小 overlay 重写 base。
- 登录项通过 SMAppService.mainApp，状态与错误来自真实 API；普通测试使用 fake，不修改系统登录项。
- 重新显示窗口刷新未修改的查询词，避免沿用隐藏前的结果。

## Milestone A 本机验收（2026-10-06）

完整测试 Core 152 + Desktop 18 = **170 项**，0 failures，1 项可选真实挂载测试 skip。
TSan 子集 Core 11 + Desktop 17 = 28 项通过，0 warnings；后增加的菜单 action 测试通过普通测试。
release CLI、desktop 与 .app 构建、Info.plist 与 ad-hoc 签名验证通过。
基线完整 ASan 157 项通过；新版本完整 sanitizer 验证待 Milestone B 最终执行。
基线 GitHub Actions 四个 job 全部通过：https://github.com/SWHsz/apfs-everything/actions/runs/37460139248 。
此处为 Milestone A 当时的本机记录；最终远端 CI 见文首验收记录。

`background-bench --idle-seconds 60` 使用 owned 临时 root/cache，结果：

| 项目 | 测量 |
|---|---:|
| idle 实测时长 | 60.010 s |
| idle user + system CPU | 0.000189 s |
| idle 磁盘读 / 写 | 0 / 0 bytes |
| compaction 调度唤醒 / 周期轮询 | 0 / 0 |
| create p50 / p95（30 次） | 20.148 / 21.438 ms |
| rename p50 / p95（30 次） | 21.465 / 23.609 ms |
| delete p50 / p95（30 次） | 18.854 / 19.503 ms |
| 暂停期间 1000 个创建后恢复收敛 | 275.016 ms，校验通过 |

create 最大值 388.57 ms，保留首次测量 outlier。benchmark 提高 compaction 阈值以隔离事件与暂停行为；不是生产策略压力测试。

真实 smoke 使用独立 UUID bundle、临时 root 和 cache；搜索、真实 API 登录项状态读取和 watcher 更新已观察。
菜单 action 使用真实 NSMenu.performAction 单元验证；桌面焦点切换影响了部分自动化，真实暂停菜单、登录项开关及系统 sleep/wake 不计为自动化通过。
用户随后指出测试实例已关闭；最新桌面 inventory 确认 APFSFindSmoke 不在运行。测试数据尚保留，未修改日用缓存。

---

# v0.4.0 — Usable Desktop Alpha

## 用户反馈修复（2026-10-06）

- 修复短搜索词隐式截断为前 50 条且无法继续查看的问题：桌面明确显示“仍有更多”，列表底部可递增加载 50 条。
  每次额外取 1 条判断是否截断；加载时保留选中项，换词复位分页并取消旧请求。
  使用 `Net` / `net` / `netforensic`、超过 50 个匹配的真实 FileIndex 和 mmap+overlay 回归场景验证。
  完整测试 Core 146 + Desktop 11 = **157 项**，0 failures、1 项可选挂载测试 skip（Core 51.237 s）。
  含分页修复的发布 `.app` 已重新构建，Info.plist 与签名验证通过。
- 修复设置页在没有读取失败时仍显示橙色警告的问题；无失败时只显示中性的目录访问帮助。
- 读取提示改为本次运行累计次数，区分权限/系统保护拒绝、dataless 跳过和其他读取失败；离线卷历史不计入提示。
  这些计数不是完全磁盘访问权限状态检测；仅有云端占位跳过时不建议修改权限。
- 搜索窗口改为 `.normal`、`isFloatingPanel = false`，热键仍激活窗口并移至当前桌面，取消持续置顶。
- README 说明 POSIX/系统保护边界，以及临时签名的 designated requirement 绑定 cdhash：重建后可能需要重新授权。
- 本机完整测试 Core 145 + Desktop 8 = **153 项**，0 failures、1 项可选真实挂载测试 skip。
  Core 53.643 s、Desktop 0.105 s；发布 `.app` 构建、Info.plist 和 `codesign --verify --deep --strict` 通过。
  窗口层级修改尚未由用户实际重启验证；此次没有重扫全盘或改变持久索引格式。

开始 HEAD：`a90920044806d2aca7d627a59963db4f0da67a8a`（main，工作区干净）。本轮仅本机 Mac 开发。
三个顺序 milestone：A `27e3596`，B `9da1cbb`，C `a5af396`。
验收结束代码 HEAD：`24eb0831d1f8e5c5aa201145d7700bf4dd0c5dd4`；后续提交只更新测量文档。snapshot v2 布局保持不变，原 127 项测试全部保留。

## 已完成实现

- A：baseReady / catchingUp / live 分离；合法旧 base 在 rebuildingUsingOldBase 继续可搜索。
  **baseReady 允许搜索，但 replay 完成前结果可能短暂陈旧。** AsyncStream 状态与 freshness 对外暴露。
  FullHistory 保留，仅可靠普通 overlap ID <= floor 跳过；特殊/歧义/不可靠事件永远处理。
  durable cursor 不跨过未写入对应 base 的 namespace mutation；state 完整绑定 base，失败回退 header。
  每 4096 records 检查 query cancellation；latest request ID 防止旧请求覆盖新结果。
  默认 CLI/桌面 fast 退出，小 overlay 不写 base；namespace 一致时才写 128-byte state。
  CompactionScheduler 单次事件驱动、quiet 重排、safety、失败 backoff；MaintenanceScheduler 全局串行重型任务。
- B：独立 VolumeIndexSession、多卷 actor 并行查询、全局排序/top 50、UUID+path 去重及部分失败结果。
  getfsstat 本地挂载发现，排除网络/autofs/辅助卷/Data 重叠；UserDefaults 按 UUID 保存选择。
  mount/unmount diff；offline 停 watcher/取消排队维护，remount 恢复缓存，取消选择不删除缓存。
- C：APFSFindDesktop / NSPanel + SwiftUI / Carbon Option+Space；40 ms debounce、100 ms 延迟 spinner。
  Enter / 双击打开、Command+Enter Finder、Command+C 路径、Escape 隐藏、Command+Q fast 退出。
  操作前后台 lstat；stale hit 移除并 scoped reconcile。SF Symbols，UI 不执行索引查询或真实图标读取。
  卷设置与基于不可读目录的权限提示；不能精确检测 FDA，用户自行授予。
  `.app` 位于 `dist/APFSFind.app`，稳定 identifier `local.apfsfind.desktop`，本地 ad-hoc signature。

## 本机测试与桌面 smoke（2026-10-06）

原始基线 127 tests 通过。A 136、B 141 tests 通过，均保留默认 native FSEvents 集成。
最终 Core 145 + Desktop 5 = **150 tests**，0 failures；仅可选真实挂载测试 1 skip。
最终代码 macOS 15 CI ASan 完整 150 tests 通过，0 failures。
本机最终普通测试 Core 145 为 51.337 s，Desktop 5 通过；完整 ASan Core 145 为 137.854 s，Desktop 5 通过，
0 AddressSanitizer errors。发布构建、最后一次 bundle 构建、Info.plist 和 ad-hoc signature 验证均通过。
额外 TSan 首次发现 lazy CompactionScheduler 初始化竞态，已改成构造阶段初始化；
修复后的完整 Core 141 + Desktop 5 TSan 通过，0 warnings，不隐藏首次失败。

桌面 actual smoke 使用本任务创建的两个 UUID 临时 root / 专用缓存，未使用日用 cache：

- bundle build、Info.plist、codesign --verify --deep --strict 通过；
- 启动立即显示，输入自动 focus；同名目录搜索返回 A/B 两条；
- ↑↓ 选择、Command+C 出现“路径已复制”；Enter 打开 owned 目录，Command+Enter 在 Finder 选中该目录；
- Settings 取消 B 后仅 A 一条，重新选择 B 后恢复两条；系统项不可关闭；
- Escape 隐藏，公开 open 入口重新显示；真实 Option+Space 由用户明确确认“能正常显示／隐藏”；
- 自动化 Option+Space 注入没有可靠触发 Carbon，**不计作自动化通过**；注册/toggle/conflict/stop wrapper 有单元测试；
- 实际窗口恢复至 input focus **14.00 / 20.19 ms**（初次 56.08 ms）；这些是 focus 通知测量，
  不含无法捕获的物理键按下到 Carbon callback 的传递时间，不冒充完整 key-to-focus 测量；
- Command+Q 正常退出，进程消失；只删除校验 inode/device/owner/mode 后的本任务 UUID fixtures/cache。

新 synthetic mmap benchmark：2 × 100,000 entries、5 warmup + 30 samples、global top 50，
p50 2.943 ms / p90 2.995 / p95 **3.031** / p99 3.047 / max 3.047；RSS 91.28 MB。
真实大索引独立进程测量见下方；synthetic 不替代实盘结果。

## v0.4 实盘结果（2026-10-06，本机 arm64 / macOS 27.0.1 / Xcode 27.0 / Swift 6.4）

所有扫描只读取目录项和元数据；缓存与变更位于本任务新建的 UUID 目录，退出后按 inode/device/owner/mode 验证并清理。
日用 cache 未参与 benchmark，没有删除用户已有缓存。先独立 cold 进程准备、退出，再独立 warm 进程测量。
实盘 worker 提高自动 compaction 阈值以隔离 ready/idle/fast-exit；生产应用阈值未改变。

| root | entries（warm live） | snapshot bytes | warm search-ready | warm live | overlap skipped | query cancel 返回 | small overlay fast exit |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `/` | 3,019,488 | 262,843,841 | 3.530 s | 63.915 s | 790 | 2.647 ms | 0.256 ms |
| `/Volumes/Data 1` | 1,490,087 | 142,042,089 | 1.707 s | 2.768 s | 1,487 | 1.716 ms | 0.158 ms |

两份 snapshot 合计 **404,885,930 bytes / 404.89 MB**；warm 两卷均 full_scans=0。
fast exit 均 compactions=0、实际 disk_bytes_written=0、保留未持久 namespace，未重写 base。
100 rename + create 的独立回归逐字节验证原 base 不变，重新启动 replay 后 verify 一致。
取消的百万 base 正确性、writer 可用、mmap 生命周期由专项测试验证；实盘表中的数值是取消请求至查询返回耗时。

根目录 replay 仍有大量不可安全跳过的历史歧义事件：95,451 directory reconciles、9 subtree reconciles、
4,337 special events，metadata lookup 109；Data 1 为 3,052 / 6 / 2,585 / 320。
Root live 尚需 63.915 s，本轮没有通过丢弃歧义事件加速，也不宣称 live 时间已全面改善。
可搜索时间已独立于 live，分别达到 <5 s / <3 s 目标；replay 中明确显示可能陈旧。
Cold ready/live 为 121.355/187.806 s 与 54.705/55.781 s，peak RSS 2.433 / 1.202 GB。

### Idle

实盘 60 s 中 Root / Data 1 都有 5 次 direct namespace patch，scheduler wakeups 均 0，实际写盘均 0。
Root CPU user+system 5.012 s、实际读取 65,536 bytes；Data 1 CPU 0.00704 s、读取 0。
实盘有系统事件，不能将其称为“完全无 namespace mutation”。
另用独立安静临时 root、**默认生产 compaction policy** 实测 60.005 s：namespace events=0、
compaction scheduler wakeups=0、CPU 0.000177 s、disk read/write=0、进程 idle wakeups=0（interrupt wakeups=2）。
周期 timer 已移除；初始扫描的进度 timer 和真实 FSEvents callback 不计入 compaction scheduler。

### 两卷查询

每个查询独立 5 warmup + 30 samples；global top 50；两个真实 v2 mmap base，由同一 MultiVolumeCoordinator 并行合并。
首次 4,509,567 entries；复测重新准备独立缓存，共 4,509,729 entries。查询 worker 不启动在线 watcher，测量 mapped query 层。

| query | 首次 p95 | 独立复测 1 p95 | 独立复测 2 p95 |
| --- | ---: | ---: | ---: |
| `apfsfi` | 78.414 ms | 65.255 ms | 62.162 ms |
| `swift` | 71.382 ms | 59.874 ms | 62.324 ms |
| `config` | 162.596 ms | 61.128 ms | 61.484 ms |
| `document` | 56.821 ms | 55.088 ms | 56.030 ms |

首次 `config` p95 162.596 ms 超过 120 ms 目标，原结果完整保留；两次复测所有查询 p95 为 55–65 ms，
均低于目标，最高单次 78.949 ms。没有更换搜索算法或减少验证条目来制造达标。
复测 RSS 为 597.80 MB。尾延迟可能受系统调度/内存压力影响，这是推断，本轮没有逐样本证据确定首次 outlier 原因。

### 原 CLI 基准

`bench --files 1000 --latency-ms 20` PASS；create/delete/same-directory rename/cross-directory rename
p95 分别为 **22.126 / 22.450 / 23.512 / 24.844 ms**，各 100 samples、0 timeouts。
10,000 content writes generation 不变、0 reconciliation；create/delete storm verify 均 missing=0 / extra=0。
原 benchmark JSON 的 version 字段沿用 0.3.1（旧 harness），执行的发布 binary 来自本轮 v0.4 代码。

### CI 与诊断

验收代码 `24eb083` 的 [macOS 15 CI](https://github.com/SWHsz/apfs-everything/actions/runs/37346128381)：
**deterministic / integration / address-sanitizer / desktop-build 四项全绿**。
Core / Desktop 全部 150 tests 保留，native FSEvents 默认运行；optional physical mount test 默认 skip。

[首次 CI](https://github.com/SWHsz/apfs-everything/actions/runs/37344187099) 失败保留：
桌面测试固定 30 ms 等待后过早读取空结果；ASan 的 95 ms 并行耗时断言实测 123.456 ms。
`29554f7` 改为等待真实 UI result；`24eb083` 使用同步门直接证明两个查询同时进入，串行实现会超时失败。
并行性能仍由独立 synthetic/实盘 benchmark 验收，没有删除结果/ranking/offline/取消断言或跳过 ASan。
TSan 的 lazy scheduler 初始化竞态在 C 中改为构造期创建；修复后完整本机检查无 warnings。

详细原始输出位于本机 `/private/tmp/apfsfind-v040-*`，不提交日志、私有文件路径列表或索引。

## 当前限制与后续

Alpha 无 notarization、App Sandbox、daemon、fuzzy、内容搜索或自动更新。macOS 14 / Intel / 真实 iCloud dataless
未专项实机验证；本机 macOS 27 / Xcode 27 与 CI macOS 15 都需独立验证。
特殊节点通知随平台不同，保持 v0.3.1 的已知限制；活动系统目录存在 race，不能宣称文件系统原子快照。
热键固定，实际外置设备拔插未做物理测试，UUID fake + 两个真实临时 root 覆盖 lifecycle/replay/verify。
下一版候选：packed directory arena、exact hash、SIMD、可选 trigram/fuzzy、真实图标、menu bar、login、
cache/exclusions UI、XPC、更新与自定义 hotkey；本轮未实现。

---

# v0.3.1 — 稳定性修复与真实磁盘验证

本轮开始：2026-10-05，`main` / `35689d19553f768129fdec493cfd8fcd73c1cc9f`，工作区干净。
仅在本机 Mac 执行；snapshot v2 的 256-byte header、40-byte record、name blobs、child table、footer 均保持原布局。

## v0.3.1 稳定性修复

CI 原失败：macOS 15.7.9 arm64 / Xcode 16.4，构建通过、测试 signal 11。
诊断提交 `8c89167` 将确定性测试、真实 FSEvents 集成测试、ASan 分成三个必需任务。
[诊断 CI](https://github.com/SWHsz/apfs-everything/actions/runs/37302501402) 在独立
`SnapshotAtomicityTests` 中复现，ASan 明确报告 `SnapshotStore.normalizedDirectory` 的
`readlink(alias, &bytes, bytes.count)` **stack-buffer-overflow / WRITE of size 11**。
Xcode 16.4 的导入将 `&[UInt8]` 传给字符指针时指向数组值的栈存储，而非元素缓冲区；
写入 `/private/var` 的字节破坏了相邻 Swift String。不是 FSEvents replay 超时或 mmap swap。
本机 Xcode 27 的基线和 ASan 未复现，说明仅依赖本机成功不足以验收。

- `2589b13`：使用 `[CChar].withUnsafeMutableBufferPointer` 显式传元素地址，新增 `/var`、`/tmp` 的 100 次别名回归。
  [原失败环境修复后 CI](https://github.com/SWHsz/apfs-everything/actions/runs/37302955825)：三个任务全绿。
- `5ccf6e8`：目录身份同时比较 kind、fileID、deviceID、isMountPoint；挂载时清理旧子树，卸载时重读实际子树。
  C shim 元数据边界不变；新目录读取协议仅用于注入确定性 fixture。
  FSEvents context 使用配对的 retain/release callback；stop/invalidate 后仍排空 callback queue，再 release。
  新增 100 次 immediate stop/repeated stop 测试。mmap query 保留强引用到旧 base，原并发替换回归保持通过。
  `cleanupTemps` 使用独立目录描述符，修复 `dup` 共享 EOF 导致重复清理遗漏；fdopendir 失败显式 close。
  [生命周期修复 CI](https://github.com/SWHsz/apfs-everything/actions/runs/37303466053)：三个任务全绿。

FSEvents 时间基准仍为目标 SDK 文档所写的 **1970**；没有改为 2001。
完整原始 CI/ASan/TSan/benchmark 输出保存在本机 `/private/tmp`，不提交大量日志或私人索引。

实盘验证另外发现并修复：本机 Unix socket 创建给出 `0x8000 / ItemXattrMod`，没有 Created 或对象类型。
原分类将其忽略，导致 fresh verify 的两个持久 missing。现仅对已知对象类型的内容标记使用 content-only；
无类型元数据标记交给普通父目录 reconciliation。真实 bind/unlink 回归通过，文件内容写入仍不触发 namespace 工作。
macOS 15 的 [诊断 CI](https://github.com/SWHsz/apfs-everything/actions/runs/37317045458)
只记录到 HistoryDone 和 root Created，2 秒窗口内没有任何 socket 事件，entry=nil。
因此不声称该平台会自动维护 socket：跨 SDK 回归改为真实 bind/unlink + 注入本机捕获的 XattrMod hint，
验证分类和实际目录元数据；普通文件的九项 watcher 测试仍使用真实事件，integration/ASan 仍必需通过。
测试使用 owned `/private/tmp` 短路径并检查 sockaddr_un 容量；初次测试路径过长的 setup 失败已修正。
第一轮系统盘 raw verify 为 compaction 后 missing=4/extra=0、清理后 missing=2/extra=4，
其余差异是活动 Codex cache / 临时文件；没有过滤或改写失败为通过，cache/workload 目录均已清理。
仅排除实际卷根的系统 `.fseventsd`（在数据盘初次测量中产生 7 个 journal missing）；
普通用户目录中同名目录保留。新增 journal 范围与旧 snapshot warm 排除升级回归。

第二轮系统盘：socket 修复后 compaction 的第二次 raw comparison 为 0/0；清理后的三次 raw comparison
分别为 6/24、2/3、3/5，涉及运行中的系统诊断日志轮转、临时文件和 Codex 自身资源更新。
完整尝试保留在 JSON；没有将其写成通过。验证器现先 flush 扫描期间的事件，再用同一安全 bulk reader
复读差异目录，报告 raw 差异与复核后的实际差异，未知元数据保守失败、超过 10k 差异直接失败。
四项回归确保持续 missing/ghost 不会清零、读取失败不会清零、扫描之后创建/删除可被验证为时序变化。
不新增通用 cache/log 排除，不修改在线索引来通过 verify；不声称获得了原子文件系统快照。

## v0.3.1 验证基线

- 初始 release build：PASS；原 105 项测试全部通过。
- 原 RAM benchmark：1,000 storm files / latency 20 ms；create/delete/same/cross rename p95：23.57 / 21.74 / 21.46 / 21.49 ms。
  内容写入 10,000 次，generation 不变、0 reconciles；创建/删除风暴各 verify 0/0。
- 修复前上述三个 suite 各 50 次：全部通过；没有把它当作 CI 崩溃已解决的证据。
- 最终完整普通测试、ASan、TSan：各 127 项，1 个 opt-in mount smoke 默认跳过，0 failures。
  ASan/TSan 均实际执行完整 suite；未通过 skip 环境变量规避原生 watcher。
- 修复后的三个 suite 各 50 次：全部通过。
- 新增进程 I/O API 成功/单调、state-only 写入远小于 full snapshot、ASCII/Unicode/NFD 字节统计、UUID 目录身份与清理拒绝测试。
- 小目录端到端 real-disk-bench：PASS，三个独立进程，10k create / 2k rename / 5k delete，compaction 期间查询，清理与最终 verify 0/0。

## v0.3.1 真实磁盘测量

已采集 `/` 与 `/Volumes/Data 1`；不重复相加 `/System/Volumes/Data`。
每次使用新的 0700 `/private/tmp/apfsfind-real-cache-UUID`，变更只发生于单独 owned UUID 目录。
清理核对规范父路径、精确 UUID、inode/device/type/owner/mode；不接受既有 cache 目录，不跟随 symlink。
冷进程退出后才启动暖进程，空闲 60 秒；测试文件写入在其他进程执行，因此不混入索引进程的 I/O。

实际资源 API：SDK 的 `proc_pid_rusage(..., RUSAGE_INFO_V4, ...)`：`ri_diskio_bytesread`、
`ri_diskio_byteswritten`、`ri_logical_writes`、`ri_phys_footprint`、`ri_lifetime_max_phys_footprint`、wakeups/pageins。
CPU/page faults/peak RSS 使用 getrusage，RSS 使用 mach_task_basic_info。
压缩内存/历史峰值使用目标 SDK 的 TASK_VM_INFO；API 不可用则置 null。
SDK v4 未提供 logical reads：JSON 明确置 null / unavailable。
文件 length、st_blocks×512 与上述进程计数独立报告；没有把文件长度当作真实磁盘写入。
`fsync_validate_publish` 包含 file fsync、只读 validation、directory map、rename 和目录 fsync；
`serialization` 与该阶段不重叠，`.total` 为含 planning 的整体阶段，不与分项累加。
文件系统 metadata overhead 未能从这些公开计数单独分离；没有伪造 SSD 底层写放大量。

## 最终提交与 CI

测量代码 HEAD：`b3a5a7c5c2801a91845045e02962ba823ed76089`；开始 HEAD 为 `35689d19553f768129fdec493cfd8fcd73c1cc9f`。结束文档提交在此代码之后，最终 hash 见 Git history / 本轮回复。
最终代码 [CI run 37322535828](https://github.com/SWHsz/apfs-everything/actions/runs/37322535828)：release build、deterministic、native integration、ASan 全部 PASS，三个 job 无 continue-on-error。
127 项本机普通测试、完整 ASan、完整 TSan：各 1 个默认 opt-in mount skip、0 failures。deterministic 模式 34 skips（仅分类诊断用）；完整原生模式不跳过普通 watcher。
最新三个 suite 各 50 次：SnapshotAtomicityTests / LiveUpdateIntegrationTests / HybridRecoveryTests，150 次退出码全部 0。原 105 项全部保留。
最终 RAM bench（1,000 files / latency 20 ms）create/delete/same/cross rename p95：21.672 / 21.953 / 21.487 / 21.482 ms；10k 内容写入无 namespace 工作，风暴与清理验证通过。

提交：`8c89167` CI 定位；`2589b13` readlink 根因修复；`5ccf6e8` 生命周期/挂载；`b10846f` 真实资源入口；`a109b68` 无类型元数据事件；`bfb9fcc` SDK 事件诊断/保留尝试；`0aecb23` 独立于通知支持的 socket 回归；`b3a5a7c` 保留 raw 的目录差异复核。

## 最终实盘数据

本机 arm64 macOS 27.0.1 (26A434)、Swift 6.4 / SDK 27.0；target macOS 14。日期 2026-10-05，Asia/Tokyo。最后两轮测量期间没有并行运行本机测试或编译；未使用 HPC。单位 MB=1,000,000 bytes。
两 root 独立测量；不相加 `/System/Volumes/Data`。所有 cache/workload 为新建 0700 UUID 目录；三进程结束后已删除。每种查询 first 单列，然后 5 次 warmup + 30 次测量，limit=50。

| 指标 | / | /Volumes/Data 1 |
| --- | --- | --- |
| cold / warm / cleanup PID | 55823 / 56201 / 56823 | 57494 / 57779 / 58122 |
| cold layout records | 3001900 | 1488325 |
| cold snapshot logical bytes / allocated bytes | 261267617 / 272338944 | 141873679 / 147120128 |
| warm cache logical / allocated bytes (含 state/lock) | 261268611 / 265863168 | 141873993 / 141881344 |
| cold time to live ms | 156189.216 | 122596.211 |
| warm time to live ms | 31836.806 | 76731.945 |
| cold startup user / system CPU s | 126.911 / 83.047 | 74.953 / 40.115 |
| warm startup user / system CPU s | 10.305 / 15.110 | 23.231 / 24.888 |
| startup_mode | warm_snapshot | warm_snapshot |
| snapshot_open_ms | 0.018 | 0.019 |
| snapshot_validation_ms | 2606.364 | 1416.944 |
| snapshot_mmap_ms | 1.914 | 0.697 |
| snapshot_restore_ms | 176.702 | 29.994 |
| warm_replay_ms | 29050.168 | 75281.671 |
| warm_replay_events | 4535 | 3987 |
| full_scans | 0 | 0 |
| base_materialized_file_entries | 0 | 0 |
| materialized_file_entries | 0 | 0 |
| base_records | 3001906 | 1488327 |
| base_directories | 498011 | 79126 |
| directory_map_entries | 498011 | 79126 |
| directory_map_estimated_bytes | 93504587 | 14695871 |
| overlay_live_entries | 2 | 0 |
| base_tombstones | 2 | 0 |
| tombstone_bitmap_bytes | 375240 | 186048 |

`snapshot_restore_ms` 在 warm 路径为 directory-map build；“没有 full_scans”并不意味着 replay 没有做目录 I/O，下面列出实际事件/reconciliation 成本。cold 的初始 scan / index build 与总 time-to-live 不等价。

| 内存/空闲 | / | /Volumes/Data 1 |
| --- | --- | --- |
| process start RSS MB | 6.095 | 6.095 |
| before mmap RSS MB | 7.700 | 7.750 |
| immediately after mmap RSS MB | 7.700 | 7.750 |
| after validation RSS MB | 281.756 | 156.369 |
| after directory map RSS MB | 427.901 | 174.195 |
| live RSS MB | 474.792 | 259.424 |
| after 60s idle RSS MB | 475.103 | 259.539 |
| warm startup lifetime peak RSS MB | 512.852 | 259.424 |
| live physical footprint MB | 152.454 | 65.062 |
| live / idle compressed MB | 0.000 / 0.000 | 0.000 / 0.000 |
| cold startup lifetime peak RSS MB | 2459.615 | 1445.102 |
| idle wall ms | 60005.054 | 60005.088 |
| idle user / system CPU s | 1.731 / 0.244 | 0.004 / 0.006 |
| idle process idle / interrupt wakeups | 97 / 194 | 71 / 123 |
| idle compaction_timer_wakeups | 120 | 120 |
| idle fsevents_received | 130 | 1 |
| idle fsevents_processed | 130 | 1 |
| idle ignored_content_events | 62 | 0 |
| idle directory_reconciles | 17 | 0 |
| idle subtree_reconciles | 1 | 0 |
| idle scanner_directories | 17 | 0 |
| idle scanner_entries | 151050 | 0 |

timer 0.5 s 一次只检查 compaction 条件，没有周期性全盘扫描。idle 中有实际 FSEvents；目录读取由 namespace/歧义事件触发。冷启动/verify 会临时分配完整路径集合；它们的 lifetime peak 不能当作 warm 常驻 RAM 或单次 CP 峰值。

### 查询：`/`

| 类型 | 实际 query | 返回 | first ms | p50 | p90 | p95 | p99 | max |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| exact_basename | `046D_B010_0001_000C_real.rpt_desc` | 1 | 28.784 | 23.915 | 24.023 | 24.097 | 24.110 | 24.110 |
| prefix | `046D_` | 50 (limit) | 59.832 | 59.584 | 60.004 | 60.239 | 60.691 | 60.691 |
| substring | `6D_B01` | 15 | 58.413 | 58.531 | 59.371 | 59.646 | 59.670 | 59.670 |
| no_match | `apfsfind-no-match-5E40C444-AD2B-4177-811F-2787DB921CE5` | 0 | 18.303 | 18.042 | 18.293 | 18.338 | 18.855 | 18.855 |
| one_character | `a` | 50 (limit) | 46.921 | 46.660 | 47.612 | 47.810 | 48.183 | 48.183 |
| two_character | `py` | 50 (limit) | 65.278 | 64.278 | 65.332 | 65.647 | 66.332 | 66.332 |

| 类型 | base p50/p95/p99 ms | overlay p50/p95/p99 | path p50/p95/p99 | 30次 user/system CPU s | minor/major faults |
| --- | --- | --- | --- | --- | --- |
| exact_basename | 23.907 / 24.089 / 24.103 | 0.002 / 0.006 / 0.007 | 0.004 / 0.009 / 0.011 | 0.716 / 0.002 | 12 / 0 |
| no_match | 18.037 / 18.333 / 18.845 | 0.003 / 0.005 / 0.006 | 0.000 / 0.001 / 0.002 | 0.666 / 0.420 | 0 / 0 |
| one_character | 46.584 / 47.718 / 48.110 | 0.004 / 0.008 / 0.010 | 0.068 / 0.080 / 0.081 | 1.856 / 0.949 | 12 / 0 |
| prefix | 59.453 / 60.110 / 60.544 | 0.003 / 0.010 / 0.011 | 0.125 / 0.137 / 0.138 | 1.808 / 0.011 | 32 / 0 |
| substring | 58.487 / 59.592 / 59.620 | 0.004 / 0.008 / 0.009 | 0.042 / 0.050 / 0.051 | 2.168 / 0.051 | 20 / 0 |
| two_character | 64.177 / 65.549 / 66.212 | 0.004 / 0.006 / 0.007 | 0.094 / 0.111 / 0.116 | 2.465 / 1.400 | 9 / 0 |

### 查询：`/Volumes/Data 1`

| 类型 | 实际 query | 返回 | first ms | p50 | p90 | p95 | p99 | max |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| exact_basename | `9c73569cc35c36b76c959a1e29556b203e047ff5ce6c42268560be6a899e27-uuid@14.0.1.json` | 1 | 17.157 | 6.957 | 7.079 | 7.115 | 7.433 | 7.433 |
| prefix | `9c735` | 17 | 33.911 | 33.526 | 34.334 | 35.303 | 47.161 | 47.161 |
| substring | `73569c` | 1 | 32.365 | 32.743 | 33.149 | 34.097 | 34.321 | 34.321 |
| no_match | `apfsfind-no-match-EE507999-9751-45C7-9CAE-27E99DDE14D6` | 0 | 8.077 | 8.140 | 8.234 | 8.543 | 8.556 | 8.556 |
| one_character | `a` | 50 (limit) | 30.916 | 30.328 | 30.945 | 30.953 | 31.595 | 31.595 |
| two_character | `py` | 50 (limit) | 29.787 | 29.549 | 30.182 | 30.408 | 30.465 | 30.465 |

| 类型 | base p50/p95/p99 ms | overlay p50/p95/p99 | path p50/p95/p99 | 30次 user/system CPU s | minor/major faults |
| --- | --- | --- | --- | --- | --- |
| exact_basename | 6.952 / 7.110 / 7.422 | 0.001 / 0.003 / 0.005 | 0.002 / 0.006 / 0.007 | 0.209 / 0.000 | 1 / 0 |
| no_match | 8.137 / 8.536 / 8.546 | 0.001 / 0.004 / 0.007 | 0.000 / 0.001 / 0.002 | 0.245 / 0.000 | 0 / 0 |
| one_character | 30.244 / 30.862 / 31.487 | 0.004 / 0.008 / 0.010 | 0.077 / 0.091 / 0.095 | 0.911 / 0.002 | 0 / 0 |
| prefix | 33.497 / 35.245 / 47.102 | 0.003 / 0.009 / 0.009 | 0.032 / 0.046 / 0.049 | 1.014 / 0.003 | 0 / 0 |
| substring | 32.735 / 34.067 / 34.298 | 0.002 / 0.009 / 0.012 | 0.004 / 0.014 / 0.016 | 0.976 / 0.002 | 0 / 0 |
| two_character | 29.470 / 30.333 / 30.386 | 0.002 / 0.007 / 0.009 | 0.075 / 0.089 / 0.093 | 0.887 / 0.002 | 0 / 0 |

first 与稳定 warm 分位数分开；没有减少 base 条目，一/二字符查询完整保留。返回 50 不等于全部匹配数，本轮没有新增全量 count 查询。

### 实际累计 I/O（各索引进程的阶段 delta）

logical reads 不可获得；filesystem metadata / SSD 控制器写放大无法独立分离。以下是进程归属计数，不是全机磁盘总量。MB 与 final file size / st_blocks 相互独立。

`/`

| 阶段 | wall ms | user/system CPU s | logical writes MB | disk writes MB | disk reads MB |
| --- | --- | --- | --- | --- | --- |
| cold scan | 50733.503 | 44.297/66.952 | 0.000 | 0.000 | 2436.579 |
| initial snapshot serialization | 2203.473 | 2.016/0.065 | 263.312 | 260.047 | 1.872 |
| initial snapshot fsync/validate/publish | 2825.252 | 2.793/0.032 | 0.004 | 1.245 | 0.004 |
| cold startup replay | 46978.094 | 24.935/15.466 | 0.000 | 0.000 | 220.402 |
| warm startup replay | 29049.994 | 7.542/15.087 | 0.000 | 0.000 | 218.149 |
| content-only (10k writes, helper process) | 80.454 | 0.000/0.001 | 0.000 | 0.000 | 0.000 |
| checkpoint request: full CP (G changed) | 6657.306 | 6.570/0.074 | 262.329 | 261.292 | 0.049 |
| small create/rename/delete | 71.072 | 0.001/0.001 | 0.000 | 0.000 | 0.000 |
| 10k/2k/5k namespace workload | 1348.236 | 1.263/0.266 | 0.000 | 0.000 | 0.000 |
| manual full compaction | 12400.328 | 21.472/3.617 | 263.582 | 261.575 | 2.028 |
| cold graceful exit | 6746.819 | 6.589/0.094 | 262.636 | 261.296 | 1.040 |
| warm graceful exit | 6732.934 | 6.569/0.083 | 263.545 | 261.591 | 1.921 |
| cleanup compaction | 7157.692 | 7.079/0.158 | 263.533 | 261.292 | 2.040 |
| cleanup graceful exit | 6898.168 | 6.604/0.113 | 263.742 | 261.296 | 6.255 |

content G：768 → 768，unchanged=True；small CRUD compactions=0.

`/Volumes/Data 1`

| 阶段 | wall ms | user/system CPU s | logical writes MB | disk writes MB | disk reads MB |
| --- | --- | --- | --- | --- | --- |
| cold scan | 18287.145 | 22.542/15.061 | 0.000 | 0.000 | 936.260 |
| initial snapshot serialization | 1080.359 | 1.048/0.024 | 142.971 | 135.266 | 0.000 |
| initial snapshot fsync/validate/publish | 1452.987 | 1.443/0.009 | 0.053 | 6.636 | 0.000 |
| cold startup replay | 73502.052 | 21.856/24.826 | 0.000 | 0.000 | 732.226 |
| warm startup replay | 75281.491 | 21.791/24.879 | 0.000 | 0.000 | 772.944 |
| content-only (10k writes, helper process) | 81.947 | 0.000/0.001 | 0.000 | 0.000 | 0.004 |
| checkpoint request: state-only | 1.188 | 0.000/0.001 | 0.020 | 0.004 | 0.000 |
| small create/rename/delete | 68.438 | 0.002/0.001 | 0.000 | 0.000 | 0.000 |
| 10k/2k/5k namespace workload | 1285.767 | 1.218/0.270 | 0.000 | 0.000 | 0.000 |
| manual full compaction | 3740.934 | 7.856/0.114 | 143.442 | 142.180 | 1.913 |
| cold graceful exit | 3436.614 | 3.384/0.043 | 143.221 | 141.898 | 0.000 |
| warm graceful exit | 3459.155 | 3.399/0.045 | 143.450 | 142.184 | 0.041 |
| cleanup compaction | 3520.310 | 3.379/0.055 | 143.319 | 141.906 | 1.483 |
| cleanup graceful exit | 0.098 | 0.000/0.000 | 0.000 | 0.000 | 0.000 |

content G：367 → 367，unchanged=True；small CRUD compactions=0.

Root 的 checkpoint 请求若因其他 namespace 变化写了整个 base，就列为 full CP；不把它误称为 128-byte state 写入。Data 1 是否实际走 state-only 由上述 counters 和 delta 确认，另有 20k entries 的隔离 API 写入量回归。

### 大索引 compaction 与最终验证

| 指标 | / | /Volumes/Data 1 |
| --- | --- | --- |
| old/new base bytes | 261268449 / 261548519 | 141873957 / 142154027 |
| CP wall ms | 12400.328 | 3740.934 |
| CP user/system CPU s | 21.472 / 3.617 | 7.856 / 0.114 |
| CP logical/disk writes MB | 263.582 / 261.575 | 143.442 / 142.180 |
| RSS before/after MB | 1256.505 / 1096.204 | 582.074 / 587.383 |
| process lifetime peak RSS at CP MB | 1517.568 | 729.268 |
| writer sampled CP peak RSS MB | 1458.668 | 729.252 |
| overlay before/after | 5003 / 105 | 5001 / 104 |
| base tombstones before/after | 2 / 5 | 0 / 0 |
| events buffered/replayed | 1514 / 1514 | 3945 / 3945 |
| queries during CP / p50/p95/max ms | 185 / 67.031 / 67.895 / 72.096 | 118 / 31.728 / 32.297 / 32.490 |
| writer wait p50/p95/p99/max ms | 0.000083 / 0.000208 / 0.000208 / 0.000208 | 0.000083 / 0.000208 / 0.000208 / 0.000208 |
| after CP confirmed missing/extra | 0 / 0 | 0 / 0 |
| after CP raw missing/extra / revalidated races | 0 / 0 / 0 | 0 / 0 / 0 |
| after CP attempts | 1 | 1 |
| after cleanup confirmed missing/extra | 0 / 0 | 0 / 0 |
| after cleanup raw missing/extra / revalidated races | 1 / 2 / 3 | 0 / 0 / 0 |
| after cleanup attempts | 1 | 1 |

CP 内另制造 100 个 owned 文件，验证 buffered/replayed；因此 after overlay 可非零。差异复核是新鲜目录项与在线索引的逐项比较，不是原子快照；raw 与 confirmed 均保留，不按系统日志/用户缓存路径忽略。两轮 exit=0、validation_passed=true、cleanup_completed=true。

### v2 布局与 folded dedup 上限

| 字段（cold 映射） | / | /Volumes/Data 1 |
| --- | --- | --- |
| record_table_bytes | 120076000 | 59533000 |
| child_table_bytes | 12007596 | 5953296 |
| original_name_blob_bytes | 64591908 | 38193559 |
| folded_name_blob_bytes | 64591833 | 38193536 |
| folded_same_as_original_count | 1917138 | 1376703 |
| folded_same_as_original_bytes | 41653593 | 35299320 |
| potential_fold_dedup_saving_bytes | 41653593 | 35299320 |
| file_id_nonzero_files | 2354966 | 1403919 |
| file_id_nonzero_directories | 498009 | 79126 |
| potential saving MB / snapshot % | 41.654 / 15.943% | 35.299 / 24.881% |

两份 cold snapshot 合计 **403,141,296 bytes / 403.141 MB**；folded bytes 引用 original bytes 的理论上限 **76,952,913 bytes / 76.953 MB（19.088%）**。这是潜在引用复用收益，不是压缩结果；本轮格式完全未变。

## 修改范围、复现与边界

修改职责：SnapshotStore / SnapshotV2Writer / SnapshotReader 的生命周期和资源采样；FSEventsWatcher / EventClassifier / UpdateCoordinator 的 retain/release、callback teardown、事件与验证；FileIndex / DirectoryReconciler / BulkScanner / HybridIndex 的挂载身份及统计；C ProcessResources + Swift ProcessResources；CLI / RealDiskBenchmarkRunner / OwnedBenchmarkDirectory；对应 crash、mount、资源、目录所有权、journal、并发 verify 测试；README / STATUS / CI。main.swift 没有堆入逻辑。

```bash
swift build -c release
swift test
APFSFIND_SKIP_FSEVENTS_TESTS=1 swift test
swift test --sanitize=address
swift test --sanitize=thread
.build/release/apfsfind bench --files 1000 --latency-ms 20
.build/release/apfsfind real-disk-bench --root / --idle-seconds 60
.build/release/apfsfind real-disk-bench --root "/Volumes/Data 1" --idle-seconds 60
```

也可显式 `--cache-dir "/private/tmp/apfsfind-real-cache-$(uuidgen)"`；必须是新路径，拒绝复用。stdout 最后一行 JSON，stderr 进度；测量日志在 `/private/tmp`，不进 Git，私有索引测完删除。
已知边界：MAC 14 / Intel 未专项实机测；macOS 15 的 Unix socket 通知未在观测窗口出现；TCC/不可读目录计数并继续；活动系统不能获得强原子 path-set 快照。warm replay 可触发大范围 reconciliation，time-to-live 不能用 mmap syscall 时间替代。CPU 数据含实际其他 namespace 事件，未绕过日志目录来达标。没有改 epoch 到 2001，没有更新 v2、添加压缩/复杂索引/网络/telemetry/GUI。

下一轮仅候选 v0.4 Usable Desktop Alpha：MultiVolumeCoordinator，用户选本地卷，跨卷并行搜索/top-k，mount 生命周期；SwiftUI/AppKit 窗口/hotkey/debounce/取消旧 query；打开/Finder 定位/复制路径/图标/来源卷；排除目录/FDA 提示/可选开机启动。本轮未实现。

以下保留 v0.3 的原始验收与第一次体积测量。

---

# v0.2.1 hardening / v0.3.0 hybrid index

本轮两个 milestone 已完成，本机正确性验收 PASS。日期：2026-10-05（Asia/Tokyo）。
环境：arm64 macOS 27.0.1 (26A434)、Apple Swift 6.4、SDK 27.0；deployment target macOS 14、Swift language mode 6。
无第三方 package。仅在本机执行，没有使用 HPC。A/B 开发完成时未 push；
后续增加实盘记录，并按用户的新指令发布到 GitHub。

## 提交与基线

- 开始 HEAD：`6ab6b9fee6cda3217353deea1ce0737cf6ee0918`，开始工作区干净，与当时 origin/main 一致。
- Phase A：`948d4ba633c6e3fd75b99d837c8f3d069a600e2b`，`fix: harden durable cursor and cache handling`。
- Phase B / 开发完成 HEAD：`2c2d811f3865f8b9e304ea35acac2c23f50457c3`，`feat: add mmap base index and delta overlay`。
  实盘数据在其后的独立文档提交中记录。

| 阶段 | release build | tests | 原 RAM bench create/delete/same/cross rename p95 ms |
| --- | --- | --- | --- |
| 开始基线 | PASS | 85 / 0 failures | 21.43 / 21.57 / 21.70 / 22.24 |
| A 完成 | PASS | 90 / 0 failures | 21.24 / 21.44 / 21.67 / 21.42 |
| B 最终 | PASS，无 warning | 105 / 0 failures / 0 skipped，15.27 s | 23.29 / 22.85 / 22.82 / 23.69 |

开始基线的真实 100k persistence bench：cold 2846.9 ms、warm 361.5 ms、30.999 bytes/entry，
但 warm 把全部文件恢复到 FileIndex；v0.3 的索引格式和内存模型不同，不能只比较启动时间。
旧版本完整状态记录仍可从基线提交读取。

## A 完成内容

128-byte durable cursor state，绑定 snapshot UUID/G/length/payload CRC/volume/history。
只有内存 namespace 已包含在持久 base 中才能单独推进 state；content-only 可以推进 C 而不变 G。
匹配 state 损坏、截断、CRC 错误或旧绑定时，忽略 state，退回 header cursor，不丢弃合法 base。
state 和 snapshot 都使用安全临时文件、fsync、原子 rename 和目录 fsync。

现有 cache 必须已经是当前用户所有的 0700 目录；不再 chmod 现有目录。
新建目录 0700，snapshot/state/零字节 lock 为 0600；拒绝任意 symlink/不安全文件类型。
已加入 MIT LICENSE 和 macOS-15 CI：release build + 全部 tests，默认不跳过原生 FSEvents 测试。
A 独立检查点当时没有 push；配置不等于远端 CI 已运行，发布后的执行状态以 GitHub Actions 为准。

A 独立检查点采用 additive v1 UUID flag（bit 0、header 168..183）；原来 flag=0、无 UUID 的 v1 仍能验证，
不采纳 state。B 对两种 v1 均执行一次安全扫描，写入独立的 v2 格式。

## FSEvents 时间基准：保留 1970

按用户补充撤掉“改为 2001 epoch”的建议，改为核对目标 SDK 并实测。
本机 `MacOSX.sdk/.../FSEvents.framework/Headers/FSEvents.h:1034` 明确要求
`seconds since Jan 1, 1970 (i.e. a posix style time_t)`。
这与用户给出的 [Apple API 文档](https://developer.apple.com/la/documentation/coreservices/1449772-fseventsgetlasteventidfordeviceb) 一致；旧编程指南的 2001 描述存在冲突。

实现使用可注入的 `CFAbsoluteTimeGetCurrent()` 时钟，在 API 边界加
`kCFAbsoluteTimeIntervalSince1970`，保持当前 SDK 所要求的参数语义，未改用 2001。
设备 fence provider 同时注入 Core 和 Persistent coordinator，测试证明在 cold/recovery scan 前调用，warm 使用持久 cursor。
本机对照 probe：直接 CF epoch 返回 0；转换后返回 1335086013，当时 host current 为 1335101758。
该差异只证明此目标 SDK/设备上转换必要，不将 host-global ID 用作持久 fence。

使用 per-device stream 和 history UUID。原生 callback probe 返回不带开头 `/` 的 device-relative path，
Data 卷 firmlink alias 验证 device/inode 后转换。scan 前捕获设备 E0，scan 后从 E0 replay，
batch 完成且 inbox 无遗漏后 HistoryDone 才进入 live，没有固定 10 秒启动期限。
允许重叠 replay；不按旧 event ID 丢弃 namespace 提示。

## B 架构与修改文件

v0.3 已将 immutable base 留在 mmap 中；RAM 仍会保存目录路径和 overlay。
默认 warm 不调用 FileIndex.restore，不创建全体 base FileEntry 或全体文件 full-path dictionary。
冷扫描与失效恢复可暂时构建 FileIndex，映射 v2 后释放；ephemeral 保留原 RAM 实现。

| 文件/组 | 职责 |
| --- | --- |
| NamespaceIndex.swift、FileIndex.swift、DirectoryReconciler.swift | 公共 namespace 接口；保留 RAM 对照与 scoped diff |
| MMapBaseIndex.swift、BaseSearch.swift | 单一只读 FD/mmap、v2 校验、child 二分定位、subtree、bounded top-k 查询 |
| HybridIndex.swift、FileEntry.swift | base/delta ref、位图、目录映射、eager delta 回收、ASCII fold fast path、查询快照与 metrics |
| SnapshotV2Writer.swift、SnapshotFormat.swift、SnapshotReader.swift | v2 流式导出、旧 v1 校验/迁移、readonly staged mapping |
| SnapshotStore.swift | 安全 cache、原子发布回滚、校验和 writer 发布 barrier 接口 |
| UpdateCoordinator.swift | authoritative metadata patch、history 去重、compaction 事件缓冲/重放、恢复 identity/fence |
| PersistentIndexCoordinator.swift | 默认 hybrid、state-only checkpoint、手动/自动 compaction、退出、失败退避 |
| CAPFSShim/BulkDirectoryReader.c、VolumeIdentity.c、include/CAPFSShim.h | no-follow 元数据查询、安全本地缓存目录 |
| CLI.swift、HybridBenchmarkRunner.swift | :compact、hybrid-bench、独立 mmap probe、真实 FSEvents 搜索可见性 |
| BenchmarkRunner.swift、PersistenceBenchmarkRunner.swift | 保留旧对照、v0.3 标识、warm/cold 比例验收 |
| CursorStateTests.swift、HybridIndexTests.swift、HybridRecoveryTests.swift | 时间/fence 注入、v2/hybrid/迁移/并发/失败/churn |
| README.md、STATUS.md | 使用、格式、测量与限制 |

稳态 RAM：directory-only `[String: EntryRef]`、live delta/path/children、base tombstone 位图、最多 4096 个 writer wait 采样。
删除 delta 立即释放其字符串/记录，整数槽复用；空闲槽最多跟随同时活跃变化的高水位，compaction 清空。
base directory 删除通过已验证的 subtree range 标记其 base 后代，并移除对应目录/delta 子树。
查询短锁捕获 base 强引用、COW 位图、live delta 数组和 G 后释放锁；扫描/排序/路径生成均在锁外。
只给 top-k 候选重建完整 base path。旧 base 在 swap 后由正在查询的强引用保活，避免悬空 mapped pointer。
查询返回捕获时的 namespace/G，允许在并发更新后完成旧 generation 的一致结果；query_retries=0。
writer wait p50/p95/p99 是最近最多 4096 次更新的窗口，max 是该实例整个运行期的最大值。
`materialized_file_entries` 计临时 RAM 文件，`base_materialized_file_entries=0` 单独证明 base 未展开。

尚未实现 trigram/SIMD 高级查询索引；宽泛 substring query 仍需要扫描 base folded names。

## Snapshot v2 布局

所有整数显式 little-endian，不序列化 Swift/C struct 内存布局。结构：

~~~text
256-byte header
canonical root UTF-8（无 NUL）+ zero padding，table 对齐 8 bytes
N × 40-byte DFS records
contiguous original-name UTF-8 blob
contiguous folded-name UTF-8 blob
(N−1) × UInt32 direct-child ordinals
16-byte footer
~~~

| header offset | bytes | 字段 |
| ---: | ---: | --- |
| 0 | 8 | APFSIDX + NUL |
| 8 / 12 / 16 / 20 | 4 each | version=2 / headerSize=256 / flags=1 / recordSize=40 |
| 24 | 8 | record count |
| 32 / 40 | 8 each | record table offset / length |
| 48 / 56 | 8 each | original blob offset / length |
| 64 / 72 | 8 each | root offset=256 / root length |
| 80 / 88 / 96 / 104 | 8 each | creation Unix seconds / G / base C / device |
| 112 / 128 | 16 each | volume UUID / history UUID |
| 144 / 148 | 4 each | payload CRC / header CRC（该字段置零后计算） |
| 152 / 160 | 8 each | exact file length / root inode |
| 168 | 16 | snapshot UUID |
| 184 | 8 | reserved zero |
| 192 / 200 | 8 each | folded blob offset / length |
| 208 / 216 | 8 each | child table offset / length |
| 224 | 32 | reserved zero |

| record offset | bytes | 字段 |
| ---: | ---: | --- |
| 0 / 4 / 8 / 12 | 4 each | parent / first child slot / direct child count / exclusive subtree end |
| 16 / 20 | 4 each | original / folded offset relative to blob |
| 24 / 26 | 2 each | original / folded UTF-8 byte length |
| 28 / 29 / 30 | 1 / 1 / 2 | kind / boundary flag / reserved zero |
| 32 | 8 | file ID，0=unknown |

root ordinal=0，parent=UInt32.max、空 basename、directory、flags=0。
parent 必须先于 child；目录直接孩子按 folded/raw/kind 排序，child table 精确覆盖 DFS subtree。
footer：`APFSEND\0`（8 bytes）、footer 前全部 payload 的 CRC32（4 bytes）、reserved zero（4 bytes）。
header payload CRC 覆盖 header 之后的全部字节（含 footer）。只有 root 在文件中保存完整路径。

reader 校验 0600/current owner/regular/readonly FD、identity、CRC、checked offsets/lengths、section 紧密布局、
name/fold UTF-8 与折叠一致性、合法 basename/type/flags、父子关系、排序、重复名及完整 subtree coverage。
限制：20M records、8 GiB file、UInt32 blob offset、NAME_MAX basename、路径长度小于 PATH_MAX。
校验用临时 UInt32 路径长度数组约 4N bytes，释放后不留下每个文件的 path/String/FileEntry。

## State v1 布局与一致性

固定 128 bytes，little-endian：

| offset | bytes | 字段 |
| ---: | ---: | --- |
| 0 / 8 / 12 | 8 / 4 / 4 | APFSSTA + NUL / version=1 / size=128 |
| 16 | 16 | snapshot UUID |
| 32 / 40 | 8 each | base generation / base file length |
| 48 / 52 | 4 each | base payload CRC / reserved zero |
| 56 / 72 | 16 each | volume / history UUID |
| 88 | 8 | effective durable cursor C |
| 96 | 4 | state CRC，该字段置零后计算 |
| 100 | 28 | reserved zero |

C 在 writer queue 完成 batch mutations/reconciliation 后推进。纯内容事件不修改 namespace，
真实 content tests 验证无额外 metadata/枚举。重复 Created 混合内容 flags 先做实际 inode/type 核对；
不把 FSEvents 的 namespace 提示误当纯内容，也不凭提示制造不存在的文件。
G 不同于 base 时不能 state-only checkpoint；旧/坏 state 退回 base C，replay 可重复但不会越过未保存 namespace。
G/C 都未变时不写文件；G 相同/C 前进时仅写 state；G 变化时合并，正常退出先 quiesce 所有已交付事件。

## Compaction 状态机与失败

live/idle → writer capture immutable base/bitmap/live delta/G/C/epoch/identity → background plan/stream write/fsync →
readonly mmap/完整校验 → writer 检查 epoch/current identity/overflow/cancel → atomic publish/swap → buffered replay → live/idle。
后台写入期间 writer 继续把事件更新到当前可查询 namespace，同时记录 bounded raw-event buffer。
缓冲 replay 的 namespace 留在新 overlay；header C 保持捕获时的值。仅当前 G 仍等于新 base G 时可安全更新 state。
默认阈值：50k live delta、64 MiB estimated delta、50k tombstones、5% tombstone/base 或 overlay/base；
quiet window 2 s，estimated safety trigger 128 MiB。timer 不逐事件落盘。

取消、generation/epoch/identity 变化、stream invalidation、缓冲 overflow、I/O 或校验失败均不发布新 base。
临时文件删除，旧 final 和当前 overlay 保留；自动重试按 2..30 s 退避。
已有 final 使用临时 hard link 支持 rename 后 fault 的回滚，不复制旧内容、不保留历史快照/WAL。
完整生成和校验在后台；rename/目录 fsync 与 adopt 在 writer barrier 内，存储延迟仍可能影响短发布阶段。
失效恢复短暂使用 RAM 重建，重新检查扫描前后 root identity，再映射替换；失败重试且不宣称成功。

## 验证

全部原 85 项测试保留，新增 A 5 项 + B 15 项，共 105。原生 FSEvents 集成测试实际运行，0 skipped。
覆盖：state 原子性/绑定/权限无副作用、fence 注入、v1 两种迁移、v2 malformed sections/tree/fold（修复 CRC 后仍拒绝）、
Unicode/NFD/大小写/ranking、目录删除/替换/recreate、旧 base 生命周期、并发查询/writer、buffered NS replay、
overflow/invalidation、I/O/CRC/cancel/rename/fsync fault、managed/automatic compaction、20×10k churn 和 restart。
原有 corruption fallback、MustScan/Dropped/Wrapped/history UUID recovery、离线 create/delete/两种 rename、
新非空目录、content-only、ephemeral、在线无每事件写入、无变化退出等继续通过。

真实 CLI smoke 用拥有的临时 root/0700 cache 和三个独立 release 进程：
cold → :stats/:checkpoint/:verify/quit → 关闭期间 create/delete/跨目录 rename → warm 搜索/:compact/:stats/:verify/:checkpoint/quit → next warm :verify。
三次 verify 都为 missing=0/extra=0；两次 warm full_scans=0、materialized_file_entries=0；手动 compaction 完成，0700/0600 实机检查通过。
未写用户真实 HOME 的默认 cache；benchmark 只创建/清理自己的 UUID 子目录，结果输出 stdout。

实际执行以下命令（每次 cache 参数来自单独拥有的 mktemp 目录）：

~~~bash
swift build -c release
swift test
swift run -c release apfsfind bench --files 1000 --latency-ms 20
swift run -c release apfsfind persistence-bench --entries 100000 --cache-dir "$(mktemp -d)"
swift run -c release apfsfind hybrid-bench --entries 100000 --delta 10000 --cache-dir "$(mktemp -d)"
swift run -c release apfsfind hybrid-bench --entries 1000000 --delta 50000 --cache-dir "$(mktemp -d)"
~~~

四类 benchmark 均 PASS，最后一行 JSON，provisional_acceptance=true；原 RAM bench 每种事件 100 samples/0 timeout。
10k content writes：namespace work=0、G 不变，46.76 ms（loop 25.43 ms），CPU user/system 0.00142/0.02400 s。
1000 file create/delete storm：84.75/85.56 ms，CPU user/system 0.06565/0.05005 与 0.06902/0.02637 s，
均无 full rebuild、verify 0/0、临时数据清理成功。

## 真实 100k persistence bench

实际创建 root + 100 directories + 99,899 files，默认 HybridIndex：

| 测量 | 结果 |
| --- | ---: |
| cold time-to-live | 3212.82 ms |
| warm time-to-live | 747.54 ms（cold 的 23.27%，<25%） |
| warm open/validate / mmap / directory map | 58.02 / 0.014 / 0.661 ms |
| warm replay | 686.12 ms，8676 received events（含 FullHistory overlap） |
| warm full scans / directory reconciles / subtree reconciles | 0 / 0 / 0 |
| warm materialized base FileEntry | 0 |
| snapshot bytes / bytes per entry | 5,799,566 / 57.99566 |
| online workload wall / CPU user/system | 740.88 ms / 1.55272 / 0.22159 s |

在线 1000 create/delete、10k content writes、100 rename 期间 snapshot inode/mtime/size 未改变；
content G 不变，verify 0/0。变化退出生成新 snapshot，下一次 warm 看见最新 rename，full_scans=0、verify 0/0。
与初期测量相比，去掉已核对的重复历史 create 的风暴计数，避免 warm 反复枚举原有目录。
RSS 同进程先 cold 后 warm 约 84.84 MB，包含 cold allocator 保留，不能作为独立 warm RSS。

## 合成 mmap base / RAM 测量

合成条目只测格式/索引成本；不是在磁盘实际创建百万文件。两种规模均有 1001 个目录。
只读子进程只 discover identity、打开/校验/映射 base、建立目录 map，不扫描、不启动 watcher。
RSS 是实际 resident bytes（含已访问的 mmap pages），不是仅计算文件长度；MB 使用 10⁶ bytes。

| 项目 | 100k base + 10k delta | 1M base + 50k delta |
| --- | ---: | ---: |
| base bytes | 5994364 | 59994364 |
| bytes/entry | 59.94364 | 59.99436 |
| map + validate + directory map ms | 56.849 | 571.139 |
| mmap syscall / validate / directory map ms | 0.023 / 55.911 / 0.915 | 0.339 / 563.451 / 7.348 |
| 独立进程 load ms | 58.503 | 574.277 |
| 独立进程 RSS before / after MB | 7.21 / 13.68 | 7.23 / 71.60 |
| directory map entries / estimated bytes | 1001 / 194188 | 1001 / 194188 |
| tombstone bitmap bytes | 12504 | 125000 |
| full scans / base materialized FileEntry | 0 / 0 | 0 / 0 |
| live delta / estimated bytes before merge | 10000 / 4495560 | 50000 / 22655560 |

同进程 hybrid bench 先冷构建再释放 FileIndex，allocator 会保留 pages，不能与只读子进程混为一谈。
后面的 compaction/churn RSS 来自这个同进程，包含冷构建/benchmark 的临时分配残留。

## 查询：20 samples/类型

| base | query | p50 ms | p95 ms | p99 ms | max ms |
| --- | --- | ---: | ---: | ---: | ---: |
| 100k | exact | 0.629 | 0.686 | 0.739 | 0.739 |
| 100k | prefix | 1.898 | 2.092 | 2.120 | 2.120 |
| 100k | substring | 0.898 | 0.909 | 0.913 | 0.913 |
| 100k | broad | 11.984 | 12.526 | 12.629 | 12.629 |
| 100k | no_result | 0.346 | 0.353 | 0.364 | 0.364 |
| 1M | exact | 4.429 | 4.578 | 4.583 | 4.583 |
| 1M | prefix | 7.033 | 7.256 | 7.264 | 7.264 |
| 1M | substring | 8.695 | 9.151 | 9.730 | 9.730 |
| 1M | broad | 103.614 | 106.416 | 107.492 | 107.492 |
| 1M | no_result | 3.328 | 3.361 | 3.361 | 3.361 |

各阶段 p95（base scan / overlay scan / candidate path reconstruction），单位 ms：

| base | query | base scan | overlay scan | path reconstruction |
| --- | --- | ---: | ---: | ---: |
| 100k | exact | 0.674 | 0.006 | 0.004 |
| 100k | prefix | 2.047 | 0.003 | 0.042 |
| 100k | substring | 0.872 | 0.002 | 0.034 |
| 100k | broad | 12.488 | 0.003 | 0.037 |
| 100k | no_result | 0.350 | 0.002 | 0.000 |
| 1M | exact | 4.555 | 0.018 | 0.009 |
| 1M | prefix | 7.203 | 0.009 | 0.046 |
| 1M | substring | 9.094 | 0.009 | 0.047 |
| 1M | broad | 106.353 | 0.014 | 0.049 |
| 1M | no_result | 3.356 | 0.005 | 0.001 |

加入 delta 后的 total query p95 ms：

| query | 100k + 10k delta | 1M + 50k delta |
| --- | ---: | ---: |
| exact | 2.716 | 17.610 |
| prefix | 4.138 | 19.965 |
| substring | 3.200 | 23.189 |
| broad | 14.542 | 116.607 |
| no_result | 2.182 | 14.211 |

## 持续查询与 namespace 维护

synthetic namespace patch 使用直接 HybridIndex.apply/lookup。没有 OS journal 延迟，不能冒充实际 FSEvents 延迟。
writer 连续无间隔 create/同路径 rename/delete，直到至少完成 20 次 broad query；没有用 sleep/减小数据集掩盖长尾。

| 项目 | 100k + 10k | 1M + 50k |
| --- | ---: | ---: |
| create/rename/delete cycles | 53208 | 56314 |
| broad samples | 21 | 21 |
| patch visibility p50/p95/p99/max ms | 0.047 / 0.050 / 0.053 / 0.476 | 0.052 / 0.058 / 0.061 / 1.795 |
| writer apply p50/p95/p99/max ms | 0.047 / 0.050 / 0.052 / 0.273 | 0.052 / 0.058 / 0.061 / 1.795 |
| writer lock wait p50/p95/p99/max ms | 0.000042 / 0.000042 / 0.000042 / 0.216833 | 0.000042 / 0.000042 / 0.000042 / 1.726917 |
| concurrent broad p50/p95/p99/max ms | 16.582 / 276.527 / 544.630 / 544.630 | 249.712 / 442.043 / 547.791 / 547.791 |
| query retries | 0 | 0 |

宽 query 在无间隔 writer 下有数百 ms 的调度/锁竞争长尾；这是当前限制。
writer 最大锁等待远低于数百 ms，base scan 本身不持 writer lock。
这不证明 query capture 公平性已经解决；delta snapshot/refcount/COW 和 NSLock 竞争值得后续单独优化。

真实小目录使用默认 PersistentIndexCoordinator + FSEvents；四类均按 fresh search hits 等待可见，每种 50 samples。
以下为百万 synthetic 运行附带的独立真实小目录 probe（不是百万真实文件）：

| workload | p50 ms | p95 ms | p99 ms | max ms |
| --- | ---: | ---: | ---: | ---: |
| create | 20.291 | 21.610 | 22.760 | 22.760 |
| delete | 20.205 | 21.456 | 21.651 | 21.651 |
| rename | 20.253 | 21.608 | 22.541 | 22.541 |
| cross_rename | 20.278 | 21.639 | 23.648 | 23.648 |

真实 event queue high watermark=4，query_retries=0；fresh verify missing/extra=0/0。

## Compaction 与二十轮 churn

| 项目 | 100k + 10k | 1M + 50k |
| --- | ---: | ---: |
| merge wall ms | 232.405 | 2081.496 |
| bytes written | 6632144 | 63272144 |
| CPU user / system seconds | 0.44929 / 0.00546 | 3.87422 / 0.06001 |
| observed peak RSS MB | 66.67 | 395.13 |
| queries completed during merge | 15 | 16 |
| queries during merge p95 ms | 15.694 | 183.760 |
| live delta / base tombstones after merge | 0 / 0 | 0 / 0 |
| synthetic buffered events | 0 | 0 |
| synthetic restart model verified | true | true |

真实小目录也在 query 运行期间执行 managed compaction：1.441 ms，完成 450 次查询、缓冲 0 个事件，随后 fresh verify 0/0。

合成 namespace 不在磁盘制造百万文件，其验证是 live-count/target lookup/合法重开后的 model 检查；
不把它称作百万文件磁盘 fresh verify。synthetic merge 没有 Core watcher，buffered events=0；
真实 buffered namespace/no cursor gap 由 HybridRecoveryTests 的 writer/事件注入测试覆盖。
CPU 计整个进程，包含同时运行的查询；peak RSS 是 chunk 边界采样，不是所有瞬间的上界。

每轮增加并删除 10,000 个独有名字，共 20 轮；首轮创建/删除各合并一次，加上前面的 delta merge 共 3 次。
后续 delta eager reclamation 不要求每轮重写 base。每轮 query 5 samples，完整逐轮值在 benchmark JSON。

| base | round | live delta | estimated overlay bytes | base tombstones | bitmap bytes | query p95 ms | RSS MB | compactions |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 100k | 1 | 0 | 0 | 0 | 13752 | 14.689 | 71.57 | 3 |
| 100k | 20 | 0 | 40000 | 0 | 13752 | 14.268 | 31.13 | 3 |
| 1M | 1 | 0 | 0 | 0 | 131256 | 118.322 | 315.24 | 3 |
| 1M | 20 | 0 | 40000 | 0 | 131256 | 104.808 | 252.90 | 3 |

二十轮后仍扫描同样数量的 base records，delta 历史字符串不参与查询；live delta=0、base tombstones=0。
末轮 estimated overlay 40,000 bytes 来自 10k 个复用空闲 UInt32 槽，没有 20×10k 个已删除字符串。
RSS 和 query work 未随轮数线性增长；重开 base/model 和真实 CLI 再次 warm 均通过。


## 本机全盘范围索引体积实测（2026-10-05）

使用本轮 v0.3.0 release 二进制（代码提交 `2c2d811`），真实扫描本机目录并写入 v2 索引。
与上面的合成 benchmark 不同，这里测的是实际文件名分布；MB/GB 均使用十进制。

分别运行 `serve --root /`、`serve --root /System/Volumes/Data` 和 `serve --root "/Volumes/Data 1"`，
worker=4、latency=20 ms，使用独立拥有的同一个 0700 临时 cache。
等待 scan/replay 到 live，正常退出并保存收到的 namespace 更新后，读取最终快照的 header/records，
用 `stat` 测文件长度和已分配块；不读取用户文件内容、不需要 root、不访问 raw disk。
三次运行均退出码 0，临时索引随后全部清理，既有用户缓存未修改。

这台 Mac 的 `/` 可见目录视图已经包含 `/Users` 等用户数据目录；实测相关路径的 st_dev 相同。
因此主结果采用 `/` + `Data 1` 两份索引，不把 `/System/Volumes/Data` 的重叠视图再相加。
以下是两份索引的条目数相加，包含各自 root 和挂载边界目录，不是去重后的 inode 数。

| 范围 | records | regular files | directories | symlinks | other | base bytes | base MB | bytes/entry |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `/`：系统及用户目录视图 | 2,918,502 | 2,295,555 | 474,586 | 148,243 | 118 | 253,089,857 | 253.09 | 86.72 |
| `/Volumes/Data 1`：工作盘 | 1,479,905 | 1,396,525 | 78,100 | 5,280 | 0 | 141,187,055 | 141.19 | 95.40 |
| 两份索引合计 | **4,398,407** | **3,692,080** | **552,686** | **153,523** | **118** | **394,276,912** | **394.28** | **89.64** |

两份 base 加两个 128-byte state 和零字节 lock，逻辑文件长度合计 **394,277,168 bytes**，约 **0.4 GB**。
比合成基准的约 60 bytes/entry 更大；实际原名/折叠名 blob 长度取决于用户文件名分布，
不能用合成短文件名的平均值直接外推实盘。

各扫描完成时的已分配块采样（`st_blocks × 512`，包含 state/lock）：

| 范围 | 已分配 bytes | MB | 启动、replay、正常退出耗时 |
| --- | ---: | ---: | ---: |
| `/` | 261,181,440 | 261.18 | 214.70 s |
| `Data 1` | 141,193,216 | 141.19 | 55.26 s |

两个不同采样时刻的分配块之和约 402.37 MB；不是严格同时采样的全盘瞬时值。
常驻规划可按约 0.4 GB，合并时需要保留旧 base 并生成新 base，按这批数据建议预留约 **0.8 GB**。
这里的文件体积/已分配块不是 SSD 的累计物理写入量；初始 replay 有 namespace 变化时，正常退出会再次合并写 base。

独立数据卷视图作为对照：`/System/Volumes/Data` 有 2,404,780 records，
base 216,137,950 bytes（216.14 MB、89.88 bytes/entry），运行 210.44 s；它不计入上述主结果。
恢复卷、VM、Preboot 等辅助卷、其他设备边界、不可读目录及 symlink 目标不递归。
运行期间 permission-denied 计数分别为 `/` 950、数据卷 891、工作盘 4，包含 replay/reconciliation 的重复访问，
不能当作不同不可读目录的数量。这是当前可访问范围的索引体积，不是完整 inode 总量或一次全盘 fresh verify 结果。

## 限制与后续边界

- required path 已实现，无 TODO/stub。数据来自单次本机 benchmark，不是多机器统计保证。
- 查询仍线性扫描 folded names；持续无间隔 synthetic writer 会出现 broad query 长尾，见真实分位数。
  不宣称所有查询低于 100 ms，也不把 RAM patch 的时间冒充真实百万文件 FSEvents 搜索可见性。
- RAM 保留目录完整路径和 live overlay；目录很多/路径很长时 directory map 成本仍会上升。
  overlay bytes 是保守估算，不是 allocator 的精确账单；持续不可写存储下无法保证阈值硬上限。
- cold/rebuild 暂时拥有完整 RAM 索引；compaction planning arrays 是 O(N)，观测 peak RSS 不是绝对瞬时上界。
  scoped reconciliation 可临时构造该范围的 paths；:verify 全量 fresh path sets 也会增加内存，需要静止目录。
- 单次大目录子树删除仍可较长占用更新锁；已测普通文件 writer 与并发查询，未验证所有百万平面目录/超深树分布。
- 整体写入/校验不持更新锁，但原子发布包含目录 fsync，慢/故障存储仍可影响该短阶段。
  在线写失败保留旧 base/overlay；cold 初次写失败会明确启动失败，不冒充 durable live。
- immutable 文件由本工具原子替换；同用户恶意原地修改/truncate 已 mmap 文件不属于当前安全保证。
  fault injection/crash-like stop 不等于真实掉电或 OS journal purge。
- history UUID 不可用时拒绝 durable replay；真实外接盘 clock/history 异常尚未专项验证。
- macOS 14、Intel、真实 iCloud dataless/DMG/network/autofs 未专项实机验证，保留 no-follow/device/mount/dataless 防护，不主动建立这些环境。
- 无 raw disk/root/helper/SIP 修改/全文索引/网络/telemetry/运行日志；不绕过 TCC/POSIX 权限。
  扫描只读目录项/元数据，默认不跨设备、不递归 symlink、best-effort 禁止 dataless materialization。
- 后续可研究更公平的 query capture、delta snapshot 成本和 SIMD/trigram；当前未实现，不宣称完整复刻 Windows Everything。
