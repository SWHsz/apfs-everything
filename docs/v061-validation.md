# v0.6.1 Release-Gate Closure

本轮开始 `main / 5caf5ce291d16f8b31606268f3d8e9ae13a99433`，工作区干净。执行环境为本机 Mac；未使用 HPC。只处理 #1 有界路径解析和 #3 可中断资源维护；NSv2 / metav1 格式未变，#2 外置存储、cold namespace builder 和查询语言均未实现。

本报告将最终代码、只读 residency、controlled fixture、真实 live 双卷和修复前诊断分开。`residency-bench` 不启动 watcher，不能替代原生 live 门槛。日用缓存只作为只读输入；真实文件内容未读取，报告不包含实际文件名/搜索结果或原始采样堆栈。

## 提交与代码

| 提交 | 结果 |
|---|---|
| `b676e65` | shutdown 分阶段统计、基线和单卷诊断 |
| `56cd843` | fast exit 取消/等待边界、严格 quiet gate、任务资源与 backoff、缓存 storage 重建 |
| `3e65429` | 子树删除沿现有 overlay child links，避免每次删除扫描全 overlay/cache |
| `d962fcc` | 元数据父目录权限/消失/yield 不再升级为整卷 bootstrap；真正 I/O 错误仍恢复 |
| `95af356` / `6d43e24` | owned 原生捕获脚本；stdout/stderr 经 pipe，由父进程写 excluded cache |
| `6eb9cec` | 保留旧测试全部断言，改用实际 flush/drain 屏障，修复 CI 的固定等待竞争 |

主体 runtime 修复在 `d962fcc`；后续提交仅测试/验证工具/文档。最终产物和原生 manifest 的 SHA、构建 HEAD 在聚合报告中记录。CLI SHA-256 `45bf3767728e10b15f0649711037a9ab5fec656d2a5c3e0991b4200833dff240`；raw release desktop SHA-256 `e54c30fda00ebe4326c1ad418d51104c72454726d12d3be10151df9e69a9f577`。独立包 ad-hoc 重签会改变已签 Mach-O hash，runtime code 未变。最终报告提交仅增补文档/聚合数据，不改变这两个产物。

最终 HEAD 为本报告所在提交，可精确获取 `git rev-parse HEAD`；最终 HEAD CI receipt 发布在 Issue #1/#3，结束回复包含其 SHA 和 run 链接。

## Fast shutdown 与旧 9.94 秒

旧 [real-volume-restart.json](benchmarks/v0.6.0/real-volume-restart.json) 只有从写入 `:quit` 到进程结束的 9.94 秒，没有实际退出请求时间或分阶段计时。旧驱动会排队 `:stats`；`stats()` 也经过 writer barrier。不能从旧报告恢复唯一耗时阶段，不能把它全部归给 fsync、watcher 或 metadataGroup。

本轮确认并修复了两条真实的慢路径：

1. 元数据停止时会在队列屏障前处理大型 pending bulk/subtree。现先发 cancellation，页/项/chunk 检查中断，再 join；不在 fast exit 启动新的大遍历，不 detach 悬空任务。
2. 真实根卷 preparation 的进程采样反复停在 `HybridIndex.remove` 对整个 delta 的路径筛选；根卷单独超过 9 分钟仍未完成。改为沿现有 child links 后，同一 owned 两卷 preparation 在 209.46 秒内完成。该证据证明 writer 的二次遍历热点，但不是旧 9.94 秒的独占归因。

Fast exit 先取消 active queries、queued/running retryable maintenance 和 metadata lookups；随后停止 watcher，drain 已交付的普通 namespace 事件。退出打断 reconciliation 时不发布 partial diff，并保留旧安全游标。等待已进入 atomic publish 的短阶段，写短 state-only 数据，保留旧合法 base，重启 replay 恢复未持久化 overlay。第二次 stop 加入同一 teardown。

