# Agent 准备式 Workflow 集成设计

**日期：** 2026-07-13
**状态：** 已确认
**范围：** Issue graph 模式下的分支提交、候选集成、冲突处理、最终审查与目标分支发布

## 1. 与既有设计的关系

本文延续 `2026-06-27-issue-graph-candidate-review-design.md` 的以下原则：

1. issue 是唯一需要 agent 或人工执行的任务单位。
2. controller 是 workflow 状态的唯一决定者。
3. agent 不写 candidate、target、checkpoint、review subject 等共享 Git 事实。
4. candidate 是下游协作和审查的集成基线。
5. final review 必须审查最终准备发布的 candidate。

本文替代旧设计中的两项责任划分：

- 不再由 controller 自动提交 issue workspace。
- 不再由 controller 把 issue branch 合入 candidate 并处理内容冲突。

新的责任划分是：

> Agent 负责把私有 issue branch 准备成已经正确提交、已经吸收最新基线、可直接集成的结果；controller 负责验证该结果，并以受保护的方式推进 candidate 和 target 共享引用。

`Workflow.GitAdapter.commit_issue_workspace/2` 和
`Workflow.GitAdapter.merge_issue_to_candidate/2` 不再属于目标接口。

## 2. 问题定义

当前实现把有效的 `issue_result.json` 直接解释为 node 完成：

```text
读取 issue_result
  -> 写 Linear 评论
  -> node completed
  -> 解锁下游
  -> 所有 node completed 时关闭 root
```

这无法证明 agent 的修改已经形成可信交付。典型反例包括：

- agent 只提交了一部分修改，工作区仍有需要提交的变更；
- 工作区同时存在应提交修改和不应提交的临时修改；
- issue branch 基于旧 candidate，遗漏了并行上游的最新修改；
- 功能只存在于本地 workspace，没有进入远程 candidate 或 target；
- final review 通过后 target 又发生变化，实际发布内容不再等于审查对象。

Controller 可以检测 dirty worktree、commit range、祖先关系和远程 SHA，但不能判断某个未提交文件是否属于业务交付，也不能替代 agent 解决语义冲突。因此，提交完整性和内容合并必须由 agent 负责。

## 3. 核心设计决定

### 3.1 不新增 handoff gate

本文不引入 `handoff gate` 这一领域概念，也不增加对应模块、配置或 node 状态。

现有 `Workflow.Controller.handle_issue_completion/2` 本来就是 issue 执行后的完成校验入口。新的 Git 交付校验直接成为该入口的一部分。

校验分为两层：

1. AgentRunner/Artifacts 校验 `issue_result.json` 是否存在且满足结构契约。
2. Controller 校验当前 issue 是否满足完成条件，并决定完成、继续 agent、重试固定操作或阻塞。

`issue_result.json` 的语义从“完成证明”调整为：

> Agent 对当前 issue 提交的结构化完成申请。

### 3.2 不新增独立 Completion 服务

完成协议属于 Controller 内部的状态转换规则，不是独立运行时组件。实现代码如果过长，可以提取为 `Workflow.Completion` 内部协作者，但它：

- 不拥有独立状态；
- 不直接被 Orchestrator 调用；
- 不成为第二个 workflow 状态权威。

### 3.3 Agent 负责私有分支，Controller 负责共享引用

私有分支包括：

- 普通 issue branch；
- rework issue branch；
- target sync preparation branch；
- 必要时的 merge resolution branch。

Agent 可以在私有分支中执行：

- 修改文件；
- 判断未提交变更是否应保留；
- `git add` 和 `git commit`；
- 合入 controller 指定的最新 candidate 或 target；
- 解决冲突并创建 merge commit；
- 运行验证并更新 `issue_result.json`。

Agent 不允许直接更新：

- root candidate branch；
- target branch；
- 远程共享引用；
- Registry checkpoint；
- 当前 issue 或 root issue 的 Linear 状态。

Controller 不负责决定如何修改或解决冲突。Controller 只在校验通过后执行受保护的共享引用推进。

### 3.4 任何仓库变更都必须发布

