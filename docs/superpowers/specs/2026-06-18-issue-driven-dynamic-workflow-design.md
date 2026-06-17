# Issue 驱动的动态任务编排设计

## 目的

Symphony 当前的核心行为是从 Linear 轮询符合条件的 issue，为每个 issue 创建 workspace，然后启动 agent 执行。这能把“手动启动 agent”变成 daemon 化流程，但它还不是完整的任务编排：复杂任务容易被一次 agent 会话压扁，执行结束后也经常无法判断结果应该算完成、待审查、需要返工、需要重规划，还是只是一段可供后续使用的情报。

本设计的目标是把 Symphony 从“检测到 issue 后执行”升级为“以 issue 为载体的动态任务编排系统”。用户仍然主要通过 Linear 创建 issue；Symphony 负责判断这个 issue 是否需要规划、拆分、执行、审查、返工、重规划或人工输入，并把任务推进到一个有意义的收口状态。

核心目标是节省人的注意力。系统应该默认自动推进，只有在低置信度、高风险、权限不足、执行失败、需求含糊或无法判断结果时才请求人介入。

## 设计原则

Issue 是人和系统共享的任务载体。调研、设计、实现、审查、返工、审批等工作都可以用普通 Linear issue 表示；Symphony 在这些 issue 之上解释关系、任务类型、工作流语义和依赖顺序。

Symphony 不应强依赖 Linear sub-issue。第一版可以使用普通 issue 加评论、标签、链接和 blocker 关系表达编排关系；以后如果 Linear sub-issue 支持成熟，可以把内部关系投影成更好的 Linear 层级体验。

规划和审查是工作流阶段，不天然等同于独立 agent，也不天然等同于独立 issue。它们可以由模型调用完成，也可以物化成普通 Linear issue。无论表现形式如何，规划必须输出结构化 Workflow Plan，执行必须输出 Completion Packet，审查必须输出 Review Decision。

执行者负责产生内容，控制层负责推进流程。下游 agent 消费上游 Completion Packet 的语义内容；Symphony 控制层只校验结构化控制信号，并据此解锁下游、创建返工、触发重规划、请求人工输入或收口 root issue。

## 核心概念

### Issue Node

`Issue Node` 对应一个 Linear issue。它可以是用户创建的 root issue，也可以是 Planner 派生出的普通 issue。

Issue Node 不使用单一 `role` 字段承载所有语义，而是拆成三个正交维度：

- 关系位置：`root`、`derived`、`follow_up`、`rework_of`
- 任务类型：`research`、`design`、`implementation`、`review`、`approval`、`maintenance`
- 工作流语义：`intake`、`executable`、`gate`、`closure`、`blocked_waiting_input`

示例：

```yaml
issue: SYM-100
relation: root
task_type: implementation
workflow_semantics: intake
```

这表示 `SYM-100` 是用户提出的根任务，目标偏实现类，但当前作为入口和总控 issue。

```yaml
issue: SYM-103
relation: derived
derived_from: SYM-100
task_type: implementation
workflow_semantics: executable
```

这表示 `SYM-103` 是从 `SYM-100` 派生出的实现任务，可以被 agent 执行。

```yaml
issue: SYM-104
relation: derived
derived_from: SYM-100
task_type: review
workflow_semantics: gate
reviews: SYM-103
```

这表示 `SYM-104` 在 Linear 里仍是普通 issue，但它的完成结果会被 Symphony 解释为对 `SYM-103` 的审查决策。

### Workflow Plan

`Workflow Plan` 是 planning 阶段对 root issue 的规划产物。它必须是结构化输出，经过 Symphony 控制层校验后才能落地。

第一版支持三类计划：

- `direct_execution`：任务足够简单，root issue 可以直接进入执行。
- `issue_graph`：任务需要拆分，Planner 创建或标记一组 derived issue，并声明它们之间的依赖关系。
- `needs_human_input`：任务信息不足、风险过高或无法可靠规划，需要人补充信息。

Workflow Plan 采用混合规划策略：

