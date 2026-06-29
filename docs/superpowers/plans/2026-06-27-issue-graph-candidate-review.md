# Issue Graph Candidate Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 Symphony workflow 从内部 execution/review phase 和双结果文件迁移到 issue graph、统一 `.symphony/issue_result.json`、显式 review issue、candidate/checkpoint/subject registry 的第一版实现。

**Architecture:** 保留 planning artifact `workflow_plan.json` 作为 root 规划输入，移除 execution/review 的特殊 artifact。所有非 planning issue 都通过 `issue_result.json` 完成；controller 根据 node `task_type` 解释 result。Git 操作先通过本地 `Workflow.GitAdapter` 封装接口落地，controller 记录 checkpoint、subject 和 review 状态；后续可以替换为远程 worker 实现。

**Tech Stack:** Elixir/Phoenix app, ExUnit, Jason JSON, existing Symphony Tracker/Registry/AgentRunner/Orchestrator modules, shell git executable.

---

## 文件结构

- Modify: `elixir/lib/symphony_elixir/workflow/artifacts.ex`
  - 固定新增 `issue_result_path/1`、`load_issue_result/1`、`validate_issue_result/1`。
  - 删除或停止使用 `completion_packet_path/1`、`review_decision_path/1`、`load_completion_packet/1`、`load_review_decision/1`、对应校验。
- Create: `elixir/lib/symphony_elixir/workflow/git_adapter.ex`
  - 封装候选分支、issue 分支、commit、push、merge、subject 构造、artifact hash。
- Modify: `elixir/lib/symphony_elixir/workflow/registry.ex`
  - 新增 root workflow Git 字段、checkpoint、subject、review 状态 helper。
- Modify: `elixir/lib/symphony_elixir/workflow/controller.ex`
  - planner materialization 自动补 final review。
  - issue completion 统一读取 `issue_result.json`。
  - 根据 `task_type=review` 解释 review outcome。
  - 对普通 issue 保存 `issue_result`、提交并合入 candidate、记录 checkpoint、解锁下游。
- Modify: `elixir/lib/symphony_elixir/workflow/prompts.ex`
  - 保留 planning prompt。
  - 将 execution/review prompt 合并成普通 issue prompt，要求写 `issue_result.json`。
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`
  - workflow artifact 校验从 `:execution`/`:review` 改为统一 `:issue`。
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
  - 不再在 execution 完成后硬编码 queue review。
  - 非 planning workflow issue 完成后调用统一 `Controller.handle_issue_completion/2`。
- Modify: `elixir/lib/symphony_elixir_web/presenter.ex`
  - artifact path 展示改为 planning 或 issue result。
- Modify: tests under `elixir/test/symphony_elixir/`
  - 更新 artifact、controller、prompt、agent runner、orchestrator 测试。
- Modify: `elixir/WORKFLOW.md`
  - 更新 agent contract：非 planning issue 写 `issue_result.json`。

## Task 1: 统一 Issue Result Artifact

**Files:**
- Modify: `elixir/lib/symphony_elixir/workflow/artifacts.ex`
- Modify: `elixir/test/symphony_elixir/workflow_artifacts_test.exs`

- [ ] **Step 1: 写失败测试**

在 `workflow_artifacts_test.exs` 添加测试：

```elixir
test "artifact helpers build planning and issue result paths" do
  write_workflow_file!(Workflow.workflow_file_path(),
    orchestration: %{enabled: true, artifact_dir: ".symphony"}
  )

  workspace = Path.join(System.tmp_dir!(), "workflow-artifacts-paths")

  assert Artifacts.workflow_plan_path(workspace) ==
           Path.join([workspace, ".symphony", "workflow_plan.json"])

  assert Artifacts.issue_result_path(workspace) ==
           Path.join([workspace, ".symphony", "issue_result.json"])
end
```

添加普通 issue result 校验测试：

```elixir
test "validate_issue_result accepts normal issue result" do
  assert :ok ==
           Artifacts.validate_issue_result(%{
             "schema_version" => 1,
             "node_key" => "implementation",
             "task_type" => "implementation",
             "outcome" => "completed",
             "summary" => "实现完成",
             "evidence" => ["mix test"],
             "decisions" => [],
             "open_questions" => []
           })
end
```

添加 review issue result 校验测试：

```elixir
test "validate_issue_result accepts review outcomes" do
  assert :ok ==
           Artifacts.validate_issue_result(%{
             "schema_version" => 1,
             "node_key" => "implementation_review",
             "task_type" => "review",
             "outcome" => "pass",
             "reviews" => ["implementation"],
             "summary" => "审查通过",
             "evidence" => ["mix test"],
             "decisions" => [],
             "open_questions" => []
           })

  assert :ok ==
           Artifacts.validate_issue_result(%{
             "schema_version" => 1,
             "node_key" => "implementation_review",
             "task_type" => "review",
             "outcome" => "needs_rework",
             "reviews" => ["implementation"],
             "summary" => "需要返工",
             "reason" => "缺少测试",
             "evidence" => ["mix test failed"],
             "decisions" => [],
             "open_questions" => []
           })
