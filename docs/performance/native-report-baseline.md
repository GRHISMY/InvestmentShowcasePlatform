# 完整报告真机性能基线（#19）

源码固定为 `39eae89dcc7278270cfa80e8588acb467bffe0f9`。本票只增加测试、采样工具与文档，不改变 App 行为。正式格力研究、完整报告及全部 11 份 PDF 均保留。数值预算在重做及本轮测量前冻结于 [native-report-budget-v1.json](native-report-budget-v1.json)，以后修复结果不能改变这份 v1 标准；产品主动调整标准时另立版本并保留原结论。

实际设备与原症状设备分开记录：用户指定当前先在 iPhone 14 验证。此前报告卡顿的 iPhone 18 Pro 尚未连接；iPhone 14 的结果不能证明原手机症状已经复现或已经修复。iPad、模拟器及 Mac Core 耗时均不作为 iPhone 性能验收。

## 原始基线与重新安装

本机外置证据目录：`/Users/lienhui/Desktop/ai-project/投资/性能基线/39eae89-20261117`。`source-39eae89.tar` 是固定提交的原始源码归档；`source-content-manifest.json` 固定源码归档和完整 Study 的逐文件 SHA-256 与字节数。`source` 为可重新构建的同一源码副本；签名配置仅在本机保留且不提交。Debug 与 Release 各自保留已签名 `.app`、构建日志和配置元数据；开发证书/描述文件失效后需以本机授权签名重新构建，不能承诺签名永久有效。

禁止卸载用户原 App 或清除其数据。安装前核对 bundle ID、源码身份与内容清单。重新安装同 bundle ID 会替换程序，但不主动删除用户容器；若已有版本身份不明确，停止安装并先保留/核对。采样不连接其他目录、不读取个人文件、不开启全设备全进程记录。

## 固定运行条件与口径

- 同一台物理 iPhone、同一 iOS build、同一内容哈希、竖屏、默认文字大小、浅色、同一刷新率设置、低电量模式关闭、无屏幕录制和调试器，充电/电量及热状态记入 run manifest。关闭无关前台 App，网络与 iCloud 状态保持一致。
- Debug (`-Onone`) 与 Release (`-O`) 分列记录；只能同配置对比，不能把 Release 比 Debug 的优势当作修复。Instruments 探针开销同样匹配。
- “进程冷”指强制终止后新进程首次进入完整报告，研究已在本机准备；不声称文件缓存/设备冷启动。热切换指同一 Reader 已完成一次不计数预热后的往返。
- 真实交互开始：目标原生控件 touch-up；结束：报告/目标段落首个完整可读且已呈现的帧。通过 Animation Hitches 时间线、屏幕内容与触摸记录确定。每个样本保存起止时间，不能把菜单按钮出现当作正文首帧。
- XCUI 的 `tap` 到正文 accessibility readiness 包含自动化等待及 IPC，是可无人重复的上界代理指标；单独命名，不用于套用首帧预算。XCTest 原生 scrolling/deceleration metric 与 Instruments 的实际 hitch/帧时延用于滚动证据；缺数据标为缺失，不记零。
- 帧延迟按设备实际 vsync 间隔 B 归一化；60Hz B=16.67ms、120Hz B=8.33ms。报告 p50/p95/p99/max、有效样本数和失败数；p95 使用 nearest-rank。滚动分别统计持续与停后再滚，不能用静止时间稀释 hitch ratio。
- 记录 Time Profiler 的主线程占用栈与 ≥100ms（滚动）/≥250ms（交互）连续忙任务数量、最长持续时间。采样栈只能作为定位线索，未做验证前不宣称根因。

## 用户路径与采样边界

1. 研究库打开完整正式格力研究，选图解；终止并重新启动 App，回到图解。在新进程内首次点“完整报告”，直到首个可读报告帧。每配置 30 次。初始位置与是否已有保存记录写入结果，不删除用户记录。
2. 同一进程图解→报告→图解预热一次，然后 10 批各 10 次往返；每个方向各 100 个样本。保留报告自己的位置，不能靠每次重建/重置位置减负。
3. 目录进入正文前段，连续快速向上滑动 30 秒，覆盖正文布局与完整数据；暂停 2 秒，再持续滚动 15 秒。每配置 5 轮。按相同相对屏幕坐标、速度和方向执行。
4. 目录依次跳到“先分清利息记在哪里，再看产品生意赚了多少”“最近一个季度，利润降得比销售金额快得多”“2026年销售收款减少，收回贷款补了一部分”，直到对应标题和正文可读；每配置合计 30 次，记录目标。

同设备同配置候选须同时满足 v1 绝对预算及回退预算。自动化 smoke 的小样本只验证采样路径，不能代替以上统计规模。

## 自动化与 Instruments

运行和实际结果补充在本文件下方。重做后的 UI 可以调整测试控件适配，但必须保留相同原生用户路径、数据与测量口径。不要用缩短内容、删 PDF、缩减判断或丢失阅读位置满足预算。

