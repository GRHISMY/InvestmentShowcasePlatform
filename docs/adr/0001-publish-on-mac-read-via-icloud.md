---
status: accepted
---

# Mac 发布研究包，iCloud 传递，iPhone 展示

Mac、iCloud 与 iPhone 的产品分工、目录接入和同步方案已获用户确认，进入实施。

Mac mini 沿用现有研究、SQL 与正式发布流程，将产出的完整研究包放入专用 iCloud 研究库；iPhone 从 iCloud 获取这些研究包，负责图解、完整报告、计算与原始依据的阅读展示。这样保留分析端与展示端的清晰分工：Mac 是研究内容的发布端，手机不维护第二份研究分析或发布逻辑。

这一决定采用同一 Apple 账号下的普通 iCloud Drive 专用研究文件夹，替代先前讨论的独立服务器下载方案。Mac 直接发布成果；iPhone 首次通过系统文件界面选定目录并保存访问授权。个人阅读记录也经 iCloud 跨设备同步，但与研究包分开保存，避免研究更新与阅读位置互相覆盖。

整体方案见[展示 App 技术方案](../display-app-technical-plan.md)，实施与实际验证结果记录在 GitHub 子任务中；此前候选保留在[架构探索备忘](../display-app-architecture.md)。