end
```

- [ ] **Step 2: 运行失败测试**

Run: `cd elixir; mix test test/symphony_elixir/workflow_artifacts_test.exs`

Expected: 失败，原因是 `Artifacts.issue_result_path/1`、`validate_issue_result/1` 或 `load_issue_result/1` 不存在。

- [ ] **Step 3: 实现 artifact helper 和校验**

在 `Artifacts` 中：

```elixir
@issue_result_filename "issue_result.json"

@spec issue_result_path(Path.t()) :: Path.t()
def issue_result_path(workspace), do: artifact_path(workspace, @issue_result_filename)

@spec load_issue_result(Path.t()) :: {:ok, map()} | {:error, term()}
def load_issue_result(workspace),
  do: load_json(issue_result_path(workspace), &validate_issue_result/1)
```

新增校验规则：

```elixir
@review_outcomes MapSet.new(["pass", "needs_rework", "needs_replan", "needs_human", "fail"])

@spec validate_issue_result(term()) :: :ok | {:error, :invalid_issue_result}
def validate_issue_result(%{
      "schema_version" => 1,
      "node_key" => node_key,
      "task_type" => "review",
      "outcome" => outcome,
      "reviews" => reviews,
      "summary" => summary,
      "evidence" => evidence,
      "decisions" => decisions,
      "open_questions" => open_questions
    } = result)
    when is_list(reviews) and is_list(evidence) and is_list(decisions) and is_list(open_questions) do
  cond do
    not non_blank?(node_key) or not non_blank?(summary) -> {:error, :invalid_issue_result}
    not MapSet.member?(@review_outcomes, outcome) -> {:error, :invalid_issue_result}
    reviews == [] or not Enum.all?(reviews, &non_blank?/1) -> {:error, :invalid_issue_result}
    outcome != "pass" and not non_blank?(result["reason"]) -> {:error, :invalid_issue_result}
    outcome == "needs_human" and not non_blank?(result["requested_input"]) -> {:error, :invalid_issue_result}
    true -> :ok
  end
end

def validate_issue_result(%{
      "schema_version" => 1,
      "node_key" => node_key,
      "task_type" => task_type,
      "outcome" => outcome,
      "summary" => summary,
      "evidence" => evidence,
      "decisions" => decisions,
      "open_questions" => open_questions
    })
    when is_list(evidence) and is_list(decisions) and is_list(open_questions) do
  if non_blank?(node_key) and non_blank?(task_type) and non_blank?(outcome) and non_blank?(summary) and evidence != [] do
    :ok
  else
    {:error, :invalid_issue_result}
  end
end

def validate_issue_result(_result), do: {:error, :invalid_issue_result}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd elixir; mix test test/symphony_elixir/workflow_artifacts_test.exs`

Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add elixir/lib/symphony_elixir/workflow/artifacts.ex elixir/test/symphony_elixir/workflow_artifacts_test.exs
git commit -m "feat(workflow): add unified issue result artifact"
```

## Task 2: Registry 增加 Checkpoint、Subject、Review 状态

**Files:**
- Modify: `elixir/lib/symphony_elixir/workflow/registry.ex`
- Modify: `elixir/test/symphony_elixir/workflow_artifacts_test.exs`

- [ ] **Step 1: 写失败测试**

在 registry 测试区域添加：

```elixir
test "registry stores checkpoints subjects and review states" do
  write_workflow_file!(Workflow.workflow_file_path(),
    workspace_root: Path.join(System.tmp_dir!(), "workflow-registry-subjects"),
    orchestration: %{enabled: true, artifact_dir: ".symphony"}
  )

  root_issue = %Issue{id: "root-subject", identifier: "YQE-SUBJECT", title: "root", state: "In Progress"}

  registry =
    root_issue
    |> Registry.new_root()
    |> Registry.put_workflow_git(%{
      "target_branch" => "main",
      "target_base_sha" => "base",
      "candidate_branch" => "symphony/YQE-SUBJECT/candidate",
      "candidate_head_sha" => "base",
      "final_review_node" => "final_review"
    })
    |> Registry.add_checkpoint(%{
      "id" => "checkpoint-001",
      "node_key" => "implementation",
      "issue_branch" => "symphony/YQE-SUBJECT/YQE-2",
      "issue_base_sha" => "base",
      "issue_head_sha" => "head",
      "candidate_before_sha" => "base",
      "candidate_after_sha" => "after",
      "merge_commit_sha" => "merge"
    })
    |> Registry.put_subject("subject-001", %{
      "type" => "candidate_range",
      "base_sha" => "base",
      "head_sha" => "after",
      "paths" => [],
      "artifact_ref" => nil,
      "status" => "pending"
    })
    |> Registry.put_review_state("implementation_review", %{
      "subject_id" => "subject-001",
      "decision" => "pass",
      "status" => "accepted",
      "decided_at" => "2026-06-27T00:00:00Z"
    })

  assert registry["candidate_branch"] == "symphony/YQE-SUBJECT/candidate"
  assert [checkpoint] = registry["checkpoints"]
  assert checkpoint["candidate_after_sha"] == "after"
  assert registry["subjects"]["subject-001"]["status"] == "pending"
  assert registry["reviews"]["implementation_review"]["status"] == "accepted"
end
```