可无人运行的入口（在仓库根目录执行；输出必须是尚不存在的外置目录）：

```sh
python3 ios/CompanyLens/Tools/run_native_performance.py \
  --source '/Users/lienhui/Desktop/ai-project/投资/性能基线/39eae89-20261117/source' \
  --content-manifest '/Users/lienhui/Desktop/ai-project/投资/性能基线/39eae89-20261117/source-content-manifest.json' \
  --device '<当前授权的物理 iPhone UDID>' --configuration Debug \
  --output '<外置目录>/debug-journey-02' \
  --scenario journey --repetitions 10 --scroll-seconds 30 --record
```

工具复制独立 harness 源码，只替换已纳入 Xcode target 的 UI 测试文件；生产 App/Core/Study/工程均保持原样。拒绝内容不匹配、模拟器、iPad、未连接的手机及覆盖已有结果。原始 `source` 和可重新安装的基线不变。它会安装同一 bundle ID 的 App 和 XCTest runner；真机首次运行须在系统“设置 → 通用 → VPN 与设备管理”信任本机开发证书，这是系统手动授权，脚本不能代替。

`journey` 覆盖完整原生路径并在 App 就绪后附加 Animation Hitches + Time Profiler；仅附加 CompanyLens，不使用 `--all-processes`。`full` 或分别选择 `fresh`、`warm`、`scroll`、`jumps` 用于扩大样本：fresh 30、warm 100、scroll 5、jumps 10（每次三个目标，共 30）。每项另存不同输出目录，Debug/Release 各跑一次；`journey` 只作为 smoke 与栈/帧采样，不能误称已满足完整次数。

保存 `native-performance.xcresult`（含原生截图与样本附件）、`native-ui.log`、`samples.json`、`summary.json`、`run-manifest.json` 和 `native-report.trace`。汇总只对明确的 XCUI 代理样本给出 nearest-rank 分布，不捏造缺失的 hitch、主线程或真实首帧指标。UI 文本查询也有测量开销；快速滑动为原生 XCUI `.fast` 手势，但自动化会在手势之间等待空闲，因此 Instruments 统计实际运动帧区间，不能把整个 gesture-window 的时长当成连续运动时间。

在 Instruments 打开 `.trace`：框选每次交互与连续/恢复滚动区间；查看 Animation Hitches 的 Hitch Time Ratio、帧时延及呈现时间线，Time Profiler 选 CompanyLens 主线程，导出所选区间的栈与长任务。通过 XCUI sample 的相对顺序、system uptime 与截图关联动作；若当前工具未记录触摸时刻/可读帧，保留“未测”并进行有外部动作时间标记的人工复采，不从 XCUI 秒数倒推真实首帧。可用 `xcrun xctrace export --input '<trace>' --toc` 检查数据表，保存导出表与完整原始 trace。

## 2026-11-17 实际尝试（未完成测量）

设备是用户授权先验证的物理 iPhone 14（iPhone14,7），iOS 27.2 / 24B119，有线连接、Developer Mode 已启用。原症状 iPhone 18 Pro 不可用；没有声称原症状在替代机复现。

- 从冻结源码构建并保存 Debug 与 Release 原始 `.app` 成功，`codesign --verify --deep --strict` 均通过；两者 App 内完整 Study 逐文件匹配冻结清单。最初 generic 签名描述文件未包含新接入的 iPhone 14，另保留 `reinstallable/Debug-iphone14` 与 `Release-iphone14` 定向构建，不覆盖原文件。当前本机开发描述文件有到期日，查看各自 `build-metadata.json`，到期后用同源重签。
- iPhone 14 Debug 的真实 UI harness `build-for-testing` 成功；测试启动失败（exit 65）：系统尚未信任开发者证书。保存原始 `.xcresult`、build/native-ui logs、run manifest 和空样本列表于 `iphone14-debug-journey-01`。之后修正正文就绪代理的视口检查并重新构建 harness 也成功。
- 原生测试尚未运行到就绪标记，Instruments 未启动。交互首帧分布、主线程长任务、hitch 和帧时延均为**未测**，不是零，没有通过性能验收。电量、温度、低电量模式、文字大小及刷新设置亦未观察。
- CLI seam 的 red→green：缺少采样工具时测试失败；实现 nearest-rank 汇总后内容保护测试仍失败；加入完整内容校验后 2 个测试通过。UI 源码已由真实 iphoneos test build 编译。没有用 Mac Core 时间代替手机证据。

可机读状态见 [2026-11-17-baseline-attempt-01.json](2026-11-17-baseline-attempt-01.json)。#19 保持未完成；本机信任后以新的 `debug-journey-02` 输出目录执行上面的命令，保存实际帧/栈数据，再分别扩大 Debug/Release 样本。#25 必须引用该状态并补齐同设备同配置测量，不能把本次构建成功当成性能通过。
