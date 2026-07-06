# 工程任务自适应 HTML 汇报设计

## 目标

Symphony 需要一种让 agent 根据具体工程任务生成合适 HTML 汇报的机制。它不是固定模板，也不是数据 dashboard 生成器，而是一个工程汇报 artifact 工作流：agent 先理解任务、证据和读者需求，再选择合适的叙事结构，最终生成可打开、可审查、可追溯的 HTML 页面。

第一版目标：

1. 建立一套本地 HTML artifact 协议，作为工程任务汇报的主形态。
2. 沉淀一个 `engineering-html-report` skill，让 agent 按任务类型自适应设计报告。
3. 把事实来源、报告设计、HTML 输出和质量校验分层，避免 agent 自由发挥时编造事实。
4. 支持功能实现、bug 修复、代码审查、调研、批量 workflow、故障诊断等不同汇报范式。
5. 生成的报告必须优先回答：做了什么、完成了吗、怎么验证、风险在哪、证据在哪里。

## 背景和参考

### Claude Code Artifacts

Claude Code Artifacts 提供了一个值得复刻的形态：Claude 把会话输出写成本地 HTML 或 Markdown 文件，再由产品层发布成可打开的 artifact。官方文档列举了 PR walkthrough、方案对比、调查时间线和工作进度 checklist 等用途。

Symphony 不应依赖 Claude Code Artifacts 作为默认能力，因为它绑定 Claude Code 会话、Anthropic 登录和发布入口。但它验证了一个关键模式：

```text
agent 生成任务专属 HTML artifact
系统保存、校验、发布并把入口回写到工作流
```

参考：https://code.claude.com/docs/en/artifacts

### Claude Skills 的 visual output / review viewer

Claude Skills 文档中的 visual output 模式展示了 skill 可以携带脚本，扫描项目后生成自包含 HTML 并打开浏览器检查。review viewer 示例则说明 HTML 可以作为评审界面，而不只是展示页。

这对 Symphony 的启发是：报告生成应该是一个 skill 工作流，而不是一组写死模板。skill 可以规定输入、输出、质量规则和验证脚本，但让 agent 根据任务决定页面结构。

参考：https://docs.anthropic.com/en/docs/claude-code/skills

### 工程汇报范式

成熟参考不是单一 HTML 工具，而是一组工程写作范式：

- PR / release note：适合功能实现、影响范围、验证和风险说明。
- ADR / MADR：适合方案、架构、取舍和后续演进。
- SRE postmortem：适合故障诊断、失败批次、根因、时间线和行动项。
- Code review report：适合 findings first、严重程度、证据和建议。
- Test report / Allure：适合结果、附件、重试、日志和证据索引。

Symphony 应借鉴这些范式的结构，而不是复制它们的模板。

## 非目标

1. 不实现 Linear Inbox 投递。
2. 不设计 root issue 下派生 issue 评论同步机制；该机制可以独立处理。
3. 不把 dashboard 作为报告的前提。
4. 不做固定 HTML 模板系统。
5. 不做以数据图表为中心的 dashboard generator。
6. 不依赖 Claude Code Artifact、Quarto、Observable、Allure 或任何单一外部工具。
7. 不让 agent 自行伪造 Git sha、测试结果、issue 状态、artifact hash 或合并事实。

## 核心原则

1. **HTML 是主阅读面，JSON 是事实层**
   HTML 用来组织工程叙事、证据导航和人类判断；事实来源应来自结构化上下文包和已存在 artifact。

2. **agent 是报告设计师，不是事实来源**
   agent 可以判断报告应该怎么读、哪些信息应该置顶、哪些证据应折叠，但不能发明完成状态、测试结果或链接。

3. **任务类型决定报告结构**
   功能实现、bug 修复、审查、调研、批量 workflow 和故障诊断不能套同一张表。skill 必须要求 agent 先选择或组合报告范式。

4. **首屏必须有判断价值**
   用户打开报告后，应立即知道整体结论、是否需要介入、最重要证据在哪里。报告不能把用户推到日志和长表格里自己分析。

5. **证据可追踪但不淹没正文**
   关键结论必须能跳回 issue result、执行摘要、测试日志、diff、PR、截图或原始 artifact。长日志和大段输出默认折叠。

6. **生成后必须校验**
   HTML 是否存在、是否自包含、是否覆盖关键任务、链接是否有效、异常是否置顶，都应有规则检查。不能相信 agent 的“已完成”自报。

## Artifact 协议

