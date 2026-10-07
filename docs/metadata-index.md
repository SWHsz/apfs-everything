# Metadata sidecar v1（v0.5.0）

Namespace snapshot v2 的 record layout 完全保留。每个 namespace base 旁新增可独立失效、重建的 `.apfsmeta` 和 `.apfsmeta.state`。文件只保存列值及身份，不保存路径、String 或预排序 ordinal 数组。运行时使用只读 mmap，加 RAM overrides/delta/deleted overlay；查询捕获强引用及 COW 状态后在锁外扫描。

## 二进制格式

所有整数为固定宽度 little-endian。总长度 `256 + 8*N + 8*N + ceil(N/4) + 16`，即约 16.25 bytes/entry + 272 bytes。未知值由 validity bitmap 表示，列字节为零；UInt64.max size 和 Int64.min mtime 均可表示有效值。

| Header offset | 字段 |
|---:|---|
| 0 / 8 / 12 | APFSMETA / version 1 / header length 256 |
| 16 / 24 | UInt64 count / namespace snapshot UUID |
| 40 / 48 / 56 | base generation / file length / payload CRC32 |
| 64 / 80 / 96 | metadata UUID / volume UUID / FSEvents history UUID |
| 112 | metadata durable cursor |
| 120 / 128 | size column offset / length |
| 136 / 144 | mtime column offset / length |
| 152 / 160 | validity offset / length |
| 168 / 176 | created Unix seconds / exact file length |
| 184 / 188 | payload CRC32 / header CRC32（计算时本字段为零） |
| 60–63 / 192–255 | reserved zero |

SizeColumn 为 N×UInt64，MTimeColumn 为 N×Int64 Unix epoch nanoseconds。每项占 bitmap 两位：bit 0=size valid，bit 1=mtime valid，末字节未使用的位必须为零。Footer 为 `APFMTEND` + UInt64 exact length。

Reader 校验文件上限、record count、列边界、CRC、所有 reserved bytes、owner、普通文件类型、0600、O_NOFOLLOW，以及 base UUID/generation/length/CRC/volume/history 完整绑定。缓存目录为 0700、逐段安全打开。mmap 只读；持有旧映射的查询在文件原子替换后仍安全。

Writer 使用同目录独占 tmp、0600、fsync、重新映射验证、atomic rename 和 directory fsync。异常会清理自己创建的临时文件。发布失败不破坏合法 namespace；旧或不匹配的 metadata 被忽略，单独重新构建。

## 独立 cursor

`.apfsmeta.state` 固定 160 bytes：APFMSTAT、version/length、metadata/base UUID、base generation/length/CRC、metadata length/CRC、volume/history UUID、cursor、CRC、reserved zero。只绑定当前两份 base；损坏或旧 state 回退 metadata header cursor。Namespace 继续使用原 128-byte state。

同一 per-device FSEvents stream 从 `min(namespaceEffectiveCursor, metadataEffectiveCursor)` 开始。两条 pipeline 各自过滤 replay overlap；特殊事件不按普通 floor 跳过。HistoryDone 后不将 live 中重复或较小 event ID 当作历史 overlap 丢弃。暂停/恢复重置各自 replay floor；用户暂停和系统睡眠原因叠加。

只有 overlay 完全干净才允许 metadata state-only 前进；dirty fast exit 不重写 sidecar，也不越过未持久化值。尚在 debounce/限速队列的 lookup 在 fast exit 中取消，保持此前 processed fence，重启 replay 恢复；不会为了退出遍历大型 pending 子树。重启从保守 cursor replay。Metadata 损坏、缺失或单独重建不要求 namespace rebuild；整个 stream 的 journal gap 同时影响 namespace 时仍走 namespace recovery。

## 扫描与 bootstrap

C shim 在现有 getattrlistbulk 请求中加入 ATTR_CMN_MODTIME 和 ATTR_FILE_DATALENGTH，按 returned attributes 解析 packed record，并 memcpy 读取未对齐字段。Regular file 记录 logical size；directory/symlink/other size 为 unknown。mtime checked 转换为 Unix 纳秒，overflow 为 unknown。不打开普通文件读取内容，不跟随 symlink，不跨设备，保留 dataless materialization 的线程级 best-effort 防护。

冷扫描同一 ScannedEntry 批次生成 namespace 与 metadata，不复制两份完整路径。Namespace 发布前按输出 ordinal 构建并验证对应 metadata tmp；namespace 发布成功后再发布匹配 metadata。两文件不能共同原子 rename，因此读者必须完整验证 UUID 绑定；中途 metadata 发布失败仍保留新 namespace，并排队独立 bootstrap。

