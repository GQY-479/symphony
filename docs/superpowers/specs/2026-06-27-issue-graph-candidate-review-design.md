# Issue Graph Candidate Review Design

## 目标

本设计把 Symphony 的工作流模型收敛为确定性的 issue graph 控制层。所有任务都是一等 issue node，审查也只是普通 issue，不再作为隐藏的内部 phase。控制层负责创建工作区、提交变更、合并候选分支、解释结构化结果、更新 registry 和调度下游。

本设计不考虑兼容旧的 `completion_packet.json`、`review_decision.json` 和内部 review phase。落地时应直接迁移到统一的 issue 结果文件。

## 核心原则

1. issue 是唯一任务单位。需求分析、调研、设计、实现、审查、返工、冲突解决和最终收口都可以是 issue node。
2. workflow graph 的依赖边决定任务顺序和 ready 条件。需要审查就创建 review issue，并让下游依赖该 review issue。
3. 集成不是认可。candidate branch 用于让下游基于前文继续工作；只有 review issue 的结果被 controller 接受后，subject 才算被认可。
4. agent 不写 Git 事实。branch、sha、checkpoint、diff range、artifact hash 等客观信息由 Symphony controller 或 Git adapter 生成、补齐或校验。
5. controller 是唯一状态写入者。agent 只提交结构化 issue result 和必要证据，不直接移动流程状态。

## 分支模型

每个 root issue 对应一个 root candidate branch：

```text
main / target branch
  ^
  | final review pass 后由 Symphony 合入
  |
symphony/<root>/candidate
  ^
  | issue 完成后由 Symphony 自动合入
  |
symphony/<root>/<issue>
```

执行规则：

1. root issue 启动时，Symphony 从目标分支创建 `symphony/<root>/candidate`。
2. 每个派生 issue 从当前 candidate HEAD 创建独立 issue branch。
3. agent 只在自己的 issue workspace / issue branch 中工作。
4. issue 完成后，Symphony 自动 commit、push issue branch。
5. Symphony 将 issue branch 合入 candidate，并记录 checkpoint。
6. 下游 issue 从新的 candidate HEAD 创建，获得上游变更和上游 issue result。
7. final review pass 后，Symphony 将 candidate 合入目标分支。

root issue 如果也需要做收尾修改，不直接写 candidate，而是创建普通的 root finalize issue branch：

```text
symphony/<root>/root-finalize
```

它完成后同样先合入 candidate，再由 final review 决定是否合入目标分支。

## Candidate Checkpoint

每次 issue branch 合入 candidate 后，controller 记录一个 checkpoint。checkpoint 是后续 review subject、下游上下文和最终审查的基础。

示例：

```json
{
  "issue_id": "YQE-701",
  "issue_branch": "symphony/YQE-700/YQE-701",
  "issue_base_sha": "...",
  "issue_head_sha": "...",
  "candidate_before_sha": "...",
  "candidate_after_sha": "...",
  "merge_commit_sha": "..."
}
```

这些字段全部由 Git adapter 产生，不进入 agent 可自由填写的结果字段。

## Workflow Graph

workflow graph 负责表达任务依赖。是否需要审查，不需要额外的 gate policy；由图结构表达。

小任务可以是：

```text
design -> implementation -> final_review
```

这表示 design 和 implementation 之间不插入独立审查，最终只审 candidate 的整体结果。

严格流水线可以是：

```text
research -> research_review -> design -> design_review -> implementation -> implementation_review -> final_review
```

这表示每个关键节点都有显式 review issue，下游依赖 review issue，而不是依赖隐藏 phase。

依赖边只表达顺序和交接，不表达“已认可”。认可来自 review issue 对 subject 的 pass 结果。

## Review Subject

review issue 必须绑定明确 subject。subject 是审查对象，不是自然语言描述。controller 根据 workflow graph、checkpoint 和 artifact 生成或校验 subject。

最小 subject 类型：

```text
issue_diff       # 某个 issue branch 的 base_sha..head_sha
candidate_range # candidate 两个 checkpoint 之间的累计变化
artifact         # 某个 issue result、设计文档或计划对象的内容哈希
```

示例：

