# Sprint 1 / v0.1.0

状态：可运行的纵向切片已完成，provisional acceptance **PASS**。

验证日期：2026-10-05（Asia/Tokyo）。本机为 arm64 macOS 27.0.1，Swift 6.4，macOS SDK 27.0；package deployment target 为 macOS 14，Swift language mode 为 6。未使用 HPC。

## 已完成

- Swift Package：Core Library、C shim、CLI executable、测试 target；无第三方依赖。
- `getattrlistbulk()` 全量扫描，安全 packed buffer 解析、基础类型/device/file ID、4 worker 默认配置、取消、权限和 race 计数。
- 本地 root metadata-only 解析；同设备、mount/autofs、symlink 和 dataless 目录边界；不打开文件内容或 raw disk。
- 内存文件名和完整路径索引、parent/children、tombstone、generation、Unicode 大小写折叠及 exact/prefix/substring 排序。
- 扫描前捕获 E0，扫描后 FSEvents replay，收到并处理 HistoryDone 后进入 live。
- callback 仅复制信息入队；串行 writer + 5 ms microbatch；查询用 pthread rwlock 并发读。
- create/remove 快速 patch；rename/compound 目录 diff；新目录子树扫描、删除目录子树 tombstone、类型和 inode 替换处理。
- content-only 无索引修改、stat 或 enumerate；兼容系统把旧 Created 标志合并到后续 Modified 的行为。
- 目录纳秒 mtime gate；显式 namespace 变化绕过 gate，gate skip 后安排一次强制复查。
- 风暴按 parent 聚合、去重、祖先合并；平面风暴只读取直接 children。过多 dirty roots/掉事件触发后台独立索引 rebuild 和短锁交换。
- rebuild 期间缓存事件并在交换前应用，失效时从 rebuild E0 重开 stream；30 s 最短间隔、指数退避、默认 8 次失败暂停自动重试，`:rebuild` 可解除暂停。
- `serve`、交互搜索、`:stats`、`:verify`、`:rebuild`、`:quit` 和 Ctrl+C 停止。
- 临时目录 benchmark、真实可见延迟分布、CPU/RSS、namespace 工作量、fresh scan verify、最后一行 JSON 和退出码。
- 运行期不保存 index、snapshot、WAL 或日志；只输出 stdout/stderr。SPM 的 `.build` 是编译产物。

## 实际结构

```text
Package.swift
.gitignore
README.md
STATUS.md
Sources/
  CAPFSShim/
    include/CAPFSShim.h
    BulkDirectoryReader.c
    IOPolicy.c
  APFSFindCore/
    FileEntry.swift
    FileIndex.swift
    BulkScanner.swift
    FSEventsWatcher.swift
    EventClassifier.swift
    DirectoryReconciler.swift
    UpdateCoordinator.swift
    PathCanonicalizer.swift
    Metrics.swift
    RWLock.swift
  apfsfind/
    main.swift
    CLI.swift
    BenchmarkRunner.swift
Tests/APFSFindCoreTests/
  FileIndexTests.swift
  PathCanonicalizerTests.swift
  BulkScannerTests.swift
  CShimSafetyTests.swift
  EventClassifierTests.swift
  ReconcilerTests.swift
  CoordinatorBatchTests.swift
  LiveUpdateIntegrationTests.swift
  BurstIntegrationTests.swift
  TestSupport.swift
```

## 关键决策

