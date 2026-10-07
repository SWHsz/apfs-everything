# v0.6.0 验证记录

范围：Issue #1 和 #3；Issue #2 外置索引存储未实现。开始 HEAD 为 `9295470152dbb4dd309d2582611111f01ea2074b`，main，工作区干净。用户授权完成后推送并验证 CI。磁盘格式仍为 namespace v2 / metadata v1，FSEvents 时间基准保留 POSIX 1970。

## 实现

两份完整目录路径字典已删除：`HybridIndex.directoryPaths` 和 `MetadataIndexCoordinator.directories`。共享 PathResolver capture 固定 mmap 生命周期，在 writer lock 外逐组件查 parent-keyed delta child、base child ordinal、tombstone 和类型；generation 改变时单路径最多重试一次。全量 Map 计数均为 0。冷扫描的参考 FileIndex 是临时构建结构，仍是大规模恢复的内存风险。

每种 resolver 的 HotDirectoryCache 默认 8192、最小 1024、最大 16384 项；两卷有 namespace/metadata 共四份缓存。LRU 按 epoch/前缀失效，warning 缩至 25%，critical 只留 root；压力解除按访问填充。每卷 2000 个目录重复探测时，各缓存约 66.6% 命中，包含组件的 parent 查找，不代表日常用户命中率。

metadata seed/build 使用 16.25 bytes/entry 的紧凑临时 private mmap columns；writer 最多 64 KiB 一块，增量 CRC、0600 临时文件、完整验证、原子发布。验证 mapping 释放后建立独立 runtime read-only mapping，不主动预热整列。取消、ENOMEM、ENOSPC 和发布失败保留旧文件。`MADV_DONTNEED` 没有产生可依赖的即时 RSS 下降，如实记录。

调度状态为 interactive / busy / opportunistic / maintaining / emergency / suspended。系统 CPU 每 2 秒采样，EWMA alpha 0.4，仅 pending/running 维护期间启用；空队列取消 timer。普通任务要求 CPU idle ≥60% 持续 10 秒及交互安静 10 秒；idle <30% 持续 2 秒或 <15% 即 yield。内存 warning、热状态 serious/critical、低电量模式阻止普通重任务；required 恢复忙时降至一个 worker，查询和 critical 压力仍让路。emergency 小块节流，或保守固定 cursor；不会丢弃正确性 overlay 来压低 RAM。

扫描按 bulk page、输出/结构检查按 4096 项、metadata/CRC 按 64 KiB 检查取消、资源及卷身份。临时构建 yield 后释放并重试，未实现跨进程构建进度保存。namespace 和 metadata overlay 有 500k 项 / 128 MiB 上限，事件 buffer 100k，原子 diff 100k，临时目录 frontier 100k、旧 base 单目录 children 展开 100k、严格累计 diff 100k，去重窗口 16384，mtime gate cache 8192。恢复期间停止对旧 base 反复 reconciliation；重启 stream 从新扫描前的栅栏 replay，不将旧历史 hints 应用到更新的扫描结果。队列溢出、stream invalidation、root subtree 触发恢复时立即停止核对旧批次，保守固定 cursor。新扫描的 namespace/metadata 验证发布后才重启 replay，generation 递增；扫描 lease 延续到发布，避免等待 HistoryDone 时保留百万项 FileIndex。处理完有序 HistoryDone 后进入 live，即使随后已入队实时事件；不要求活跃系统盘的实时队列瞬间归零。Metadata 子树遇到权限限制／正常消失 race 按 namespace 的排除策略处理，意外 I/O／枚举上限才触发全 sidecar recovery。

Rename alias 深度最多 16、数量 64、保留估算 32 MiB；超限前切换到权威重建／紧急维护。10k 次目录往返 rename、checkpoint/restart、Unicode NFC/NFD、unknown last、base/delta/global top-K 与所有 sort 的随机 property tests 已覆盖。

## 内存实测