最终代码的受控正常 UI quit，在 Root required recovery 正运行时，双卷引擎退出 **6.802 ms**，进程 exit=0；退出前后四个 owned namespace/metadata base 的 SHA-256 均未改变。Root teardown 等待工作在 checkpoint 结束为 6.312 ms，没有等待完整 rebuild。第二次正常 UI quit 双卷引擎 **109.351 ms**，进程 exit=0，四个 base 哈希同样不变。只有两个实际样本，不能声称已经统计证明普通 live 两卷 p95<1秒。旧 9.94 秒的阶段证据缺失仍明确保留；修复前 4.184 ms 双卷 UI 诊断仅作对照。

| shutdown 阶段（ms） | 第一次 Root | 第一次 Data 1 | 第二次 Root | 第二次 Data 1 |
|---|---:|---:|---:|---:|
| cancel queries | 0.0003 | 0.0003 | 0.0004 | 0.0003 |
| stop watcher | 0.0320 | 0.0312 | 0.0415 | 0.5867 |
| namespace drain | 0.0032 | 0.0530 | 0.4800 | 0.0198 |
| metadata updater | 0.0528 | 0.0080 | 108.4750 | 0.0060 |
| cancel maintenance | 0.0160 | 0.0043 | 0.0149 | 0.0197 |
| wait metadata group | 0.0004 | 0.0001 | 0.0001 | 0.0001 |
| wait checkpoint group | 0.0006 | 0.00004 | 0.0007 | 0.0003 |
| state-only write | 0.0008 | 0.0005 | 0.0008 | 0.0009 |
| session teardown | 6.3116 | 0.0018 | 0.0065 | 0.0021 |
| total | 6.4703 | 0.1037 | 109.0414 | 0.6429 |

第一次退出时 Root 在 recovery，state-only 阶段几乎没有实际写入；第二次阶段也近零。这些数值不能用来推断 fsync 的一般成本。各阶段按实际代码边界记录，multi-volume total 还包含共享取消/并发调度；不由相加两卷 total 得出。

## 旧 787.80 CPU 秒的归因边界

旧 [native-live-600.json](benchmarks/v0.6.0/native-live-600.json) 的 600 秒不是严格 quiet：有新增条目、running/queued maintenance。那时没有任务资源 spans，无法事后给出加总恰好 787.80 秒的排他分解。

| 旧窗口中的证据 | 可以判断什么 |
|---|---|
| Root live directory reconciles +317,273；Data 1 +436 | 确有大量 live reconciliation |
| Root scanner entries +2,499,748；Data 1 +413,657 | 确有真实目录 I/O/遍历，不是纯 no-work timer |
| replay_directory_reconciles 未增长 | 这部分新增 reconciliation 未记为 initial replay |
| metadata bootstrap/checkpoint、compaction 完成计数 0 或未出现，仍有待办/运行任务 | 不能把“未完成”理解为“没有消耗 CPU” |
| 没有 CRC/validation/recovery 的排他 CPU 数据 | 相应独占秒数未知 |

因此“主要来自实际 reconcile 和未结束维护”是证据支持的推断，不能声称已量化各自独占 CPU。本轮任务日志给出 kind/volume/urgency、queued/running、yield/restart、records/directories/events、峰值、结束原因与 CPU/I/O。资源统计为 **overlapping process interval**：同进程并发工作会重复进入多个 span，不能相加当作任务独占 CPU。

真实修复前新诊断发现 Root metadata bootstrap 反复完成/重启。父目录 catch 将 EPERM/EACCES/消失和 MaintenanceYield 都调用 invalidated；现统一局部失败策略，增加 errno/recovery-request/yield counters，yield 保留待办且不推进游标。大任务让步/无进展重试采用最多 30 秒的指数 one-shot backoff；emergency correctness 不受该延迟阻挡。没有增加 native 20 分钟 deadline。

## Quiet gate 与原生双卷

门槛要求两卷 namespace live、metadata live、events/batches/pending=0，无 scheduled compaction/metadata、无 queued/running maintenance，并连续 30 秒两类 generation 不变。20 分钟不通过即失败并输出 blockers/tasks/queues/dirty/overlay/cursors。通过后隐藏 600 秒，单独记录 60 秒 CPU、600 秒 I/O 和 mutation gate；不能把 busy 段写为 idle。