不引入可选 `completion_policy`。

只要 workflow 产生受 Git 管理的文件变更，root Done 前就必须满足：

```text
变更已经提交
AND 变更已经进入远程 candidate
AND final review 审查的是当前 candidate
AND candidate 已经进入远程 target
```

没有仓库变更的 issue 可以在 artifact 和结果校验通过后完成，不制造空提交。

## 4. 组件责任

| 组件 | 责任 |
|---|---|
| Orchestrator | 调度、claim、并发、agent continuation、controller retry、退避和 reconcile |
| Workflow.Controller | 解释结果、完成校验、决定合法转换、推进共享引用、记录 checkpoint、更新 Tracker |
| AgentRunner | 执行首次 agent turn 和后续 continuation，校验结果 artifact 契约 |
| 执行 Agent | 修改、测试、判断 dirty 文件、提交、吸收最新 candidate、解决冲突 |
| Integration Agent | 将最新 target 合入 candidate preparation branch，解决冲突并提交 |
| Review Agent | 只读审查明确 subject，不修改代码和 Git 历史 |
| GitAdapter | 读取 Git 事实、校验祖先关系、创建私有分支、push 私有分支、受保护地推进共享引用 |
| Registry | 保存 candidate、issue head、checkpoint、subject、review 和 publication 事实 |
| Planner | 规划业务和 review node，不规划机械 continuation |
| Tracker | 保存外部 issue 状态、评论和交付入口 |

## 5. 分支模型

```text
remote target
    ^
    | final review 后由 controller 受保护推进
    |
remote candidate
    ^
    | controller 验证后快进
    |
agent-prepared issue/integration branch
```

Agent 不是把自己的 branch 合入 candidate，而是把最新 candidate 合入自己的私有 branch，使其满足：

```text
current_candidate_sha 是 prepared_issue_head_sha 的祖先
```

随后 Controller 可以把 candidate 从预期 SHA 快进到 prepared issue HEAD。Controller 不需要解释内容，也不需要解决冲突。

## 6. 触发时机和流程

### 6.1 Root planning 完成

触发点：`Controller.handle_planning_completion/2` 成功物化 issue graph 后。

Controller 执行：

1. 解析配置中的 remote 和 target branch。
2. fetch 远程 target。
3. 记录 `target_base_sha`。
4. 从 target 创建 `symphony/<root>/candidate`。
5. push candidate。
6. 将 candidate Git 事实写入 Registry。
7. 只有 candidate 初始化成功后才允许业务 node 进入 ready。

candidate 初始化失败时，root 保持 planning 或 blocked，不派发业务 node。

### 6.2 Issue 派发

触发点：现有 `Controller.issue_dispatch_metadata/1`。

Controller 为 agent 增加以下上下文：

```json
{
  "issue_branch": "symphony/YQE-134/YQE-155",
  "base_candidate_sha": "abc123",
  "candidate_branch": "symphony/YQE-134/candidate",
  "candidate_head_sha": "abc123",
  "completion_requirements": {
    "commit_required_if_changed": true,
    "business_worktree_must_be_clean": true,
    "shared_refs_must_not_be_updated": true
  }
}
```

这里的 `completion_requirements` 只是 agent prompt 中的完成要求，不是新的 gate、状态或领域对象。实现时可以使用更直接的字段名称，而不要求保留该 JSON 包装。

所有受版本控制的业务修改必须发生在当前 issue workspace。Root workspace 和上游 workspace 只作为只读上下文，不能作为绕开 issue branch 的写入位置。

### 6.3 Agent 首次执行结束

触发点：现有 Orchestrator 在 `:issue` agent phase 结束后调用
`Controller.handle_issue_completion/2`。

Agent 在结束前负责：

1. 检查所有 tracked 和 untracked 业务文件。
2. 判断每项未提交变更是否属于当前 issue。
3. 提交需要交付的内容。
4. 清理不需要交付的临时内容。
5. 运行适当验证。
6. 写入并读回 `issue_result.json`。

`.symphony/issue_result.json` 是控制 artifact，不要求进入业务 commit，也不计入业务工作区 dirty 判定。