进程指标区分 RSS、physical footprint、internal resident、external/file-backed resident、compressed、pageins、wakeups、logical/disk writes。独立 private/anonymous ledger 与 dirty private pages 在普通应用层不可可靠获取，报告 `null/unavailable`；internal+compressed 仅作比较代理，不能冒充精确 private ledger。

v0.5 与 v0.6 的同数据集只读诊断含 4,923,278 entries（系统 3,308,277；Data 1 1,615,001）。两份旧 Map 各 630,979 项，合计估算 228.45 MiB。namespace 文件合计 439,850,047 bytes，metadata 合计 80,003,813 bytes。日用缓存未修改，缺少 metadata 时使用 owned scratch。

| 同数据集阶段 | v0.5 physical MiB | v0.6 physical MiB | v0.5 RSS MiB | v0.6 RSS MiB |
|---|---:|---:|---:|---:|
| 600 秒只读 idle 末端 | 302.35 | 8.02 | 5.56 | 5.55 |
| 30 次 broad queries 后 | 302.47 | 8.19 | 407.73 | 463.00 |
| 全部 queries 后 | 302.72 | 10.52 | 418.75 | 372.52 |
| reclaim opportunity 后 | 见原始 phases | 10.56 | 见原始 phases | 374.48 |

v0.6 internal+compressed：600 秒末端约 7.38 MiB，全部 queries 后约 9.78 MiB。此诊断在系统卷恢复和 sanitizer 负载期间运行，保留其查询未达标 outliers；它不启动 FSEvents，不能当成 live 桌面验收。600 秒 CPU 0.000868 秒，disk writes 0，logical writes 16,384 bytes，interrupt wakeups 2。

另一次现有 matched metadata 的 5,031,012 entries 只读查询复测：30 次 broad queries 后 physical 17.38 MiB，internal+compressed 16.72 MiB，RSS 396.28 MiB；全部 queries/reclaim 后 physical 7.16 MiB、internal+compressed 6.48 MiB、RSS 399.66 MiB。RSS 250 MiB 软目标仍未达到，主要剩余项为 file-backed mmap resident；不能把映射文件大小、RSS 和 private footprint 混为一谈。

原始数据：[基线](benchmarks/v0.6.0/v05-residency.json)、[同数据集 600 秒诊断](benchmarks/v0.6.0/residency-under-recovery-load.json)、[最终查询复测](benchmarks/v0.6.0/residency-query-final.json)。

## Metadata 构建

真实构建 1,000,000 个条目：999,899 个文件、100 个父目录及 root。独立新进程加载既有 namespace 后重建 metadata，namespace full scans = 0，peak RSS **110.25 MiB**，小于 400 MiB；耗时 90.24 秒。完整 cold namespace+metadata peak RSS 855.13 MiB，较 v0.5 946.89 MiB 降低约 9.7%；不能声称整个 cold build 内存减半。冷扫描完整 Swift FileIndex 图仍未替换。

metadata-only 文件 16,250,272 bytes；10k 次同文件写入只做 1 次 lookup，namespace generation 不变；metadata 单次更新 p95 240.18 ms，包含 200 ms debounce。重启匹配 fresh metadata scan，warm namespace full scans = 0，replay 2.56 秒。[百万真实文件报告](benchmarks/v0.6.0/metadata-1m.json)。

## 查询与实时更新

每种 sort × exact / substring / one-character / no-result 各 20 次，limit 51，两卷合并。

| Sort | 最慢分类 p95 ms | 门槛 ms |
|---|---:|---:|
| relevance | 93.39 | 120 |
| name asc / desc | 76.30 / 74.96 | 120 |
| mtime asc / desc | 74.66 / 74.57 | 150 |
| size asc / desc | 124.26 / 77.45 | 150 |

100 samples/操作的 namespace create/delete/same-dir rename/cross-dir rename p95：21.67 / 21.42 / 21.80 / 21.67 ms，0 timeouts。1000 create/delete storm 167.94 / 143.78 ms，fresh verify missing=extra=0，10k 内容写入 generation 不变。[namespace 报告](benchmarks/v0.6.0/namespace.json)。

