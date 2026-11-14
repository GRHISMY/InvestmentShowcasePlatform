# 看懂公司 · 黑白研究档案

SwiftUI/PDFKit原生阅读器。从同一正式发布包读取`research.json`与`reading.json`，展示公司关系、图上解释、计算与原始PDF。研究与讲解意图的约定见[数据契约](../../docs/company-study-data.md)。

当前为格力正式r4报告：2020—2025全年及2026年前九个月，资料截至2026-11-09。原25条判断、104条事实与22项计算保持不变，补入有原页支持的主体关系。11个场景与8张图是这次研究的选择，不规定其他公司的数量或主线。

研究库打开一份完整、固定的研究版本。图解与完整报告共用 `StudyReader`，各自保留位置并支持明确关联与来源返回。长正文与图形按自然尺寸滚动，系统字体可放大；复杂图可以打开同图全屏查看。计算、全部输入、完整依据与所有引用原页沿统一详情路径查证，原生 PDFKit 保留引用定位与独立续读。

## 打开和构建

用完整Xcode打开`CompanyLens.xcodeproj`，运行共享scheme `CompanyLens`。最低iOS17，Mac预览最低macOS14。首版每台设备使用一个窗口；iPhone、iPad 的记录通过同一研究目录交换。真机安装使用 Xcode 的开发 Team 签名。模拟器、签名设备构建与实际设备验收是三项不同检查，结果见 GitHub 实施任务 #15/#16。

本机开发签名放在未提交的 `Configuration/LocalSigning.xcconfig`；新机器可复制同目录的 `.example` 并填写自己的 Team ID。Xcode 工程与 UI 测试共用该设置，仓库不保存账号或证书。

在项目根目录执行：

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project ios/CompanyLens/CompanyLens.xcodeproj -scheme CompanyLens \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath /tmp/company-lens-json CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build

env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  ios/CompanyLens/Tools/build_mac_preview.sh
```

Mac预览输出至`Verification/看懂公司-Mac预览.app`，脚本只构建。iPhone模拟器在Device Hub中显示，Mac预览不代替手机验收。

## 更新数据

```sh
python3 ios/CompanyLens/Tools/prepare_resources.py --case /absolute/company-case
```

只读取正式案例的`published/research/current.json`。打包器验证快照、哈希、阅读绑定与PDF页数，全部成功才事务性替换`Study`。研究正文、阅读稿和完整PDF原样复制，不修改案例或SQLite，不生成第二份研究结论。`Study`目录名避开iOS包根目录的保留资源名。

## 模块边界

- `ResearchLibrary`：读取正式v1/v1.1/v1.2，检查研究身份、主体、期间、章节、依据与物理页。
- `ReadingLibrary`：读取配对阅读稿，检查研究字节哈希、引用、数字、关系、事件阶段与关键未知，提供只读Interface。
- `StudyReader`：固定版本内的图解导航、焦点、真实来源、有效观察及语义位置；`StudyReaderHost` 统一接入展示。
- `StudyShelf`：发现、准备与固定版本，管理本机记录和各设备候选；`AppleCloudFolder` 只负责系统授权、协调读取和本设备文件写入。
- `StudyWorkspace`：组装研究库和活动 Reader；具体页面不持有另一套业务导航或书签。
- `StudyDiagram`和SwiftUI：按通用图形数据绘制、适配屏幕；公司名、金融数字和解释不写入Swift。
- PDFKit：读取完整原件并定位物理页，不用截图代替原件。

旧包没有阅读稿时继续全文阅读；损坏或错配的阅读稿明确报错。SQLite是研究时可重建的检索层，App离线阅读不依赖它。Mac 发布到普通 iCloud Drive 专用目录；首版保留本机已准备版本和跨设备候选。估值、交易、实时行情与 App Store 上架不属于本轮范围。

## 验证

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path ios/CompanyLens
python3 -m unittest discover -s ios/CompanyLens/Tools -p 'test_*.py'
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swiftc ios/CompanyLens/Core/ResearchLibrary.swift \
  ios/CompanyLens/Core/ReadingLibrary.swift ios/CompanyLens/Tools/verify_native_story.swift \
  -o /tmp/company-lens-reading-check
/tmp/company-lens-reading-check ios/CompanyLens/Study
```

本轮实现与验收证据见 [GitHub 技术方案的子任务](https://github.com/GRHISMY/InvestmentShowcasePlatform/issues/4)。原研究迁移过程见[历史验收记录](../../.scratch/study-json-pipeline/验收记录.md)。`Verification`中的旧记录保留作历史，不能冒充本轮验证。