### 6.4 Controller 完成校验

Controller 按以下顺序检查：

1. `issue_result.json` 已通过结构校验。
2. result 的 node key 和 task type 与 Registry 一致。
3. 当前 HEAD 属于预期私有 issue branch。
4. 除允许的 `.symphony` 控制文件外，没有未提交业务变更。
5. 根据 `base_candidate_sha..issue_head_sha` 判断当前 issue 是否产生业务提交。
6. 如果存在业务提交，则变更已经完整进入 commit range。
7. 如果存在业务提交，则 fetch 最新远程 candidate，并校验其 HEAD 是当前 issue HEAD 的祖先。
8. 如果不存在业务提交，则跳过 candidate 祖先校验，按第 6.8 节记录 `no_change` checkpoint。

校验不会自动提交、恢复或删除文件。

Review node 不执行上述业务 Git 校验。普通 review 只校验 subject、result 和 review outcome；final review 还必须执行第 6.10 节的 publication 校验。Review agent 产生业务文件或 Git 变更时，结果无效并进入人工检查。

### 6.5 工作区未正确收口

触发条件：存在未提交业务变更，或者 Git 历史无法证明业务变更已经提交。

Controller 返回 agent continuation，而不是完成、自动 commit 或立即 blocked：

```elixir
{:continue_agent, issue_id, :dirty_worktree, context}
```

Continuation context 必须包含：

- `git status --porcelain` 的结构化路径列表；
- tracked diff 摘要；
- untracked 路径列表；
- 当前 base、HEAD 和 candidate SHA；
- 当前 `issue_result` 摘要；
- 明确要求 agent 判断提交、清理或请求人工。

Orchestrator 保留当前 issue 的 claim 和 workspace，优先继续原 agent session。若无法恢复原 session，也必须在同一 workspace 中启动 continuation，而不是重新开始任务。

Agent 必须选择：

- 应交付：补充验证并提交；
- 不应交付：清理或恢复；
- 无法判断：输出 `needs_human`。

### 6.6 Candidate 已前进

触发条件：当前 issue 存在业务提交，并且远程 candidate 不是当前 issue HEAD 的祖先。

Controller 返回：

```elixir
{:continue_agent, issue_id, :candidate_advanced, context}
```

Context 必须包含新的 candidate SHA 和相关 checkpoint 摘要。Agent 在自己的 issue branch 中：

1. 合入新的 candidate SHA。
2. 解决冲突。
3. 重新运行受影响验证。
4. 提交合并结果。
5. 更新 `issue_result.json` 的 evidence 和 summary。

Agent 不直接更新 candidate。完成后重新进入同一个 Controller 完成校验。

### 6.7 推进 Candidate

触发条件：

```text
业务工作区干净
AND issue_result 有效
AND current_candidate_sha 是 issue_head_sha 的祖先
```

Controller 在单一权威 Orchestrator 的串行回调中执行：

1. push 或确认私有 issue branch。
2. 以 `current_candidate_sha` 为 expected value，把远程 candidate 快进到 `issue_head_sha`。
3. 禁止非快进和无保护强推。
4. fetch 并确认远程 candidate HEAD 等于 `issue_head_sha`。
5. 写入 candidate checkpoint。
6. 保存 Registry。
7. 将 node 标为 completed。
8. 创建最终 Issue Result 评论。
9. 更新当前 Linear issue 到 terminal state。
10. 解锁下游 node。

如果远程 candidate 在步骤 2 前已变化，Controller 不推进引用，重新返回
`:candidate_advanced` continuation。

### 6.8 无仓库变更的 Issue

当 Controller 确认当前 issue 没有业务 diff 时：

- 不要求空 commit；
- 不推进 candidate；
- 记录 `kind = no_change` checkpoint，其中包含 result artifact hash；
- 在 result、evidence 和 node contract 校验通过后完成 node。

### 6.9 Final review 前同步 Target

触发点：final review 的所有业务依赖已经 completed，但 final review 尚未派发。

Controller fetch 远程 target 和 candidate：