最终二进制 `6eb9cec` 在 `/` 与 `/Volumes/Data 1` 上**未通过严格 20 分钟 quiet gate**。到期瞬时 blockers 为空，但 stable_seconds=0：连续 30 秒 generation 不变的条件未满足。没有启动 600 秒 idle；不能宣称真实双卷 quiet CPU/写盘通过。聚合数据见 [native-final.json](benchmarks/v0.6.1/native-final.json)。

| 最终 live 双卷非 quiet 诊断 | 结果 |
|---|---:|
| 首个 30 秒诊断至 timeout 的窗口 | 1169.955 秒 |
| 该窗口 CPU user / system / total | 80.916 / 37.705 / 118.621 秒 |
| disk read / disk write / logical write delta | 383,852,544 / 0 / 0 bytes |
| 到期 physical / RSS / compressed | 44.86 / 107.03 / 19.83 MiB |
| 到期 internal / external resident | 23.80 / 73.72 MiB |
| namespace mutations Root / Data 1 | +743 / +38 |
| FSEvents Root / Data 1 | +15,071 / +270 |
| queued/running maintenance、CPU sampler | 0 / 0，inactive |
| full directory maps / materialized base entries | 0 / 0 |

父目录 EPERM 已局部处理，quiet 等待期间 parent recovery/bootstrap 请求为 0。但这里仍有真实 namespace/metadata 更新，44.86 MiB 是 busy 末端 gauge，不能替代 quiet gate。修复前实例则有 Root metadataBootstrap 反复启动，20 分钟同样失败，保留为 `before-parent-fix-native.json`。

自动全局暂停状态通过；暂停期间在 owned fixture 创建 37-byte 文件、删除、重命名，恢复后 namespace 路径集合 12/12，但 **metadata size verify 在 120 秒内失败**。查询造成 realtime reconciliation 的 resource yield，当前 namespace coordinator 仍升级为 required full rebuild；高频 verify 查询又反复中断恢复。每卷诊断记录 4 次 yield/rebuild 请求。这是未关闭的 #3 问题，不能用 unit tests 的正常恢复通过掩盖。停止高频查询后 UI 曾显示两卷 live，并可见 owned born 文件大小 37 bytes；这只是局部人工观测，不能改写完整自动 verify 失败。Root 再次恢复时 metadata 排序列禁用。

首轮 7 个排序方向、各 5 次查询中 metadata_complete 全为 true，relevance/name/mtime/size 最差 p95 为 553.02 / 98.41 / 180.48 / 78.01 ms；小样本含首次冷查询，不能据此声称 query latency 无回归。系统菜单栏 AX 读取超时，最终菜单全局/单卷暂停恢复没有取得人工回复，列为未验证。原首轮退出捕获缺失，不能称正常退出通过；随后同一 cache/代码的受控 restart 与正常 UI quit 另行记录。第一次受控 restart：Root search-ready 3.442 秒、live 282.518 秒；Data 1 search-ready 2.159 秒、live 3.981 秒。owned fixture 全 12 路径与 37-byte metadata verify **通过**。Root 有 2 次 full scan（reconcile_error/resource_yield），查询 metadata_complete 全 false，诊断时 Root 又在 Rebuilding/failed；Data 1 full scans=0，Live/live。重启局部 fixture 通过不等于纯增量恢复或全部 release gates 通过。

第二次受控 restart：Root search-ready 2.701 秒、live 112.114 秒；Data 1 search-ready 1.631 秒、live 120.195 秒。两卷各完成一次 reconcile-error full rebuild，随后均 Live/live。fixture 12/12 与 37-byte metadata 通过，7 个方向的查询 metadata_complete 全 true，最差 p95 relevance/name/mtime/size 为 66.92 / 83.65 / 69.24 / 74.60 ms。因为发生 full scan，不能称 pure replay gate 通过。