- 简单任务直接执行。
- 中等复杂度任务一次规划出完整 issue 图。
- 复杂或不确定任务只规划下一步或前几步，后续根据 Completion Packet 动态重规划。

### Dependency / Handoff Edge

`Dependency / Handoff Edge` 表示 issue 之间的顺序与交接关系。它不只是 blocker 关系，还说明上游 Completion Packet 如何成为下游 issue 的上下文。

例如：

```yaml
from: SYM-101
to: SYM-102
kind: handoff
requires_review: false
handoff_summary: "调研结论用于设计 MiMo-Code 接入方案"
completion_packet_ref: "linear-comment:..."
```

这里的边表达两个含义：

- `SYM-102` 在顺序上依赖 `SYM-101`。
- `SYM-102` 的执行者应该继承 `SYM-101` 的 Completion Packet 作为上下文。

### Completion Packet

每个编排 issue 完成时都必须产出 `Completion Packet`。它是完成报告、下游交接输入、review 材料和 root issue 收口证据的统一载体。

Completion Packet 至少包含：

```markdown
## Completion Packet

### Outcome
完成 / 部分完成 / 阻塞 / 需要重规划 / 需要人工输入

### Summary
本任务实际完成了什么。

### Evidence
可验证证据：文件、提交、测试、链接、命令输出、调研来源等。

### Decisions
本任务做出的关键判断或选择。

### Open Questions
仍未解决的问题。

### Next Handoff
给下游任务或 reviewer 的注意事项。
```

`Outcome`、`Summary`、`Evidence` 必填。其他字段可以为空，但字段本身必须出现。没有证据的 Completion Packet 不应被自动判定为通过。

不同任务类型可以使用不同模板重点：

- 调研任务重点输出结论、依据、备选方案和风险。
- 设计任务重点输出设计决策、接口、约束和验收标准。
- 实现任务重点输出改动说明、测试结果和已知问题。
- 审查任务重点输出判定、理由、打回项或通过依据。

### Review Decision

`Review Decision` 是 review 阶段对 Completion Packet 的判断结果。它可以由内部 review 阶段产生，也可以由一个普通 review issue 产出。

第一版支持这些结果：

- `pass`：结果可接受，可以解锁下游或收口。
- `needs_rework`：结果不满足要求，需要创建或解锁返工 issue。
- `needs_replan`：当前计划不再适用，需要回到 planning。
- `needs_human`：需要人类补充信息或做高风险决策。
- `fail`：任务失败，停在可诊断状态。

Review 可以自动推进状态，但低置信度、高风险或证据不足时应转人工。

## 系统组件、阶段与执行者

### Symphony 控制层

Symphony 控制层是现有 orchestrator 的增强方向。它不是新的 agent，也不承担调研、设计、实现、审查的语义工作。

控制层负责：

- 发现需要进入 planning 的 root issue。
- 校验 Workflow Plan。
- 创建或标记 derived issue。
- 维护依赖与 readiness。
- 只启动满足条件的 ready issue。
- 校验 Completion Packet 的最低结构。
- 根据 Review Decision 自动推进、返工、重规划、请求人工或收口。
- 记录每次状态推进的原因。

### 工作流阶段

第一版关注这些阶段：

- `planning`：把 root issue 转换为直接执行、issue graph 或人工输入请求。
- `execution`：执行某个 ready issue。
- `review`：判断 Completion Packet 是否可接受。
- `replan`：根据执行结果或审查结果调整计划。
- `closure`：判断 root issue 是否可以收口。

阶段不是执行者。一个阶段可以由 Codex、MiMo-Code、OpenCode、人类或专门的模型调用执行。

### 执行者

执行者是实际干活的主体，包括：

- Codex
- MiMo-Code
- OpenCode
- 人类
- 用于 planning 的模型调用
- 用于 review 的模型调用

执行者可以提出建议，但不能绕开控制层直接改变整个 workflow 的权威状态。比如 executor 可以在 Completion Packet 中建议关闭 root issue，但真正关闭 root issue 的动作由控制层基于工作图状态和 Review Decision 执行。

## 生命周期

完整链路如下：