每次报告生成使用一个稳定目录：

```text
.symphony/reports/<report-id>/
  report_context.json
  report_brief.json
  index.html
  summary.md
  manifest.json
  assets/
```

### report_context.json

`report_context.json` 是事实包。它由 Symphony 控制层、运行 agent 或报告生成前置脚本收集。第一版可以是宽松 schema，但必须区分事实和解释。

示例：

```json
{
  "schema_version": 1,
  "subject": {
    "kind": "workflow",
    "id": "YQE-700",
    "title": "实现工程 HTML 汇报机制",
    "links": []
  },
  "task": {
    "original_request": "...",
    "task_type_hint": "feature_implementation",
    "success_criteria": []
  },
  "work_items": [
    {
      "id": "YQE-701",
      "title": "...",
      "status": "completed",
      "result": {
        "outcome": "completed",
        "summary": "...",
        "evidence": []
      },
      "artifacts": []
    }
  ],
  "changes": {
    "commits": [],
    "files": [],
    "diff_refs": []
  },
  "verification": {
    "commands": [],
    "test_results": [],
    "logs": []
  },
  "risks": [],
  "open_questions": [],
  "raw_artifacts": []
}
```

### report_brief.json

`report_brief.json` 是 agent 在写 HTML 前生成的报告设计说明。它让报告结构可审查、可复用，也能避免 agent 直接进入排版。

示例：

```json
{
  "schema_version": 1,
  "report_kind": "feature_implementation",
  "audience": "workflow owner",
  "reader_goal": "快速判断功能是否实现、验证是否充分、风险在哪里",
  "top_questions": [
    "完成了吗？",
    "改了什么？",
    "怎么验证？",
    "还需要我看哪里？"
  ],
  "sections": [
    "结论",
    "用户可见变化",
    "核心实现",
    "验证结果",
    "风险和后续",
    "证据索引"
  ],
  "attention_policy": "失败、阻塞、未验证和需要人工决策的内容置顶"
}
```

### manifest.json

`manifest.json` 描述输出结果和质量状态。

```json
{
  "schema_version": 1,
  "report_id": "YQE-700-20260706",
  "generated_at": "2026-07-06T12:00:00+08:00",
  "generator": "engineering-html-report",
  "context_hash": "sha256:...",
  "brief_path": "report_brief.json",
  "html_path": "index.html",
  "markdown_path": "summary.md",
  "quality": {
    "status": "pass",
    "checks": {}
  }
}
```

## `engineering-html-report` Skill 设计

这个 skill 的职责是把事实包变成任务专属 HTML 汇报。它不是模板 skill，而是报告作者 skill。

### 输入

skill 接收：

- `report_context.json`
- 用户额外要求
- 可选的既有报告样例
- 可选的品牌或视觉约束

### 工作流

1. **读取事实包**
   区分任务目标、工作项、结果、验证、风险、证据和原始材料。

2. **判断报告范式**
   选择一个主范式，也可以组合多个范式。例如“功能实现 + 批量 workflow”。

3. **生成 report brief**
   写出读者、核心问题、首屏信息、章节结构、证据入口和异常策略。

4. **生成 HTML**
   写出单页、自包含、可本地打开的 `index.html`。页面结构由任务决定，而不是固定模板。

5. **生成 Markdown 摘要**
   写出短 `summary.md`，供 Linear、PR、聊天或纯文本归档引用。

6. **自检和修正**
   检查覆盖率、证据链接、外部依赖、异常置顶、长日志折叠和可读性。

### 输出

```text
index.html
summary.md
report_brief.json
manifest.json
```

### HTML 约束

1. 单页静态 HTML。
2. CSS 和必要 JS 内嵌。
3. 不请求外部网络资源。
4. 不使用远程字体、远程脚本或远程样式。
5. 可直接从文件系统打开。
6. 有目录和锚点。
7. 长日志、长 diff、原始 JSON 默认折叠。
8. 关键结论附近必须有证据入口。
9. 页面首屏必须包含结论、状态和需要关注项。

## 报告范式库

skill 应提供范式指导，但不强制固定模板。

### 功能实现报告

适合 feature / implementation issue。

推荐结构：

```text
结论
用户可见变化
核心实现
修改文件和模块
验证结果
风险和后续
证据索引
```

### Bug 修复报告

推荐结构：

```text
结论
症状和影响
根因
修复点
回归验证
残余风险
证据索引
```

### 代码审查报告

推荐结构：

