# v0.6.2 — Reconciliation Convergence

开始 HEAD：`5588ec7e1305839a81473a535aaadb121d1da0ff`。本轮仅处理 Issue #3；Issue #1 根据 v0.6.1 resolver/memory 证据关闭，#12 勾选；Issue #2 未实现。

## 语义与边界

- `MaintenanceYield` 是局部未完成，不是 stream invalidation。已完成的原子目录 diff 可发布，未完成 frontier 有界保留；事件游标不越过队列。
- 默认 4096 work roots、100k frontier、32 MiB queue hard cap，canonical dedup、ancestor merge、FIFO continuation。新 ancestor input 不反复抢占旧 frontier。
- correctness slice 32 directories / 20 ms，active query 中至少推进一个父目录。每个父目录原子 bulk listing 有 100k entry safety bound；真正 hard overflow 可以恢复。
- EACCES/EPERM/ENODATA 局部保留；消失 race 修复父目录；权威 I/O 连续 3 次失败才升级。Dropped/Wrapped/RootChanged/identity/corruption/overflow 仍恢复，多个请求合并。
- full recovery yield 保留同一 epoch，指数 backoff，旧 base 可搜索，临时 graph 释放。没有 `requestRebuild(reason:resource_yield)`。
- metadata subtree continuation 每片 32 directories / 20 ms；连续 callback 不再无限推迟 debounce 截止时间。
- NSv2/metav1 disk layouts、FSEvents 时间基准、cold builder 未改。

## 验收设计

100k mapped namespace、1000 dirty parents、第100次读注入 yield，同时持续 broad query；cursor pin、所有 parents 收敛、零 full scan。真实 FSEvents owned root 10 轮 create/delete/rename/content，持续查询，每轮 namespace/size/mtime 在30秒内收敛。Fast exit/replay、full recovery same-epoch retry、重复权威 I/O 的单次恢复另测。

Controlled quiet 使用 `background-bench --idle-seconds 60`：无输入，CPU <=0.05s，disk/logical writes 0，sampler和scheduler wakeups 0，generation不变。

独立 owned native app 通过 `prepare_native_smoke.py --active-live` 与 `run_native_smoke.py MANIFEST --label first`，只读克隆日常 namespace snapshot，自己的 metadata/cache/fixture。父进程捕获 stdout/stderr 写在排除的 owned cache；不向日常索引写入。等待两卷 live+metadata available 后开始固定1200秒 active window，5秒采样、30秒摘要；允许真实 generation变化，检查 full scan/resource-yield recovery/backlog/physical，deadline 检查 maintenance 完成。然后真实卷 fixture 连续10轮增量收敛，每轮30秒上限、查询保持活跃，并验证全部owned文件size+mtime。最终实际菜单与正常quit/restart另验。

## 当前结果

验收进行中，Issue #3 OPEN，尚未创建 release tag。最终结果会补记，未通过的尝试保留，不用延长 timeout 或重启后的 full scan 替代增量通过。

### 保留的中间尝试

`c4f5bda` 的独立 release app 完成固定 1200 秒 active window（236 次采样，调度后结束于 1201.865 秒），gate 无 blocker。两卷 full scans 和 resource-yield rebuild 均为 0，active interval CPU 280.332315s，disk/logical writes 0；30 秒摘要及端点中的 physical 最大 145.94 MiB，5 秒 gate 没有超过 150 MiB。受监控根仍持续接收真实输入，不能把这段 CPU 当作 quiet idle。

随后 10 轮 pause/resume 保持 broad query，每轮 owned namespace 12/12、全部 size/精确 mtime 正确，最长 12.834498s，full scan/resource-yield rebuild delta 都为 0。实际 UI 正常退出的 multi-volume 阶段共 14.884333ms。active 摘要 deferred frontier 最大 12,676、queue bytes 最大 1,561,691、metadata pending 最大 444；末尾新 scoped subtree 从 12,676 降至 8,115，不能把根数 2 误报为只有两个待处理目录。

