# Sprint 2 / v0.2.0

状态：required path 已实现，当前本机 provisional acceptance **PASS**。验证日期 2026-10-05（Asia/Tokyo）。执行环境：本地 arm64 macOS 27.0.1、Swift 6.4、SDK 27.0；deployment target 保持 macOS 14，Swift language mode 6。未使用 HPC。

## Baseline

开始修改前 HEAD：bd63cbc3ea9e610441135f691fa5211fa2af5efd。

实际执行原有基线：

| 检查 | 结果 |
| --- | --- |
| swift build -c release | PASS，无 warning |
| swift test | 60 tests，0 failures，0 skipped，约 2.60 s |
| bench --files 1000 --latency-ms 20 | PASS，全部 0 timeout，verify 0/0，cleanup 成功 |

基线 create/delete/同目录 rename/跨目录 rename p95：21.37 / 21.09 / 21.33 / 22.36 ms。内容写入 10000 次：loop 26.53 ms，总 44.31 ms，实际忽略 1 个合并事件，无 namespace 工作。1000 文件 create/delete storm：102.84 / 101.65 ms。

## 完成内容与修改文件

Package.swift 的三个生产 target 和测试 target 保持不变，无第三方依赖。

| 文件 | 变更 |
| --- | --- |
| Sources/CAPFSShim/include/CAPFSShim.h | volume metadata、CRC32、安全 cache directory 接口 |
| Sources/CAPFSShim/VolumeIdentity.c | root device/inode、volume UUID、mount point；openat/no-follow cache 创建 |
| Sources/CAPFSShim/CRC32.c | pthread_once CRC32 IEEE 表，流式累积 |
| Sources/APFSFindCore/VolumeIdentity.swift | 卷身份、history UUID、device fence、相对路径/绝对 alias 转换 |
| Sources/APFSFindCore/SnapshotFormat.swift | v1 explicit endian/layout/错误/export metadata |
| Sources/APFSFindCore/SnapshotReader.swift | 一次 mmap，校验完整格式和身份 |
| Sources/APFSFindCore/SnapshotWriter.swift | compact ID remap、4096 分块、流式 CRC/写入、G 检查 |
| Sources/APFSFindCore/SnapshotStore.swift | SHA256 key、0700/0600、advisory lock、原子发布与 tmp cleanup |
| Sources/APFSFindCore/FileIndex.swift | canonical export order、短锁 chunk、预分配 bulk restore、初始 G 发布 |
| Sources/APFSFindCore/BulkScanner.swift | 排除本工具 cache 子树 |
| Sources/APFSFindCore/FSEventsWatcher.swift | per-device stream 与 callback 路径转换、dispatch flush barrier |
| Sources/APFSFindCore/UpdateCoordinator.swift | warm 安装、writer-confined cursor、G/C/V barrier、rebuild E0/replay |
| Sources/APFSFindCore/PersistentIndexCoordinator.swift | 默认持久化、cold/warm/fallback、异步/退出 checkpoint、stats |
| Sources/apfsfind/CLI.swift | v0.2、ephemeral/rebuild/cache、:checkpoint、可取消正常退出 |
| Sources/apfsfind/BenchmarkRunner.swift | 保留原 RAM benchmark，v0.2 输出，复用安全临时目录所有权 |
| Sources/apfsfind/PersistenceBenchmarkRunner.swift | 100k cold/warm/RSS/size/verify/online/exit benchmark |
| Tests/APFSFindCoreTests/LiveUpdateIntegrationTests.swift | 保留原断言，等待实际已处理 content event |
| Tests/APFSFindCoreTests/PerDeviceWatcherTests.swift | SDK 原生 relative-to-device probe |
| Tests/APFSFindCoreTests/SnapshotTestSupport.swift | 独占 fixture 与可重新计算 CRC 的 corruption helpers |
| Tests/APFSFindCoreTests/SnapshotFormatTests.swift | CRC 向量/分块、little-endian、整数溢出 |
| Tests/APFSFindCoreTests/SnapshotRoundTripTests.swift | 最小、Unicode、deep、symlink、compaction、deterministic、100k |
| Tests/APFSFindCoreTests/SnapshotCorruptionTests.swift | 恶意 header/record/blob、identity、type/mode 拒绝 |
| Tests/APFSFindCoreTests/SnapshotAtomicityTests.swift | fault、取消、并发 publisher、stale tmp、symlink、权限 |
| Tests/APFSFindCoreTests/PersistentRecoveryTests.swift | offline/crash-like/warm/fallback/no online writes/G/C/ephemeral |
| README.md、STATUS.md | 使用、架构、格式、实測与限制 |