- [ ] **Step 2: 运行失败测试**

Run: `cd elixir; mix test test/symphony_elixir/workflow_artifacts_test.exs`

Expected: 失败，原因是 Registry helper 不存在。

- [ ] **Step 3: 实现 Registry helper**

新增：

```elixir
@spec put_workflow_git(map(), map()) :: map()
def put_workflow_git(registry, attrs) when is_map(registry) and is_map(attrs) do
  registry
  |> Map.merge(normalize_map(attrs))
  |> Map.put("updated_at", DateTime.utc_now() |> DateTime.to_iso8601())
end

@spec add_checkpoint(map(), map()) :: map()
def add_checkpoint(registry, checkpoint) when is_map(registry) and is_map(checkpoint) do
  update_in(registry, ["checkpoints"], fn checkpoints ->
    (checkpoints || []) ++ [normalize_map(checkpoint)]
  end)
end

@spec put_subject(map(), String.t(), map()) :: map()
def put_subject(registry, subject_id, subject)
    when is_map(registry) and is_binary(subject_id) and is_map(subject) do
  put_in(registry, ["subjects", subject_id], normalize_map(subject))
end

@spec put_review_state(map(), String.t(), map()) :: map()
def put_review_state(registry, review_node, review_state)
    when is_map(registry) and is_binary(review_node) and is_map(review_state) do
  put_in(registry, ["reviews", review_node], normalize_map(review_state))
end
```

更新 `new_root/1` 默认结构：

```elixir
"checkpoints" => [],
"subjects" => %{},
"reviews" => %{}
```

更新 `valid_registry?/1` 接受这些字段缺省或正确类型。

- [ ] **Step 4: 运行测试确认通过**

Run: `cd elixir; mix test test/symphony_elixir/workflow_artifacts_test.exs`

Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add elixir/lib/symphony_elixir/workflow/registry.ex elixir/test/symphony_elixir/workflow_artifacts_test.exs
git commit -m "feat(workflow): track checkpoints and review subjects"
```

## Task 3: Git Adapter 骨架

**Files:**
- Create: `elixir/lib/symphony_elixir/workflow/git_adapter.ex`
- Create: `elixir/test/symphony_elixir/workflow_git_adapter_test.exs`

- [ ] **Step 1: 写失败测试**

创建测试文件：

```elixir
defmodule SymphonyElixir.WorkflowGitAdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Workflow.GitAdapter

  test "build subject helpers return deterministic maps" do
    assert GitAdapter.build_issue_diff_subject("branch", "base", "head") == %{
             "type" => "issue_diff",
             "branch" => "branch",
             "base_sha" => "base",
             "head_sha" => "head",
             "paths" => []
           }

    assert GitAdapter.build_candidate_range_subject("candidate", "base", "head") == %{
             "type" => "candidate_range",
             "branch" => "candidate",
             "base_sha" => "base",
             "head_sha" => "head",
             "paths" => []
           }
  end

  test "hash_artifact returns sha256 for a file" do
    path = Path.join(System.tmp_dir!(), "git-adapter-artifact-#{System.unique_integer([:positive])}.json")
    File.write!(path, "abc")

    assert {:ok, hash} = GitAdapter.hash_artifact(path)
    assert hash == Base.encode16(:crypto.hash(:sha256, "abc"), case: :lower)

    File.rm!(path)
  end
