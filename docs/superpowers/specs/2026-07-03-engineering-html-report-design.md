# 工程任务 HTML 汇报机制设计

## 目标

Symphony 需要在自动执行多 issue workflow 后，给人一个稳定、可回看、能快速判断结果质量的汇报入口。这个入口不能只依赖 Linear issue 被标记为 Done，也不能要求用户逐个翻派生 issue 评论。

第一版目标是建立一套 Symphony 自己可控的 artifact/report 协议：

1. 每个 root workflow 和重要 issue 都可以生成本地汇报 artifact。
2. 本地汇报至少包含 HTML 和 Markdown 两种形式，其中 HTML 是主形态。
3. Linear 只承载重点摘要、状态同步和本地/发布报告链接。
4. 派生 issue 完成后，root issue 能看到增量状态，而不是只在派生 issue 里留下结果。
5. 报告必须基于 Symphony 控制层事实和 artifact，不把 agent 最终回复当作权威来源。

## 背景和参考

### Claude Code Artifacts

Claude Code 的 artifacts 提供了一个值得复刻的形态：agent 把会话输出写成 HTML 或 Markdown 文件，再通过产品层发布成可打开的页面。它适合 PR walkthrough、方案对比、调查时间线和长任务进度展示。

Symphony 不能直接依赖 Claude Code artifact 作为统一能力，因为它绑定 Claude Code 会话、Anthropic 登录和 claude.ai 发布入口。但它验证了一个重要模式：

```text
agent 生成任务专属 HTML artifact
系统保存、校验、发布并把链接回写到任务系统
```

### Claude Skills 的 visual output / review viewer

Claude Skills 文档里的 visual output 模式强调 skill 可以携带脚本，扫描项目后生成自包含 HTML，并打开浏览器检查。review viewer 示例则说明 HTML 可以作为质量评审界面，而不只是静态展示页。

这对 Symphony 的启发是：汇报不应该只是固定模板，而应该是一个生成工作流。不同任务类型可以选择不同报告范式，但最终遵守同一份 artifact 协议。

### ADR / SRE Postmortem / Allure

现有工程实践可以提供报告结构参考：

- ADR / MADR：适合方案、架构、取舍类任务，强调背景、决策、方案和影响。
- Google SRE Postmortem：适合故障、失败批次和诊断任务，强调影响、根因、时间线和后续行动。
- Allure：适合测试和批量执行结果，强调结果文件、附件、历史、重试和证据链接。

Symphony 不需要复制这些工具，但需要吸收它们的结构原则：汇报必须把结论、证据、风险和后续动作放在同一页面中。

## 非目标

1. 不把 Claude Code artifact 当作必需依赖。
2. 不在第一版实现通用静态站点或多路由应用。
3. 不要求 Linear 成为完整报告承载面。
4. 不把 dashboard 作为唯一入口；dashboard 可以消费报告，但报告 artifact 本身应独立存在。
5. 不让 agent 自行伪造 Git sha、checkpoint、artifact hash 或最终合并事实。

## 核心原则

1. **控制层事实优先**
   报告事实来源优先级为 workflow registry、issue result、execution summary、Git adapter 事实、验证日志和 Linear 快照。agent 的自然语言回复只能作为辅助材料。

2. **HTML 是主汇报面**
   HTML 用于呈现复杂结构、时间线、证据索引、过滤、折叠和对比。Markdown 用于 Linear 摘要、纯文本归档和快速 skim。

3. **Linear 只放重点和入口**
   Linear 评论应该回答这几个问题：当前批次进度如何、哪些 issue 已完成、哪些需要注意、完整报告在哪里。不要把完整日志墙塞进 Linear。

4. **每个派生 issue 完成后同步 root 状态**
   派生 issue 完成时，Symphony 应把精简状态同步到 root issue 或 root workflow 记录中，让 root issue 成为批次回看入口。

5. **报告可重复生成**
   同一个 workflow 可以在运行中多次刷新报告。报告需要有 manifest 记录版本、生成时间、输入事实包 hash 和发布目标。

6. **发布是 adapter，不是报告生成的一部分**
   local file、local HTTP、Lark、GitHub Pages、对象存储、Claude artifact 都只是发布 adapter。核心 artifact 必须在本地文件系统中先成立。

## Artifact 目录协议

每个 root workflow 使用一个稳定目录：

```text
.symphony/reports/<root-workflow-id>/
  manifest.json
  report_context.json
  index.html
  summary.md
  assets/
  snapshots/
```

如果需要给单个 issue 生成报告，可以使用：

```text
.symphony/reports/issues/<issue-id>/
  manifest.json
  report_context.json
  index.html
  summary.md
```

### manifest.json

`manifest.json` 记录报告自身元数据：