```text
Root issue created
-> Planning
-> Direct execution OR derived issue graph
-> Execute ready issues in dependency order
-> Completion Packet
-> Review Decision
-> Advance / Rework / Replan / Human Input
-> Close root issue when graph is resolved
```

详细数据流：

1. 用户创建 root issue。
2. Symphony 控制层发现该 issue 需要编排。
3. 进入 planning 阶段。
4. planning 执行者输出 Workflow Plan。
5. 控制层校验 Workflow Plan。
6. 控制层创建或标记 derived issue，并建立依赖边。
7. 控制层只启动 ready issue。
8. execution 执行者完成 issue，输出 Completion Packet。
9. 下游 issue 继承上游 Completion Packet 作为上下文。
10. review 阶段输出 Review Decision。
11. 控制层根据 Review Decision 推进流程。

推进规则：

- `pass`：解锁下游 issue；如果整个工作图已解决，则进入 closure。
- `needs_rework`：创建或解锁返工 issue，返工 issue 通常仍是具体任务类型，如 `implementation` 或 `design`。
- `needs_replan`：回到 planning，使用已有 Completion Packet 和 Review Decision 作为输入。
- `needs_human`：在 Linear 留下明确请求，并停止自动推进该分支。
- `fail`：记录失败原因，停在可诊断状态。

## Readiness 与有序调度

新模型下，一个 issue 是否执行不再只由 Linear state、label 和 assignee 决定，还需要满足 workflow readiness。

一个 issue 可以执行的最低条件：

- 它处于允许执行的 Linear state。
- 它属于当前 Symphony 管理的 workflow graph，或被明确标记为可直接执行。
- 它的上游依赖已完成。
- 必需的上游 Completion Packet 已存在。
- 必需的 review gate 已通过。
- 它没有等待人工输入。
- 它没有被其他 agent 或 worker claimed。
- 其目标 agent/backend 可用。

这意味着有些 issue 在 Linear 中看起来是 active，但 workflow 上仍然未 ready。系统应该通过评论、日志或 dashboard 解释它为什么暂不执行。

## Linear 中的可见性

Linear 是用户主要查看和介入任务的地方。所有对用户重要的事实都应该回写到 Linear。

第一版至少需要在 Linear 中可见：

- root issue 是否被规划。
- 派生了哪些 issue。
- 每个 derived issue 来自哪个 root issue。
- 每个 issue 依赖哪些上游。
- 每个 issue 的 Completion Packet。
- Review Decision 及其理由。
- 为什么创建返工 issue。
- 为什么请求人工输入。
- root issue 为什么被收口或暂不能收口。

第一版不强依赖 Linear sub-issue。派生关系可以先通过评论、标签、issue 链接和 blocker 关系表达。

## 人工介入策略

第一版采用低打扰自动推进策略。

系统默认自动执行：

- 规划
- 创建或标记 derived issue
- 解锁 ready issue
- 启动执行
- 审查
- 状态推进
- 返工或重规划
- root issue 收口

系统在这些情况请求人工介入：

- Planner 低置信度。
- Workflow Plan 结构不合法或风险过高。
- issue 描述不足以规划。
- Completion Packet 缺少 evidence。
- Reviewer 低置信度或结果冲突。
- 需要权限、凭据、外部确认或高风险操作。
- 多次返工后仍无法通过。
- 控制层无法判断 root issue 是否可收口。

人工介入应该停在明确状态，并留下具体请求，而不是留下“请看看”这种无边界提示。

## 第一版范围

第一版包括：

- Root issue 识别。
- Planning 阶段。
- 结构化 Workflow Plan。
- `direct_execution`、`issue_graph`、`needs_human_input` 三类计划。
- 普通 Linear issue 承载 derived issue。
- issue 依赖和 readiness 判断。
- 每个编排 issue 必须产出 Completion Packet。
- Review Decision。
- 默认自动推进状态。
- 通过 Linear 评论、标签、链接和 blocker 关系提供可见性。

第一版暂不包括：

- 完整 DAG 可视化。
- 复杂条件分支语言。
- 多层嵌套 workflow。
- 强依赖 Linear sub-issue。
- 完整持久化数据库。
- 完整动态 workflow DSL。
- 完整人类审批系统。
- 完整通用 workflow engine。