persistent background 的 create/rename/delete p95 40.55 / 22.67 / 22.00 ms；create max 202.12 ms 保留。暂停期间修改 1000 项，恢复 385.18 ms，stale 保留及 verify 一致。60 秒无变化 CPU **0.000238 秒**，disk/logical writes **0**，CPU sampler 前后 inactive，CPU/两种 maintenance timers wakeups **0**。[background 报告](benchmarks/v0.6.0/background.json)。

## 压力与桌面实盘

真实 CPU 压力只启动并终止本轮拥有的 10 个子进程：最终 idle EWMA 0.322%，普通维护保持 queued，压力结束后恢复，sampler 17 次唤醒。Fake memory/thermal/power/query 信号验证 cache 缩减、running task yield、旧 base 可查、overlay 保留和 emergency cursor 安全。

已填满 cache 的 fake warning/critical：5001 → 2048 → 1 项；最终使用 200-byte padding 的合法目录名，估算 cache 2,214,126 → 907,264 → 236 bytes，结构正确性通过。系统 physical footprint 27,640,408 → 27,673,176 bytes，**未实测下降**；此前短路径 22,037,056 → 22,151,744 bytes 也未下降。allocator best-effort relief 不等于释放所有 runtime 保留页；不能用 cache 估算替代实际 footprint。CLI warm 提示按状态区分 ready/replaying/live，不在 baseReady 时错误宣称 replay complete。CLI 报告的 `passed` 是结构/功能结果，`physical_footprint_decreased=false` 单独明确指出未过资源 gate。[最终压力报告](benchmarks/v0.6.0/lightweight.json)、[短路径前次报告](benchmarks/v0.6.0/lightweight-short-path-pressure.json)。恢复并行重负载时 CPU 120 秒恢复 deadline 曾失败，另存 [失败报告](benchmarks/v0.6.0/lightweight-under-recovery-load.json)。

真正的原生 APFSFindResourceSmoke 使用独立 bundle/cache，与日用应用隔离，系统 `/` 和 `/Volumes/Data 1` 皆启用。前几次完整实盘尝试因旧 base 重复核对、宽目录 frontier 和旧 buffer 回放进入恢复循环；失败聚合数据保留在 benchmarks/v0.6.0/native-*.json。此前 peak physical 达约 4.16 GiB，不能用只读 7–18 MiB 的结果掩盖恢复峰值。

最终原生实例完成两卷 live + metadata available 的 **600 秒隐藏测量**：系统 3,142,816 → 3,147,934，Data 1 1,562,473 → 1,562,489，共 4,710,423 entries。此独立 app 没有日用应用的 FDA 授权，读不到的系统目录照常计入 unreadable；不把来源范围差异当作内存优化。

开始 physical **83.22 MiB** / RSS **268.94 MiB**；末端 physical **138.06 MiB** / RSS **265.88 MiB**。两份全量 Map=0，warm materialized FileEntry=0，开始和末端两卷均 live、metadata available。开始 `quiet_start_condition=false`，期间实际增加 5134 entries、后台维护仍排队/运行，CPU 累计 **787.80 秒**、disk writes **0**、logical writes **28,672 bytes**。这不是 no-work idle，不能套用安静 root 的 CPU/timer 零唤醒验收。

模拟 warning 后 physical **121.30 MiB** / RSS **249.27 MiB**，四份 cache 收缩到最多 2048；此下降伴随后台维护 yield，不能证明单独缓存回收的效果。源数据保留 [native-live-600.json](benchmarks/v0.6.0/native-live-600.json)。该次 binary 早于最终旧宽目录 child-count 预检与严格 diff 上限，因此不算最终 binary 的完整原生重新验收。最终保护分支另有 100,001-child 回归测试和完整 sanitizer 验证；真实卷 CLI 重启测量使用最终实现。

