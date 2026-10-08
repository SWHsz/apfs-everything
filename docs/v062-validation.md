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
