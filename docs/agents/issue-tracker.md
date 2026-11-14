# Issue tracker: GitHub

本项目的任务与规格以 GitHub Issues 为准，仓库为 [GRHISMY/InvestmentShowcasePlatform](https://github.com/GRHISMY/InvestmentShowcasePlatform)。使用已登录的 `gh` CLI 操作。

## 仓库定位

本目录的 `origin` 指向 `https://github.com/GRHISMY/InvestmentShowcasePlatform.git`。每次会话首次创建任务前，运行 `gh repo view --json nameWithOwner` 核对目标，并在后续命令中显式使用 `--repo GRHISMY/InvestmentShowcasePlatform`。

任务只写入此用户仓库。若命令解析到其他仓库，先修正仓库定位；技能来源仓库不是本项目的任务追踪位置。

## 文件与状态约定

- 每份规格建立一个 Issue，每个实现任务另建一个 Issue，并关联到规格。
- 正文记录问题、范围、验收条件与必要上下文；讨论使用 Issue 评论。
- 分诊状态使用 GitHub 标签，映射见 `docs/agents/triage-labels.md`。
- 未完成任务保持 open；完成时说明结果并以 completed 原因关闭；不予实施时使用 not_planned 原因关闭。
- `.scratch/` 保留本地历史归档、实验和验证产物；新规格、任务及分诊状态写入 GitHub。

## 技能操作对应关系

以下命令均需加上 `--repo GRHISMY/InvestmentShowcasePlatform`：

- 创建任务：`gh issue create --title "标题" --body-file /tmp/issue-body.md`。多行正文先写入临时文件，保留真实换行。
- 读取任务：`gh issue view <number> --json number,title,body,labels,comments,state,assignees`。
- 列出任务：`gh issue list --state open --limit 100 --json number,title,body,labels,assignees`，按需使用 `--label`、`--state` 过滤；结果达到上限时继续分页检索。
- 修改正文：`gh issue edit <number> --body-file /tmp/issue-body.md`。
- 追加讨论：`gh issue comment <number> --body-file /tmp/comment.md`。
- 添加或移除标签：`gh issue edit <number> --add-label "标签"` 或 `--remove-label "标签"`。
- 完成：先记录完成依据，再运行 `gh issue close <number> --reason completed`。已关闭任务需要补充说明时，单独添加评论。
- 不予实施：说明原因后运行 `gh issue close <number> --reason "not planned"`。

技能要求 “publish to the issue tracker” 时，创建 GitHub Issue；要求 “fetch the relevant ticket” 时，通过编号或 URL 读取对应 Issue。

## 父子任务与依赖

- 新建子任务：`gh issue create --parent <parent> ...`；关联已有任务：`gh issue edit <parent> --add-sub-issue <child>`。均显式指定本仓库。
- 子任务不受支持时，在子任务正文顶部写 `Part of #<parent>`，并在父任务正文维护任务清单。
- 阻塞关系优先使用 GitHub 原生依赖：`gh issue edit <child> --add-blocked-by <blocker>`；创建时也可用 `--blocked-by <n>,<n>`。
- 查询未关闭阻塞数：`gh api repos/GRHISMY/InvestmentShowcasePlatform/issues/<n> --jq .issue_dependencies_summary.blocked_by`，0 表示没有未关闭的阻塞。
- 原生依赖不可用时，在正文顶部写 `Blocked by: #<n>, #<n>`；所有阻塞任务关闭后才解除阻塞。

## Pull requests as a triage surface

**PRs as a request surface: no.**

## Wayfinding operations

使用 `/wayfinder` 时，地图和子任务都保存在 GitHub：

- 地图：一个带 `wayfinder:map` 标签的 Issue，正文包含 Notes / Decisions-so-far / Fog。
- 子任务：关联到地图的 sub-issue，带 `wayfinder:<type>` 标签，type 为 research / prototype / grilling / task。标签在首次使用时按需创建。
- 子任务关联不受支持时，地图正文维护任务清单，子任务顶部写 `Part of #<map>`。
- 从地图的 open 子任务中，排除仍有未关闭阻塞或已分配负责人的任务，按地图顺序选取第一个。
- 开始前用 `gh issue edit <n> --add-assignee @me` 认领。
- 解决后将答案追加为评论，关闭子任务，并在地图的 Decisions-so-far 中追加结论摘要与任务链接。

## 迁移记录

2026-11-14 从本地 Markdown 切换为 GitHub Issues：

- 原 `.scratch/study-json-pipeline/spec.md` → [规格 #1：研究关系与讲解意图](https://github.com/GRHISMY/InvestmentShowcasePlatform/issues/1)。
- 原 `.scratch/study-json-pipeline/issues/01-contract-compiler.md` → [任务 #2：契约、发布、格力迁移与原生消费者](https://github.com/GRHISMY/InvestmentShowcasePlatform/issues/2)，已关联为 #1 的子任务。

两项均依据原有 `Resolution: completed` 和验收记录，以 closed/completed 归档；原始接口约定已附于 #2。此后状态、正文修订和讨论以 GitHub 为准，本地原件仅保留历史。