```json
{
  "schema_version": 1,
  "report_id": "root-YQE-700",
  "report_type": "root_workflow",
  "root_issue_id": "YQE-700",
  "generated_at": "2026-07-03T16:00:00+08:00",
  "generator": "engineering-html-report",
  "context_hash": "sha256:...",
  "html_path": "index.html",
  "markdown_path": "summary.md",
  "publish_targets": [
    {
      "kind": "local_file",
      "url": "file:///..."
    }
  ],
  "status": "generated"
}
```

### report_context.json

`report_context.json` 是报告生成事实包，控制层负责构造。第一版最小结构：

```json
{
  "schema_version": 1,
  "report_type": "root_workflow",
  "root_issue": {
    "id": "YQE-700",
    "identifier": "YQE-700",
    "title": "...",
    "url": "https://linear.app/..."
  },
  "workflow": {
    "status": "running",
    "started_at": "...",
    "updated_at": "...",
    "target_branch": "main",
    "candidate_branch": "symphony/YQE-700/candidate"
  },
  "nodes": [
    {
      "node_key": "implementation",
      "issue_id": "YQE-701",
      "task_type": "implementation",
      "status": "completed",
      "outcome": "completed",
      "summary": "...",
      "evidence": [],
      "artifact_paths": [],
      "branch": "...",
      "checkpoint_id": "checkpoint-001"
    }
  ],
  "reviews": [],
  "checkpoints": [],
  "risks": [],
  "open_questions": [],
  "links": []
}
```

控制层可以从现有数据填充这些字段：

- `Workflow.Registry`
- `.symphony/issue_result.json`
- `Workflow.ExecutionSummary`
- `Workflow.GitAdapter`
- Linear issue read snapshot
- observability runtime snapshot

## HTML 报告形态

第一版 HTML 应该是自包含单页：

1. 不依赖外部 CSS、JS、字体或网络请求。
2. 支持直接从文件系统打开。
3. 支持浏览器截图和基本 DOM 校验。
4. 对长文本、日志、证据和 diff 链接使用折叠区域。
5. 页面顶部先给结论，不把用户拖进细节。

建议信息架构：

```text
标题区：root issue、批次状态、更新时间、完整性提示
结论区：已完成/失败/阻塞/需人工关注数量
关键变化：本批次实际交付了什么
Issue 表格：每个节点的状态、结果、证据、链接
时间线：调度、执行、审查、合并、发布事件
证据索引：artifact、测试、日志、PR、diff、截图
风险和待办：open questions、needs_rework、needs_human
发布信息：本地路径、外部链接、Linear 回写位置
```

不同任务可以套不同“报告范式”，但页面外壳保持一致：

- 实现任务：目标、文件变化、测试、风险、后续。
- 修复任务：症状、根因、修复、回归验证。
- 调研任务：问题、结论、证据、未确认项。
- 批量 workflow：issue 矩阵、状态统计、证据索引、异常清单。
- 审查任务：审查对象、发现、严重程度、采纳状态。

## Markdown 摘要形态

`summary.md` 不是 HTML 的降级版，而是给 Linear 和纯文本归档使用的短摘要。建议包含：

```text
# Workflow 汇报：<root issue>

状态：...
更新时间：...
完整报告：...

## 结论
- ...

## Issue 状态
| Issue | 状态 | 结果 | 证据 |

## 需要关注
- ...
```

Markdown 应控制长度，避免在 Linear 中刷屏。完整证据留给 HTML。

## Linear 集成

### Inbox 约束

Linear Inbox 本质是 Linear 的通知中心，不是通用消息投递队列。公开资料显示用户通常通过订阅、被提及、被分配、issue 活动等事件收到 Inbox 通知。第一版不假设存在可直接创建 Inbox 通知的 API。

因此 Symphony 的设计应优先使用可靠机制：

1. 在 root issue 下创建或更新汇总评论。
2. 在评论中提及需要通知的人或团队，前提是配置允许。
3. 保持 root issue 订阅者能通过正常 issue 活动收到通知。
4. 如果后续 GraphQL schema 确认有 notification/inbox 写接口，再作为可选 adapter 接入。

### Root issue 汇总评论

root issue 下需要有一条稳定汇总评论。第一版可以先追加评论，后续再考虑更新同一条评论。

评论内容应短：

```markdown
## Symphony 汇报更新

状态：运行中 / 已完成 / 需要关注
进度：5/7 issue completed，1 needs_rework，1 blocked
完整报告：<link>

最新完成：
- YQE-701 implementation：completed，证据 3 项
- YQE-702 review：needs_rework，发现 2 个问题

需要关注：
- YQE-704 缺少验证证据
```

### 派生 issue 完成后的同步

每个派生 issue 被控制层接受 `issue_result.json` 后，Symphony 应执行：

1. 更新 registry 中对应 node 的 `issue_result`。
2. 刷新 root workflow 的 `report_context.json`。
3. 重新生成或增量更新 HTML/MD 报告。
4. 在 root issue 发布短状态更新或更新汇总评论。
5. 在派生 issue 保留本 issue 的完成评论。