## Snapshot format v1

所有整数 little-endian，不写 Swift/C struct 内存布局。文件结构：

~~~text
192-byte header
canonical root UTF-8 bytes（无 NUL）
zero padding，record table 对齐至 8 bytes
N × 24-byte records
contiguous UTF-8 basename blob（无 NUL）
~~~

Header：

| offset | bytes | 字段 |
| ---: | ---: | --- |
| 0 | 8 | magic APFSIDX + NUL |
| 8 | 4 | version = 1 |
| 12 | 4 | header size = 192 |
| 16 | 4 | flags = 0 |
| 20 | 4 | record size = 24 |
| 24 | 8 | record count |
| 32 / 40 | 8 each | record table offset / length |
| 48 / 56 | 8 each | name blob offset / length |
| 64 / 72 | 8 each | root path offset (=192) / length |
| 80 | 8 | creation Unix seconds |
| 88 | 8 | index generation G |
| 96 | 8 | last successfully processed per-device event ID C |
| 104 | 8 | root device ID |
| 112 | 16 | volume UUID bytes |
| 128 | 16 | FSEvents history UUID bytes |
| 144 | 4 | CRC32 of bytes [192, EOF) |
| 148 | 4 | CRC32 of header，hash 时该字段置零 |
| 152 | 8 | exact file length |
| 160 | 8 | root inode/file ID |
| 168 | 24 | reserved zero |

Record：

| offset | bytes | 字段 |
| ---: | ---: | --- |
| 0 | 4 | compact parent ID |
| 4 | 4 | basename offset relative to blob |
| 8 | 2 | UTF-8 basename byte length |
| 10 | 1 | kind：file=1、directory=2、symlink=3、other=4 |
| 11 | 1 | flags：bit 0 = mount/device traversal boundary |
| 12 | 4 | reserved zero |
| 16 | 8 | file ID，0 = unknown |

record ID 是 ordinal，连续 0...N-1；root 为 0，parent=UInt32.max、name length=0、directory、flags=0。其他 parent 必须先于 child，必须是可遍历 directory。device 由 header 提供；不同 device 的条目记录 boundary bit，恢复后仍不允许递归进入。导出以 raw UTF-8 basename 排序的 DFS 形成确定顺序，payload 不受原 RAM ID/插入顺序影响；header 的时间、G、C 可不同。

限制：20,000,000 records，8 GiB 文件，name blob ≤ UInt32.max，basename ≤ NAME_MAX，恢复路径 < PATH_MAX。检查 checked arithmetic、canonical section 边界、连续 name offsets、有效 UTF-8、禁止 slash/NUL/dot/dotdot、合法 kind/flags、CRC、owner/type/mode。拒绝 UInt64.max cursor（SinceNow）和 generation，避免恶意 sentinel 静默跳过 replay。duplicate path 在 bulk restore 私有构建阶段拒绝，失败内容不发布。

snapshot 不含 tombstone、foldedName、重复 full paths、Swift object metadata、hash table、JSON keys 或查询缓存。root bytes 是唯一完整路径。

## Identity、per-device probe 与 cursor