1. 保存完整 path 和简单映射，搜索线性扫描；优先保证维护行为可验证。重复 subtree remove 可立即返回，重建负责回收 tombstone。
2. 一次事件 microbatch 的主 diff 用一次 mutation write lock；目录 I/O 在锁外，消失目录的父级修复另用短锁。后台扫描及独立索引构建都在 builder 上完成，writer 继续接收事件，读取仍访问旧索引。初始及替代索引按 4096 条目分块构建，以响应取消。
3. dirty scope 的 diff 优先于该 scope 内的 direct patch。避免 stale create/remove、父目录删除与子项创建在同一 batch 中留下 ghost。
4. 目录 file ID 改变会重置旧子树；重读时重新插入该 scope 全部实际 descendants，包括 inode 幸存的子项。
5. 不配对 rename。由实际目录状态解决事件顺序、重复和 compound flags。
6. FSEvents 使用 FileEvents、NoDefer、UseCFTypes、WatchRoot，并加 FullHistory 覆盖首个历史 chunk 边界；允许重叠事件，不使用 IgnoreSelf。
7. **目前只有进程内 host-level event ID**。per-device stream、FSEvents UUID、持久 cursor 都留到下一 sprint，不支持跨重启恢复。
8. dataless I/O policy 采用编译期 best-effort；目录元数据的 dataless 标志提供额外跳过保护。本机 dataless thread policy 设置成功；可选 automount I/O policy 在当前 kernel 返回 EINVAL，安全退回缓存 mount/trigger 检查，不把它误计为 dataless 失败。
9. benchmark 仅使用独占 system temporary 子目录；删除前检查 canonical parent、精确 UUID 名称和目录类型。成功清理纳入 acceptance，stdout JSON 不写结果文件。

## 构建和测试结果

实际执行，退出码均为 0：

```bash
swift build -c release
swift test
swift run -c release apfsfind bench --files 1000 --latency-ms 20
```

最终 release 构建无编译警告。启动修复后 `swift test`：**60 tests，0 failures，0 skipped**，测试执行约 3.2 s；FSEvents 本机默认运行。

覆盖 initial seed、create/delete、两种 rename、移入非空目录、删除目录 ghost、1000 文件 burst、symlink 不递归、扫描到 watcher 启动 gap replay、content write 不修改索引、掉事件恢复、失败重建暂停和手动恢复。另有批次冲突、目录 inode 更换、并发读写、路径边界、packed 多页读取、root symlink loop/`..` 和输出 buffer 边界测试。新增 HistoryDone 已到而恢复仍在排队、消失目录逐级父级修复、实际权限拒绝和恢复、errno 分类，以及 10k 分散 dirty paths 祖先合并回归。

短 CLI smoke：query、`:stats`、`:verify`、`:rebuild` request、`:quit` 均通过；独立 Ctrl+C smoke 在 5 s 内退出，exit code 130。临时 smoke root 除 seed 外未产生任何运行文件。

早期测试曾暴露根目录 parent walk 越界循环、旧 Created 标志保留及临时路径 `/var`/`/private/var` 差异；已修复并加入回归验证。

## 大 HOME 启动修复实测

用户在终端扫描 1157675 files / 158327 directories 后遇到固定 10 s replay 失败。本机也复现旧版退出：历史结束标记已收到，但事件处理或恢复仍未完成。已去掉 `serve` 的固定启动超时，显示实际状态和事件进度；子目录权限/dataless 排除不再误触发全量重建，消失或替换目录由父目录修复。真实根目录失败和意外 I/O 仍进入有退避的恢复。

修复后用 release executable 对真实 `/Users/huangsizhe` 做 metadata-only 启动、`Package.swift` 查询、`:stats` 和 `:quit`，退出码 **0**：

- 初始枚举 22.68 s，内存索引构建 35.50 s，replay 约 10.6 s，总启动至退出约 69.95 s；并行进行过 Swift 测试编译，故不作为隔离性能 benchmark。
- live entries **1079445**，FSEvents received/processed **2468/2468**，directory reconciles **15260**，full rebuilds **0**。
- 本宿主初始扫描有 **596** 个权限拒绝，replay 有 **38** 个 EPERM，均按不可读目录排除；终端与 Codex 的隐私授权不同，数量不能与用户终端直接比较。
- 一次 `Package.swift` 查询返回 10 条，耗时 **802.5 ms**；RSS 170967040 bytes（约 163 MiB）。本版百万条目搜索仍是线性扫描，该值不承诺所有查询延迟。

没有改动 HOME 的文件；搜索工具没有保存索引或日志。`minimalRoots` 现用集合查询真实祖先，避免原先先做 O(N²) 合并再检查 dirty limit 的 CPU 放大点。

另一次只读 HOME 运行在内存索引构建阶段发送 Ctrl+C，约 **0.17 s** 后以 **130** 退出，验证大树启动的取消路径。

## Benchmark 实测

