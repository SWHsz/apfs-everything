# apfsfind v0.2.0

macOS 本地文件名搜索工具。使用 getattrlistbulk() 扫描目录，通过 FSEvents 在内存中维护创建、删除和重命名。搜索大小写不敏感，按文件名子串匹配，exact、prefix、substring 依次排序，最多返回 50 个路径。

Sprint 2 增加紧凑磁盘快照和跨重启增量恢复：第一次扫描，后续优先加载快照并 replay。完整运行时索引仍恢复到 RAM，查询仍是线性遍历。本机验证与格式布局见 [STATUS.md](STATUS.md)。

## 构建和使用

需要 macOS 14+、Swift 6 和 macOS SDK；Swift Package Manager，无第三方 package 依赖。

~~~bash
swift build -c release
swift test
.build/release/apfsfind serve --root "$HOME"
~~~

默认命令是 serve，默认目录是 $HOME。也可通过 SwiftPM 启动：

~~~bash
swift run -c release apfsfind serve --root /Users/yourname/projects --workers 4 --latency-ms 20
~~~

输入普通文字搜索。启动进度、checkpoint 完成/失败输出 stderr；搜索结果、stats 和 benchmark 输出 stdout。程序不写日志文件，不联网。

| 参数 | 含义 |
| --- | --- |
| --root PATH | 指定本地扫描目录，默认 $HOME |
| --workers N | 扫描 worker 数，1–16，默认 4 |
| --latency-ms N | FSEvents latency，1–1000 ms，默认 20 |
| --ephemeral | 不读写快照，保持纯 RAM 模式 |
| --rebuild-index | 忽略旧快照，全量扫描，成功恢复后覆盖快照 |
| --cache-dir PATH | 指定独立缓存目录；默认见下文 |

~~~bash
.build/release/apfsfind serve --root "$HOME" --ephemeral
.build/release/apfsfind serve --root "$HOME" --rebuild-index
.build/release/apfsfind serve --root "$HOME" --cache-dir "$HOME/Library/Caches/apfsfind-test"
~~~

| 交互命令 | 行为 |
| --- | --- |
| :stats | 索引/事件计数、generation、cursor、状态、CPU/RSS、snapshot 大小/耗时、startup_mode |
| :verify | fresh scan 与内存 path set 比较，报告 missing/extra；不修改索引 |
| :checkpoint | 异步保存快照；已有任务时不重复启动；成功显示 bytes、records、duration |
| :rebuild | 后台重建并 replay，期间查询旧索引；恢复成功后保存快照 |
| :quit | 停止事件流，若 generation 变化则保存一次快照后退出 |

启动没有固定 10 秒截止时间，等待 HistoryDone 和必要恢复，期间显示进度。启动时 Ctrl+C 取消扫描/恢复；live 时第一次 Ctrl+C 正常退出并保存变化，第二次取消退出 checkpoint，保留已有快照。EOF 同样正常退出。

## 持久化与恢复

默认位置：

~~~text
~/Library/Application Support/apfsfind/indexes/
  <SHA256(canonical root UTF8 + NUL + volume UUID bytes)>.apfsidx
  <same filename>.lock
~~~

快照包含敏感的文件名元数据，包括 root、basename、父关系和基础类型。目录为 0700，快照和零字节协调 lock 文件为 0600。Reader 检查 owner、普通文件类型和权限；缓存路径和最终文件拒绝任意符号链接。仅识别并验证 macOS 自带的 root-owned /var、/tmp 到 /private 的别名，以支持 mktemp 路径。缓存不能等于或包含扫描 root。

本工具的缓存子树会从扫描、reconciliation、verify 和普通事件更新中排除，避免默认扫描 HOME 时把自己的快照纳入索引。ephemeral 模式不创建缓存，也不排除该子树。