实现前阅读当前 SDK FSEvents.h。原生 probe 使用临时子目录，不经过产品 callback 转换。实测 Data volume mount 为 /System/Volumes/Data；临时 canonical root 位于 /private/var/folders/...；relativeRoot 为 private/var/folders/...（无开头 /）；原生 callback 同样无开头 /。

SDK 的 volume root watch path 为 empty string。Data firmlink alias 不在 f_mntonname 字面前缀下时，先验证 mount+absoluteAlias 的 device/inode 与 root 相同，再采用该 alias 的相对 components；不会凭卷名推断。

根身份检查包括 canonical root UTF-8 byte equality、device、root inode、volume UUID、FSEvents history UUID。snapshot filename 使用 SHA256(root UTF-8 + NUL + volume UUID bytes)，同 root/volume 保存一个 final。history UUID 不可用时目前明确拒绝 durable replay。

E0 使用 FSEventsGetLastEventIdForDeviceBeforeTime(device, Unix seconds) 在 scan 前捕获，使用 SDK 的 conservative fence，不把 host-global ID 持久化。FSEventStreamCreateRelativeToDevice 保留 FileEvents / NoDefer / UseCFTypes / WatchRoot / FullHistory；不保留 host-level 另一套分支，ephemeral 使用相同 watcher。

FullHistory 首个历史 chunk 可以覆盖 cursor 之前的活动，不能直接按旧 ID 丢弃。已知 same-kind create 在风暴计数前幂等过滤，create/remove 冲突仍根据整个 batch 进行 authoritative reconciliation。replaying 中多个 dirty parents 直接按事件范围 diff，避免反复 replay 同一历史块引起 full rebuild 循环；live 的 dirtyParentLimit 仍保留。80 个离线 rename parents 的回归测试已通过。

HistoryDone 只有在 batch mutations 完成且 inbox 无遗漏/overflow、状态仍 replaying 时才能转 live。C 只在 writer queue 中于 batch apply/reconcile 后推进；content-only 推进 C、不推进 G。overflow/stream invalid/root MustScan 等进入 dirty，不能 checkpoint，恢复重新捕获 E0 后 replay。

## Checkpoint 与原子性

writer barrier 捕获同一逻辑时刻的 G/C/V 和 recovery epoch。ID-only 导出计划与 old→new remap 在临时 RAM；每 4096 条短锁复制必要 basename/元数据，两次顺序输出 table/blob。没有完整 NamespaceEntry 数组或完整 binary Data 副本，没有持有索引锁执行磁盘写入/fsync。

导出中 G 改变立即 abort；发布前再次核对 G/epoch/state/identity。取消和 generation abort 计数并明确报告，不冒充成功。初次 warm 安装保持快照 G；未变化 warm exit 不重写文件。

store 使用 pinned directory FD、openat/O_NOFOLLOW、0700 directory、0600 regular snapshot、root-specific advisory lock。只允许明确验证的 macOS /var、/tmp 系统别名；自定义 cache/final symlink 拒绝。缓存子树排除防止 checkpoint 反馈事件。

流程：O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW tmp → streaming write/CRC → check length → fsync(file) → close → beforePublish validation → rename → fsync(directory)。旧 final 用临时 hard link 支持 rename 后失败回滚，不复制旧数据；数据峰值 old + one new tmp。成功仅保留 final 与零字节 lock，不保留历史 snapshot。下次启动在锁可获得时清理 stale tmp，不删除另一 publisher 的 active tmp。

fault tests 包含 header 写入后、fsync 前、rename 前后、directory fsync 前的失败；全部保留旧合法 snapshot，取消/并发 publisher 同样通过。没有模拟真实断电，也不将 fault injection 宣称为所有存储故障的保证。

写入仅在 cold 首次 live、完整失效恢复成功后、手动 :checkpoint、generation 变化的正常退出。没有应用级 WAL、周期/按 mutation 的高频写入。普通在线更新不写 snapshot。

## 最终构建、测试与 CLI smoke

实际执行，均退出码 0：