end
```

- [ ] **Step 2: 运行失败测试**

Run: `cd elixir; mix test test/symphony_elixir/workflow_git_adapter_test.exs`

Expected: 失败，模块不存在。

- [ ] **Step 3: 实现 GitAdapter 最小接口**

创建模块，先实现 subject/hash；实际 Git 操作接口在本任务返回 `{:error, :git_operation_not_configured}`，表示 controller 尚未调用真实 Git 修改。后续任务接入 controller 时，如果需要自动提交和合并，必须先把这些接口改成真实实现或在测试中注入 adapter。

```elixir
defmodule SymphonyElixir.Workflow.GitAdapter do
  @moduledoc """
  Workflow 控制层使用的 Git 事实与操作边界。
  """

  @spec build_issue_diff_subject(String.t(), String.t(), String.t()) :: map()
  def build_issue_diff_subject(branch, base_sha, head_sha) do
    %{"type" => "issue_diff", "branch" => branch, "base_sha" => base_sha, "head_sha" => head_sha, "paths" => []}
  end

  @spec build_candidate_range_subject(String.t(), String.t(), String.t()) :: map()
  def build_candidate_range_subject(branch, base_sha, head_sha) do
    %{"type" => "candidate_range", "branch" => branch, "base_sha" => base_sha, "head_sha" => head_sha, "paths" => []}
  end

  @spec hash_artifact(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def hash_artifact(path) when is_binary(path) do
    with {:ok, body} <- File.read(path) do
      {:ok, :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)}
    end
  end

  def create_candidate_branch(_root_issue, _target_branch), do: {:error, :git_operation_not_configured}
  def create_issue_branch(_root_issue, _issue, _candidate_head_sha), do: {:error, :git_operation_not_configured}
  def commit_issue_workspace(_issue, _workspace), do: {:error, :git_operation_not_configured}
  def push_branch(_branch), do: {:error, :git_operation_not_configured}
  def merge_issue_to_candidate(_issue_branch, _candidate_branch), do: {:error, :git_operation_not_configured}
  def merge_candidate_to_target(_candidate_branch, _target_branch, _expected_head_sha), do: {:error, :git_operation_not_configured}
end
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd elixir; mix test test/symphony_elixir/workflow_git_adapter_test.exs`

Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add elixir/lib/symphony_elixir/workflow/git_adapter.ex elixir/test/symphony_elixir/workflow_git_adapter_test.exs
git commit -m "feat(workflow): add git adapter boundary"
```

## Task 4: Planner Materialization 支持 Review Issue 和 Final Review

**Files:**
- Modify: `elixir/lib/symphony_elixir/workflow/artifacts.ex`
- Modify: `elixir/lib/symphony_elixir/workflow/controller.ex`
- Modify: `elixir/test/symphony_elixir/workflow_artifacts_test.exs`
- Modify: `elixir/test/symphony_elixir/workflow_controller_test.exs`

- [ ] **Step 1: 写失败测试**

新增 plan 校验测试：review node 允许 `reviews` 和 `subject_selector`。

```elixir
test "validate_plan accepts review nodes with subject selector" do
  assert :ok ==
           Artifacts.validate_plan(%{
             "kind" => "issue_graph",
             "summary" => "实现后审查",
             "confidence" => "high",
             "nodes" => [
               %{"node_key" => "implementation", "task_type" => "implementation", "title" => "实现", "goal" => "实现功能", "agent_id" => "codex"},
               %{
                 "node_key" => "implementation_review",
                 "task_type" => "review",
                 "title" => "审查实现",
                 "goal" => "审查实现结果",
                 "agent_id" => "codex",
                 "reviews" => ["implementation"],
                 "subject_selector" => %{"type" => "candidate_range", "from" => "implementation.candidate_before_sha", "to" => "implementation.candidate_after_sha"}
               }
             ],
             "edges" => [%{"from" => "implementation", "to" => "implementation_review"}]
           })
end
```

新增 controller 测试：缺 final review 时自动补建。

```elixir
test "issue_graph materialization auto creates final review when missing" do
  workspace_root = Path.join(System.tmp_dir!(), "workflow-controller-final-review-#{System.unique_integer([:positive])}")

  write_workflow_file!(Workflow.workflow_file_path(),
    tracker_kind: "memory",
    workspace_root: workspace_root,
    orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
  )

  Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
  Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

  root_issue = %Issue{id: "root-final-review", identifier: "YQE-FINAL", title: "root", state: "In Progress"}
  workspace = Path.join(workspace_root, root_issue.identifier)
  File.mkdir_p!(Path.join(workspace, ".symphony"))

  File.write!(
    Artifacts.workflow_plan_path(workspace),
    Jason.encode!(%{
      "kind" => "issue_graph",
      "summary" => "只有实现节点",
      "confidence" => "high",
      "nodes" => [
        %{"node_key" => "implementation", "task_type" => "implementation", "title" => "实现", "goal" => "实现功能", "agent_id" => "codex"}
      ],
      "edges" => []
    })
  )

  assert {:ok, registry} = Controller.handle_planning_completion(root_issue, workspace)
  assert Registry.node(registry, "final_review")["task_type"] == "review"
  assert Registry.node(registry, "final_review")["reviews"] == ["__root_candidate__"]
  assert Registry.node(registry, "final_review")["subject_selector"] == %{"type" => "final_candidate_range"}
  assert Enum.any?(registry["edges"], &(&1["from"] == "implementation" and &1["to"] == "final_review"))
end
```

- [ ] **Step 2: 运行失败测试**

Run: `cd elixir; mix test test/symphony_elixir/workflow_artifacts_test.exs test/symphony_elixir/workflow_controller_test.exs`

Expected: 失败，原因是 review node 字段未保存或 final review 未补建。

- [ ] **Step 3: 实现 plan validation 和 final review 补建**

