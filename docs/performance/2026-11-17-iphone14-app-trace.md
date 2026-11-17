# iPhone 14 原始完整报告测量检查点

本次范围是同一台 iPhone 14（iPhone14,7）、iOS 27.2 / 24B119、有线、竖屏、系统深色与 XL。它不是原症状 iPhone 18 Pro；iPad 不在本轮测量范围。用户选择的条件见[补充 v1](native-report-condition-addendum-iphone14-dark-xl-v1.json)。原始[数值预算 v1](native-report-budget-v1.json)、样本数、nearest-rank 统计及真实 touch-up→首个完整可读已呈现帧的定义均未改变。**#19/#25 性能验收未完成。**

大文件统一保存在 `/Users/lienhui/Desktop/ai-project/投资/性能基线/39eae89-20261117`，不提交仓库。冻结 `source`、源码归档与完整 Study 清单保持不变。普通构建与外置诊断源码/构建分开保存；诊断版本不得称为原始生产字节。

## 正常 App 的可靠反馈

`iphone14-debug-journey-04`：UI exit 0、trace exit 0，实际 App PID1450，Instruments 日志与保存 TOC 的 PID/可执行路径一致。39e/Debug 来源可追溯至前一轮 journey03 的 Debug 构建及 `XCUIApplication.launch()` 安装链；04 本身尚无后续工具新增的显式安装 manifest/URL 核验。`iphone14-release-journey-01` 虽实际 App PID1458、UI/trace exit0，但旧 prelaunch/activate 路径可能复用此前安装，**实际配置未验证，不计入 Release 验收或配置对比**。

Debug04 的 Time Profiler 在 trace 26.517553–28.097553s 记录约1.50s 主线程采样，其中约1.40s 在 CA commit、约1.38s 在 layout/display，栈经过 UIKit intrinsic sizing 与 SwiftUI VStack/Text 测量。保存 `first-report-long-task-profile.txt`。这是真实报告重建的布局反馈，足以支持在隔离分支验证最小 eager-layout 修复；它不是首个可读帧指标或完整根因证明。

| Debug04 实际窗口 | pipeline 帧数 | p50 / p95 / p99 / max，ms | App hitch 数 / 合计 ms | 主线程 ≥100ms 区间 |
| --- | ---: | --- | ---: | ---: |
| 持续滚动，34.185s / 8手势 | 601 | 83.39 / 100.08 / 116.61 / 116.73 | 325 / 16,248.01 | 24 |
| 停后恢复，17.039s / 4手势 | 299 | 83.43 / 100.15 / 116.68 / 116.79 | 159 / 7,971.66 | 12 |

这些是 `hitches-frame-lifetimes` 实际 pipeline lifetime，不是正文可读帧分类。窗口包含 AX/IPC 等待，不能充当 active scrolling 分母，因此不由它们计算正式 hitch ratio。相邻 vsync 主峰约16.6755ms。全 Debug journey 有520个 hitch、合计约33.453s；≥100ms 主线程区间136个、≥250ms 区间105个、最长1,582.84ms。约32.30s / 总89s sampled CPU 位于 accessibility user-testing snapshot（36.2%），不能把全路径自动化成本当普通手指耗时。

`journey02` 的 `--attach CompanyLens` 实际录到 Runner1398，trace 无效；03 当时 App PID附加失败。这两轮 UI 通过与 XCUI 代理独立保留，均不计入有效 App trace。旧 journey 的 `fresh-process-first-report` 标签没有验证启动时恢复图解，可能先恢复过报告；衍生结果按未验证冷状态的报告重建处理。

## 原生滚动 metric 的补充及限制

`iphone14-debug-scroll-01` 与 `iphone14-release-scroll-01` 均 UI exit0，使用相应配置的标准 XCTest launch；它们早于显式安装哈希核验。`xctest-native-metrics.json` 保存 XCTest 原始 metric，`native-scroll-diagnostics.json` 保存衍生分布。各配置5个实际报告样本：Debug hitch ratio 为681.5606、680.9579、674.4912、685.4432、687.9185ms/s；Release 为602.8817、597.4652、612.5401、609.6010、608.3119ms/s。它们清楚显示滚动问题，不能替代冻结的各阶段完整比较。

SDK `XCTMeasureOptions` 明确 iterationCount5 执行6次 block并丢弃第一份 metric；全部12个操作窗口仍保留。block合并持续与停后恢复，不能声称获得分阶段正式 ratio。metric 的 frameCount 返回0但 FPS/hitch非零，这是字段缺失，不是零实际帧。工具未公开活动时长聚合口径，不反推总运动秒数。

## 安装、冷进程与录制管道纠正