~~~bash
swift build -c release
swift test
swift run -c release apfsfind bench --files 1000 --latency-ms 20
swift run -c release apfsfind persistence-bench --entries 100000 --cache-dir /private/tmp
~~~

最终 release build 无新增 warning。swift test：**85 tests，0 failures，0 skipped**，执行约 5.47 s，包含原有全部 60 项和新增 25 项。没有删除/弱化原断言；原 content integration test 增加“已收到并处理 content event”条件等待。device-relative 的 kernel journal 发布可晚于 flush；固定 sleep 无法证明事件处理。等待使用 state、HistoryDone、queue、generation 或实际可见条件。两次 interrupt 的旧快照保留及后续 replay 另有回归测试。

新测试覆盖 round trip、composed/decomposed Unicode、深层目录、symlink、unknown file ID、无 tombstone、ID compaction、相同 payload、100k、CRC、全部 offset/length/parent/name/count corruption、identity、unsafe type/mode、fault/cancel/并发、stale tmp/symlink、offline create/delete/两种 rename/新非空目录、旧 cursor crash-like recovery、Wrapped/Dropped/root MustScan/history UUID fallback、缓存排除、ephemeral、强制 scan、无变化退出，以及 G/C 同步捕获。

CLI smoke 使用两个独立 swift run serve 进程及拥有的 mktemp-style root/cache：第一次 seed、等待 live/首次保存、:checkpoint、:verify、正常退出；关闭期间 create 与 rename；第二次报告 warm_snapshot，没有 Initial scan，找到 created-while-offline.txt 和 renamed.txt，seed.txt 不再出现，verify 0/0。0700/0600 实机检查通过。所有测试/benchmark 显式注入临时 cache，未创建用户默认 HOME 索引。

## 原延迟 benchmark（v0.2）

每种 100 samples，0 timeout：

| workload | median ms | p95 ms | p99 ms | max ms |
| --- | ---: | ---: | ---: | ---: |
| create | 19.74 | 21.16 | 21.74 | 22.30 |
| delete | 19.87 | 21.31 | 21.69 | 22.27 |
| 同目录 rename | 19.95 | 21.26 | 21.95 | 22.52 |
| 跨目录 rename | 20.72 | 22.40 | 23.36 | 24.70 |

scan+replay 147.24 ms。10000 content writes：loop 25.72 ms，总 43.42 ms，实际忽略 1 个事件，G 402→402，namespace work 0；user/system CPU 0.001618 / 0.024586 s。

1000 文件 create storm 87.75 ms，user/system CPU 0.0743 / 0.0495 s，1 次 directory reconcile；delete storm 88.76 ms，CPU 0.0721 / 0.0246 s，1 次 reconcile。两次 verify 0/0、full rebuild 0、cleanup 成功，provisional_acceptance=true。最终 RSS 12,369,920 bytes。

## 100,000 entries persistence benchmark（v0.2）

实际创建 root + 100 个 directory + 99,899 个短 basename 文件；一次运行的结果：

| cold path | 实测 |
| --- | ---: |
| full scan | 248.9 ms（stats integer 248） |
| RAM build | 1949.9 ms（stats integer 1949） |
| initial replay | 214 ms |
| time to live | 2419.56 ms |
| snapshot write，包含 fsync/publish | 59.16 ms |
| snapshot bytes | 3,099,897 |
| record table bytes | 2,400,000 |
| name blob bytes | 699,593 |
| bytes/live entry | 30.99897 |
| checkpoint observed peak RSS | 92,749,824 bytes |

| warm path | 实测 |
| --- | ---: |
| open/validate | 8.12 ms |
| mmap syscall | 0.019 ms |
| bulk FileIndex restore | 78.04 ms |
| replay | 88.91 ms |
| time to live | 176.89 ms |
| received replay events（含重叠/HistoryDone） | 3529 |
| full recursive scanner calls | **0** |
| directory/subtree reconciles before verify | **0 / 0** |
| RSS before load | 79,675,392 bytes |
| RSS immediately after mmap | 79,675,392 bytes |
| RSS after restore | 88,113,152 bytes |
| live RSS | 85,016,576 bytes |
| verify missing/extra | **0 / 0** |