在 `valid_node?/1` 允许 review 字段可选；如果 `task_type == "review"`，`reviews` 必须是非空字符串数组，`subject_selector` 必须是 map。

在 `materialize_plan/4` 创建节点前调用 `ensure_final_review_node/2`，规则：

```elixir
defp ensure_final_review_node(nodes, edges) do
  if Enum.any?(nodes, &(&1["node_key"] == "final_review")) do
    {nodes, edges}
  else
    executable_keys =
      nodes
      |> Enum.reject(&(&1["task_type"] == "review"))
      |> Enum.map(& &1["node_key"])

    final_node = %{
      "node_key" => "final_review",
      "task_type" => "review",
      "title" => "Final workflow review",
      "goal" => "审查 root candidate 相对目标分支的最终结果",
      "agent_id" => Config.settings!().orchestration.reviewer_agent,
      "reviews" => ["__root_candidate__"],
      "subject_selector" => %{"type" => "final_candidate_range"}
    }

    final_edges = Enum.map(executable_keys, &%{"from" => &1, "to" => "final_review", "kind" => "review"})
    {nodes ++ [final_node], edges ++ final_edges}
  end
end
```

在 `put_derived_node/7` 保存 `reviews` 和 `subject_selector`。

- [ ] **Step 4: 运行测试确认通过**

Run: `cd elixir; mix test test/symphony_elixir/workflow_artifacts_test.exs test/symphony_elixir/workflow_controller_test.exs`

Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add elixir/lib/symphony_elixir/workflow/artifacts.ex elixir/lib/symphony_elixir/workflow/controller.ex elixir/test/symphony_elixir/workflow_artifacts_test.exs elixir/test/symphony_elixir/workflow_controller_test.exs
git commit -m "feat(workflow): materialize review nodes explicitly"
```

## Task 5: Controller 统一 Issue Completion

**Files:**
- Modify: `elixir/lib/symphony_elixir/workflow/controller.ex`
- Modify: `elixir/test/symphony_elixir/workflow_controller_test.exs`

- [ ] **Step 1: 写失败测试**

新增普通 issue 完成测试：

```elixir
test "issue completion stores issue result and unlocks downstream nodes" do
  workspace_root = Path.join(System.tmp_dir!(), "workflow-controller-issue-result-#{System.unique_integer([:positive])}")

  write_workflow_file!(Workflow.workflow_file_path(),
    tracker_kind: "memory",
    workspace_root: workspace_root,
    orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
  )

  Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

  root_issue = %Issue{id: "root-result", identifier: "YQE-RESULT", title: "root", state: "In Progress"}
  issue = %Issue{id: "derived-result", identifier: "YQE-RESULT-1", title: "调研", state: "In Progress"}
  downstream = %Issue{id: "derived-result-2", identifier: "YQE-RESULT-2", title: "实现", state: "Todo"}

  root_issue
  |> Registry.new_root()
  |> Registry.put_node("research", %{"node_key" => "research", "issue_id" => issue.id, "issue_identifier" => issue.identifier, "agent_id" => "codex", "task_type" => "research", "workflow_semantics" => "executable", "status" => "ready", "dependencies" => []})
  |> Registry.put_node("implementation", %{"node_key" => "implementation", "issue_id" => downstream.id, "issue_identifier" => downstream.identifier, "agent_id" => "codex", "task_type" => "implementation", "workflow_semantics" => "executable", "status" => "waiting", "dependencies" => ["research"]})
  |> Map.put("status", "planning_complete")
  |> Registry.save!()

  workspace = Path.join(workspace_root, issue.identifier)
  File.mkdir_p!(Path.join(workspace, ".symphony"))

  File.write!(
    Artifacts.issue_result_path(workspace),
    Jason.encode!(%{
      "schema_version" => 1,
      "node_key" => "research",
      "task_type" => "research",
      "outcome" => "completed",
      "summary" => "调研完成",
      "evidence" => ["research.md"],
      "decisions" => [],
      "open_questions" => []
    })
  )

  assert {:ok, {:completed, "derived-result"}} = Controller.handle_issue_completion(issue, workspace)
  assert {:ok, registry} = Registry.load_by_root_identifier(root_issue.identifier)
  assert Registry.node(registry, "research")["status"] == "completed"
  assert Registry.node(registry, "research")["issue_result"]["summary"] == "调研完成"
  assert Registry.node(registry, "implementation")["status"] == "ready"
