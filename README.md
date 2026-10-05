# APFSFind — v0.4.0 Desktop Alpha

APFSFind 是一个 macOS 本地文件名搜索工具。按 Option+Space 打开搜索窗口，搜索系统卷与自己选择的本地卷。
Swift 6 / macOS 14+，无第三方 Swift package；目前是可运行的桌面 Alpha。

> 截图位置预留。尚未提供 notarized 安装包，请在本机从源码构建。

## 构建与运行

```bash
cd "/Volumes/Data 1/everything"
bash scripts/build_app.sh
open dist/APFSFind.app
# 或：bash scripts/run_app.sh
```

产物为 `dist/APFSFind.app`，脚本完成本地 ad-hoc 签名，无需 Apple Developer 账号。
应用启动即显示窗口，后台开始索引系统根目录 `/`。首次扫描可能耗时并占用较多内存。
有缓存时校验并映射 base 后立即开放搜索；“正在更新索引”表示仍在 replay，结果可能短暂陈旧。
打开或在 Finder 显示前会检查目标是否仍存在；失效结果会移除并修复对应父目录。

## 搜索与快捷键

大小写不敏感文件名子串搜索；exact、prefix、substring 顺序，最多 50 条。空输入不扫描索引。

| 操作 | 快捷键 |
| --- | --- |
| 显示／隐藏窗口 | Option+Space |
| 选择结果 | ↑ / ↓ |
| 打开 | Enter 或双击 |
| 在 Finder 中显示 | Command+Enter |
| 复制完整路径 | Command+C |
| 隐藏窗口 | Escape |
| 正常退出 | Command+Q |

热键不要求辅助功能权限。注册冲突会在窗口提示；本版固定 Option+Space。

## 卷与权限

齿轮按钮打开卷设置：系统 `/` 默认开启；其他本地卷只有勾选后才索引。
选择按卷 UUID 保存；卸载后保留离线状态与缓存，重新挂载后恢复。取消选择停止该卷，不删除缓存。
系统 Data 的重叠视图、辅助 APFS 卷、网络卷和 autofs 不作为额外卷索引。

“部分目录无法读取，搜索结果可能不完整”根据实际不可读目录计数显示，不声称精确检测 Full Disk Access。
可通过按钮打开系统设置，在 **隐私与安全性 → 完全磁盘访问权限** 中自行添加 APFSFind；随后重启应用。
程序不会绕过权限或请求 root。

## 缓存与安全

默认缓存：`~/Library/Application Support/apfsfind/indexes/`。目录 0700，索引文件 0600；包含敏感文件名元数据。
每个 root + volume UUID 对应 immutable snapshot v2 和 128-byte cursor state。
在线更新主要在内存中，达到阈值才后台合并。正常退出采用 fast：小变化不会重写几百 MB 的 base，
下次通过保守 cursor replay 恢复。无周期 compaction timer。

只读取目录项与元数据，不读文件内容，不访问 raw disk，不跟随 symlink 目录，默认不跨设备。
best-effort 禁止 dataless materialization；不联网、无 telemetry、无运行日志文件。
本机实盘测量与限制见 [STATUS.md](STATUS.md)，引擎和格式细节见 [architecture](docs/architecture.md)。

## 已知限制

目前单进程、线性子串扫描、SF Symbols 图标；无 fuzzy、内容搜索、预览、后台 daemon、开机启动或缓存删除 UI。
未 notarize / App Sandbox；macOS 14、Intel、真实 iCloud dataless 和掉电耐久未专项实机验证。
活动系统目录可能短暂陈旧；特殊节点（例如 Unix socket）的事件交付随系统版本不同。
新扫描、rebuild、compaction 全局串行，以控制多卷维护的峰值内存。

## CLI 与测试（高级使用）

```bash
swift build -c release
swift test
swift test --sanitize=address
.build/release/apfsfind serve --root "$HOME"
.build/release/apfsfind bench --files 1000 --latency-ms 20
.build/release/apfsfind multivolume-bench --entries-per-volume 100000 --volumes 2
.build/release/apfsfind usability-bench --root / --idle-seconds 60
.build/release/apfsfind usability-bench --root "/Volumes/Data 1" --idle-seconds 60
```

`serve` 默认 root 为 `$HOME`。输入文字搜索；`:stats`、`:verify`、`:rebuild`、`:checkpoint`、`:compact`、`:quit` 可用。
base ready 即可输入，catch-up 结果可能陈旧；`:quit` / EOF / 首次 Ctrl+C fast 退出，第二次 Ctrl+C 取消未发布写入。
`--workers 4`、`--latency-ms 20`、`--ephemeral`、`--rebuild-index`、`--cache-dir PATH` 保留。
serve 的 cache-dir 是精确缓存目录；已有目录必须是当前用户所有的 0700，无 symlink，不能位于 root 上方。

原 `persistence-bench`、`hybrid-bench`、`real-disk-bench` 均保留，参数见 `apfsfind --help`。
新 benchmark 最后一行输出 JSON。usability 默认创建并清理自己的 UUID 缓存与测试目录，
先独立冷进程准备 snapshot，再用独立 warm 进程测 search-ready、live、取消、60 秒 idle 和小 overlay fast exit。
`--cache-dir EXISTING_TEST_CACHE` 可测已有测试缓存，程序不会删除传入缓存；不要指向日用索引。
该测量关闭自动 compaction，以隔离退出与 idle 数据；生产应用仍使用默认阈值策略。
multivolume-bench 使用 synthetic mmap，报告两卷并行 global top 50 分位数，不冒充实盘事件延迟。

真实 FSEvents 测试默认运行；仅可选挂载烟测默认跳过：

```bash
APFSFIND_RUN_MOUNT_TESTS=1 swift test --filter NativeMountSmokeTests
```

CI 保留 deterministic、native integration、ASan，并新增桌面构建、bundle 和签名验证。