~~~mermaid
flowchart TD
    Root[Canonical root 与卷身份] --> Valid{合法快照?}
    Valid -->|是| Mmap[mmap 校验并 bulk restore 到 RAM]
    Valid -->|否或强制重建| Scan[捕获 per-device E0 后全量扫描]
    Mmap --> Replay[从快照 cursor replay]
    Scan --> ReplayCold[从 E0 replay]
    Replay --> Gate[处理 HistoryDone 与队列]
    ReplayCold --> Gate
    Gate --> Live[Live 查询与内存更新]
    Replay -->|丢事件或历史失效| Rebuild[Dirty / 后台 full rebuild]
    Rebuild --> ReplayCold
    Live --> Capture[首次 cold / 恢复后、显式命令或变化退出]
    Capture --> Write[捕获 G/C/V、分块导出、CRC32、fsync、原子 rename]
~~~

快照是显式 little-endian binary v1：192 字节 header、24 字节固定 record table、连续 UTF-8 basename blob。仅 root 保存完整路径；不保存 tombstone、foldedName、Swift 对象、dictionary、查询缓存，也不使用 Codable、JSON、压缩或数据库。

Reader 使用一次 mmap，校验大小、CRC32、offset/length、parent-before-child、UTF-8 名称和身份。恢复一次预分配并正向构建 FileEntry、path/directory map、children 和 foldedName；不逐条调用普通 upsert。快照不合法时不会发布其内容，回退 full scan。

事件流使用 FSEventStreamCreateRelativeToDevice，cursor 与卷的 FSEvents history UUID 绑定。保留 FileEvents、NoDefer、UseCFTypes、WatchRoot、FullHistory。FullHistory 的首块重叠事件会幂等处理，不能仅按旧 ID 丢弃。history UUID 变化、EventIdsWrapped、掉事件、root-level MustScanSubDirs 或无法恢复的 reconciliation 进入 dirty/rebuilding，重建前重新捕获 E0，replay 至 live 后发布新快照。

每个 batch 在 patch/reconcile 完成后，由同一 writer 推进 lastProcessedEventID。content-only 可以推进 cursor，但不改变 generation，也不执行文件 stat/内容读取。

checkpoint 在 writer barrier 捕获 generation G、cursor C 和 identity V。每次短锁导出 4096 条必要字段，流式写临时文件和 CRC，不持全局索引锁执行磁盘 I/O。G 改变或恢复 epoch 改变则 abort，删除 tmp，保留旧 final；可手动或退出时重试。发布使用 0600 tmp、fsync、rename 和目录 fsync。并发 publisher 使用 advisory lock；成功后一个 final，无无限历史副本，写入期间最多 old + one new tmp 的数据占用。

普通在线 patch/reconciliation 不写持久索引，没有应用级 WAL，没有周期或按事件数量触发的 checkpoint。cold 首次进入 live、完整失效恢复后、显式 :checkpoint，以及 generation 变化的正常退出会写快照。系统自己的 FSEvents journal 由 macOS 管理。

## 事件维护与扫描边界

内存索引使用 ContiguousArray<FileEntry>、path/directory 映射、parent/children、tombstone 和 generation；查询使用 rwlock。普通 create/remove 走 patch，rename/compound 由目录实际状态 reconciliation，不依赖 rename 配对。目录 I/O 在索引锁外，batch 一次短锁应用；新/替换目录扫描子树，删除目录删除整棵子树。

checkpoint 的 durable cursor 不能越过尚未完成的 diff，因此 coordinator 强制完成歧义目录检查，不依赖 mtime gate 的延迟复查。DirectoryReconciler 的 mtime gate API 和测试仍保留。

| 配置 | 默认值 |
| --- | --- |
| directPatchBatchLimit | 256 events |
| dirtyParentLimit | 64 directories |
| microBatchWindowMilliseconds | 5 ms |
| fullRebuildMinInterval | 30 s |
| rebuildDebounceMilliseconds | 100 ms |
| maxPendingEvents | 100000 |
| maxConsecutiveRebuildFailures | 8 |