end
```

新增 review pass 测试，使用 `issue_result.json` 而不是 `review_decision.json`：

```elixir
test "review issue result pass accepts subject and unlocks downstream nodes" do
  workspace_root = Path.join(System.tmp_dir!(), "workflow-controller-review-result-#{System.unique_integer([:positive])}")

  write_workflow_file!(Workflow.workflow_file_path(),
    tracker_kind: "memory",
    tracker_terminal_states: ["Closed"],
    workspace_root: workspace_root,
    orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
  )

  Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

  root_issue = %Issue{id: "root-review-result", identifier: "YQE-REVIEW-ROOT", title: "root", state: "In Progress"}
  implementation_issue = %Issue{id: "impl-review-result", identifier: "YQE-REVIEW-1", title: "实现", state: "Closed"}
  review_issue = %Issue{id: "review-result", identifier: "YQE-REVIEW-2", title: "审查实现", state: "In Progress"}
  downstream_issue = %Issue{id: "downstream-review-result", identifier: "YQE-REVIEW-3", title: "下游", state: "Todo"}

  root_issue
  |> Registry.new_root()
  |> Registry.put_node("implementation", %{"node_key" => "implementation", "issue_id" => implementation_issue.id, "issue_identifier" => implementation_issue.identifier, "agent_id" => "codex", "task_type" => "implementation", "workflow_semantics" => "executable", "status" => "completed", "dependencies" => [], "issue_result" => %{"summary" => "实现完成"}})
  |> Registry.put_node("implementation_review", %{"node_key" => "implementation_review", "issue_id" => review_issue.id, "issue_identifier" => review_issue.identifier, "agent_id" => "codex", "task_type" => "review", "workflow_semantics" => "executable", "status" => "ready", "dependencies" => ["implementation"], "reviews" => ["implementation"], "subject_selector" => %{"type" => "candidate_range", "from" => "implementation.candidate_before_sha", "to" => "implementation.candidate_after_sha"}})
  |> Registry.put_node("downstream", %{"node_key" => "downstream", "issue_id" => downstream_issue.id, "issue_identifier" => downstream_issue.identifier, "agent_id" => "codex", "task_type" => "implementation", "workflow_semantics" => "executable", "status" => "waiting", "dependencies" => ["implementation_review"]})
  |> Registry.put_subject("subject-implementation", %{"type" => "candidate_range", "base_sha" => "base", "head_sha" => "head", "paths" => [], "status" => "pending"})
  |> Map.put("status", "planning_complete")
  |> Registry.save!()

  workspace = Path.join(workspace_root, review_issue.identifier)
  File.mkdir_p!(Path.join(workspace, ".symphony"))

  File.write!(
    Artifacts.issue_result_path(workspace),
    Jason.encode!(%{
      "schema_version" => 1,
      "node_key" => "implementation_review",
      "task_type" => "review",
      "outcome" => "pass",
      "reviews" => ["implementation"],
      "summary" => "审查通过",
      "evidence" => ["mix test"],
      "decisions" => [],
      "open_questions" => []
    })
  )

  assert {:ok, {:completed, "review-result"}} = Controller.handle_issue_completion(review_issue, workspace)

  assert {:ok, registry} = Registry.load_by_root_identifier(root_issue.identifier)
  assert Registry.node(registry, "implementation_review")["status"] == "completed"
  assert Registry.node(registry, "downstream")["status"] == "ready"
  assert registry["reviews"]["implementation_review"]["status"] == "accepted"
end
```

- [ ] **Step 2: 运行失败测试**

Run: `cd elixir; mix test test/symphony_elixir/workflow_controller_test.exs`

Expected: 失败，原因是 `Controller.handle_issue_completion/2` 不存在。

- [ ] **Step 3: 实现 `handle_issue_completion/2`**

新增 public API：

```elixir
@spec handle_issue_completion(Issue.t(), Path.t()) ::
        {:ok, {:completed, String.t()} | {:needs_rework, String.t(), String.t()} | {:needs_replan, String.t(), String.t()} | {:needs_human, String.t(), String.t()} | {:fail, String.t(), String.t()}}
        | {:error, term()}
def handle_issue_completion(%Issue{} = issue, workspace) when is_binary(workspace) do
  with {:ok, result} <- Artifacts.load_issue_result(workspace),
       :ok <- Tracker.create_comment(issue.id, render_issue_result_comment(issue, result)),
       {:ok, action} <- apply_issue_result(issue, result) do
    {:ok, action}
  end
end
```

普通 node：

```elixir
defp apply_issue_result(issue, %{"task_type" => task_type} = result) when task_type != "review" do
  case Registry.load_by_issue_id(issue.id) do
    {:ok, registry, node_key, _node} ->
      updated_registry =
        registry
        |> put_node_issue_result(node_key, result)
        |> put_node_status(node_key, "completed")
        |> unlock_ready_nodes()
        |> maybe_complete_registry()

      with :ok <- Registry.save!(updated_registry),
           :ok <- Tracker.update_issue_state(issue.id, workflow_terminal_state()),
           :ok <- maybe_close_root_issue(updated_registry, issue.id) do
        {:ok, {:completed, issue.id}}
      end

    {:error, :not_found} ->
      {:ok, {:completed, issue.id}}

    {:error, reason} ->
      {:error, reason}
  end