- 如果 target HEAD 已经是 candidate HEAD 的祖先，生成 final review subject 并派发 review。
- 如果不是，Controller 创建系统派生的 integration issue。

该 issue 使用：

```text
task_type = integration
node purpose = target_sync
```

它是真正需要 agent 执行的 issue node，不是隐藏 phase。Integration agent 负责：

1. 从当前 candidate 创建私有 preparation branch。
2. 合入 Controller 指定的最新 target SHA。
3. 解决冲突。
4. 运行验证。
5. 提交集成结果。
6. 写 `issue_result.json`。

Controller 按普通 issue 的完成校验处理它，并在校验通过后快进 candidate。Candidate 变化会使旧 final review subject 失效，因此 final review 只能在 target sync 完成后派发。

### 6.10 Final review 通过

Final review agent 只审查 Controller 生成的不可漂移 subject。Subject 至少包含：

```json
{
  "type": "final_candidate_range",
  "target_sha": "target-at-review",
  "candidate_sha": "candidate-at-review"
}
```

Review `pass` 只是申请 Controller 接受审查结果，不直接关闭 review issue 或 root。

Controller 再次 fetch 远程引用并检查：

```text
reviewed_candidate_sha == current_candidate_sha
AND reviewed_target_sha == current_target_sha
AND current_target_sha 是 current_candidate_sha 的祖先
```

三项成立时：

1. 以 `reviewed_target_sha` 为 expected value，将远程 target 快进到 reviewed candidate。
2. fetch 并确认远程 target SHA。
3. 保存 publication checkpoint。
4. 将 final review node 标为 completed。
5. 保存 Registry status = completed。
6. 更新 final review issue 到 terminal state。
7. 最后更新 root issue 到 terminal state。

任何 SHA 已变化时：

1. 不推进 target。
2. 将当前 final review subject 和 review 标记为 stale。
3. 如有必要创建新的 target sync issue。
4. 创建或重新派发新的 final review。

## 7. Controller 结果类型

`handle_issue_completion/2` 的结果扩展为：

```elixir
{:completed, issue_id}
{:continue_agent, issue_id, reason, context}
{:retry_controller, issue_id, reason, context}
{:blocked, issue_id, reason}
{:needs_rework, issue_id, reason}
{:needs_replan, issue_id, reason}
{:needs_human, issue_id, reason}
{:fail, issue_id, reason}
```

语义固定为：

- `completed`：完成事实已经持久化，可以释放 claim 并解锁下游。
- `continue_agent`：需要 agent 做语义判断或修改，继续同一 issue。
- `retry_controller`：只需重试 fetch、push、Registry 或 Tracker 等固定操作，不运行 agent。
- `blocked`：当前状态无法安全自动推进。
- review outcomes：保持现有返工、重规划和人工处理语义。

Orchestrator 必须区分 agent continuation 和 controller retry，避免网络错误浪费 agent turn，也避免 dirty workspace 被当作固定操作重试。

## 8. Registry 最小扩展

### 8.1 Root Git 事实

```json
{
  "remote": "origin",
  "target_branch": "main",
  "target_base_sha": "...",
  "candidate_branch": "symphony/YQE-134/candidate",
  "candidate_head_sha": "...",
  "publication": {
    "status": "pending",
    "reviewed_candidate_sha": null,
    "expected_target_sha": null,
    "published_target_sha": null
  }
}
```

### 8.2 Node Git 事实

```json
{
  "branch": "symphony/YQE-134/YQE-155",
  "base_candidate_sha": "...",
  "head_sha": "...",
  "checkpoint_id": "...",
  "continuation": {
    "reason": "candidate_advanced",
    "attempt": 1,
    "observed_at": "..."
  }
}
```

`continuation` 只是最近一次未满足完成条件的诊断信息，不是新的 node 状态。Node 在 continuation 期间保持 `running`。

### 8.3 Checkpoint

