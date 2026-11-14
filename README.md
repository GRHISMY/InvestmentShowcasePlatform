# 公司研究 App · 黑白研究档案

这里保存原生App、研究阅读契约、打包与验证工具。公司原始PDF与研究案例放在上一级投资目录；公司研究Skill继续安装在Codex的Skill目录。源码已从原iCloud投资工作台中独立迁出。

开始工作先读本文。研究原则与实际数据职责见[研究关系与讲解意图](docs/company-study-data.md)；详细执行与检查见[本轮记录](.scratch/study-json-pipeline/验收记录.md)。

产品范围见[GitHub 产品规格 #3](https://github.com/GRHISMY/InvestmentShowcasePlatform/issues/3)。研究库、阅读核心和展示三项职责基线已确认，具体 Interface 已逐项展开，整体技术方案见[GitHub 技术提案 #4](https://github.com/GRHISMY/InvestmentShowcasePlatform/issues/4)及[本机方案文档](docs/display-app-technical-plan.md)，尚待整体定稿。当前 CompanyLens 是用户已确认的视觉与阅读体验参考，详见[参考项目探索记录](docs/companylens-reference.md)；此前的[架构探索备忘](docs/display-app-architecture.md)保留早期候选思路，均不代表代码已经实现。

## 当前实现

App直接读取同一发布包的`research.json`与`reading.json`。主阅读是固定画布：看全貌、进入一处关系、点选图、核对计算与证据、打开完整PDF，再回到原位置。本地保存阅读进度，完整报告可另行深入阅读。

研究结果与讲解意图由AI按公司实际问题组织；CLI验证、复算并生成只读阅读文件。每家公司可以有不同主线、角色、场景数量与图形组合。当前包为格力2020—2025全年及2026年前九个月，原始资料仍截至2026-11-09，不代表已查到今天的最新披露。

## 打开 App

用Xcode打开[CompanyLens.xcodeproj](ios/CompanyLens/CompanyLens.xcodeproj)，运行共享scheme `CompanyLens`。本机的iPhone18Pro模拟器在Device Hub中显示。

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project ios/CompanyLens/CompanyLens.xcodeproj -scheme CompanyLens \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath /tmp/company-lens-json CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build
```

Mac原生预览使用同一份源码；它不替代手机验收：

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  ios/CompanyLens/Tools/build_mac_preview.sh
```

## 研究引擎与数据更新

引擎唯一实现仍在`~/.codex/skills/company-financial-analysis`。`scripts/cfa`调用该安装，不维护第二套脚本；非默认安装可设`CFA_SKILL_DIR`。依赖Python3、Poppler；原生构建需要完整Xcode。

```sh
scripts/cfa research template --schema-version company-research/v1.2 \
  --case ../格力2020-2026 --output ../格力2020-2026/workpapers/research-input.json
scripts/cfa research --help
scripts/cfa reading --help
python3 ios/CompanyLens/Tools/prepare_resources.py --case ../格力2020-2026
```

生成模板不是完成研究。先依真实材料组织并采用研究与讲解意图，完成语义复核，再正式发布。打包工具只读取已发布快照，核对哈希/页数/阅读绑定后事务性更新`Study`。

## 验证

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path ios/CompanyLens
python3 -m unittest discover -s ios/CompanyLens/Tools -p 'test_prepare_resources.py'
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swiftc ios/CompanyLens/Core/ResearchLibrary.swift \
  ios/CompanyLens/Core/ReadingLibrary.swift ios/CompanyLens/Tools/verify_native_story.swift \
  -o /tmp/company-lens-reading-check
/tmp/company-lens-reading-check ios/CompanyLens/Study
```

## 目录

- `ios/CompanyLens`：SwiftUI/PDFKit原生App、Core与行为测试。
- `ios/CompanyLens/Study`：同版本完整研究、编译阅读稿及原始PDF。
- `ios/CompanyLens/Tools`：打包、Mac预览与来源核验工具。
- `docs`：已确认的契约与协作约定。
- `.scratch/study-json-pipeline`：本轮迁移规格、验证与必要历史记录。

不含原投资工作台、旧资产归块页面及无关原型。旧路径保留兼容入口，后续开发以此目录为准。用户进度不属于研究JSON；估值、交易、实时更新、跨设备同步及上架不在当前实现范围内。