end
```

review node 复用现有 `maybe_apply_review_registry_update` 的语义，但输入字段从 `decision` 改为 `outcome`。

- [ ] **Step 4: 将旧 completion/review API 改为删除或内部不使用**

删除 `handle_execution_completion/2` 和 `handle_review_completion/2` 的调用点后，再删除函数。若某些测试仍引用旧 API，更新为 `handle_issue_completion/2`。

- [ ] **Step 5: 运行测试确认通过**

Run: `cd elixir; mix test test/symphony_elixir/workflow_controller_test.exs`

Expected: PASS。

- [ ] **Step 6: 提交**

```bash
git add elixir/lib/symphony_elixir/workflow/controller.ex elixir/test/symphony_elixir/workflow_controller_test.exs
git commit -m "feat(workflow): handle issue results uniformly"
```

## Task 6: Prompts 和 AgentRunner 使用 Issue Result

**Files:**
- Modify: `elixir/lib/symphony_elixir/workflow/prompts.ex`
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`
- Modify: `elixir/test/symphony_elixir/core_test.exs`
- Modify: `elixir/test/symphony_elixir/workflow_prompt_contract_test.exs`

- [ ] **Step 1: 写失败测试**

更新 prompt contract：

```elixir
test "execution workflow prompt requires issue_result" do
  prompt = Prompts.append("base", :issue, %{"node_key" => "implementation", "task_type" => "implementation"}, "/tmp/workspace")
  assert prompt =~ "issue_result.json"
  refute prompt =~ "completion_packet.json"
  refute prompt =~ "review_decision.json"
end
```

更新 AgentRunner artifact repair 测试：`:issue` 缺失时修复 `.symphony/issue_result.json`。

- [ ] **Step 2: 运行失败测试**

Run: `cd elixir; mix test test/symphony_elixir/core_test.exs test/symphony_elixir/workflow_prompt_contract_test.exs`

Expected: 旧 prompt 仍提到 completion/review 文件。

- [ ] **Step 3: 修改 Prompts**

`append/4` 支持 `:issue`，删除 `:execution` 和 `:review` 分支。普通 issue prompt 根据 `task_type` 输出同一个 `issue_result.json` schema；review task_type 说明允许 outcome 集合和 reason 规则。

- [ ] **Step 4: 修改 AgentRunner**

`load_workflow_artifact(:issue, workspace)` 使用 `Artifacts.issue_result_path/1` 和 `Artifacts.load_issue_result/1`。

`workflow_artifact_repair_prompt(:issue, ...)` 要求写 `issue_result.json`。

`artifact_workflow_phase?` 后续在 orchestrator 改为包含 `:planning` 和 `:issue`。

- [ ] **Step 5: 运行测试确认通过**

Run: `cd elixir; mix test test/symphony_elixir/core_test.exs test/symphony_elixir/workflow_prompt_contract_test.exs`

Expected: PASS。

- [ ] **Step 6: 提交**

```bash
git add elixir/lib/symphony_elixir/workflow/prompts.ex elixir/lib/symphony_elixir/agent_runner.ex elixir/test/symphony_elixir/core_test.exs elixir/test/symphony_elixir/workflow_prompt_contract_test.exs
git commit -m "feat(workflow): prompt agents for unified issue results"
```

## Task 7: Orchestrator 移除内部 Review Phase

**Files:**
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Modify: `elixir/test/symphony_elixir/workflow_orchestrator_test.exs`
- Modify: `elixir/test/symphony_elixir/orchestrator_status_test.exs`

- [ ] **Step 1: 写失败测试**

更新现有“execution completion queues review”用例为“issue completion releases claim and ready nodes are scheduled by normal poll”。

核心断言：

```elixir
assert metadata.workflow_phase == :issue
refute_receive {:queued_review, _}
```

更新 artifact error 测试期望 `.symphony/issue_result.json`。

- [ ] **Step 2: 运行失败测试**

Run: `cd elixir; mix test test/symphony_elixir/workflow_orchestrator_test.exs test/symphony_elixir/orchestrator_status_test.exs`

Expected: 旧逻辑仍 queue review 或仍引用 old artifact。

- [ ] **Step 3: 修改 orchestrator phase 分派**

`handle_agent_down/5`：

```elixir
case Map.get(running_entry, :workflow_phase) do
  :planning -> handle_workflow_phase_down(state, issue_id, running_entry, :planning)
  :issue -> handle_workflow_phase_down(state, issue_id, running_entry, :issue)
  _ -> handle_legacy_normal_agent_down(...)
end
```

`:issue` completion 调用 `Controller.handle_issue_completion/2`。

删除 `:execution` 完成后 queue review 的逻辑，删除 `:review` 特殊 completion 逻辑。

`Controller.issue_dispatch_metadata/1` 返回 `workflow_phase: :issue`。

- [ ] **Step 4: 更新错误归类和 dashboard 文案**

