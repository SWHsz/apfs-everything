# apfsfind v0.3.1

macOS 本地文件名搜索 CLI，Swift 6 / macOS 14+，无第三方 package。
首次用 `getattrlistbulk()` 扫描；后续从只读 mmap 基础索引恢复，通过 FSEvents 维护内存变化层。
按大小写不敏感文件名子串搜索，exact、prefix、substring 依次排序，同级按路径排序。
默认最多显示 50 条结果。实测、格式布局和已知限制见 [STATUS.md](STATUS.md)。

2026-10-05 本机实盘测量：`/` 的系统/用户目录视图与 `Data 1` 工作盘共 **4,398,407 个索引条目**，
两份 v2 基础索引合计 **394.28 MB**（约 0.4 GB），平均 **89.64 bytes/entry**。
条目包括文件、目录和符号链接；权限不可读目录及辅助卷未包含。
本机 `/` 已涵盖用户目录，`/System/Volumes/Data` 的重叠测量未重复相加。
合并需要临时写入新 base，按这批数据建议预留约 0.8 GB；完整范围与磁盘采样见
[实盘记录](STATUS.md#本机全盘范围索引体积实测2026-10-05)。

## 使用

~~~bash
swift build -c release
swift test
.build/release/apfsfind serve --root "$HOME"
~~~

输入文字搜索；输入 `:quit` 或 Ctrl+C 退出。默认命令 `serve`，默认 root 为 `$HOME`。
大目录扫描和 replay 没有固定 10 秒期限；启动进度、错误输出 stderr，搜索、stats 输出 stdout。

| 参数 | 用途 |
| --- | --- |
| `--root PATH` | 本地扫描目录 |
| `--workers N` | 初始扫描 1–16 workers，默认 4 |
| `--latency-ms N` | FSEvents latency 1–1000 ms，默认 20 |
| `--ephemeral` | 使用原 RAM FileIndex，不读写缓存 |
| `--rebuild-index` | 忽略旧基础索引，全量重建 |
| `--cache-dir PATH` | **精确缓存目录**，默认 `~/Library/Application Support/apfsfind/indexes` |

已有缓存目录必须归当前用户所有、权限已经为 0700，且路径没有任意 symlink。
不满足时拒绝，程序不修改已有目录权限。程序新建的缓存目录为 0700。
缓存不能等于扫描 root 或成为其上级目录；缓存子树从扫描、事件更新和 verify 中排除。
macOS 自带的 `/tmp`、`/var` 别名经过验证后支持，网络卷和 autofs 拒绝。

~~~bash
.build/release/apfsfind serve --root /Users/yourname/projects --cache-dir /tmp/apfsfind-private-cache
.build/release/apfsfind serve --root "$HOME" --ephemeral
.build/release/apfsfind serve --root "$HOME" --rebuild-index
~~~

| 命令 | 行为 |
| --- | --- |
| `:stats` | base/overlay、generation/cursor、恢复、合并、查询分阶段、CPU/RSS |
| `:verify` | fresh scan 比较 path set，报告 missing/extra；需要目录暂时静止 |
| `:checkpoint` | namespace 变化则合并；只有 cursor 变化则写 state；均未变化则无 I/O |
| `:compact` | 强制请求后台合并，重复请求不会重复启动 |
| `:rebuild` | 后台全量扫描，重新捕获设备 fence、replay、映射新基础索引 |
| `:quit` / EOF | 停止事件交付，完成收到的更新，保存尚未持久化的变化 |

启动时 Ctrl+C 取消扫描；live 后第一次 Ctrl+C 正常保存退出，第二次取消尚未发布的写入。
已提交的原子发布不能被事后撤回；被取消的临时文件不会替换原基础索引。

## 运行结构

~~~text
readonly mmap v2 base
  + base tombstone bitmap
  + directory-only path -> base/delta ref
  + RAM delta paths / children
  -> HybridIndex
~~~

默认 warm 启动不调用 `FileIndex.restore()`，不为全部文件保存完整 path、foldedName 或 FileEntry。
内存中的目录路径用于父目录定位；文件通过目录引用和 child table 二分定位。
原 `FileIndex` 保留给 ephemeral、冷扫描/失效恢复的临时构建、旧格式测试和对照基准。

查询短锁捕获强引用 base、COW 位图、当前 live delta 和 generation 后释放锁。
base 扫描、排序和结果路径生成均在锁外；只为选出的候选生成完整 base 路径。
查询保持捕获时的一致状态，合并切换后旧查询仍可安全完成；返回的 generation 表明对应状态。
当前仍是线性子串搜索，没有 trigram、SIMD 或复杂倒排索引。

普通 create/remove 提示先以安全的 metadata lookup 核对实际类型/inode，不制造 ghost。
rename、复合事件、风暴走实际目录 diff；纯文件内容事件不执行 metadata lookup 或目录枚举。
重复历史 create 经过元数据确认后从风暴计数排除；不会仅凭旧 event ID 丢弃事件。
所有 cursor 在 batch 更新完成后推进，更新尽量幂等。

## 缓存与恢复

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

## 测试与测量

~~~bash
swift build -c release
swift test
swift run -c release apfsfind bench --files 1000 --latency-ms 20
swift run -c release apfsfind persistence-bench --entries 100000 --cache-dir "$(mktemp -d)"
swift run -c release apfsfind hybrid-bench --entries 100000 --delta 10000 --cache-dir "$(mktemp -d)"
swift run -c release apfsfind hybrid-bench --entries 1000000 --delta 50000 --cache-dir "$(mktemp -d)"
~~~

所有 benchmark 创建并清理自己的 UUID 临时子目录；`--cache-dir` 在 benchmark 中是这些子目录的父目录，
不会覆盖用户正常缓存。shell 的 `mktemp` 父目录可以测量后自行删除。benchmark 只把结果输出 stdout。
`bench` 是旧 RAM 后端对照；`persistence-bench` 走真实文件/default hybrid 冷/warm/退出恢复。
`hybrid-bench` 用合成 base 测 mmap、查询、并发 namespace patch、合并与二十轮每轮 10,000 次创建/删除，
另用真实小目录测 FSEvents 搜索可见性。合成百万条目的 patch 延迟不冒充百万真实文件的 FSEvents 延迟。
独立只读子进程报告 mmap RSS，避免同进程冷构建分配器保留内存影响判断。

真实 FSEvents 测试默认运行。受限 runner 可显式设置 `APFSFIND_SKIP_FSEVENTS_TESTS=1`；
CI 默认完整 `swift build -c release` 与 `swift test`，不默认跳过。

## 边界

扫描只读取目录项和元数据，不读文件内容；不跟随子目录 symlink，默认不跨设备，
best-effort 关闭线程级 dataless materialization，检查本地卷/autofs 和不可遍历 dataless 目录。
无需 root，不访问 raw disk，不关闭 SIP，不建立网络连接，不写运行日志或 telemetry。
本版单 root/单卷；TCC/权限排除继续计数，不绕过权限。macOS 14、Intel、真实 iCloud dataless、
掉电耐久和真实 journal purge 未专项实机验证。不是 Everything 的完整克隆。

## 真实磁盘验证

```bash
.build/release/apfsfind real-disk-bench --root / --idle-seconds 60
.build/release/apfsfind real-disk-bench --root "/Volumes/Data 1" --idle-seconds 60
```

每次先退出冷启动进程，再启动新的暖启动进程。测量 60 秒空闲、六类查询的首查询与
30 次分位数、实际进程 I/O、10k/2k/5k namespace workload 和大索引 compaction。
stdout 最后一行为 JSON；进度输出 stderr。查询结果数量为最多 50 条的实际返回数量，并注明是否被上限截断。

默认新建 `/private/tmp/apfsfind-real-cache-UUID`。可用 `--cache-dir` 指定符合该形式的**新路径**；
现有目录会被拒绝，默认持久缓存不参与。测试变更仅在单独的 UUID 目录中，结束后清理两者。
错误、清理失败或最终 verify 差异会返回非零。活动系统目录在 fresh scan 期间仍可能变化，原始差异会保留。
I/O 使用 `proc_pid_rusage` 实际计数，压缩内存使用 `TASK_VM_INFO`；SDK 未提供的 logical reads 不会估算。
v2 的 folded-name 去重只统计潜在收益，不修改格式。卷根的系统 `.fseventsd` 事件日志排除在扫描和维护范围之外；
用户普通目录下同名文件夹仍会索引。详细结果见 [STATUS.md](STATUS.md)。
特殊节点（如 Unix socket）的通知随系统版本不同；macOS 15 CI 在观测窗口内没有交付其创建事件，
不保证这类节点的自动实时维护，可用 `:rebuild` 重新扫描。

可选挂载烟测（默认跳过，不需要 root）：
```bash
APFSFIND_RUN_MOUNT_TESTS=1 swift test --filter NativeMountSmokeTests
```