这样 root issue 可以成为批量任务入口，而派生 issue 仍然保留细节证据。

## 生成器设计

新增一个逻辑能力：`engineering-html-report`。它可以先作为内部模块实现，后续再沉淀为 Codex/Symphony skill。

职责：

1. 读取 `report_context.json`。
2. 判断报告类型和任务范式。
3. 生成 `index.html` 和 `summary.md`。
4. 输出 `manifest.json`。
5. 做基本验证：HTML 可打开、关键字段存在、链接目标存在、没有外部依赖。

建议模块边界：

```text
SymphonyElixir.Workflow.ReportContext
  从 registry、execution summary、issue result、Linear snapshot 构造事实包

SymphonyElixir.Workflow.ReportGenerator
  把事实包渲染成 HTML/MD/manifest

SymphonyElixir.Workflow.ReportPublisher
  发布到 local_file、local_http 或后续外部 adapter

SymphonyElixir.Workflow.ReportNotifier
  把摘要和链接写回 Linear root issue
```

## 验证要求

第一版最低验证：

1. `report_context.json` schema 校验通过。
2. `manifest.json` schema 校验通过。
3. `index.html` 包含 root issue、状态统计、issue 表格和证据链接。
4. `index.html` 不包含外部 `http://` 或 `https://` 资源依赖。
5. `summary.md` 长度可控，并包含 HTML 报告链接。
6. Linear 评论生成函数有测试覆盖，确认不会输出完整日志墙。

如果运行环境有浏览器能力，应增加截图/DOM 检查：

1. HTML 页面非空。
2. 关键区域可见。
3. 长 issue 标题不会挤压布局。
4. 移动宽度下表格可横向滚动或转为列表。

## 发布 adapter

第一版建议只实现：

```text
local_file
local_http
```

后续可扩展：

```text
lark_html_publish
github_pages
static_host
object_storage
claude_artifact
```

`claude_artifact` 只能在 Claude backend 可用时作为可选发布 adapter，不能成为 Symphony 默认能力。

## 和 Dashboard 的关系

Dashboard 可以消费报告，但不是报告机制的前提。

建议关系：

1. report artifact 是持久事实和展示文件。
2. dashboard 是运行时入口，可以列出最近 reports、嵌入 HTML、显示生成状态。
3. Linear 是通知和追溯入口，指向 report。

这样 dashboard 不在线时，报告仍然存在；Linear 链接不失效时，用户能从 root issue 回到完整上下文。

## 分阶段落地

### 阶段 1：设计和协议

- 写入本设计文档。
- 明确 artifact 目录、manifest、report_context、HTML/MD 形态。
- 明确 Linear Inbox 只作为通知效果，不假设直接投递 API。

### 阶段 2：本地 artifact MVP

- 新增 ReportContext 和 ReportGenerator。
- 从一个 root workflow registry 生成 `report_context.json`。
- 生成自包含 `index.html` 和 `summary.md`。
- 添加 schema/HTML 字符串级测试。

### 阶段 3：Linear root 汇总

- 派生 issue 完成后刷新报告。
- root issue 下追加或更新汇总评论。
- 评论只包含重点、状态和报告链接。

### 阶段 4：发布和 Dashboard 接入

- 增加 local HTTP 或静态发布 adapter。
- Dashboard 展示 report 列表和最近 workflow 报告入口。
- 后续根据需要接入 Lark/GitHub Pages/对象存储。

### 阶段 5：报告范式库

- 按任务类型扩展报告布局。
- 支持实现、修复、调研、审查、批量 workflow、事故诊断。
- 把生成规则沉淀为可复用 skill。

## 关键风险

1. **Linear Inbox API 不确定**
   第一版不能承诺直接投递 Inbox。通过 root issue 评论、mention 和订阅行为实现通知效果。

2. **报告变成新日志墙**
   HTML 可以丰富，但首页必须先给结论和异常；长日志默认折叠。

3. **事实来源漂移**
   agent 评论、Linear 状态、registry、Git 事实可能不一致。报告必须标出来源和生成时间，以控制层事实为准。

4. **本地链接不可分享**
   local file 对单机可用，但跨设备不可用。发布 adapter 需要作为后续重点，不应阻塞本地 MVP。

5. **模板僵化**
   固定模板会让复杂任务变难读。第一版可以有统一外壳，但内容区应由任务范式决定。

## 已定决策

1. Symphony 自己实现 artifact/report 协议，不直接依赖 Claude Code artifact。
2. HTML 是主汇报形态，Markdown 是短摘要和 Linear 回写形态。
3. Linear root issue 必须成为批次回看入口。
4. 派生 issue 完成后应同步 root workflow 状态并刷新报告。
5. Inbox 先按 Linear 通知机制间接触发，不假设直接写 Inbox。
6. 报告生成和发布分层，发布 adapter 可替换。
7. Dashboard 可以接入报告，但报告 artifact 不依赖 Dashboard 存在。
