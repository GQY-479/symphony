# Issue 驱动的动态任务编排

这是 Symphony 第一版可选动态编排能力。它仍然以 Linear issue 作为用户可见的任务载体，但不再把每个 issue 都当成一次单轮执行，而是让 root issue 先进入 planning，由规划结果派生普通 Linear issue，再按 registry 中的依赖关系逐步执行、审查和解锁下游任务。

## 开启方式

在 `WORKFLOW.md` 的 YAML front matter 中加入：

```yaml
orchestration:
  enabled: true
  planner_agent: codex
  reviewer_agent: codex
  artifact_dir: ".symphony"
  planning_max_turns: 1
  review_max_turns: 1
```

不开启时，Symphony 保持旧行为：轮询候选 issue，并直接按路由派给对应 agent。

## 结构化工件

每个 workflow issue 通过 workspace 内的文件交接：

- planning: `.symphony/workflow_plan.json`
- non-planning issue: `.symphony/issue_result.json`

review 不再是 orchestrator 内部 phase；review 是普通 issue node。是否需要审查、审查哪些对象、以及审查后何时解锁下游，都由 workflow graph 中的 review node 和依赖边表达。

这些文件是控制层推进 workflow 的依据。普通评论只用于人类可见性，不作为恢复状态的真相源。

## 执行流程

1. root issue 被发现后，先由 `planner_agent` 执行 planning。
2. planner 写出 `workflow_plan.json`。
3. planner 只能写出 `issue_graph` 或 `needs_human_input`。所有可执行工作，包括小任务，都用 `issue_graph` 表达。
4. `issue_graph` 必须显式包含 `final_review` node；controller 只校验和物化 graph，不替 planner 补建编排节点。
5. 派生 issue 只有在 registry 节点为 `ready` 且依赖已完成时才会执行。
6. 普通 issue agent 写出 `issue_result.json` 后，Symphony 写回 Issue Result 评论，并按 registry 依赖边解锁下游。
7. review issue agent 也写出 `issue_result.json`。`outcome=pass` 会把 review 节点标记为 `completed`，并把依赖满足的下游节点推进到 `ready`。
8. review `needs_rework` 会创建普通返工 issue，原节点在 registry 中标记为 `superseded`，下游改为等待返工节点通过。
9. review `needs_replan` 会把 root workflow 标记为 `replanning`，废弃未完成节点，并把这些被废弃的派生 issue 移到终态，避免旧路径继续被轮询；随后调度 root issue 重新进入 planning，planner 会收到重规划原因和被审查 issue。
10. `needs_human` 和 `fail` 会把 issue 留在可诊断的 blocked 状态，避免静默成功。

## 需要人工输入

Planner 可以写出 `needs_human_input` 计划：

```json
{
  "kind": "needs_human_input",
  "summary": "任务信息不足，无法可靠规划",
  "confidence": "low",
  "request": "请补充目标仓库、目标行为和验收标准"
}
```

Symphony 会把这个请求写入 root issue 评论，registry 状态会变成 `needs_human_input`，Orchestrator 会把 root issue 放入 blocked，并在 dashboard/API 中显示明确原因。

## Issue 交接

每个非 planning issue 的 `issue_result.json` 会被写回对应 registry 节点。下游 issue 被派发时，Symphony 会把依赖节点的 issue result 摘要放入 workflow context，issue 阶段提示词会把这些上游摘要追加给 agent。

这意味着 issue 之间的协作不是只靠 Linear 标题或 blocker 顺序串起来；上游任务完成时产出的结构化交接内容会成为下游任务的显式输入。

## Registry

Workflow registry 存放在：

```text
<workspace.root>/.symphony/workflows/<root-identifier>.json
```

registry 记录 root issue、派生 issue、节点状态、依赖边和 agent 分配。第一版不依赖 Linear sub-issue，也不引入数据库。

## 可观测性

runtime snapshot、HTTP API 和 dashboard 会暴露：

- `workflow_phase`: `planning` 或 `issue`
- `workflow_root_issue_id`: 所属 root issue 标识
- `workflow_blocked_reason`: 等待依赖、审查失败或需要人工介入的原因

这让用户能看到 issue 处在编排链条的哪个环节，而不是只看到一个没头没尾的 agent session。