RSS 是同一 benchmark 进程先 cold 后 warm 的阶段采样；cold 对象已释放，但 allocator 会保留 pages，不代表独立 warm 进程的最低 RSS。checkpoint peak 是 chunk 边界观察到的峰值，不是全进程高频采样/绝对瞬时上界。没有据此宣称最终 RAM 优化完成。

在线 workload：1000 create + 1000 delete、10000 content writes、100 次 rename；590.96 ms，user/system CPU 1.179043 / 0.169961 s（含 generator、轮询和 verify）。snapshot inode/mtime/size 全部不变；content generation 不变，online verify 0/0。变化退出产生一次新快照，下一次 warm 能见最新 rename，full_scans=0，verify 0/0。最后单行 JSON provisional_acceptance=true。结果未写入仓库。

独立 synthetic format test：100,000 records，3,000,010 bytes，**30.0001 bytes/entry**，低于 64 bytes/entry 目标。真实 arbitrary filename 分布没有硬性 bytes/entry 上限。

## 已知限制与未完成项

- Sprint 2 required path 没有 TODO/stub；受测场景全部通过。corruption 检查针对启动时文件；假定本工具按 immutable/atomic replacement 管理快照。同用户恶意并发原地修改或 truncate 已 mmap 文件不属于当前保证。
- v0.2 解决 warm startup 和持久恢复，但完整运行时 namespace 仍恢复到 RAM。最终的 mmap immutable base + RAM delta 属于下一 Sprint，不能宣称 v0.2 已解决全部内存问题。
- search 仍线性扫描，完整路径/Swift map 保留；运行期 tombstone 累积，rebuild 需要额外索引内存。
- ID planning 对单目录 children 排序时持一次 read lock；极宽目录排序仍可能暂时阻塞 writer，尚未进行百万平面目录的隔离测量。导出/写文件不持全局锁。
- 当前 history UUID 为 nil 的卷拒绝启动；readonly/no-journal 卷、外接盘时钟异常、真实 journal purge、突然断电均未专项实机验证。Dropped/Wrapped/MustScan/history change 使用真实 watcher 加 synthetic invalidation/identity 注入测试，不声称制造了真实 OS journal 损坏。
- crash-like 测试采用“不保存当前变化即停止”模拟旧 checkpoint 恢复，未宣称做了真实 SIGKILL/断电耐久测试。
- 本 Sprint 未对真实 HOME 写快照或做新的百万条目持久化 benchmark；100k 的数字不能外推所有 HOME 分布。v0.1 真实 HOME 的历史启动实测仍在 baseline commit STATUS 中。
- 未实机验证 macOS 14、Intel、真实 dataless iCloud/DMG/network/autofs；保留扫描 metadata checks 和原测试，不主动建立这些环境。
- verify 非原子磁盘 snapshot，需要静止目录。TCC/POSIX 读取排除依旧存在，不绕过权限。持续变化可让 checkpoint G 校验 abort，退出/手动可重试。
- 如 cache 安全打开失败，明确拒绝该配置；如写入失败，在线索引继续服务，记录错误并保留旧 final。真正存储故障后的回滚为 best-effort。
- 持续掉事件可能保持 dirty/rebuilding，沿用有退避/熔断的恢复，不保证固定启动时间。多卷 system-wide indexing 不在本版范围。

## 下一 Sprint 边界

只记录，当前没有实现：mmap immutable base index + RAM delta overlay + base tombstone bitmap + query base/delta merge + 后台 compaction + 低 RAM directory map。下一轮让 snapshot 直接成为可查询的 immutable base，RAM 只保留变化层；v1 fixed record/name blob/parent-before-child 格式为此保留接口基础。
