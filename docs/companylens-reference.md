# 参考项目：看懂公司 · 黑白研究档案

2026-11-14。用户已确认当前 CompanyLens 原型是后续 App 的参考项目，尤其认可其样式；本文件是源码与样本探索记录。最终动线和技术架构需要后续评估，参考原型的实现不自动成为设计约束。

后续产品范围和参考要求以 [GitHub 产品规格 #3](https://github.com/GRHISMY/InvestmentShowcasePlatform/issues/3) 为准。

## 参考对象

- 工程 CompanyLens，iOS 显示名称“看懂公司”，界面品牌“黑白研究档案”。
- 版本 0.1.0，应用标识 `com.companylens.prototype`。
- 当前内容为格力研究，覆盖 2020—2025 全年及 2026 年前三季度，资料截至 2026-11-09。
- 图解标题“一家公司，连起来看。”；阅读稿 `gree-connected-study`，revision 2。六个全貌入口、十一个场景与八张图属于当前案例，其他公司不受这些数量约束。
- 本轮核对了入口、图解、完整报告、解释、计算、依据、PDF、阅读状态及正式数据。未执行新的构建、真机或模拟器验收；界面查看工具本次未能打开模拟器。

识别依据：[工程配置](https://github.com/GRHISMY/InvestmentShowcasePlatform/blob/a1c83c0/ios/CompanyLens/CompanyLens.xcodeproj/project.pbxproj)、[项目说明](https://github.com/GRHISMY/InvestmentShowcasePlatform/blob/a1c83c0/ios/CompanyLens/README.md)、[正式阅读稿](https://github.com/GRHISMY/InvestmentShowcasePlatform/blob/a1c83c0/ios/CompanyLens/Study/reading.json)。

## 值得保留的视觉气质

| 特征 | 参考中的表现 |
| --- | --- |
| 研究档案感 | 图解主阅读使用暖纸底、黑色主文字、灰色次级信息和细分隔线；完整报告偏白底 |
| 编辑式层级 | 衬线大标题与关键数值，常规正文，日期、编号及部分数值采用便于核对的等宽表现 |
| 克制图形 | 线条图标、细线关系、轻量边框与选中反馈；图形服务研究解释 |
| 明确主次 | 黑底浅字突出主要动作，章节小标、当前问题、图、解释和限制形成层次 |
| 阅读节奏 | 留白和分段帮助理解，计算显示原始输入，依据保留出处及原页入口 |

主要来源：[图解阅读](https://github.com/GRHISMY/InvestmentShowcasePlatform/blob/a1c83c0/ios/CompanyLens/App/VisualStudyReader.swift)、[通用图形](https://github.com/GRHISMY/InvestmentShowcasePlatform/blob/a1c83c0/ios/CompanyLens/App/StudyDiagram.swift)、[计算核对](https://github.com/GRHISMY/InvestmentShowcasePlatform/blob/a1c83c0/ios/CompanyLens/App/StudyCalculationReader.swift)、[完整报告](https://github.com/GRHISMY/InvestmentShowcasePlatform/blob/a1c83c0/ios/CompanyLens/App/ReadingViews.swift)。精确字号、颜色、品牌和控件仍可打磨，可读性优先。

## 当前真实阅读路径

1. 启动读取内置的一份研究；有配对阅读稿时进入图解，否则打开完整报告。当前没有研究库或 iCloud 获取入口。
2. 全貌显示研究摘要、覆盖期间、资料截止日期、图解覆盖范围、自由探索入口及开始或继续阅读。
3. 一个研究问题包含章节位置、标题、图、焦点说明、限制和深入核对入口。点击角色、关系或数据会改变当前焦点。
4. 解释、计算和依据是分支。计算显示结果、输入及限制；依据显示摘录、出处、物理页和反证标识。计算和依据均可直接进入 PDF，并不要求按固定顺序依次查看。
5. PDF 打开引用物理页，可以读前后文、缩放和重新定位引用页，然后返回依据或计算，再回到图中。
6. 回到全貌会保留图解场景与焦点；主线的前进与访问历史中的返回是不同动作。
7. 完整报告目前通过全貌页的“原报告”入口打开，内部提供总览、问题索引、继续追踪及判断、依据、计算和原页。它不是直接显示 Markdown 文件，也没有从图解焦点直接定位对应报告判断的联动。

来源：[App 入口](https://github.com/GRHISMY/InvestmentShowcasePlatform/blob/a1c83c0/ios/CompanyLens/App/CompanyLensApp.swift)、[图解阅读与依据/PDF](https://github.com/GRHISMY/InvestmentShowcasePlatform/blob/a1c83c0/ios/CompanyLens/App/VisualStudyReader.swift)、[解释](https://github.com/GRHISMY/InvestmentShowcasePlatform/blob/a1c83c0/ios/CompanyLens/App/StudyExplanationSheet.swift)、[计算](https://github.com/GRHISMY/InvestmentShowcasePlatform/blob/a1c83c0/ios/CompanyLens/App/StudyCalculationReader.swift)、[图解状态](https://github.com/GRHISMY/InvestmentShowcasePlatform/blob/a1c83c0/ios/CompanyLens/Core/VisualStudyState.swift)、[报告状态](https://github.com/GRHISMY/InvestmentShowcasePlatform/blob/a1c83c0/ios/CompanyLens/Core/ReaderState.swift)。

## 不能自动照搬的现状

- 固定单屏画布、按高度压缩整张图、小屏把解释另行展开。
- 固定的两列入口、分页数量、底部前后按钮、三个报告页签和多层弹层。
- 格力的章节主线与内容数量，以及具体节点布局和关系淡化方式。
- 摘录每段固定字数、计算逐项翻页、计算输入只打开第一处来源的做法。
- 图解和报告彼此分离的导航与位置保存，以及固定的内置研究目录。

这些是后续动线或技术评估的输入，既不是本轮已选技术方案，也不据此要求全部重写。

## 规格需要覆盖的体验边界

- 图解节选主线完成与完整研究阅读应能区分。
- “核对引用原页”与“继续读到上次 PDF 页”是两种目的，保存位置不能遮蔽明确引用。
- 多来源、多页依据和多输入计算都应能核对；没有数字的定性研究同样有效。
- 图解与完整报告允许一对多及没有对应图解的内容，不能强造对应关系。
- 长文、较大字体、窄屏和密集图不应靠挤小文字维持固定版式。
- 当前原型尚不具备目标中的 iCloud 研究库、多家公司入口、直接交叉阅读或跨设备位置同步。

## 参考基线识别

本轮对七份主要展示源码、四份 Core 源码及两份正式 JSON 样本，按相对名称和原始字节汇总得到 SHA-256：`6789f5146eb85d8c06b3032db63a3ac325b26f35ecbde2acbfac1e5439c59fcf`。它仅用于识别本次探索的十三份参考文件，不是整个工程或已安装 App 的发布哈希；未据此推送源码。

实施说明：以上源码证据固定到参考基线 `a1c83c0`。当前图解入口为[共用阅读宿主](../ios/CompanyLens/App/StudyReaderHost.swift)，导航与位置规则为[阅读核心](../ios/CompanyLens/Core/Reading/StudyReader.swift)，平台可见性观察为[原生滚动宿主](../ios/CompanyLens/App/ReadingScrollView.swift)。实施状态以 GitHub 子任务为准。
