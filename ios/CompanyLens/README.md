# 看懂公司 · 黑白研究档案

SwiftUI/PDFKit原生阅读器。从同一正式发布包读取`research.json`与`reading.json`，展示公司关系、图上解释、计算与原始PDF。研究与讲解意图的约定见[数据契约](../../docs/company-study-data.md)。

当前为格力正式r4报告：2020—2025全年及2026年前九个月，资料截至2026-11-09。原25条判断、104条事实与22项计算保持不变，补入有原页支持的主体关系。11个场景与8张图是这次研究的选择，不规定其他公司的数量或主线。

主阅读采用固定画布，前进、回退、回到全貌及本机续读保留焦点。点选图后解释、限制与证据一起变化；关键未知仍在主线可见。计算与原始PDF分别打开，再回到原位置；完整报告通过独立入口深入阅读。较小窗口可在独立解释层阅读完整正文，主画面保留关键限制及导航。

## 打开和构建

用完整Xcode打开`CompanyLens.xcodeproj`，运行共享scheme `CompanyLens`。最低iOS17，Mac预览最低macOS14。真机安装需配置自己的开发Team，本轮验收使用iPhone模拟器。

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
- `VisualStudyState`：阅读导航、焦点与本机书签；`ReaderState`：完整报告及证据/计算/PDF返回位置。
- `StudyDiagram`和SwiftUI：按通用图形数据绘制、适配屏幕；公司名、金融数字和解释不写入Swift。
- PDFKit：读取完整原件并定位物理页，不用截图代替原件。

旧包没有阅读稿时继续全文阅读；损坏或错配的阅读稿明确报错。SQLite是研究时可重建的检索层，App离线阅读不依赖它。估值、交易、实时更新、云同步和上架不属于当前实现。

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

本轮实际检查及范围见[验收记录](../../.scratch/study-json-pipeline/验收记录.md)。`Verification`中的旧记录保留作历史，不能冒充本轮验证。