第二次 restart 诊断时 physical 88.42 MiB、RSS 1387.84 MiB；CPU累计 193.051 秒、disk writes 466,702,336 bytes，属于 recovery/setup，不能记入 quiet steady-state。两卷恢复并行期间 physical peak **2045.11 MiB**、RSS peak **2261.97 MiB**。终态两份 full maps/materialized base 都为零；恢复过程的 temporary FileIndex graph/allocator 峰值仍很高，本轮没有重写 cold builder，明确保留该风险。这里只能证明恢复后 physical gauge 小于150MiB，不能替代严格 quiet 验收。

两次受控捕获均使用同一最终 runtime binary 和 owned cache。原首轮 capture 的进程/父进程在继续任务时已不在，缺少 exit.json；其正常退出方式未知，报告保留为未观察退出，没有当作 crash/normal quit 的通过证据。

原生测试 bundle 没有继承日用应用的完全磁盘访问授权。不可读/系统保护数量按实际 scope 报告，不能把 owned fixture verify 说成所有受保护目录的完整文件系统一致性验证。每次 prepare 全量读取目录项和元数据、按同设备/不 follow symlink diff 到 owned cache；准备期 I/O 与常驻测量分开。

## 最终三个 benchmark

| 指标 | 结果 |
|---|---|
| Controlled create/delete/rename p95，100 samples/operation | 21.51 / 21.48 / 21.66 ms |
| Controlled 安静 60 秒 CPU user+system | 0.000156 秒 |
| Controlled 安静 disk/logical writes | 0 / 0 |
| sampler / compaction / metadata timer wakes | inactive / 0 / 0 |
| pause 1000 mutations → resume | 78.33 ms，verify true |
| 只读两卷 existing cached entries | 4,923,278 |
| 只读 600 秒 CPU / disk writes | 0.000247 秒 / 0 bytes |
| 只读 600 秒 logical writes | 20,480 bytes，独立报告；不能称所有写入都为零 |
| 只读 600 秒末端 physical / RSS | 7.50 / 5.69 MiB |
| 只读查询后 reclaim opportunity physical / RSS | 9.97 / 385.75 MiB |
| 只读所有查询类型最差 p95 relevance/name/mtime/size | 75.16 / 75.21 / 73.53 / 74.31 ms |

只读 bootstrap 在 owned 临时位置生成缺失 metadata，不修改日用缓存。其 setup 写入不属于 600 秒 idle。原生 live gate 与本表结果独立。

## Cache 结构和实际释放

独立 fresh process 只创建长路径 cache，没有 FileIndex graph；每阶段 5 次 kernel gauge 采样。warning 收集 MRU 2048，创建小 Dictionary 并重建 LRU；critical 安装新的 root-only container；normal 只恢复上限。weak-reference 回归验证旧 storage 释放，旧 snapshot/resolver 生命周期保持正确。

| 阶段 | entries | 实际 Dictionary capacity | estimated bytes | physical footprint 范围 MiB |
|---|---:|---:|---:|---:|
| before | 16,384 | 24,576 | 41,683,759 | 48.31–48.53 |
| warning | 2,048 | 3,072 | 5,212,160 | 31.38–31.45 |
| critical | 1 | 1 | 134 | 31.49–31.55 |

Storage generation 1→2→3，rebuilds 0→1→2。warning 的 kernel footprint 实际下降；critical 的引用/容量继续释放，但 kernel/allocator 没有立即再下降。RSS before 52.64–53.31、warning 53.80–53.88、critical 53.91–53.97 MiB，未同步下降，不能隐藏这点。结构有界与引用可释放为 correctness gate，不要求 macOS 立即降低 RSS。

实际 owned 10 CPU workers 的 busy 测量：idle EWMA 0.330%，opportunistic task 延迟；恢复空闲后继续。结束只回收 owned workers，没有终止未知进程。所有 maintenance kinds 的 checkpoint cancellation、queued/running bootstrap、active query、两卷/第二次退出、旧 base 保留/重启 replay、strict quiet、no-progress/backoff、cache MRU/旧引用并发回归均保留。

## 测试、CI、Issues