当前 sampler 显式安装所选 Debug/Release `.app`，校验 bundle ID、executable、完整 Study 与构建字节 manifest；保留设备返回的安装 URL。准备完成后再次安装同一产品，使用 `devicectl` 启动，核对唯一 `CompanyLens.app/CompanyLens` 路径和确切 PID，并在 TRACE_READY 再核对一次。新的 XCUI proxy 只等待 foreground，避免旧 proxy 的 activate 替换已附加进程。重试只允许同一已验证 PID 的短暂 xctrace exit21，绝不回退到模糊名称或全进程录制。

新的 cohort 准备先持久化报告目录目标 `gree-profit`，再持久化图解 business-delivery；回研究库等待“已保存在本机”，终止进程。新进程在任何 mode action 前必须验证恢复的图解标题且没有 report controls。原来不符合要求的准备已由 `diagnostic-restore-precondition-red-01` 实际 exit65 拒绝，未伪造有效样本。

CLI 检查覆盖安装配置、旧/新测试来源、错误进程、PID替换、错误/缺失 trace、保存超时回收子进程，以及 UI退出码独立保留。`trace_status=verified-app-target` 仅表示目标身份和可读 trace，不表示性能验收。`first-frame` 只执行上述准备后首次报告路径，减少无关录制；额外模板、instrument、options 文件及哈希均保存。

## 诊断首帧证据：尚缺内容→commit 的边

外置诊断 observer 仅包裹公开 `UIApplication.sendEvent`，每个事件向原实现转发一次，记录 ended UITouch 的原始 uptime。实际正式标题/正文的背景 UIView 为 clear、`isOpaque=false`、非交互且 AX-hidden。仅 ended touch 触发补充扫描；正常布局回调仍采样。几何检查拒绝后台、隐藏/低alpha、裁剪、过渡与遮挡。marker 是候选几何，不是实际呈现帧。

当前 v6 外置源码 `diagnostic-source-39e-frame-probe-v6` 的 overlay SHA-256 为 `25bd9266140bdd12182a46a7da0f9b01e9910ab2041c54b2db3ab58f2c524959`，patch SHA-256 为 `4b927ea5c5513fb2d13d0fd4bbce806d3faf6d0bbb7625f62a9db6a4e6f942a3`。Core、Study、工程未改；普通源码和归档未改。v6只给原有背景 probe补上与现有 readingAnchor 一致的 proposal sizing。该诊断开销今后须与候选配对，不能与普通构建混为一组。

- `diagnostic-verified-fresh-03` / App1580：UI exit0、159.452s、显式安装与测量 PID匹配；用户暂停时原 recorder 未完成归档，原 manifest 不改写成成功。4.8GB原始 trace-data 离线恢复为单独 `recovered-frame-evidence.trace`，保留 `recovery-summary.json`、TOC及 CA/display 导出。恢复数据没有 measurement marker，不能提供首帧样本。
- `diagnostic-first-report-only-01` / App1609：最小 Blank组合出现 Apple modeler backtrace/tagged-backtrace错误，trace exit2，工具正确拒绝；可导出 TouchEnded，但无正文布局 marker。该 trace不计入有效录制。
- `diagnostic-first-report-only-02` / App1621：原 Animation Hitches+Time Profiler模板并显式启用 measurement subsystem，45s，UI/trace exit0；安装 URL、built-app manifest 与测量 PID一致，开始/结束nominal、100%电量、低电量模式关闭、Dark/XL。只读导出保存在 `frame-validation/`。

独立验证从 run02 的原始 `os-signpost-arg` 恢复 TouchEnded uptime43237.671026958s，映射到 trace21.053893374667s；signpost本身晚约20.05ms，不能拿格式化 message或记录时刻代替真实 touch timestamp。App1621 的 CA client commit 为[21.149298041,22.717205666]s，context1660166040在[22.707206,22.716989166]s提交3190layers，原始 CA code0x79明确连接 swap975508，`display-surface-swap` 实际呈现时间22.740799208s。

**run02仍没有任何 NonemptyTextLaidOut marker，因此缺“目标完整标题+明确定义的可读正文区域→该 commit”这一条边。1.6869s 不能称为真实可读首帧。** 最终截图确实清晰显示完整两行标题和三行正文，但截图更晚，只能佐证最终视口。下一步只对既有目标 marker 记录一次拒绝原因、bounds/full+clipped及归属，定位具体 predicate；不增加无关 observer、不用 layout、预计vsync或最近surface代替真实终点。

## 未完成的验收

原始默认 Light/L 条件组按用户选择未运行；当前只做 Dark/XL 同条件比较。Debug/Release各配置的30次首报告、每方向100次热切换、30次目录跳转、5轮分阶段 active-scroll主指标及最终候选同条件对比尚未齐。最终候选必须包含已确认视觉稿和 #25 修复。现有真实布局/滚动反馈允许最小修复与测量并行，不能提前关闭 #19/#25。