live 风暴按 parent 聚合，过多 dirty roots 升级后台 rebuild。replay 的历史重叠可覆盖很多 parent，直接对这些事件范围做 reconciliation，避免“重建 → replay 同一块 → 再重建”的循环。掉事件/溢出仍走完整恢复。失败重建有退避，连续失败后暂停自动重试，:rebuild 可恢复。

- 不访问 raw disk，不需要 root/helper，不修改 SIP，不读取文件内容；会读取本工具自己的索引快照。
- 目录打开使用 O_RDONLY、O_DIRECTORY、O_CLOEXEC、O_NOFOLLOW；枚举使用 getattrlistbulk()、FSOPT_NOFOLLOW，C shim 验证 packed buffer。
- root 做有界 metadata-only canonicalization；不递归跟随子目录 symlink，symlink 本身会被索引。
- 默认不跨 device，不进入下级挂载、network filesystem、DMG、autofs 或 automount trigger。指定 / 仍受限制，不代表完整系统盘覆盖。
- 每个扫描线程 best-effort 禁止 dataless materialization；SDK 缺少常量时安全降级。另有目录 dataless 元数据跳过检查，不通过读取内容触发 iCloud 下载。
- 消失文件视为 race；不可读子目录计数并继续，root 无法打开则明确失败。不会绕过 TCC/POSIX 权限；需要完整 HOME 覆盖时，由用户为实际运行的终端/宿主配置权限。

## 测试与测量

~~~bash
swift build -c release
swift test
swift run -c release apfsfind bench --files 1000 --latency-ms 20
swift run -c release apfsfind persistence-bench --entries 100000 --cache-dir /private/tmp
~~~

本机 FSEvents 集成测试默认运行，只操作拥有的临时 root/cache。原 benchmark 仍是纯 RAM；每种 create/delete/两种 rename 各 100 个真实可见延迟样本，另有 10000 content writes 和 create/delete storm、CPU、verify。

persistence-bench 创建独占临时 root；--cache-dir 指定一个已存在的父目录，benchmark 在其中创建自己的 UUID 缓存子目录，完成后只清理该子目录。默认也在系统临时目录。--entries 支持 102–1000000，包含 root 和 100 个分组目录。

新 benchmark 分别报告 scan/build/replay、snapshot write/size/table/blob、load/validate/mmap/restore、time to live、事件数、RSS、warm verify、在线 inode/mtime/size 不变以及退出 checkpoint/下一次 warm 结果。等待基于状态、事件处理和实际索引条件，不通过固定 sleep 判断恢复完成。FSEvents flush 只能排空已发布事件，不能强迫 kernel 立即发布所有文件活动。

两种 benchmark 均输出人类 summary，最后一行单行 JSON；不写结果文件。性能数字是同一进程的 generator、查询与维护合计，不能单独归因于维护 CPU。

## 当前限制与下一 Sprint

v0.2 解决 warm startup 和持久恢复，但完整运行时 namespace 仍恢复到 RAM。完整路径、Swift 对象与映射仍占内存，查询为 O(entries)，运行期 tombstone 会累积，rebuild 需要额外索引空间。

verify 是 fresh scan，不是原子文件系统 snapshot；请等待目录静止后比较。FSEvents 合并、TCC、权限和持续变化会影响恢复耗时；history UUID 不可用的卷目前拒绝启动。时间 fence 使用 SDK 的 per-device conservative API，外部磁盘/时钟异常依赖失效恢复，未实测所有场景。

下一 Sprint 才实现 mmap immutable base + RAM delta overlay、base tombstone bitmap、base/delta query merge、后台 compaction 和低 RAM directory map。本轮没有 GUI、全文索引、raw APFS 解析、APFS snapshot 解析、searchfs()、Endpoint Security、网络/telemetry、自动更新或数据库。