```text
审查结论
Findings first
严重程度和影响
文件/行证据
建议修复
测试缺口
```

### 调研/方案报告

推荐结构：

```text
推荐结论
问题背景
候选方案
取舍分析
证据和来源
不确定性
下一步
```

### 批量 Workflow 报告

推荐结构：

```text
整体状态
需要关注
Issue 结果矩阵
执行时间线
验证和证据索引
失败/返工/阻塞详情
后续动作
```

### 故障诊断报告

推荐结构：

```text
当前结论
影响范围
时间线
根因或候选根因
已执行修复
验证结果
预防动作
```

## 质量校验

第一版可以用规则检查保证下限。

必需检查：

1. `index.html` 存在且非空。
2. `summary.md` 存在且长度可控。
3. `report_brief.json` 存在，且说明报告范式和读者目标。
4. HTML 不包含外部 `<script src>` 或 `<link href>`。
5. 每个关键 work item 至少在 HTML 中出现一次。
6. 每个 failed / blocked / needs_human / needs_rework 项出现在需要关注区域。
7. 每条关键结论附近有证据链接或证据说明。
8. 长日志和原始 JSON 不直接铺在正文中。
9. 如果存在验证命令，报告必须展示验证结果。
10. 如果没有验证，报告必须显式标注“未验证”或“验证缺失”。

可选视觉检查：

1. 用浏览器打开 HTML。
2. 截图确认页面非空。
3. 检查首屏可见区域包含结论和需要关注项。
4. 检查窄屏下不发生明显重叠。

## 与 Symphony 的集成边界

### 控制层职责

Symphony 控制层负责：

1. 生成或收集 `report_context.json`。
2. 提供 artifact、issue、Git、验证和日志路径。
3. 调用报告 skill 或报告 agent。
4. 保存输出目录和 manifest。
5. 运行质量校验。
6. 把报告路径交给通知、dashboard 或发布 adapter。

### Agent 职责

报告 agent 负责：

1. 理解任务和读者需求。
2. 选择报告范式。
3. 生成 `report_brief.json`。
4. 写 `index.html` 和 `summary.md`。
5. 根据校验失败原因修正报告。

### 发布和通知职责

发布不是本设计重点。后续可以接：

```text
local_file
local_http
lark_html_publish
github_pages
object_storage
claude_artifact
```

Linear、dashboard、PR 或聊天只负责放入口，不负责承载完整报告。

## MVP

第一版只做最小闭环：

1. 写入 `engineering-html-report` skill。
2. 准备一个示例 `report_context.json`。
3. 让 agent 基于该事实包生成 `report_brief.json`、`index.html`、`summary.md` 和 `manifest.json`。
4. 实现一个校验脚本，检查 HTML 自包含、work item 覆盖、异常置顶和证据入口。
5. 提供 2 个 golden 示例：
   - 功能实现报告。
   - 批量 workflow 含失败/返工报告。

不在 MVP 中做：

1. Linear Inbox。
2. root issue 评论机制。
3. dashboard 嵌入。
4. 外部发布。
5. 多页静态站点。

## 风险和控制

1. **报告像模板填空**
   控制：要求先生成 report brief，解释读者目标和章节选择。

2. **报告像日志墙**
   控制：长日志、diff、原始 JSON 默认折叠；首页必须先给结论。

3. **agent 编造事实**
   控制：事实只能来自 `report_context.json` 和明确 artifact；校验器检查链接和覆盖率。

4. **HTML 漂亮但不可用**
   控制：浏览器打开、截图、链接检查和窄屏检查作为可选质量门。

5. **过早产品化**
   控制：先做本地 artifact 和 skill，不急着接发布、dashboard 和 Linear。

6. **范式库僵化**
   控制：范式是建议，不是模板。agent 可以组合和调整，但必须在 brief 中说明原因。

## 已定决策

1. 当前重点是工程任务 HTML 汇报，不做 Linear Inbox。
2. root issue 评论同步机制独立处理，不纳入本设计 MVP。
3. Symphony 自己保存本地 artifact，不依赖 Claude Code Artifact 产品能力。
4. HTML 是主汇报形态，Markdown 是短摘要形态。
5. 报告结构由 agent 按任务自适应选择。
6. `report_context.json` 是事实层，`report_brief.json` 是报告设计层，`index.html` 是阅读层。
7. `engineering-html-report` 应作为 skill/工作流沉淀，而不是硬编码模板。
8. 质量校验是必需环节；校验失败的报告不能作为正式汇报入口。