下面是启动修复后 `--files 1000 --latency-ms 20` 的一次终端输出记录。每个 latency workload 100 个样本、2 s 硬超时，全部 **0 timeout**，所有 p95 < 500 ms。分位数采用 nearest-rank；统计真实查询可见时间，不在 latency 测量中调用 flush。

| workload | min ms | median ms | p90 ms | p95 ms | p99 ms | max ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| create | 16.81 | 20.14 | 21.40 | 21.76 | 31.53 | 221.55 |
| delete | 17.41 | 20.12 | 21.30 | 21.71 | 25.15 | 37.05 |
| 同目录 rename | 17.77 | 20.24 | 20.82 | 21.59 | 21.97 | 22.30 |
| 跨目录 rename | 15.35 | 20.39 | 22.04 | 22.16 | 41.94 | 142.83 |

初始扫描约 0.7 ms（7 个 live entries），内存索引构建约 0.5 ms，scan + replay 35.61 ms。

content-write：10000 次 pwrite，write loop 14.62 ms，含事件观察/排空共 32.26 ms；收到 1 个合并事件并忽略 1 个，direct patches / directory reconciles / subtree reconciles / full rebuilds 均为 0。entries 109 → 109，live entries 7 → 7，generation 402 → 402。user CPU 0.000684 s，system CPU 0.012324 s。

| storm | wall ms | user CPU s | system CPU s | direct patches | dirty dirs | directory reconciles | subtree reconciles | verify missing/extra |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| create 1000 files | 130.92 | 0.094803 | 0.053951 | 135 | 2 | 2 | 0 | 0 / 0 |
| delete 1000 files | 139.77 | 0.105057 | 0.049919 | 0 | 3 | 3 | 0 | 0 / 0 |

两种 storm 均完成 convergence。最终 RSS 11304960 bytes（约 10.78 MiB），queue high watermark 580；entries 1109 / live 7 / tombstones 1102；generation 406，state live，full rebuilds 0，掉事件 0。临时目录清理成功，JSON `cleanup_completed=true`、`provisional_acceptance=true`，退出码 0。

CPU 是同进程的 workload generator、轮询查询和 index maintenance 的合计，不是单独的 maintenance CPU。以上是本机一次小规模测量，不推断大 `$HOME` 或其他机器的性能。

## 未完成和已知限制

- Sprint 1 required path 无 TODO stub；当前受测路径无未解决的已确认 correctness bug。
- 未在真实 iCloud dataless 目录做专项测试，也未在真实 network/DMG/autofs 挂载上主动创建测试环境；扫描边界有 metadata checks 和单元测试，未声称这些环境已实机验证。
- macOS 14 和 Intel Mac 的实际运行未验证；当前已验证 arm64 macOS 27，deployment target 保持 14。
- `:verify` 是 fresh scan，不是原子 snapshot；变化中的树可能产生暂时差异，应先等待静止和事件收敛。
- Full Disk Access/TCC 和 POSIX 权限会造成不可读目录；不会绕过权限。真实大 `$HOME` 已做上述启动 smoke，完整权限覆盖和静止目录的隔离性能尚未测量。
- tombstone 及完整 path 占用会累积，查询 O(entries)，重建需要额外索引内存。
- `serve` 等待 replay 和恢复完成，没有固定启动期限，可 Ctrl+C 取消；benchmark 仍有 10 s 启动期限。持续掉事件时索引可能保持 dirty；自动失败重试有熔断，手动恢复仍遵守 rebuild 最短间隔。
- 后台扫描在目录 bulk pages 之间响应取消；局部 filesystem race 依赖后续事件/reconciliation 收敛。
- 系统级 `/` 特殊情况、多卷索引、重启持久恢复均不属于本版支持承诺。

## 下一 sprint 候选（本轮不实现）

先在真实较大本地目录继续测量维护成本，再考虑 per-device FSEvents stream、UUID 和 persistent cursor/snapshot；评估 Extended File ID rename pairing、packed string arena、mmap index。GUI、global hotkey、system-wide multi-volume indexing 保持独立候选。

运行入口：

```bash
swift run -c release apfsfind serve --root "$HOME" --latency-ms 20
```