最终 UI 搜索、菜单暂停/恢复和正常按钮 fast quit/restart 因 Mac 锁屏而无法操作，已向用户请求解锁；不冒充已完成。小根目录 CLI 的暂停/恢复、create/rename/delete、fast-exit/replay 已验证，原生多卷的上述 UI 操作仍是 release 限制。最终 CLI 从该 owned cache 重启真实 Data 1 卷：进入 live、namespace full scans=0，12 个 owned fixture 结果完全匹配（含 rename、delete 和 hidden create）；`:quit` 正常结束、exit=0，但用了 **9.94 秒**，不宣称瞬时退出。[真实卷重启报告](benchmarks/v0.6.0/real-volume-restart.json)。真实 macOS memory pressure、热状态/低电量切换和物理 sleep/wake 未操作；这些行为采用 injectable tests 验证。此前用户人工确认 Option+Space、菜单全局/单卷暂停恢复、登录项恢复原设置；不重复声称本轮做了新的物理键盘／睡眠验收。

## 测试、提交与复现

开始 CI：[37558381259](https://github.com/SWHsz/apfs-everything/actions/runs/37558381259)，四项 required jobs 成功。最终本机普通、ASan、TSan 各 **220 项**（Core 200 + Desktop 20），0 failures，1 项可选真实挂载 skip；无 sanitizer 诊断。Core 耗时约 82.83 / 194.54 / 268.84 秒。[完整检查摘要](benchmarks/v0.6.0/checks.json)。最后恢复/live 状态修复另有 43 项针对性测试通过。Release CLI/desktop、app 构建、0.6.0/600 Info.plist 与 ad-hoc 签名验证通过；代码提交 `ad04d6b6d4321680314ca4bf83ecc1c674cc5927` 的 [CI run 37606991928](https://github.com/SWHsz/apfs-everything/actions/runs/37606991928) 四项 required jobs（deterministic、integration、address-sanitizer、desktop-build）全部成功；文档补记提交推送后仍需核对其最终 HEAD 的 [main CI](https://github.com/SWHsz/apfs-everything/actions/workflows/ci.yml?query=branch%3Amain)，最终 SHA/run 记录在 Issue #1/#3 的本轮结束评论。

分阶段提交：`3470e6b` baseline、`f952640` bounded resolver、`c94a5c0` resource scheduler，`ad04d6b` hardening/实测（完整 SHA `ad04d6b6d4321680314ca4bf83ecc1c674cc5927`）。

```bash
swift build -c release
swift test -j 4
swift test -j 4 --sanitize=address
swift test -j 4 --sanitize=thread
bash scripts/build_app.sh
codesign --verify --deep --strict dist/APFSFind.app
.build/release/apfsfind residency-bench --root / --second-root "/Volumes/Data 1" --idle-seconds 600
.build/release/apfsfind residency-bench --root / --second-root "/Volumes/Data 1" --cache-dir OWNED_MATCHED_CACHE --idle-seconds 0
.build/release/apfsfind metadata-bench --entries 1000000
.build/release/apfsfind lightweight-bench --entries 1000000
.build/release/apfsfind background-bench --idle-seconds 60
.build/release/apfsfind bench --files 1000 --latency-ms 20
```

第二卷不存在会明确报错，不选其他盘。真实 native smoke 是独立测试 bundle 的 `APFSFindResourceSmoke` 受控入口（bundle ID 必须以 `local.apfsfind.desktop.smoke.` 开头），等两卷 live、metadata available 后隐藏 600 秒；`quiet_start_condition` 单独记录是否无 queued/running maintenance，繁忙 live 系统不会被冒充 no-work idle；只输出聚合 stdout，不写运行日志，不读文件内容。benchmark 文件均 owned/受限权限，日用 cache 保持不变。测量结束后核对进程、打开文件、inode/device 与 bundle 身份，只移除了本轮独立 smoke bundle、scratch 索引及 fixture；保留聚合报告与 dist/APFSFind.app。

Issue #1/#3 的关闭按任务书 release gates 决定；有未通过 gate 时保持 open、发布真实指标。Issue #2 保持 open，scope 不变。未创建 v0.6.0 发布 tag。