```json
{
  "id": "checkpoint-001",
  "kind": "candidate_promotion",
  "node_key": "implementation",
  "issue_branch": "symphony/YQE-134/YQE-155",
  "base_candidate_sha": "...",
  "issue_head_sha": "...",
  "candidate_before_sha": "...",
  "candidate_after_sha": "...",
  "result_artifact_hash": "..."
}
```

第一版不引入通用 operation journal。可恢复性由远程引用、commit 图、checkpoint 和 publication 事实共同提供。

## 9. GitAdapter 目标边界

GitAdapter 提供事实和受保护操作，不负责语义判断：

```text
create_candidate_branch(root, target_ref)
create_issue_branch(issue, candidate_sha)
create_preparation_branch(issue, source_sha)
fetch_ref(remote, ref)
inspect_workspace(workspace, allowed_control_paths)
commit_range(base_sha, head_sha)
ancestor?(ancestor_sha, descendant_sha)
push_private_branch(branch, head_sha)
compare_and_swap_ref(remote, ref, expected_sha, new_sha)
hash_artifact(path)
```

删除目标接口：

```text
commit_issue_workspace
merge_issue_to_candidate
merge_candidate_to_target
```

Target 发布使用同一个 `compare_and_swap_ref` 约束；只有 Controller 已证明 target 是 candidate 的祖先并且 final review subject 未漂移时才允许调用。

## 10. 并发与冲突

多个 agent 可以从同一个 candidate SHA 并行工作。完成顺序由 candidate 推进顺序决定。

示例：

```text
A、B 都从 C0 开始
A 准备出 A1，Controller 将 candidate 从 C0 推进到 A1
B 准备出 B1，但 B1 不包含 A1
Controller 继续 B agent，并提供 A1
B 将 A1 合入自己的 branch，解决冲突并提交为 B2
Controller 将 candidate 从 A1 推进到 B2
```

同一 Orchestrator 进程中的完成回调天然串行。对于外部进程或人工对远程分支的修改，`compare_and_swap_ref` 提供最终并发保护。

不允许：

- 无条件 force push candidate 或 target；
- Controller 静默解决冲突；
- Agent 直接更新共享 candidate 或 target；
- Candidate 漂移后继续使用旧 review subject。

## 11. 恢复和幂等

Git push、Registry 文件写入和 Tracker 更新无法形成单一原子事务，恢复规则必须以外部事实为准。

### 11.1 Candidate 已推进但 Registry 未保存

重新处理 issue completion 时：

1. fetch candidate；
2. 如果 candidate HEAD 等于已验证 issue HEAD，视为共享引用推进已经成功；
3. 重建或补写 checkpoint；
4. 不重新运行 agent，不重复生成 commit。

### 11.2 Registry 已保存但 Tracker 未更新

返回 `retry_controller`，只重试评论和 Tracker 状态更新。不得重新运行 agent 或重新推进 Git 引用。

### 11.3 远程临时失败

返回 `retry_controller`，由 Orchestrator 使用现有指数退避机制重试。

### 11.4 历史或引用异常

以下情况进入 blocked 或 needs_human：

- issue HEAD 不属于预期仓库或 branch；
- candidate 出现无法解释的非快进变化；
- commit 图缺失或对象不可读取；
- 远程权限永久不足；
- continuation 超过配置的最大次数仍无法形成干净结果。

## 12. Tracker 更新顺序

Tracker 不是 Git 交付事实来源，状态更新必须排在完成事实持久化之后。

普通 issue：

```text
candidate remote confirmed
  -> checkpoint saved
  -> node completed saved
  -> Issue Result comment
  -> derived issue terminal
```

Root issue：

```text
target remote confirmed
  -> publication checkpoint saved
  -> final review completed saved
  -> registry completed saved
  -> final review issue terminal
  -> root issue terminal
```

Continuation 期间不写“已完成”评论，不把 issue 移到 terminal state。

## 13. Agent Prompt 契约

### 13.1 普通执行和返工 Agent

必须：

- 在当前 issue workspace 中修改业务文件；
- 检查全部未提交变更；
- 提交所有应交付变更；
- 清理不应交付变更；
- 运行验证；
- 写 `issue_result.json`。

禁止：