这份真实结果属于 `c4f5bda`，**不是最终 binary 验收**。`c4f5bda` 的 [CI 37728864446](https://github.com/SWHsz/apfs-everything/actions/runs/37728864446) 和路径校验优化 `0186466` 的 [CI 37730953087](https://github.com/SWHsz/apfs-everything/actions/runs/37730953087) 都在 ASan 的 1000-parent 30 秒门槛失败，其余三项成功；均保留失败，不打 tag。

定位到 `HybridIndex.children` 先按 folded name 排序、再按 canonical path 排序，前一次 Unicode folding/ranking 对 reconciliation 没有作用。`83adda1` 直接使用 resolver 的 sibling refs，保留最终 path 排序，未修改 snapshot 或测试时限。本机针对性 ASan 16 项通过，1000-parent 整项 16.871s；最终完整检查、CI、原生窗口和菜单验收仍在进行。

### 83adda1 的固定 binary（后续发现 metadata frontier 重复工作）

代码 HEAD：`83adda1e0e4860073feae37863ee55a57463bc03`。版本 0.6.2 / 602，macOS 27.0.1 (26A434)、Swift 6.4、arm64。本机普通、完整 ASan、完整 TSan 各 253 项（233 Core + 20 Desktop），0 failures，1 可选挂载 skip；release CLI/App 构建及签名验证通过。[代码 CI 37732319912](https://github.com/SWHsz/apfs-everything/actions/runs/37732319912) 四项 required jobs 全绿。CI ASan 的 1000-parent 整项 51.425s 包含 100k snapshot 创建；其中原有 30 秒收敛断言通过，未扩展 deadline。

受控 60 秒 quiet：CPU 0.000260s、disk/logical writes 0、CPU sampler wakeups 0、deferred timer 0，其他 maintenance scheduler wakeups 0。该 gate 未放宽。

最终桌面 executable SHA-256：`f57dd84ade744dcaf17e24c67bfcb57f8312848c4b37141b2ab34817a952bb2c`。owned fixture 和四份只读 base 使用同一独立 cache；准备数据来自 `8cbdc6c`，此前 runtime 为 `c4f5bda`，随后替换为上述最终 binary 并重置 fixture，身份/签名/四份 base 哈希均核对。没有重新生成或修改日常 namespace cache。

固定 1200 秒 active window（sleep/diagnostics 调度后结束于 1204.817s，238 次 5 秒采样）PASS，无 blocker：

| 指标 | 最终结果 |
|---|---:|
| 两卷 live namespace 条目 | 4,945,027 |
| full scans / resource-yield rebuild | 0 / 0 |
| maintenance restart loop / deadline tasks | 0 / 0 |
| physical：30 秒摘要最大 / 末端 | 120.50 / 97.56 MiB |
| 5 秒采样 physical gate | 全部 <=150 MiB |
| active CPU user + system | 780.404083s |
| active disk / logical writes | 0 / 0 |
| deferred roots / frontier 摘要最大 | 1 / 14,073 |
| deferred queue bytes 摘要最大 | 1,719,452 |
| metadata pending 摘要最大 | 2,790 |

启动 replay 的 lifetime physical peak 为 **170.03 MiB**，active start 前已达到，active end 的 lifetime peak 未再增加。150 MiB 是本次 active window 的采样门槛，不代表 cold/recovery build 或启动阶段的绝对内存上限。

按 volume UUID 对齐诊断：Root 收到 12,513、处理 12,516 个事件（消化了 baseline 的 5 项 backlog，末端 2 项瞬时 backlog），完成 108,932 次 namespace directory reconciliation、123,703 次 metadata subtree bulk；Data 1 收到/处理各 290 项。Root 在末段 scoped subtree frontier 达到 14,073，随后清空；metadata backlog 也反复消退，没有单调积累。这是有真实输入和大型 scoped repair 的 CPU 成本，不能当作 idle，也未以丢弃事件减少成本。两卷 namespace/metadata full maps、materialized mmap entries 仍为 0。

最终 native 10 轮保持 broad query，每轮 create/delete/rename/content 后全部 namespace 12/12、size/精确 mtime 正确，full scans delta 和 resource-yield rebuild delta 均为 0：

| 轮次 | 收敛秒数 |
|---|---:|
| 1 | 0.498623 |
| 2 | 1.993528 |
| 3 | 0.350039 |
| 4 | 0.346093 |
| 5 | 0.348761 |
| 6 | 0.488646 |
| 7 | 0.796005 |
| 8 | 0.342404 |
| 9 | 0.344825 |
| 10 | 0.340288 |

owned fixture 验证不等价于完整系统盘一致性认证；准备时 Root 956 个、Data 1 4 个不可读目录仍是本机覆盖边界。

实际最终搜索窗口已显示 12 条、47.7–61.6ms，并呈现 size/mtime。状态栏菜单未向当前自动化暴露，已请求在仍运行的独立实例上验证全局及 Test Volume 2 暂停/恢复；确认前保持 #3 OPEN、无 tag，正常 quit/restart 与四份 base hash 复核随后执行。

`83adda1` 随后经实际 UI Quit 正常退出，引擎 multi-volume 阶段 3.275917ms，四份 base 哈希不变。暖重启没有 full scan/resource-yield rebuild，owned fixture namespace/size/mtime 12/12 正确（只读验证 0.044889s）。UI 自动化调用本身有长时间排队，因此引擎 shutdown stage 不是端到端 UI 自动化时间。

暖重启 profile 发现 `MetadataUpdateCoordinator.drain` 的 subtree budget 分支只 `break` 内层 while，外层仍对每个余下 root 合并整个剩余 suffix，产生平方数量级的 `Set.formUnion`。此前 active gate 和正确性通过不消除这一 CPU 问题。`eeccc2e` 让整个 subtree slice 在一次 yield 后退出，注入 `MaintenanceYield` 也保留当前 DFS frontier 和全部未开始 siblings。

新增 1000-sibling metadata 回归用例：旧实现失败，yield count 1998 大于按已读目录与注入 yield 得出的预算 4；修复后 0.121s 通过，全部 size/mtime 正确、cursor pin 后推进、零 bootstrap。新增用例的 deadline 10 秒，不修改已有 30 秒/1200 秒验收时限。最终固定 binary 的完整测试、CI、真实窗口及 UI 正在重新验收；前述 `83adda1` 记录保留为中间结果。


## `eeccc2e` 固定 binary 的真实失败与后续修复

完整本机普通/ASan/TSan 各 254 项（234 Core +20 Desktop），0 failures，1 可选挂载 skip；四项 CI 全绿。受控 quiet 60 秒 CPU 0.000245s、disk/logical writes0、sampler/timer0。

真实双卷固定窗口 1204.852s /239 samples **FAIL**，唯一 blocker 为 physical footprint limit。30 秒摘要最大232.77MiB、末端177.36MiB；active CPU914.683977s，disk/logical writes0。10轮owned fixture路径、size、精确mtime全部正确，最长12.008931s，full scan/resource-yield rebuild均0。实际UI Quit引擎6.814458ms、exit0。

本次启动时Root metadata inbox hard overflow造成一次metadataBootstrap（active window前完成）；启动前到退出后的四份base哈希中三份不变，Root metadata base改变。两个namespace base未变。不能把启动前/退出后哈希差异描述为退出重写，也不能声称四份base均不变。此窗口的资源上限失败保留，不因后续版本通过而改写。

vmmap显示DefaultMallocZone实际分配约74MiB及约75MiB碎片，空闲MallocLarge仍驻留35.4MiB。`242138a`在累计枚举32768条后的chunk结束时，异步执行已有malloc_zone_pressure_relief，并在namespace/metadata工作批次包裹autoreleasepool。仅释放空闲allocator页，不丢弃live索引，不新增周期timer。

最终代码`242138a54ec22a13ebc2bae7c78dd8359b790368`本机普通/ASan/TSan各254项，0 failures，1可选挂载skip；release CLI/app、签名通过。[四项required CI](https://github.com/SWHsz/apfs-everything/actions/runs/37743421493)全绿。quiet60.004078s，CPU0.000253s、disk/logical writes0、sampler/deferred timer/metadata timer0，pause1000项恢复227.772750ms。真实双卷验收使用原namespace bases及上述metadata bootstrap结果继续replay，不为本轮重新full scan或重置历史游标。


## `242138a` 最终固定窗口失败，继续保留 #3 OPEN

1201.172911秒/238 samples，30秒摘要physical最大271.95MiB、末端216.00MiB。blockers为physical footprint、维护physical footprint、maintenance restart count>=3。active CPU1365.084325秒，disk writes52,633,600 bytes、logical writes53,203,200 bytes；Root metadata inbox hard overflow后的metadataBootstrap在本窗口执行，不能称零写盘或无维护重试。namespace full scans/resource-yield rebuild仍0，frontier有界并清空；此结果不满足E。

10轮路径均12/12，size/mtime仅第1和第9轮在30秒内正确；第2–8与第10轮失败，不能称B通过。原失败记录只汇总size/mtime，不含逐项差异；后续smoke补充仅owned generated slots的字段差异，不输出真实文件名。程序随后实际UI Quit、exit0；退出前后四份base哈希相同（区别于整个启动至退出区间，期间有上述bootstrap）。

`dc88201`继续修复metadata原始事件队列按canonical delivered path合并，并union事件flags、保留最大event ID、将HistoryDone置于batch末端。合并不会隐藏create/remove歧义或真实失效，不同pending paths的100000上限不变。同路径10000条content burst、created+removed与HistoryDone+KernelDropped回归通过。

旧实现的未配对文件rename origin会持有整个MetadataQuerySnapshot。真实mmap生命周期回归在旧实现失败（替换metadata base后旧MMapMetadataIndex仍存活），修复后旧map释放，迟到的新文件名仍复用size/mtime；目录rename snapshot最多64个、估算8MiB，拒绝的来源保留scoped subtree traversal，65目录cap/fallback回归通过。删除无读取方的recent副本缓存，metadata receive/sync批次也释放autorelease临时对象。

这些修复已通过targeted回归；完整测试、最终固定binary实盘及UI仍须重新运行。不得用`83adda1`中间通过记录替代最新HEAD验收。


## `dc88201` 实盘结果与 point lookup 修复

本机普通/ASan/TSan各257项（237 Core +20 Desktop），0 failures，1可选挂载skip；release CLI/app与签名通过。[四项required CI](https://github.com/SWHsz/apfs-everything/actions/runs/37749753445)全绿。受控quiet60秒CPU0.000192s、disk/logical writes0、sampler/deferred timer/metadata timer0。

真实双卷固定窗口1203.953504秒/238 samples **FAIL**：摘要physical最大237.079796MiB、末端188.657944MiB；blockers为physical footprint与maintenance unfinished at deadline。CPU780.014576s，disk/logical writes0，namespace full scans/resource-yield rebuild均0；没有metadata inbox overflow或bootstrap。Root一次opportunistic compaction持续排队，未开始、没有重启循环；实际UI显示系统内存紧张，原调度策略因此延后整理。该解释不消除内存上限及未完成维护的失败。

10轮owned fixture全部namespace、size、精确mtime正确，最长11.409360s，均在原30秒期限内、full scan/resource-yield rebuild0。实际UI搜索12条、68.1ms。实际UI Quit后exit0，多卷引擎shutdown7.182958ms，退出前后四份base哈希相同。菜单人工确认尚未收到，不能将程序内API暂停/恢复代替最终菜单验收。

进一步发现`HybridIndex.entry(at:)`在两次snapshot generation检查都遇到无关更新时返回nil。metadata bulk以该结果核对身份，会把仍存在的条目当作缺失。有限并发回归只修改无关文件10000次、查询不变的12层路径2000次：原实现0.779s内产生3次错误缺失；修复后相同测试0.683s通过，相关14项回归全绿。初次无限writer版本曾产生1984次错误缺失；该版本在修复后会因NSLock writer反复抢占造成测试饥饿，已改为有限输入，未放宽现有验收deadline。

修复将单条lookup的解析及结果读取放在同一次namespace锁内，避免将generation竞争解释成不存在，也不跨writer更新持有整份overlay容器。搜索仍保留原immutable capture。资源诊断额外记录真实memory/thermal/low power/query/idle状态，帮助区分维护等待原因；未修改resource gate或伪造normal压力。新代码需重新通过完整测试与最终实盘验收。

`0ee3573e741458349695d2c9eda0a0c233d6d319`完整普通/ASan/TSan各258项（238 Core +20 Desktop），0 failures、1可选挂载skip；release CLI/app、签名通过。[四项required CI](https://github.com/SWHsz/apfs-everything/actions/runs/37757694838)全绿。受控quiet 60.010094s，CPU 0.000261s，disk/logical writes0、sampler/deferred/metadata timer0。独立测试bundle已更新为相同release代码，签名后Desktop SHA256 `fadb91386fb97a0b168ddc37142cecfd4611e952097c9cd9d965875f9ba24458`；真实最终窗口尚待完成。


## `0ee3573` 启动期限失败与短锁解析

最终独立实例在原1200秒启动期限内未同时达到双卷Live，输出`active_live_unavailable`：Root Catching up、Data 1 Live，两卷metadata available；**没有执行20分钟窗口或10轮fixture，不能沿用上一binary的结果**。此时系统memory normal、thermal nominal、low power false、active query0；maintenance queued/running0。Root frontier22082项/2724253 bytes，full scan/resource-yield rebuild0；deadline physical181.782852MiB。Data 1约358.649s进入Live。

之前的180–237MiB实盘及此次启动失败均保留，汇总见[aggregate receipts](benchmarks/v0.6.2/native-runs.json)。Mac锁屏、人工确认未收到，故停止该已失败的owned测试进程（exit -15），此退出不能称正常UI Quit；停止前后四份base哈希相同。

此次将整条路径解析放在namespace锁内避免了错误缺失，但metadata reader与writer的争用增加。后续`78ba33f`只固定不可变base，在锁外component walk，短锁中检查当前exact overlay key及base tombstone；base publication竞争才回退锁内解析，不因普通generation变化返回nil、不固定整个overlay容器。目录删除/替换的已有adjacency清理保持lookup一致。新增并发base publication与目录替换回归，与已有point、deferred、resolver等18项一起通过；完整新binary验收仍在进行。

`78ba33f1fde1ebbb03fda8d1c1e642b6ba4fe1dc`完整普通/ASan/TSan各259项（239 Core +20 Desktop），0 failures、1可选挂载skip；release CLI/app及签名通过。[四项required CI](https://github.com/SWHsz/apfs-everything/actions/runs/37762349672)全绿。受控quiet 60.010103s、CPU 0.000185s、disk/logical writes0，sampler/deferred/metadata timer0。独立bundle签名后Desktop SHA256 `bdfd2af1eee37934ed1f149d0dfd806674ab6457df107a1448ac226de517de8a`；最终实盘结果待完成。


## `78ba33f` 启动失败及稀疏修复范围

原1200秒启动deadline再次输出`active_live_unavailable`，Root Catching up、Data 1 Live；未执行20分钟窗口或10轮fixture。本次deadline physical217.579773MiB、进程lifetime peak266.829MiB，真实环境memory warning、thermal nominal、query0。Root metadata inbox overflow1引发一次bootstrap epoch，4个attempt（restart0–3），前三次busy yield、最后完成；namespace full scan/resource-yield rebuild0。不得称无bootstrap/无维护重试或零写盘：process disk52,641,792、logical53,162,240 bytes。

该失败实例在锁屏状态由SIGTERM停止，exit-15，不能算正常UI退出。停止前后四份base哈希均相同；整个启动至停止区间仅Root metadata base变化。原始capture SHA256 `8bcfd8152ab055744107efeea5fa002e770b3fc75431e699f6bb343919b59f1d` 与汇总保留。

继续追踪发现：父目录listing与某个子树请求合并时，旧队列及初始事件处理均会将整个祖先提升为recursive，遍历无关兄弟目录。确定性回归在旧实现实际读取unrelated/deep，2个断言失败。`96da257`将recursive范围保存在每个frontier节点，合并队列所有权不扩大扫描范围；父目录先读，后发现目录身份替换时允许把已读子节点升级为reset，保留子孙。deferred namespace发布后仅对实际mutation的父目录发metadata hint，未变化listing不再重复入队；未发布的I/O失败计划不发hint。

新增祖先合并、初始nested dirty、迟到ancestor replacement及published parent hint四项回归，相关52项targeted全绿。snapshot格式与cold builder不变。最终新binary普通/ASan/TSan、quiet和真实双卷验收重新运行，不能以旧版本成功窗口代替。

`96da257`首次完整ASan运行243 Core tests，1 skip、1 failure：既有nested-create回归仍断言祖先必须使用recursive策略，而新实现已正确发现created且只读root与nested两个listing。原failure日志保留；`007705d`将该策略断言改为实际directory_reconciles=2/subtree_reconciles=0，并保留created存在/direct patches=0断言，相关19项回归通过。`b9164c8`另补迟到recursive祖先升级已读listing以及I/O重试保留全部sparse frontier。最终完整测试需重新通过，不能把此失败写成ASan成功。

`007705d007a3da1c2d43f637b7d8038c296445f0`最终完整普通/ASan/TSan各264项（244 Core+20 Desktop），0 failures、1可选mount skip；release CLI/app及签名通过。[四项required CI](https://github.com/SWHsz/apfs-everything/actions/runs/37769456695)全绿。controlled quiet60秒CPU0.000181s、disk/logical writes0、sampler/deferred/metadata timer0。最终独立bundle Desktop SHA256 `12dd62b15f3b8c5cbc2c189f938cfd183b69f3c749bc83115ea4012a120cc516`；实盘窗口使用旧缓存和cursor继续replay，未重建初始化或改变期限。


## `007705d` 固定窗口失败与 queued bootstrap 竞态

稀疏范围修复后，Data 1约5.615s、Root约24.660s进入Live，旧缓存/cursor原样replay，无full scan；这比此前1200秒仍Catching up明显改善。但原1200秒active window仍**FAIL**：1201.853046s/235 samples，physical上限及维护physical上限失败、deadline仍有queued metadataCheckpoint。期间一次自然namespace compaction完成，Root旧base的约13万条overlay归零，末端physical120.470352MiB；30秒摘要physical最大416.923706MiB，进程lifetime peak由窗口开始的216.454727MiB升至449.252014MiB，不能把末端值代替窗口峰值。process CPU1813.984878s、disk338,132,992、logical346,636,800 bytes，full scan/resource-yield rebuild0。

Root metadata bootstrap先yield busy，重试等待lease时捕获旧base；更高优先级namespace compaction在它之前发布new base+valid metadata。旧任务获lease后因旧UUID不匹配抛generationChanged，catch将刚发布的新metadata置fail，并留下storageError。后续opportunistic checkpoint因该error永远无法开始；deadline Root metadata unavailable，10轮native fixture未开始。E失败后锁屏环境下SIGTERM停止，exit-15，停止前后四份base哈希相同。整段自然compaction与metadata发布改变base的结果另外保留，不能称全程无base写入。

生产路径回归使用真实scheduler blocker：先排队bootstrap，再让emergency compaction先发布new base。旧代码0.318s内5项断言失败，metadata_bootstrap_failures=1、metadataFailure=namespace generation changed、新metadataAvailable=false、target size丢失。`614c7bb`在lease获准后才获取immutable namespace base；ordinal lookup只保留resolver，扫描期间不固定整份metadata overlay。相关31项回归通过；完整新binary验收继续进行。

`614c7bba9674197febf6a32721ad3d8b03bb16cf`完整普通/ASan/TSan各265项（245 Core+20 Desktop），0 failures、1可选mount skip；release CLI/app及签名通过。[四项required CI](https://github.com/SWHsz/apfs-everything/actions/runs/37773283229)全绿。controlled quiet60秒CPU0.000208s、disk/logical writes0、sampler/deferred/metadata timer0。独立bundle Desktop SHA256 `fe40308ca0ece8aafc2b62341ae8cfd80723f8c3053d74f74913d191c3177454`。最终实盘继续使用上次自然compaction产生的有效base和原cursor，不人为清空缓存、重置cursor或初始化full scan；新窗口与前述失败单独记录。


## `614c7bb` 实盘失败与 metadata inbox 有界修复

原1200秒窗口完成：1200.614625s/239 samples，full scan/resource-yield rebuild0。E仍失败：physical与maintenance physical峰值超限、metadata bootstrap反复busy yield及deadline未完成。窗口末端physical122.267227MiB，进程lifetime peak227.657852MiB；末端低值不能代替窗口峰值。process CPU726.373230s、disk writes0、logical writes94,208 bytes。10轮真实pause/create/delete/rename/content/resume加持续查询全部通过，最大2.202430s，每轮12条namespace及size/精确mtime正确、full scan/resource-yield rebuild0。解锁后实际搜索显示12行（48.7ms），Cmd-Q正常退出227.960125ms；退出前后四份base哈希相同。该binary未完成真实菜单及restart验收，不将旧binary或API pause称最终UI菜单验证。

普通metadata inbox的distinct path hard cap命中后，旧实现会分配整卷private bootstrap columns。`7a6a384`保留原hard cap，但已知watched root的普通事件丢失改为bounded metadata目录修复（32 directories或20ms）；游标锁定到frontier完成。重复溢出只要求当前pass完成后的单次补偿pass，避免重置正在处理的frontier；暂停/namespace publication时只保留scalar repair fence。真正KernelDropped/UserDropped等失效、frontier hard cap和重复权威I/O失败仍进入原恢复路径。未改变namespace recovery语义、snapshot格式、threshold或验收期限。

新40-parent真实目录回归同时覆盖suspend overflow、首次部分目录读完后再次溢出、旧cursor100直到两pass完成才推进240、全部新size恢复。它实际抓出了两处早推进：suspended flush与resume empty-batch fast path。已修复并保留原失败日志；35项metadata/cursor/deferred专项回归全绿。完整sanitizer、CI及最终新binary双卷窗口重新运行。


`7a6a384`首次完整ASan有1项测试断言失败：20ms预算在ASan下只容纳root一个目录，测试却假定一次flush必读两个；没有内存错误。`542030d`等待两次实际bounded读取达到注入点，保留原5秒测试上限、32/20ms产品预算及所有cursor/正确性断言；19项metadata ASan专项通过，完整pipeline重新运行，原失败保留。


`542030d`本机完整ASan（201.949s）及TSan（331.976s）各266项通过，包含246 Core+20 Desktop，0 failures、1可选mount skip；正式构建及最终实盘尚待完成。


`542030da25717366350c0f4782e3a1780e2c42b8`最终普通/ASan/TSan各266项（246 Core+20 Desktop）、0 failures、1可选mount skip；release CLI/app及签名通过。[四项required CI](https://github.com/SWHsz/apfs-everything/actions/runs/37778168573)全绿。Controlled quiet 60秒CPU0.000277s、disk/logical writes0、sampler及deferred/metadata timer0。独立bundle Desktop SHA256 `b3704dcc3e0999714120999e4923e9389e2dc8e31c94cb902b2c4e83aa186c2d`，`overflow-final` capture继续原base与cursor；固定实盘窗口及最终UI/restart进行中。


## `542030d` 与 `44dd583` 的失败证据

`542030d` 固定窗口1204.730230s/240 samples，四项blocker：physical、maintenance physical、restart loop及deadline maintenance。摘要physical最大184.907875MiB，末端130.454727MiB，lifetime223.642319MiB；process CPU1567.220704s、disk writes0、logical409600 bytes。10轮fixture全部通过，最大1.376922s，namespace/size/精确mtime均正确，full scan/resource-yield rebuild delta0。实际UI搜索12行55.3ms，正常Cmd-Q multi-volume退出0.415917ms，停止前后四份base哈希相同；没有完成菜单/restart验收。旧菜单请求发出后实例已经结束，用户的迟到回复不计作菜单通过。

旧实现缺少subtree errno计数，因此不能把本次bootstrap归因于已证实的EOVERFLOW。`44dd583` 增加有界bulk page cursor及按errno的诊断：普通inbox root修复不再需要把一个超宽目录整体读入数组；FD、单页和child frontier跨slice保留，父目录文件身份重新验证，取消关闭FD。真实失效请求按ticket合并，旧恢复不能清除后来的stream gap，三条cursor fast path均受recovery fence约束。NSv2/metav1格式没有变化。新增2048文件分页/取消/真实overflow修复，以及late-gap和hard-error cursor回归；完整普通/ASan/TSan各269项（249 Core+20 Desktop）、0 failures、1可选mount skip；[四项required CI](https://github.com/SWHsz/apfs-everything/actions/runs/37785605375)全绿。Controlled quiet CPU0.000366s、disk/logical writes0，sampler和maintenance timers0。

`44dd583` 的 `paged-final` 窗口仍FAIL：1203.545173s/237 samples，physical超150MiB、deadline metadataBootstrap未结束。末端physical250.580391MiB；详见公开聚合JSON，不能以末端或旧成功run代替最终gate。启动Root一次真实queue overflow恢复包含2个scan attempt，lifetime physical peak2320.253159MiB（旧cold builder，未在本轮重构）；这2次属于窗口baseline，active interval两卷full scan及resource-yield rebuild delta0。scope repair完成一次，随后真实metadata recovery请求一次、required bootstrap完成一次，又有emergency bootstrap运行至deadline。窗口process CPU624.221540s、disk50,757,632、logical51,560,704 bytes。新errno诊断没有观察到subtree EOVERFLOW；不能反向断言上一版本失败由宽目录造成。

随后10轮fixture全部通过，最大3.054844s，每轮12条namespace及全部size/精确mtime正确，full scan/resource-yield rebuild delta0。实际UI搜索12行38.8ms，Cmd-Q正常退出1.194708ms，父进程exit0，停止前后四份base哈希相同。该失败候选没有要求用户补做菜单，也没有进行restart验收。原始capture与独立cache继续保留。

## `7cbaa4e` 的下一候选修复

代码审查和回归测试确认两项可独立重现的问题，不把它们混同于已经证实的全部实盘失败原因：metadata safetyBytes只增不减，delta删除、mapped delete/recreate会累计已释放的预算；排队的旧bootstrap在新namespace+valid metadata发布后仍会执行整卷扫描。现在按实际retained allocation计费，hard cap保持500k entries/128MiB，仅净增长触发hard recovery，达到容量时替换已有值仍可进行。诊断同时暴露accounted bytes与overflow flag。旧repair获lease后发现新base且metadata有效、没有新recovery pending时跳过；显式用户rebuild仍强制执行，yield重试保留force语义。

新增delta churn10000轮、mapped delete/recreate1000轮、hard-cap/cursor pin和实际scheduler supersession回归，23项metadata专项通过。完整普通/ASan/TSan、quiet、CI与最终native窗口重新进行；#3保持OPEN，无tag。


`7cbaa4e` 完整普通/ASan/TSan各273项（253 Core+20 Desktop）、0 failures、1可选mount skip；release CLI/app及签名通过。[四项required CI](https://github.com/SWHsz/apfs-everything/actions/runs/37794397557)全绿。Controlled quiet CPU0.000494s、disk/logical writes0，sampler/maintenance timers0。真正的候选capture标签为`accounted-final`，签名后Desktop SHA256 `823023fe4be9e630f33aa3bfdc964eb59dd86a51f94eb5b45f74dc47e985d08f`。

前一次`accounting-final`启动不是有效候选：UI退出后的AX观察重新启动了旧bundle，refresh的“无存活进程”前置检查失败，而随后命令仍执行了旧binary启动。实际SHA仍为`44dd583`；两个已验证属于owned bundle的旧进程被SIGTERM停止，该85.285s capture不计入任何gate。错误启动原始记录保留，之后refresh与launch拆为独立步骤，只有refresh exit0、manifest HEAD及实际SHA核对后才启动候选。日常cache不受影响。


`7cbaa4e` 的20分钟active interval完成1200.007362s/236 samples，唯一blocker为physical footprint；没有full scan/resource-yield rebuild、maintenance loop或deadline task，event/dirty queue无单调积累。摘要physical最大203.767227MiB、末端190.689079MiB、lifetime peak204.751602MiB；process CPU334.064246s、disk/logical writes0。10轮真实fixture全部通过，最大0.362591s，full scan/resource-yield rebuild delta0。实际搜索12条57.1ms，正常Cmd-Q退出0.929875ms，四份base哈希不变，并用进程列表确认退出，不再调用会重新激活bundle的AX观察。菜单/restart尚未最终验收，不能因为恢复收敛而忽略150MiB失败。

只读vmmap诊断（不修改进程）显示allocated52.7MiB、dirty+swap碎片84.6MiB，以及约52.8MiB的empty large malloc regions；这是分配器分类，不等于这些页均可马上释放。已有pressure relief多次返回0，不把降低RSS当作被保证的行为。继续定位到普通metadata parent branch仍会一次处理所有group，而非子树路径已有的32 directories/20ms slice。`4fed316` 为该分支增加同样的小批预算、保留未开始路径及cursor fence，并在事件分类时逐事件释放Foundation临时对象；rate limit和真实错误保留原延迟，纯slice continuation用一次性短延迟，清空后不留timer。新100-parent/12800-file回归在旧实现4项断言失败（一次读完100个parent、cursor早于分片要求推进、无pending/yield），修复后31项metadata专项全绿。

`4fed316` 完整普通/ASan/TSan各274项（254 Core+20 Desktop）、0 failures、1可选mount skip；独立pipeline保留。之后审查queued repair优化发现正确性边界：namespace compaction只是复制已知metadata，并不能恢复在hard cap后丢失的更新。`0f291e6` 记录单调overflow epoch（不会被base bind清除），仅无排队前/期间丢失的repair才能被新有效base取代。新回归使用实际scheduler和compaction，分别在排队前及排队期间触发4-entry测试上限，要求最后两个未接受的文件metadata也经真实bootstrap恢复；生产500k/128MiB上限不变。新候选完整验收继续，#3 OPEN，无tag。


## `ceec3c7` 工程验收与最终实盘

`0f291e6` 完整 ASan216.792s、TSan330.022s 各275项（255 Core+20 Desktop）、0 failures、1可选mount skip。普通275项92.952s在 `ceec3c7` 提交后完成；release CLI/app在该HEAD另行重建和签名验证。Controlled quiet60秒CPU0.000215s、disk/logical writes0、sampler/deferred/metadata timer0。

`4fed316` 与 `0f291e6` 两次远端CI测试编译失败，原因是Swift6.0不能及时推断新增100-parent/12800-file fixture的嵌套flatMap类型，并非sanitizer运行失败。原日志保留。`ceec3c7` 将同一fixture改为显式类型与循环，数据量、断言及deadline不变；两项受影响回归的本机ASan22.025s、TSan33.066s通过。[最终代码四项required CI](https://github.com/SWHsz/apfs-everything/actions/runs/37804919468)全部成功，其中ASan为完整测试。

独立最终capture标签 `loss-final`，签名后Desktop SHA256 `2535e354a9f13d03b744678e5ee41af01a30cef4916bad789a1d4d48de1fb816`，CLI SHA256 `7553fec154e558d4b2db89716fb01c16d9c585d5ba993b559a494448a88497a4`。使用原cache与cursor继续恢复，没有重置缓存以规避历史输入。启动Root真实queue overflow执行一次namespace full scan并bootstrap metadata，约2.3GiB lifetime peak属于现有cold builder；该路径本轮未重构。进入Live后的固定20分钟窗口单独计算full scan delta，不把启动扫描说成纯增量启动。窗口、10轮fixture及最终UI/restart结果随后记录；当前#3 OPEN，无tag。


`loss-final` 固定窗口完成1202.405659s /235 samples，**FAIL**：physical footprint limit、maintenance unfinished at deadline。摘要physical最大177.252220MiB、末端112.127197MiB，窗口CPU229.334996s、disk/logical writes0；两卷full scan/resource-yield rebuild delta0，没有restart loop。Root metadata checkpoint在真实系统memory warning时排队，deadline未执行；不取消或隐藏该任务来改写gate。只读vmmap显示allocated约27MiB、dirty+swap碎片约57MiB，不能据此断言所有超限已被归因或可立即回收。

随后10轮真实pause/create/delete/rename/content/resume加持续查询全部通过，最长5.635304s，每轮12条namespace与全部size/精确mtime正确，full scan/resource-yield rebuild delta0。Mac再次锁屏，UI搜索、菜单、正常退出和restart尚待实际操作；本次保持独立实例运行等待解锁，不使用户的回复再次落到已经关闭的旧实例。公开聚合明确该capture为native_actions_complete之前的不可变prefix；完整退出receipt后续追加。


## 下一候选：普通 parent bulk 分页与覆盖范围过滤

在失败窗口之后的只读heap统计中仍看到约3MiB的ScannedEntry数组。普通metadata parent refresh现在复用安全bulk cursor，只保留一页、最多32个page/parent scheduling units或20ms后续读；已读page收到新事件时完成当前pass，再补一pass，不重置进度、不提前推进cursor。暂停或namespace publication关闭FD并重新保留原请求，停止取消并关闭FD。父目录100k-entry上限、事件上限及snapshot格式不变。

另一个正确性问题有直接旧代码回归证据：普通父目录listing包含namespace未索引的兄弟条目，旧实现仍将这些metadata加入RAM overlay。4-entry测试上限下，即使namespace只有一个文件，旧实现四项断言失败：多余metadata、overflow、错误值可查询及游标未推进。修复只接收仍与当前namespace类型/device/fileID匹配的条目；RAM namespace未记录identity的缺省语义保留。旧失败日志完整保留。新增实际2048文件分页及已读文件中途再写用例，通过writer回调确定性插入新事件，要求补偿pass、size恢复、全目录metadata正确、cursor锁定和无bootstrap。34项metadata专项通过；完整277项/ASan/TSan以及最终新binary实盘还须重新完成，不能把 `loss-final` 的10轮结果套用到该候选。


报告提交 `01471da77b4aefabdd7953c758a7fb5428352191` 已推送，[四项required CI](https://github.com/SWHsz/apfs-everything/actions/runs/37811795130)全绿。后续分页候选完整ASan218.679s、277项（257 Core+20 Desktop）、0 failures、1可选mount skip；TSan及普通/release/quiet仍在进行。首轮专项暴露RAM fixture没有device/fileID但新guard要求完整identity的兼容问题，已改为仅校验已知identity，并保留类型/mount校验，34项专项重新通过；不把该首轮测试失败隐藏。


`61f4f6` 本机完整277项ASan218.679s、TSan328.509s、普通95.603s全部通过，release CLI49.934s/app5.328s，controlled quiet70.043s wrapper通过，原始pipeline保留。远端 [CI37814623814](https://github.com/SWHsz/apfs-everything/actions/runs/37814623814) integration在既有100轮watcher immediate teardown测试中signal5崩溃，主线程停在FSEventsWatcher.stop的callbackQueue barrier，worker为system trap；不能声称该HEAD四项CI全绿。失败job日志已保存，不删除或自动无限重跑。

目标SDK声明Stop阻止后续callback、Invalidate取消dispatch调度。原顺序先Invalidate再排空，可能与已执行的callback source teardown并发；下一候选在Stop后先排空在执行的callback，再Invalidate并排空取消边界，最后Release。该机制目前是针对崩溃位置的修复假设，未将其写成已证实的framework内部根因。立即停止回归增加到1000轮，不延长现有deadline；新的watcher改动需重新验证并运行最终binary。

最终 watcher 候选 `e11b233ff450ce7b99cdc21b4c99eec357f95072`：完整普通277项95.146s、受影响15项ASan23.186s/TSan37.887s、release及签名通过；[四项required CI](https://github.com/SWHsz/apfs-everything/actions/runs/37816627231)全部成功，其中完整ASan和integration覆盖该HEAD。此前分页候选完整277项ASan/TSan成功，但不将其标为当前本机完整sanitizer run。Controlled quiet60.003s CPU0.000233s、disk/logical writes0、sampler及deferred/metadata timer0。详情见[parent-page receipt](benchmarks/v0.6.2/local-validation-parent-pages.json)和[watcher receipt](benchmarks/v0.6.2/local-validation-watcher.json)。最终签名Desktop SHA256 `08673992370f87997787cc1abb8235fa2ef12c2d9119093fad23737738ddf297`，继续原缓存与cursor；实盘及UI gate进行中。前一已失败ceec候选在身份及四份base哈希复核后SIGTERM退出（-15），不记为正常UI退出，失败capture完整保留。

`e11b233` 的固定双卷 active-live窗口1200.713s、235次gate观察通过：无新增namespace full scan/yield rebuild、无维护重启loop，截止队列为空；30秒诊断physical最高116.987MiB、结束116.893MiB，启动lifetime peak2116.487MiB另列。CPU333.201s、disk writes53,444,608 bytes、logical writes54,018,304 bytes；窗口内一次opportunistic metadata checkpoint在原deadline内完成（2.385s、无restart），真实active gate不要求零写入，不将此称controlled quiet。启动两个卷各有一次真实queue overflow recovery，未清缓存或调低replay范围。

随后10轮B有9轮通过，round5失败30.177s：namespace12/12，但born/renamed两个owned slot的size/精确mtime为unknown；其余轮次正确，full scan/yield rebuild始终0。这个结果不能作为B通过。冻结完整窗口/actions capture并保存哈希，当前未进行UI验收/正常Quit/restart。

新增确定性回归复现同类缺口：namespace floor100、metadata floor200，replay150–152发布新文件和rename destination；namespace正确但metadata仍unknown，两项断言在修复前失败。raw普通事件被metadata较高floor跳过，而立即namespace publication没有已有deferred路径的ID0 changed-parent补偿。现在将该通知放到runtime mutation publication共用入口，覆盖立即diff、parent repair、deferred batch及compaction replay；仅实际发布的changed parents触发，unchanged scopes不会全树重复刷新，临时build graph不通知runtime metadata。23项专项（包含独立floor、立即/延后hint、分页cursor）通过。这个回归证明机制存在；没有完整原始round5事件trace，不将其写成该实盘失败每一步均已溯源。新候选须重新完成全部验收，不能借用e11的E通过结果。