第一版成功标准：

用户提出一个复杂 root issue 后，系统能自动规划、创建或选择执行 issue、有序执行、产出交接、审查结果，并把 root issue 推进到完成、返工、重规划或需要人工输入之一。

## 默认实现选择

第一版默认选择：

- Review 可以先作为内部阶段执行；必要时也可以物化成普通 review issue。
- 派生关系先用 Linear 评论、标签、issue 链接和 blocker 关系表达。
- Completion Packet 必须写入 Linear comment，并可选保存到 workspace。
- 尽量少新增 Linear state，先用现有状态加标签和评论承载 workflow 信息。
- Planner 和 Reviewer 初始使用当前最可靠的 agent/model，后续再扩展到 MiMo-Code 或 OpenCode。
- 控制层只读取结构化控制字段，不尝试替下游 agent 深度理解语义内容。

## 风险

### Planner 输出不可靠

Planner 可能过度拆分、漏掉依赖、生成不可执行任务，或者把简单任务复杂化。

缓解方式：

- Workflow Plan 必须结构化。
- 控制层必须校验 plan。
- Planner 输出必须包含置信度和拆分理由。
- 低置信度或过度复杂的 plan 转人工。

### Completion Packet 形式化

agent 可能写出格式完整但没有证据的 Completion Packet。

缓解方式：

- `Outcome`、`Summary`、`Evidence` 必填。
- 没有 evidence 不自动通过。
- Reviewer 必须检查 evidence 是否能支撑 outcome。

### Review 误判

Reviewer 不是绝对可信，自动推进可能放大错误。

缓解方式：

- Review Decision 包含置信度和理由。
- 高风险、低置信度、证据不足时转人工。
- 多次返工失败后停止自动推进。

### Linear 状态与 workflow readiness 分裂

一个 issue 在 Linear 中可能是 active，但在 workflow 上尚未 ready。

缓解方式：

- 在 Linear 评论或 dashboard 中解释 blocked reason。
- readiness 判断要可观测。
- 调度日志必须记录为什么没有执行某个 active issue。

### 派生 issue 过多

Planner 可能制造大量噪音，让用户失去全局视角。

缓解方式：

- 简单任务优先 direct execution。
- 派生 issue 必须有明确目的和验收标准。
- root issue 中回写当前 workflow 摘要。

### 系统膨胀为通用 workflow engine

动态编排容易不断吸收条件分支、循环、复杂审批和 DSL。

缓解方式：

- 第一版只支持 root issue、derived issue、依赖、Completion Packet、Review Decision、rework/replan/human 这条主链。
- 复杂 DSL、多层嵌套和完整审批系统后置。

## 开放问题

这些问题不阻塞第一版设计，但需要在实现计划中继续收敛：

- 是否需要提供配置，让不同 workflow 选择内部 review 或物化成 review issue。
- 派生关系是否需要内部元数据文件或轻量持久化。
- Planner 和 Reviewer 初始使用哪个 agent/model。
- 是否需要新增少量专门状态，例如 `Needs Planning`、`Ready`、`In Review`、`Needs Human`。
- Completion Packet 除了 Linear comment，是否必须保存到 workspace。
- root issue 的关闭条件如何映射到当前 Linear state。

## 与现有 SPEC 的关系

现有 SPEC 已经定义了 Symphony 作为 scheduler/runner 的核心能力：轮询 issue、创建 per-issue workspace、启动 agent、维护运行状态、重试和观测。

本设计不替代这些能力，而是在其上增加一层 issue-driven workflow 控制：

- 原来的 issue eligibility 继续保留。
- 新增 workflow readiness，避免无序执行。
- 原来的 agent runner 继续执行单个 issue。
- 新增 planning、completion、review、replan、closure 语义。
- 原来的 Linear adapter 继续提供 tracker 读写能力。
- 新增对派生关系、Completion Packet 和 Review Decision 的可见性要求。

这让 Symphony 从“每个 issue 一个执行会话”逐步升级为“issue 图上的有序任务闭环”。