- 直接 push candidate 或 target；
- 修改 Linear 状态表示完成；
- 把需要交付的修改留在未提交工作区。

### 13.2 Continuation Agent

Continuation prompt 只描述当前未满足的完成条件，不要求重新实现任务。Agent 必须复用当前 workspace、Git 历史和 artifact。

### 13.3 Integration Agent

负责 target sync 或无法继续原 agent 的显式集成任务。它可以合并、解决冲突和提交，但仍不能更新共享引用。

### 13.4 Review Agent

保持只读。不得 add、commit、merge、push、创建 PR 或改写审查 subject。

## 14. 完成判定

普通 node 完成条件：

```text
result artifact 有效
AND agent branch 工作区已正确收口
AND agent branch 包含完成时的 candidate
AND candidate 已推进并在远程确认
AND checkpoint 已持久化
```

无变更 node 使用 `no_change` checkpoint 替代 candidate 推进。

Root workflow 完成条件：

```text
所有 executable node completed
AND final review accepted
AND final review subject 未漂移
AND remote target 已推进到 reviewed candidate
AND publication checkpoint 已持久化
```

`workflow_completed?/1` 必须同时验证 node 完成和 publication invariant，不能再只检查 node status。

## 15. 测试和验收

### 15.1 Controller 单元测试

- 有效 result 加未提交业务变更返回 `continue_agent`，不完成 node。
- Candidate 已前进返回 `continue_agent`，上下文包含最新 SHA。
- 工作区干净且 candidate 是 issue HEAD 祖先时允许推进。
- 无变更 issue 生成 `no_change` checkpoint，不制造空提交。
- Review pass 不直接关闭 root。
- Target 或 candidate 漂移时 final review 标记 stale。

### 15.2 GitAdapter 集成测试

使用临时 bare remote 验证：

- 私有 branch push；
- candidate 快进；
- expected SHA 不匹配时拒绝；
- 非快进更新拒绝；
- target 快进；
- ancestor 和 commit range 事实读取。

### 15.3 恢复测试

- Candidate push 后、Registry 保存前中断，重试后补写 checkpoint。
- Registry 保存后、Tracker 更新前中断，只重试 Tracker。
- Candidate CAS 竞争失败后继续原 agent。
- Final review 后 target 漂移，禁止关闭 root 并重新同步审查。

### 15.4 端到端回归

必须复现 YQE-134/YQE-155/YQE-160 类型场景：

```text
Agent result 声称完成
但 workspace 仍有未提交业务变更
```

验收结果必须是：

- 当前 node 不 completed；
- root 不进入 Done；
- 原 issue agent 收到 continuation；
- 变更完成提交、candidate 和 target 发布并经过 final review 后，root 才能 Done。

## 16. 迁移和兼容

- 新创建的 root workflow 使用本文语义。
- 已完成的历史 workflow 不自动重新打开。
- 缺少 candidate、branch 或 checkpoint 事实的存量 active workflow 不自动猜测，应进入 needs_human 或重新 planning。
- Registry 新字段读取必须容忍缺省，但新的完成路径不能在关键 Git 事实缺失时关闭 root。
- 旧的 Controller 自动 commit/merge 接口在新路径落地后移除，不并行保留两套完成语义。

## 17. 非目标

本文不设计：

- 通用分布式事务引擎；
- 独立 Completion 服务；
- 可配置的 artifact-only/requires-publication 完成策略；
- Agent 直接写共享分支或 Tracker 状态；
- Controller 自动判断业务冲突应如何解决；
- 自动 force push、自动丢弃未提交修改或自动 revert。

## 18. 最终不变量

实现必须始终满足：

1. Agent 决定私有 workspace 中哪些修改应提交，以及如何解决内容冲突。
2. Controller 决定 issue 是否完成，并且是共享 workflow 状态的唯一写入者。
3. Candidate 和 target 只通过带 expected SHA 的受保护更新推进。
4. `issue_result.json` 有效不等于 issue 已完成。
5. Review pass 不等于 root 已完成。
6. Root Done 必须对应已经确认的远程 target publication。