已有 v2 cache 没有 metadata 时立即开放 relevance/name 搜索，MaintenanceScheduler 串行排队 metadataBootstrap。捕获设备 fence E0，bulk 扫描与当前 base ordinal 的 kind/fileID 对齐；消失或替换项保持 invalid。扫描时 metadata events 继续更新 RAM overlay，安装后保留并 drain。

当 namespace 没有未持久化变化时 header cursor=E0；有未持久化 namespace delta 时使用 `min(E0, namespace durable cursor)`，因为 sidecar 的 base ordinals 无法表示尚未持久化的新路径。此保守处理避免重启后漏回放 delta。Base 替换则中止、为新 base 重排。进入任务和发布前均检查 root/device/volume/history 与当前namespace完整匹配；卷身份变化时等待namespace恢复，不能把新卷的列值标记成旧base。

## 在线事件与维护

Metadata 接收 namespace 已处理后的原始事件，并独立过滤自己的 replay floor。Content/inode/create/delete/rename 更新 metadata；typed xattr/Finder/owner-only 事件跳过 lookup。无法可靠分类的事件保守刷新或 bootstrap。父目录 mtime 随 namespace 变化刷新。

默认 200 ms trailing debounce，以 device+fileID 优先、否则 canonical path 合并；小批量至多 64 项。每秒最多 20,000 个 metadata lookups，超出留待一次性延迟任务，不推进 cursor 越过 pending。Inbox/buffer 有界（100,000），溢出触发恢复。

大批次按父目录 bulk 枚举；超过 512 项可 collapse 整个父目录。稀疏更新少于该目录条目数的 1/8 时，使用每次至多 64 个 basename 的 C microbatch：安全打开一个父目录，fstatat AT_SYMLINK_NOFOLLOW，避免为了 100 个变化重复枚举 10,000 个兄弟项。此方案不读内容，也不引入排序数组。Rename 使用 file ID 和 frozen metadata capture 复用；目录 rename 的后代通过 prefix alias 捕获旧值，不逐文件 stat。从范围外移入的已填充目录可能只有一个事件；未知目录/替换目录使用同设备、可取消的 bulk 子树枚举补齐后代，未跟随 symlink。

Metadata checkpoint 独立阈值：100,000 项、32 MiB、quiet 30 s、最小间隔 600 s、safety 256 MiB。全局 MaintenanceScheduler 与 cold scan/rebuild/namespace compaction 串行。无变化不启动周期 timer。Metadata-only checkpoint 不改写 namespace；没有 ordinal 的 delta 保持 dirty 和保守 fence。大量保留 rename/delta 达 safety 时进行 namespace compaction。

Namespace compaction 先捕获旧 metadata，按新 ordinal 生成、验证匹配 tmp，再发布 namespace 和 metadata，之后恢复 buffered events。异常、身份变化、取消或 metadata 发布失败均不会安装错误 ordinal 的 sidecar；metadata 独立重建。

## 查询与桌面

Relevance 维持 exact → prefix → substring。Name、mtime、size 支持升降序；unknown 两个方向都排末尾。Name 的同主键使用原 basename、path、volume name/UUID；mtime/size 的同主键使用 matchRank、folded basename、path、volume name/UUID。

每卷扫描全部 filename 候选并维护有界 top-K+1，不收集全部匹配项；metadata 排序在候选阶段读取列值，不对前 50 条局部重排。多卷并行、同一 comparator 合并 global top-K，UUID+path 去重。分页扩大 limit，保留选中项与 sort，无 offset cursor。

任一在线 searchable 卷没有 metadata，UI 禁用 size/mtime，保留该卷的 relevance/name 结果。Catch-up 时允许排序并显示暂时更新提示。保存 lastSortKey/Direction；构建期间临时 fallback 不覆盖偏好，metadata 可用后恢复。隐藏窗口取消查询、继续维护索引；重显刷新当前词，避免后台每次 metadata 状态变化触发全盘查询。

## 可复现测量

`metadata-bench --entries 100000|1000000` 创建 owned 临时文件和独立 cache，报告 build/resources、四种 query 分类及七种 sort 的 20 次分位数、10k 同文件写入、10k 文件更新、fast exit/restart 与 fresh metadata scan 对照。

`metadata-bench --root / --second-root '/Volumes/Data 1'` 只读打开已有日用 namespace，metadata 只写 owned scratch cache。该测量不回放或改写日用 namespace，旧路径可能无 metadata；它衡量当前 cached ordinals 上的全量扫描/top-K，而不是日用索引 freshness 验收。JSON 不包含实际查询文件名或路径，只有聚合指标和指定的卷根。

实测结果及失败后优化见 STATUS.md 与 docs/benchmarks/v0.5.0/。CPU 为进程 user/system，disk 和 logical writes 分开，peak RSS 为该 benchmark 进程高水位；不能将逻辑写入等同于物理写入。
