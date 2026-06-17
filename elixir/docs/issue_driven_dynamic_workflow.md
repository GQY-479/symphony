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

每个 phase 通过 workspace 内的文件交接：

- planning: `.symphony/workflow_plan.json`
- execution: `.symphony/completion_packet.json`
- review: `.symphony/review_decision.json`

这些文件是控制层推进 workflow 的依据。普通评论只用于人类可见性，不作为恢复状态的真相源。

## 执行流程

1. root issue 被发现后，先由 `planner_agent` 执行 planning。
2. planner 写出 `workflow_plan.json`。
3. `direct_execution` 计划只在 registry 中落 root 节点；`issue_graph` 计划会创建普通派生 Linear issue。
4. 派生 issue 只有在 registry 节点为 `ready` 且依赖已完成时才会执行。
5. execution agent 写出 `completion_packet.json` 后，Symphony 写回 Completion Packet 评论，并排队 review。
6. reviewer 写出 `review_decision.json`。
7. review `pass` 会把当前节点标记为 `completed`，并把依赖满足的下游节点推进到 `ready`。
8. `needs_human`、`needs_rework`、`fail` 等决策会把 issue 留在 blocked 状态，避免静默成功。

## Registry

Workflow registry 存放在：

```text
<workspace.root>/.symphony/workflows/<root-identifier>.json
```

registry 记录 root issue、派生 issue、节点状态、依赖边和 agent 分配。第一版不依赖 Linear sub-issue，也不引入数据库。

## 可观测性

runtime snapshot、HTTP API 和 dashboard 会暴露：

- `workflow_phase`: `planning`、`execution` 或 `review`
- `workflow_root_issue_id`: 所属 root issue 标识
- `workflow_blocked_reason`: 等待依赖、审查失败或需要人工介入的原因

这让用户能看到 issue 处在编排链条的哪个环节，而不是只看到一个没头没尾的 agent session。