```json
{
  "type": "candidate_range",
  "base_sha": "...",
  "head_sha": "...",
  "paths": ["lib/foo", "test/foo"]
}
```

`paths` 只能表示审查关注范围，不能证明语义影响只限于这些路径。最终 review 应覆盖 candidate 相对目标分支的整体 diff。

## 统一 Issue Result

每个 issue 完成时输出同一种结果文件。建议命名为：

```text
.symphony/issue_result.json
```

最小字段：

```json
{
  "schema_version": 1,
  "node_key": "implementation",
  "task_type": "implementation",
  "outcome": "completed",
  "summary": "...",
  "evidence": [],
  "decisions": [],
  "open_questions": []
}
```

review issue 仍然输出同一个文件：

```json
{
  "schema_version": 1,
  "node_key": "implementation_review",
  "task_type": "review",
  "outcome": "pass",
  "reviews": ["implementation"],
  "summary": "...",
  "evidence": [],
  "decisions": [],
  "open_questions": []
}
```

`subject` 可以出现在 review issue 的任务输入、registry 记录和 controller 补齐后的结果中。agent 不应手写未校验的 Git sha 作为事实来源。

## Review Result Semantics

controller 根据 `task_type=review` 解释 review issue 的 `outcome`：

```text
pass         -> subject accepted，依赖该 review 的下游可 ready
needs_rework -> 创建或解锁 rework issue
fail         -> 阻塞相关路径，等待人工或重规划
needs_human  -> 转人工输入
```

review 不直接移动其他 issue。controller 校验 result 来源、subject 和 workflow graph 后，确定性更新 registry。

## 已通过 Subject 的失效

如果后续 candidate 变更触碰已通过 subject 的范围，旧 review 不能继续无条件代表当前结果。

第一版采用保守规则：

```text
同文件或同 artifact 后续被修改 -> 相关 accepted subject 标记为 stale
final review pass -> 覆盖 candidate 当前整体结果
```

这不能证明语义级影响，但能避免把明显已被修改过的范围继续标为完全有效。

## 审查失败和返工

candidate 允许未审查内容进入，因此 review 不通过时，失败内容可能已经在 candidate 中。controller 必须执行明确动作，不能只记录失败。

默认处理：

```text
needs_rework -> 基于当前 candidate 创建 rework issue
fail         -> 阻塞相关下游，等待人工或重规划
needs_human  -> 请求人工决策
```

是否 revert 失败范围应作为显式动作，不作为默认行为。revert 本身会产生新的 candidate checkpoint，并可被后续 review 覆盖。

## 合并冲突

issue branch 合入 candidate 如果发生冲突，controller 不应静默解决。处理方式是创建普通 issue node：

```text
task_type = merge_resolution
```

merge resolution issue 由 agent 或人工解决冲突，输出 `issue_result.json`，提交后再合入 candidate。冲突解决产生的 diff 也必须成为可审查 subject。

## 最终收口

root issue 完成前必须存在 final review issue。final review 的 subject 是 candidate 相对目标分支的固定范围：

```text
target_base_sha..candidate_head_sha
```

final review pass 后，controller 校验 candidate HEAD 未漂移，然后将 candidate 合入目标分支，并关闭 root issue。未通过则按 review result semantics 进入返工、阻塞或人工输入。

## 非目标

1. 不解决本地未上传文件、本地工作区和远程仓库不一致的问题。
2. 不保留内部 planning / execution / review phase 的双轨制。
3. 不保留 `completion_packet.json` 和 `review_decision.json` 两套结果文件。
4. 不让 agent 决定 Git branch、sha 或最终合并动作。
5. 不用额外 gate policy 表达是否审查；是否审查由 workflow graph 中的 review issue 和依赖边表达。

## 待实现决策

1. 结果文件名最终采用 `issue_result.json`，还是改为 `node_result.json`。
2. registry 中 checkpoint、subject、accepted/stale/failed 状态的具体字段。
3. Git adapter 的接口边界：创建分支、提交、push、合入 candidate、合入 target、生成 subject。
4. planner 输出 graph 时如何声明 review issue 的 `reviews` 和 subject 选择。
5. final review 是否作为所有 root workflow 的强制节点。