原有 220 项保留，最终 **240 项（220 Core + 20 Desktop）**。普通、ASan、TSan 均 0 failures；没有 sanitizer 诊断。普通 102.17 秒，ASan 200.34 秒，TSan 305.63 秒。默认 1 项真实挂载 opt-in skip，随后 `APFSFIND_RUN_MOUNT_TESTS=1` 单独执行 NativeMountSmokeTests，1 项通过、0 skip（9.29 秒）。Release build、0.6.1/601 app build 和签名检查均通过。完整结果见 [final-checks.json](benchmarks/v0.6.1/final-checks.json)。

代码 HEAD `6eb9cec` 的 [CI 37638402037](https://github.com/SWHsz/apfs-everything/actions/runs/37638402037) 四项 required jobs 全部成功。最终报告提交的 HEAD CI 通过后在 Issue #1/#3 留下链接；精确 HEAD 可由下列查询复核，避免把前一提交的 CI 当作最新结果。

```bash
gh run list --repo SWHsz/apfs-everything --commit "$(git rev-parse HEAD)" --json databaseId,headSha,status,conclusion,url
```

首次 `d962fcc` CI integration 的旧 compaction invalidation 测试出现竞争：writer barrier 不保证 asyncAfter drain 已执行，固定等待 20 ms 在 runner 负载下不足。`6eb9cec` 改为 flush/drain 后再做原来的拒绝发布/旧 base 字节断言，没有减少断言、删测或扩大等待。

#1/#3 **保持 OPEN**：final native verify 和 strict quiet 未通过，菜单单卷操作也未完成验收。不创建 v0.6 release tag。后续首先需要将 reconciliation 的 resource yield 保留为有界局部待办并固定安全 cursor，避免升级整卷恢复；同时证明查询让步后维护最终收敛。不能通过延长 deadline 或把 busy 窗口改称 idle 收口。#2 未实现，下一轮单独做 v0.6.2 外置/分层索引存储；后续再做磁盘支持的 cold builder。完整 cold build 的约 855 MiB 历史峰值没有在本轮解决。

## 临时缓存清理

两次受控正常退出后，按 manifest 的 uid/inode/device 核验，删除本轮 63/B7/79 owned cache、独立测试 app 和 owned fixture，累计逻辑文件大小 1,444,355,987 bytes（约1.35GiB）。APFS clone 的实际物理回收量没有测量，不把逻辑大小当作释放磁盘量。没有删除未知 tmp 文件或日用缓存；聚合验收与 cleanup receipt 已保留，原始临时捕获目录已清理，复现需要重新 prepare。独立 APFSFindV061Smoke 现已关闭；没有可供继续检查菜单的存活实例。

## 精确复现

```bash
cd "/Volumes/Data 1/everything"
swift build -c release
swift test -j 4
swift test -j 4 --sanitize=address
swift test -j 4 --sanitize=thread
APFSFIND_RUN_MOUNT_TESTS=1 swift test -j 4 --filter NativeMountSmokeTests
bash scripts/build_app.sh
codesign --verify --deep --strict dist/APFSFind.app

.build/release/apfsfind background-bench --idle-seconds 60
.build/release/apfsfind lightweight-bench --entries 1000000
.build/release/apfsfind residency-bench --root "/" --second-root "/Volumes/Data 1" --idle-seconds 600

# 所有负载检查结束后 prepare，立即 launch；输出的第一行是 owned manifest 路径。
python3 scripts/prepare_native_smoke.py
python3 scripts/run_native_smoke.py "$MANIFEST" --label first
# 在独立 APFSFindV061Smoke 完成报告后，验菜单全局/单卷暂停、搜索和排序，再正常界面退出。
python3 scripts/prepare_native_smoke.py --restart "$MANIFEST"
python3 scripts/run_native_smoke.py "$MANIFEST" --label second
# 等 restart_fixture_verify / restart_complete，正常界面第二次退出。
```

`MANIFEST` 设置为 prepare 打印的第一行绝对路径，不使用日用 cache 作为写入目的地。日志/metadata/base 只在显式 owned benchmark 目录产生。正常应用没有这些 native polling/capture 文件。
