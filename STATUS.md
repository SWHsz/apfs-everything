# v0.2.1 hardening / v0.3.0 hybrid index

本轮两个 milestone 已完成，本机正确性验收 PASS。日期：2026-10-05（Asia/Tokyo）。
环境：arm64 macOS 27.0.1 (26A434)、Apple Swift 6.4、SDK 27.0；deployment target macOS 14、Swift language mode 6。
无第三方 package。仅在本机执行，没有使用 HPC，没有 push。

## 提交与基线

- 开始 HEAD：`6ab6b9fee6cda3217353deea1ce0737cf6ee0918`，开始工作区干净，与当时 origin/main 一致。
- Phase A：`948d4ba633c6e3fd75b99d837c8f3d069a600e2b`，`fix: harden durable cursor and cache handling`。
- Phase B / 结束 HEAD：本文件所在的 `feat: add mmap base index and delta overlay` 提交；具体 SHA 在最终交付回复中。
  可用 `git log -1 --format=%H --grep='^feat: add mmap base index and delta overlay$'` 查询。

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
本轮没有 push，未声称远端 CI 已运行。

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