`artifact_workflow_phase?/1` 接受 `:planning | :issue`。

`normalize_workflow_phase/1` 支持 `"issue"`。

旧 `"execution"` / `"review"` 分支如果只用于错误恢复测试，删除对应特殊期望。

- [ ] **Step 5: 运行测试确认通过**

Run: `cd elixir; mix test test/symphony_elixir/workflow_orchestrator_test.exs test/symphony_elixir/orchestrator_status_test.exs`

Expected: PASS。

- [ ] **Step 6: 提交**

```bash
git add elixir/lib/symphony_elixir/orchestrator.ex elixir/test/symphony_elixir/workflow_orchestrator_test.exs elixir/test/symphony_elixir/orchestrator_status_test.exs
git commit -m "feat(workflow): run review as normal issue nodes"
```

## Task 8: 文档和工作流契约更新

**Files:**
- Modify: `elixir/WORKFLOW.md`
- Modify: `elixir/docs/issue_driven_dynamic_workflow.md`
- Modify: `docs/superpowers/specs/2026-06-27-issue-graph-candidate-review-design.md` if implementation naming diverges.

- [ ] **Step 1: 搜索旧契约**

Run: `rg -n "completion_packet|review_decision|execution phase|review phase|Completion Packet|Review Decision" elixir/WORKFLOW.md elixir/docs docs/superpowers/specs`

Expected: 找到旧 contract。

- [ ] **Step 2: 更新文档**

将非 planning artifact 改为：

```text
非 planning workflow issue 必须写 `.symphony/issue_result.json`。
review 是普通 issue node；是否需要审查由 workflow graph 的 review issue 和依赖边表达。
```

- [ ] **Step 3: 搜索确认旧契约移除**

Run: `rg -n "completion_packet|review_decision|Completion Packet|Review Decision" elixir/WORKFLOW.md elixir/docs docs/superpowers/specs`

Expected: 只允许历史说明或非目标中出现；当前 agent contract 不再要求旧文件。

- [ ] **Step 4: 提交**

```bash
git add elixir/WORKFLOW.md elixir/docs/issue_driven_dynamic_workflow.md docs/superpowers/specs/2026-06-27-issue-graph-candidate-review-design.md
git commit -m "docs(workflow): update issue result contract"
```

## Task 9: 全量针对性验证和清理

**Files:**
- Modify: only files already listed in Tasks 1-8 whose tests fail during this task.

- [ ] **Step 1: 运行 workflow 相关测试**

Run:

```bash
cd elixir
mix test test/symphony_elixir/workflow_artifacts_test.exs \
         test/symphony_elixir/workflow_controller_test.exs \
         test/symphony_elixir/workflow_orchestrator_test.exs \
         test/symphony_elixir/workflow_prompt_contract_test.exs \
         test/symphony_elixir/core_test.exs
```

Expected: PASS。

- [ ] **Step 2: 运行 broader workflow smoke tests**

Run:

```bash
cd elixir
mix test test/symphony_elixir/workflow_smoke_test.exs
```

Expected: PASS，或者只失败在明确需要按新模型重写的旧 smoke contract；若失败，更新 fake agent scripts 写 `issue_result.json`。

- [ ] **Step 3: 搜索旧 API 残留**

Run:

```bash
rg -n "completion_packet_path|review_decision_path|load_completion_packet|load_review_decision|handle_execution_completion|handle_review_completion|queue_review|workflow_phase: :execution|workflow_phase: :review|completion_packet.json|review_decision.json" elixir/lib elixir/test
```

Expected: 无代码路径残留；测试中不再断言旧 artifact。文档历史引用另用 Task 8 管控。

- [ ] **Step 4: 运行格式和完整测试**

Run:

```bash
cd elixir
mix format --check-formatted
mix test
```

Expected: PASS。

- [ ] **Step 5: 最终提交**

```bash
git status --short
git add elixir docs
git commit -m "feat(workflow): unify issue graph orchestration"
```

只提交本计划相关文件，不提交用户已有的 `elixir/WORKFLOW.local.md` 修改，除非用户明确要求。

## 自检

- Spec coverage:
  - issue 都是一等 node：Task 4、5、7。
  - review 不是内部 phase：Task 4、5、7。
  - 统一 `.symphony/issue_result.json`：Task 1、5、6。
  - candidate/checkpoint/subject registry：Task 2、3、5。
  - Git 事实由 adapter/controller 生成：Task 3、5。
  - final review 强制：Task 4、7。
  - 文档契约：Task 8。
- Placeholder scan:
  - 本计划没有未解析占位项。
  - Task 5 的 review pass 测试已经给出完整 ExUnit 结构和断言。
- Type consistency:
  - 结果文件统一为 `.symphony/issue_result.json`。
  - result 字段统一使用 `outcome`，不再使用 review 专属 `decision`。
  - registry subject 状态统一为 `pending | accepted | failed | stale`。
