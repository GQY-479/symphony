# Workflow Orchestration Unification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make issue execution conform to the original workflow design: every issue runs through one workflow state machine, artifacts and registry are authoritative, and Linear comments/workpads are visibility only.

**Architecture:** The control layer remains in `Orchestrator`, `Workflow.Controller`, `Workflow.Registry`, and `Workflow.Artifacts`. Simple work is represented as a `direct_execution` workflow node, complex work as an `issue_graph`, and blocked planning as `needs_human_input`; no separate long-term execution model owns state. Tests are added at artifact, controller, orchestrator, prompt, and smoke layers so each phase and the actual orchestration loop prove the intended behavior.

**Tech Stack:** Elixir, ExUnit, Jason, the existing memory tracker, fake CLI/Codex app-server backends, file-backed workflow registry.

---

## File Structure

- Modify: `elixir/WORKFLOW.md`
  - Make orchestration the default documented path.
  - Replace workpad/comment-as-truth language with artifact/registry-as-truth language.
  - Keep workpad guidance only as a visibility surface for non-workflow progress notes.
- Modify: `elixir/lib/symphony_elixir/config/schema.ex`
  - Default orchestration to enabled.
  - Add a compatibility escape hatch only if needed for tests or local configs: `orchestration.mode: "workflow" | "legacy"`.
- Modify: `elixir/lib/symphony_elixir/config.ex`
  - Validate new orchestration mode if added.
  - Keep existing agent validation.
- Modify: `elixir/test/support/test_support.exs`
  - Update default orchestration test config to enabled, unless a test explicitly opts out.
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
  - Route all normal issue dispatch through workflow decision logic.
  - Treat no-registry root issues as planning dispatch.
  - Keep legacy dispatch only behind explicit compatibility config, not as the default conceptual branch.
  - Persist enough workflow claim/block/retry state to recover after restart, or reconstruct it from registry and tracker state.
- Modify: `elixir/lib/symphony_elixir/workflow/artifacts.ex`
  - Strengthen `completion_packet.json` and `review_decision.json` validation.
  - Reject evidence-free completion packets.
  - Validate `issue_graph` node uniqueness and edge references at artifact level, not only controller level.
- Modify: `elixir/lib/symphony_elixir/workflow/prompts.ex`
  - Tell planners/executors/reviewers that JSON artifacts are mandatory control signals.
  - Tell executors to include all Completion Packet fields.
  - Tell reviewers that pass is invalid when evidence is missing or insufficient.
- Modify: `elixir/lib/symphony_elixir/workflow/registry.ex`
  - Use atomic write via temp file plus rename.
  - Add helper for deterministic root workspace path that does not run workspace creation hooks.
- Modify: `elixir/lib/symphony_elixir/workflow/controller.ex`
  - Stop creating workspace side effects while building workflow context.
  - Save registry transitions atomically.
  - Make `needs_human` and `fail` review decisions write explicit blocked/failed registry state.
  - Ensure `needs_replan` always schedules the root issue from registry root metadata.
- Create: `elixir/test/symphony_elixir/workflow_prompt_contract_test.exs`
  - Assert the shipped `WORKFLOW.md` and workflow phase prompts preserve the design contract.
- Modify: `elixir/test/symphony_elixir/workflow_artifacts_test.exs`
  - Add stricter schema and invalid graph tests.
- Modify: `elixir/test/symphony_elixir/workflow_controller_test.exs`
  - Add registry state tests for `needs_human`, `fail`, strict packet handling, and root workspace context without hook side effects.
- Modify: `elixir/test/symphony_elixir/workflow_orchestrator_test.exs`
  - Add default workflow dispatch tests and explicit legacy compatibility tests if the compatibility mode is kept.
- Modify: `elixir/test/symphony_elixir/workflow_smoke_test.exs`
  - Add actual orchestration smoke tests for direct execution, missing evidence rejection, needs human, fail, and restart recovery.
- Modify: `elixir/test/symphony_elixir/live_e2e_test.exs`
  - Convert or add a gated live E2E that uses real orchestration, not direct `AgentRunner.run/3`.

---

### Task 1: Lock The Design Contract In Tests

**Files:**
- Create: `elixir/test/symphony_elixir/workflow_prompt_contract_test.exs`
- Test: `elixir/test/symphony_elixir/workflow_prompt_contract_test.exs`

- [ ] **Step 1: Write the failing prompt contract tests**

Create `elixir/test/symphony_elixir/workflow_prompt_contract_test.exs`:

```elixir
defmodule SymphonyElixir.WorkflowPromptContractTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Workflow.Prompts

  @repo_root Path.expand("../..", __DIR__)
  @workflow_md Path.join(@repo_root, "WORKFLOW.md")

  test "shipped WORKFLOW.md makes workflow artifacts and registry authoritative" do
    body = File.read!(@workflow_md)

    assert body =~ "orchestration:"
    assert body =~ "enabled: true"
    assert body =~ "Workflow registry"
    assert body =~ "Completion Packet"
    assert body =~ "Review Decision"
    assert body =~ "artifact"
    assert body =~ "source of truth"

    refute body =~ "Treat a single persistent Linear comment as the source of truth"
    refute body =~ "single persistent scratchpad comment"
    refute body =~ "Use exactly one persistent workpad comment"
  end

  test "phase prompts require structured artifacts as control signals" do
    workspace =
      Path.join(System.tmp_dir!(), "workflow-prompt-contract-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      orchestration: %{enabled: true, artifact_dir: ".symphony"}
    )

    planning = Prompts.append("base", :planning, %{}, workspace)
    execution = Prompts.append("base", :execution, %{}, workspace)
    review = Prompts.append("base", :review, %{}, workspace)

    assert planning =~ "workflow_plan.json"
    assert planning =~ "direct_execution"
    assert planning =~ "issue_graph"
    assert planning =~ "needs_human_input"
    assert planning =~ "控制层"

    assert execution =~ "completion_packet.json"
    assert execution =~ "outcome"
    assert execution =~ "summary"
    assert execution =~ "evidence"
    assert execution =~ "decisions"
    assert execution =~ "open_questions"
    assert execution =~ "next_handoff"

    assert review =~ "review_decision.json"
    assert review =~ "pass"
    assert review =~ "needs_rework"
    assert review =~ "needs_replan"
    assert review =~ "needs_human"
    assert review =~ "fail"
    assert review =~ "evidence"
  end
end
```

- [ ] **Step 2: Run the contract test and verify it fails**

Run:

```bash
cd elixir
mise exec -- mix test test/symphony_elixir/workflow_prompt_contract_test.exs
```

Expected: FAIL because `WORKFLOW.md` still has `enabled: false` and says the persistent Linear comment is the source of truth.

- [ ] **Step 3: Update `WORKFLOW.md` contract language**

In `elixir/WORKFLOW.md`, change frontmatter:

```yaml
orchestration:
  enabled: true
  planner_agent: codex
  reviewer_agent: codex
  artifact_dir: ".symphony"
  planning_max_turns: 1
  review_max_turns: 1
```

Replace the Default posture bullets that currently say workpad/comment is authoritative with:

```md
- Treat Symphony workflow artifacts and the workflow registry as the source of truth for control state.
- Linear comments and workpads are visibility surfaces only; they must not be used as the authoritative workflow state.
- Planning must produce `workflow_plan.json`, execution must produce `completion_packet.json`, and review must produce `review_decision.json` when orchestration is active.
- Completion Packet evidence is required for automatic pass decisions.
```

Replace guardrail language that requires exactly one workpad with:

```md
- Keep Linear comments concise and reviewer-oriented.
- Do not use Linear comments or workpads as the authoritative workflow state; registry and artifacts own state transitions.
```

- [ ] **Step 4: Update phase prompts to encode the same contract**

Modify `elixir/lib/symphony_elixir/workflow/prompts.ex`.

In `planning_prompt/2`, add these bullets after `规划阶段附加要求:`:

```elixir
    - 这是 workflow 控制层消费的规划阶段；`workflow_plan.json` 是控制信号，不是进度备注。
    - Linear comment/workpad 只用于可见性，不能替代 artifact，也不能作为权威状态。
```

In `execution_prompt/2`, add this JSON shape:

```elixir
    - `completion_packet.json` 必须包含所有字段；`outcome`、`summary`、非空 `evidence` 是自动进入 review/pass 链路的最低证据：

      ```json
      {
        "outcome": "completed | blocked | partial | failed",
        "summary": "完成内容或阻塞说明",
        "evidence": ["实际运行过的命令、检查、截图或结构化证据"],
        "decisions": [],
        "open_questions": [],
        "next_handoff": "给 review 或下游节点的交接"
      }
      ```
```

In `review_prompt/2`, add:

```elixir
    - Review Decision 是控制层消费的审查结果；不要用最终回复或 Linear comment 替代 `review_decision.json`。
    - 如果 Completion Packet 缺少 evidence 或 evidence 不足以支撑 summary，不允许输出 `pass`。
```

- [ ] **Step 5: Run the contract test and verify it passes**

Run:

```bash
cd elixir
mise exec -- mix test test/symphony_elixir/workflow_prompt_contract_test.exs
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add elixir/WORKFLOW.md elixir/lib/symphony_elixir/workflow/prompts.ex elixir/test/symphony_elixir/workflow_prompt_contract_test.exs
git commit -m "test: lock workflow orchestration contract"
```

---

### Task 2: Make Workflow The Default Dispatch Model

**Files:**
- Modify: `elixir/lib/symphony_elixir/config/schema.ex`
- Modify: `elixir/lib/symphony_elixir/config.ex`
- Modify: `elixir/test/support/test_support.exs`
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Modify: `elixir/test/symphony_elixir/workflow_orchestrator_test.exs`

- [ ] **Step 1: Write failing dispatch tests for unified default behavior**

Append to `elixir/test/symphony_elixir/workflow_orchestrator_test.exs`:

```elixir
test "orchestration is enabled by default and new root issues enter planning" do
  workspace_root =
    Path.join(System.tmp_dir!(), "workflow-orchestrator-default-#{System.unique_integer([:positive])}")

  write_workflow_file!(Workflow.workflow_file_path(),
    tracker_kind: "memory",
    workspace_root: workspace_root,
    agents: %{
      codex: %{kind: "codex_app_server", command: "codex app-server"}
    },
    routing: %{default_agent: "codex"}
  )

  assert Config.settings!().orchestration.enabled == true

  issue = %Issue{
    id: "root-default-workflow",
    identifier: "YQE-DEFAULT-WORKFLOW",
    title: "Default workflow root",
    state: "Todo"
  }

  assert {:dispatch, metadata} = Orchestrator.workflow_dispatch_decision_for_test(issue, workflow_state())
  assert metadata.workflow_phase == :planning
  assert metadata.agent_id == "codex"
  assert metadata.workflow_root_issue_id == "YQE-DEFAULT-WORKFLOW"
end

test "legacy dispatch requires explicit compatibility mode" do
  workspace_root =
    Path.join(System.tmp_dir!(), "workflow-orchestrator-legacy-mode-#{System.unique_integer([:positive])}")

  write_workflow_file!(Workflow.workflow_file_path(),
    tracker_kind: "memory",
    workspace_root: workspace_root,
    agents: %{
      codex: %{kind: "codex_app_server", command: "codex app-server"}
    },
    routing: %{default_agent: "codex"},
    orchestration: %{enabled: false, mode: "legacy"}
  )

  issue = %Issue{
    id: "legacy-explicit",
    identifier: "YQE-LEGACY",
    title: "Explicit legacy issue",
    state: "Todo"
  }

  assert :legacy = Orchestrator.workflow_dispatch_decision_for_test(issue, workflow_state())
end
```

- [ ] **Step 2: Run the dispatch tests and verify they fail**

Run:

```bash
cd elixir
mise exec -- mix test test/symphony_elixir/workflow_orchestrator_test.exs
```

Expected: FAIL because orchestration currently defaults to disabled and there is no explicit mode field.

- [ ] **Step 3: Add orchestration mode to config schema**

In `elixir/lib/symphony_elixir/config/schema.ex`, update `Orchestration`:

```elixir
embedded_schema do
  field(:enabled, :boolean, default: true)
  field(:mode, :string, default: "workflow")
  field(:planner_agent, :string, default: "codex")
  field(:reviewer_agent, :string, default: "codex")
  field(:artifact_dir, :string, default: ".symphony")
  field(:planning_max_turns, :integer, default: 1)
  field(:review_max_turns, :integer, default: 1)
end
```

Update the cast list:

```elixir
[:enabled, :mode, :planner_agent, :reviewer_agent, :artifact_dir, :planning_max_turns, :review_max_turns]
```

- [ ] **Step 4: Validate orchestration mode**

In `elixir/lib/symphony_elixir/config.ex`, update `validate_orchestration/1` so it accepts only `"workflow"` and `"legacy"`:

```elixir
defp validate_orchestration(settings) do
  orchestration = settings.orchestration

  with :ok <- validate_inclusion("orchestration.mode", orchestration.mode, ["workflow", "legacy"]) do
    if orchestration.mode == "legacy" or orchestration.enabled != true do
      :ok
    else
      agent_ids = Map.keys(settings.agents || %{})

      with :ok <-
             validate_orchestration_agent(
               agent_ids,
               "orchestration.planner_agent",
               orchestration.planner_agent
             ),
           :ok <-
             validate_orchestration_agent(
               agent_ids,
               "orchestration.reviewer_agent",
               orchestration.reviewer_agent
             ) do
        validate_non_blank_string("orchestration.artifact_dir", orchestration.artifact_dir)
      end
    end
  end
end
```

If `validate_inclusion/3` does not exist, add:

```elixir
defp validate_inclusion(_field, value, allowed) when value in allowed, do: :ok

defp validate_inclusion(field, value, allowed) do
  {:error, "#{field} must be one of #{Enum.join(allowed, ", ")}, got #{inspect(value)}"}
end
```

- [ ] **Step 5: Update test workflow defaults**

In `elixir/test/support/test_support.exs`, change defaults:

```elixir
@orchestration_defaults %{
  "enabled" => true,
  "mode" => "workflow",
  "planner_agent" => "codex",
  "reviewer_agent" => "codex",
  "artifact_dir" => ".symphony",
  "planning_max_turns" => 1,
  "review_max_turns" => 1
}
```

Add the mode line in `orchestration_yaml/1`:

```elixir
"  mode: #{yaml_value(Map.get(config, "mode"))}",
```

- [ ] **Step 6: Route legacy only through explicit mode**

In `elixir/lib/symphony_elixir/orchestrator.ex`, replace the `if orchestration.enabled == true do ... else :legacy end` branch in `workflow_dispatch_decision/2` with:

```elixir
cond do
  orchestration.mode == "legacy" ->
    :legacy

  orchestration.enabled == true ->
    case Controller.issue_dispatch_metadata(issue.id) do
      {:ok, metadata} ->
        if Controller.issue_ready?(issue.id) do
          {:dispatch, metadata}
        else
          {:block, Map.put(metadata, :error, "workflow waiting on dependencies")}
        end

      {:error, :not_found} ->
        workflow_root_dispatch_decision(issue, orchestration)

      {:error, reason} ->
        {:block,
         workflow_block_metadata(issue, %{
           workflow_phase: :planning,
           error: "workflow registry lookup failed: #{inspect(reason)}"
         })}
    end

  true ->
    {:block,
     workflow_block_metadata(issue, %{
       workflow_phase: :planning,
       error: "workflow orchestration is disabled; set orchestration.mode: legacy only for compatibility"
     })}
end
```

- [ ] **Step 7: Run the dispatch tests**

Run:

```bash
cd elixir
mise exec -- mix test test/symphony_elixir/workflow_orchestrator_test.exs
```

Expected: PASS after updating any older tests that intentionally expect `:legacy` to set `orchestration: %{enabled: false, mode: "legacy"}`.

- [ ] **Step 8: Commit**

```bash
git add elixir/lib/symphony_elixir/config/schema.ex elixir/lib/symphony_elixir/config.ex elixir/lib/symphony_elixir/orchestrator.ex elixir/test/support/test_support.exs elixir/test/symphony_elixir/workflow_orchestrator_test.exs
git commit -m "feat: make workflow dispatch the default"
```

---

### Task 3: Strengthen Artifact Schemas

**Files:**
- Modify: `elixir/lib/symphony_elixir/workflow/artifacts.ex`
- Modify: `elixir/test/symphony_elixir/workflow_artifacts_test.exs`

- [ ] **Step 1: Write failing artifact validation tests**

Append to `elixir/test/symphony_elixir/workflow_artifacts_test.exs`:

```elixir
test "validate_completion_packet requires all handoff fields and non-empty evidence" do
  valid_packet = %{
    "outcome" => "completed",
    "summary" => "实现完成",
    "evidence" => ["mise exec -- mix test test/symphony_elixir/workflow_controller_test.exs"],
    "decisions" => ["registry remains authoritative"],
    "open_questions" => [],
    "next_handoff" => "review registry transition"
  }

  assert :ok == Artifacts.validate_completion_packet(valid_packet)

  for invalid_packet <- [
        Map.delete(valid_packet, "decisions"),
        Map.delete(valid_packet, "open_questions"),
        Map.delete(valid_packet, "next_handoff"),
        %{valid_packet | "evidence" => []},
        %{valid_packet | "next_handoff" => ""}
      ] do
    assert {:error, :invalid_completion_packet} ==
             Artifacts.validate_completion_packet(invalid_packet)
  end
end

test "validate_plan rejects duplicate node keys and unknown edge references" do
  duplicate_nodes = %{
    "kind" => "issue_graph",
    "summary" => "duplicate node keys",
    "confidence" => "low",
    "nodes" => [
      %{"node_key" => "same", "task_type" => "research", "title" => "A", "goal" => "A", "agent_id" => "codex"},
      %{"node_key" => "same", "task_type" => "implementation", "title" => "B", "goal" => "B", "agent_id" => "codex"}
    ],
    "edges" => []
  }

  unknown_edge = %{
    "kind" => "issue_graph",
    "summary" => "unknown edge",
    "confidence" => "low",
    "nodes" => [
      %{"node_key" => "known", "task_type" => "research", "title" => "A", "goal" => "A", "agent_id" => "codex"}
    ],
    "edges" => [%{"from" => "known", "to" => "missing"}]
  }

  assert {:error, :invalid_workflow_plan} == Artifacts.validate_plan(duplicate_nodes)
  assert {:error, :invalid_workflow_plan} == Artifacts.validate_plan(unknown_edge)
end

test "validate_review_decision requires reason fields for non-pass decisions" do
  assert :ok ==
           Artifacts.validate_review_decision(%{
             "decision" => "needs_human",
             "summary" => "需要用户确认 API key 权限",
             "confidence" => "high",
             "reason" => "缺少权限",
             "requested_input" => "请确认是否允许写入 Linear 项目"
           })

  assert :ok ==
           Artifacts.validate_review_decision(%{
             "decision" => "fail",
             "summary" => "实现破坏现有行为",
             "confidence" => "medium",
             "reason" => "验收命令失败"
           })

  assert {:error, :invalid_review_decision} ==
           Artifacts.validate_review_decision(%{
             "decision" => "needs_human",
             "summary" => "缺信息",
             "confidence" => "medium"
           })
end
```

- [ ] **Step 2: Run artifact tests and verify they fail**

Run:

```bash
cd elixir
mise exec -- mix test test/symphony_elixir/workflow_artifacts_test.exs
```

Expected: FAIL because current completion validation allows empty evidence and missing handoff fields, and plan validation does not reject duplicate keys or unknown references.

- [ ] **Step 3: Implement stricter completion packet validation**

Replace `validate_completion_packet/1` in `elixir/lib/symphony_elixir/workflow/artifacts.ex`:

```elixir
@spec validate_completion_packet(term()) :: :ok | {:error, :invalid_completion_packet}
def validate_completion_packet(%{
      "outcome" => outcome,
      "summary" => summary,
      "evidence" => evidence,
      "decisions" => decisions,
      "open_questions" => open_questions,
      "next_handoff" => next_handoff
    })
    when is_binary(outcome) and is_binary(summary) and is_list(evidence) and
           is_list(decisions) and is_list(open_questions) and is_binary(next_handoff) do
  if non_blank?(outcome) and non_blank?(summary) and non_blank?(next_handoff) and evidence != [] do
    :ok
  else
    {:error, :invalid_completion_packet}
  end
end

def validate_completion_packet(_packet), do: {:error, :invalid_completion_packet}
```

Add helper:

```elixir
defp non_blank?(value) when is_binary(value), do: String.trim(value) != ""
defp non_blank?(_value), do: false
```

- [ ] **Step 4: Implement stricter plan graph validation**

In `validate_plan/1`, after validating nodes and edges for `issue_graph`, call a new reference validator:

```elixir
with :ok <- validate_plan_nodes(nodes),
     :ok <- validate_plan_edges(edges),
     :ok <- validate_plan_node_keys(nodes),
     :ok <- validate_plan_edge_references(nodes, edges) do
  :ok
end
```

Add helpers:

```elixir
defp validate_plan_node_keys(nodes) do
  node_keys = Enum.map(nodes, & &1["node_key"])

  if Enum.all?(node_keys, &non_blank?/1) and Enum.uniq(node_keys) == node_keys do
    :ok
  else
    {:error, :invalid_workflow_plan}
  end
end

defp validate_plan_edge_references(nodes, edges) do
  node_keys = MapSet.new(Enum.map(nodes, & &1["node_key"]))

  if Enum.all?(edges, fn edge ->
       from = edge["from"] || edge[:from]
       to = edge["to"] || edge[:to]
       MapSet.member?(node_keys, from) and MapSet.member?(node_keys, to)
     end) do
    :ok
  else
    {:error, :invalid_workflow_plan}
  end
end
```

- [ ] **Step 5: Implement decision-specific review validation**

Replace `validate_review_decision/1` with:

```elixir
@spec validate_review_decision(term()) :: :ok | {:error, :invalid_review_decision}
def validate_review_decision(%{
      "decision" => decision,
      "summary" => summary,
      "confidence" => confidence
    } = review)
    when decision in @review_decisions and is_binary(summary) and is_binary(confidence) do
  cond do
    not non_blank?(summary) or not non_blank?(confidence) ->
      {:error, :invalid_review_decision}

    decision == "needs_human" ->
      require_non_blank_review_field(review, "reason")
      |> then(fn
        :ok -> require_non_blank_review_field(review, "requested_input")
        error -> error
      end)

    decision in ["needs_rework", "needs_replan", "fail"] ->
      require_non_blank_review_field(review, "reason")

    true ->
      :ok
  end
end

def validate_review_decision(_decision), do: {:error, :invalid_review_decision}

defp require_non_blank_review_field(review, field) do
  if non_blank?(review[field]) do
    :ok
  else
    {:error, :invalid_review_decision}
  end
end
```

- [ ] **Step 6: Update existing tests and fixtures to include required fields**

Update every test fixture that writes `completion_packet.json` so it includes:

```elixir
"decisions" => [],
"open_questions" => [],
"next_handoff" => "review this completion"
```

Update every `needs_rework`, `needs_replan`, `needs_human`, or `fail` `review_decision.json` fixture so it includes:

```elixir
"reason" => "test reason"
```

For `needs_human`, also include:

```elixir
"requested_input" => "test requested input"
```

- [ ] **Step 7: Run artifact tests**

Run:

```bash
cd elixir
mise exec -- mix test test/symphony_elixir/workflow_artifacts_test.exs
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add elixir/lib/symphony_elixir/workflow/artifacts.ex elixir/test/symphony_elixir/workflow_artifacts_test.exs elixir/test/symphony_elixir
git commit -m "feat: enforce workflow artifact schemas"
```

---

### Task 4: Make Review Outcomes Authoritative In Registry

**Files:**
- Modify: `elixir/lib/symphony_elixir/workflow/controller.ex`
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Modify: `elixir/test/symphony_elixir/workflow_controller_test.exs`
- Modify: `elixir/test/symphony_elixir/workflow_orchestrator_test.exs`

- [ ] **Step 1: Write failing controller tests for `needs_human` and `fail`**

Append to `elixir/test/symphony_elixir/workflow_controller_test.exs`:

```elixir
test "review needs_human marks node and registry blocked with requested input" do
  workspace_root =
    Path.join(System.tmp_dir!(), "workflow-controller-review-human-#{System.unique_integer([:positive])}")

  write_workflow_file!(Workflow.workflow_file_path(),
    tracker_kind: "memory",
    workspace_root: workspace_root,
    orchestration: %{enabled: true, artifact_dir: ".symphony"}
  )

  root_issue = %Issue{id: "root-human", identifier: "YQE-HUMAN", title: "root", state: "In Progress"}
  reviewed_issue = %Issue{id: "derived-human", identifier: "YQE-HUMAN-1", title: "needs human", state: "In Progress"}

  root_issue
  |> Registry.new_root()
  |> Registry.put_node("implementation", %{
    "node_key" => "implementation",
    "issue_id" => reviewed_issue.id,
    "issue_identifier" => reviewed_issue.identifier,
    "agent_id" => "codex",
    "task_type" => "implementation",
    "workflow_semantics" => "executable",
    "status" => "ready",
    "dependencies" => []
  })
  |> Map.put("status", "planning_complete")
  |> Registry.save!()

  workspace = Path.join(workspace_root, reviewed_issue.identifier)
  File.mkdir_p!(Path.join(workspace, ".symphony"))

  File.write!(
    Artifacts.review_decision_path(workspace),
    Jason.encode!(%{
      "decision" => "needs_human",
      "summary" => "需要确认外部 API 权限",
      "confidence" => "high",
      "reason" => "无法判断是否允许写入生产 Linear 项目",
      "requested_input" => "请确认是否允许创建派生 Linear issue"
    })
  )

  assert {:ok, {:needs_human, "derived-human", "需要确认外部 API 权限"}} =
           Controller.handle_review_completion(reviewed_issue, workspace)

  assert {:ok, registry} = Registry.load_by_root_identifier(root_issue.identifier)
  assert registry["status"] == "blocked"
  assert registry["blocked_reason"] == "需要确认外部 API 权限"
  assert registry["human_input_request"] == "请确认是否允许创建派生 Linear issue"
  assert Registry.node(registry, "implementation")["status"] == "blocked"
end

test "review fail marks node and registry failed without pretending completion" do
  workspace_root =
    Path.join(System.tmp_dir!(), "workflow-controller-review-fail-#{System.unique_integer([:positive])}")

  write_workflow_file!(Workflow.workflow_file_path(),
    tracker_kind: "memory",
    workspace_root: workspace_root,
    orchestration: %{enabled: true, artifact_dir: ".symphony"}
  )

  root_issue = %Issue{id: "root-fail", identifier: "YQE-FAIL", title: "root", state: "In Progress"}
  reviewed_issue = %Issue{id: "derived-fail", identifier: "YQE-FAIL-1", title: "fail", state: "In Progress"}

  root_issue
  |> Registry.new_root()
  |> Registry.put_node("implementation", %{
    "node_key" => "implementation",
    "issue_id" => reviewed_issue.id,
    "issue_identifier" => reviewed_issue.identifier,
    "agent_id" => "codex",
    "task_type" => "implementation",
    "workflow_semantics" => "executable",
    "status" => "ready",
    "dependencies" => []
  })
  |> Map.put("status", "planning_complete")
  |> Registry.save!()

  workspace = Path.join(workspace_root, reviewed_issue.identifier)
  File.mkdir_p!(Path.join(workspace, ".symphony"))

  File.write!(
    Artifacts.review_decision_path(workspace),
    Jason.encode!(%{
      "decision" => "fail",
      "summary" => "实现破坏了调度不变量",
      "confidence" => "high",
      "reason" => "workflow smoke 失败"
    })
  )

  assert {:ok, {:fail, "derived-fail", "实现破坏了调度不变量"}} =
           Controller.handle_review_completion(reviewed_issue, workspace)

  assert {:ok, registry} = Registry.load_by_root_identifier(root_issue.identifier)
  assert registry["status"] == "failed"
  assert registry["failure_reason"] == "实现破坏了调度不变量"
  assert Registry.node(registry, "implementation")["status"] == "failed"
end
```

- [ ] **Step 2: Run controller tests and verify they fail**

Run:

```bash
cd elixir
mise exec -- mix test test/symphony_elixir/workflow_controller_test.exs
```

Expected: FAIL because `maybe_apply_review_registry_update/2` currently ignores `needs_human` and `fail`.

- [ ] **Step 3: Implement registry updates for `needs_human`**

In `elixir/lib/symphony_elixir/workflow/controller.ex`, add this clause before the catch-all `maybe_apply_review_registry_update/2`:

```elixir
defp maybe_apply_review_registry_update(%Issue{} = issue, %{"decision" => "needs_human"} = decision) do
  case Registry.load_by_issue_id(issue.id) do
    {:ok, registry, node_key, _node} ->
      registry
      |> put_node_status(node_key, "blocked")
      |> put_in(["nodes", node_key, "review_summary"], decision["summary"])
      |> Map.put("status", "blocked")
      |> Map.put("blocked_reason", decision["summary"])
      |> Map.put("human_input_request", decision["requested_input"] || decision["reason"])
      |> Registry.save!()

    {:error, :not_found} ->
      :ok

    {:error, reason} ->
      {:error, reason}
  end
end
```

- [ ] **Step 4: Implement registry updates for `fail`**

Add:

```elixir
defp maybe_apply_review_registry_update(%Issue{} = issue, %{"decision" => "fail"} = decision) do
  case Registry.load_by_issue_id(issue.id) do
    {:ok, registry, node_key, _node} ->
      registry
      |> put_node_status(node_key, "failed")
      |> put_in(["nodes", node_key, "review_summary"], decision["summary"])
      |> Map.put("status", "failed")
      |> Map.put("failure_reason", decision["summary"])
      |> Registry.save!()

    {:error, :not_found} ->
      :ok

    {:error, reason} ->
      {:error, reason}
  end
end
```

- [ ] **Step 5: Write failing orchestrator dispatch tests for blocked/failed registry**

Append to `elixir/test/symphony_elixir/workflow_orchestrator_test.exs`:

```elixir
test "root issue with blocked registry is blocked with diagnostic metadata" do
  write_workflow_file!(Workflow.workflow_file_path(),
    tracker_kind: "memory",
    orchestration: %{enabled: true, artifact_dir: ".symphony"}
  )

  issue = %Issue{id: "root-blocked", identifier: "YQE-BLOCKED", title: "blocked", state: "In Progress"}

  issue
  |> Registry.new_root()
  |> Map.put("status", "blocked")
  |> Map.put("blocked_reason", "需要人确认范围")
  |> Map.put("human_input_request", "请选择方案 A 或 B")
  |> Registry.save!()

  assert {:block, metadata} = Orchestrator.workflow_dispatch_decision_for_test(issue, workflow_state())
  assert metadata.workflow_phase == :planning
  assert metadata.error =~ "需要人确认范围"
  assert metadata.error =~ "请选择方案 A 或 B"
end

test "root issue with failed registry is blocked instead of replanned or executed" do
  write_workflow_file!(Workflow.workflow_file_path(),
    tracker_kind: "memory",
    orchestration: %{enabled: true, artifact_dir: ".symphony"}
  )

  issue = %Issue{id: "root-failed", identifier: "YQE-FAILED", title: "failed", state: "In Progress"}

  issue
  |> Registry.new_root()
  |> Map.put("status", "failed")
  |> Map.put("failure_reason", "review failed workflow")
  |> Registry.save!()

  assert {:block, metadata} = Orchestrator.workflow_dispatch_decision_for_test(issue, workflow_state())
  assert metadata.workflow_phase == :planning
  assert metadata.error =~ "workflow failed"
  assert metadata.error =~ "review failed workflow"
end
```

- [ ] **Step 6: Implement blocked/failed root dispatch handling**

In `workflow_root_dispatch_decision/2`, add clauses:

```elixir
{:ok, %{"status" => "blocked"} = registry} ->
  {:block,
   workflow_block_metadata(issue, %{
     workflow_phase: :planning,
     workflow_root_issue_id: registry["root_issue_identifier"] || issue.identifier,
     error:
       "workflow blocked: #{registry["blocked_reason"] || "missing reason"}; request: #{registry["human_input_request"] || "-"}"
   })}

{:ok, %{"status" => "failed"} = registry} ->
  {:block,
   workflow_block_metadata(issue, %{
     workflow_phase: :planning,
     workflow_root_issue_id: registry["root_issue_identifier"] || issue.identifier,
     error: "workflow failed: #{registry["failure_reason"] || "missing reason"}"
   })}
```

- [ ] **Step 7: Run controller and orchestrator tests**

Run:

```bash
cd elixir
mise exec -- mix test test/symphony_elixir/workflow_controller_test.exs test/symphony_elixir/workflow_orchestrator_test.exs
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add elixir/lib/symphony_elixir/workflow/controller.ex elixir/lib/symphony_elixir/orchestrator.ex elixir/test/symphony_elixir/workflow_controller_test.exs elixir/test/symphony_elixir/workflow_orchestrator_test.exs
git commit -m "feat: persist review block and failure states"
```

---

### Task 5: Remove Registry And Workspace Side Effects

**Files:**
- Modify: `elixir/lib/symphony_elixir/workflow/registry.ex`
- Modify: `elixir/lib/symphony_elixir/workflow/controller.ex`
- Modify: `elixir/test/symphony_elixir/workflow_artifacts_test.exs`
- Modify: `elixir/test/symphony_elixir/workflow_controller_test.exs`

- [ ] **Step 1: Write failing atomic registry write test**

Append to `elixir/test/symphony_elixir/workflow_artifacts_test.exs`:

```elixir
test "registry save writes atomically without leaving temp files" do
  workspace_root =
    Path.join(System.tmp_dir!(), "workflow-registry-atomic-#{System.unique_integer([:positive])}")

  write_workflow_file!(Workflow.workflow_file_path(),
    workspace_root: workspace_root,
    orchestration: %{enabled: true, artifact_dir: ".symphony"}
  )

  root_issue = %Issue{id: "root-atomic", identifier: "YQE-ATOMIC", title: "atomic", state: "In Progress"}
  registry = Registry.new_root(root_issue)

  assert :ok = Registry.save!(registry)

  path = Registry.registry_path(root_issue.identifier)
  assert File.exists?(path)
  assert {:ok, loaded} = Registry.load_by_root_identifier(root_issue.identifier)
  assert loaded["root_issue_identifier"] == root_issue.identifier

  temp_files =
    path
    |> Path.dirname()
    |> File.ls!()
    |> Enum.filter(&String.contains?(&1, ".tmp"))

  assert temp_files == []
end
```

- [ ] **Step 2: Write failing root workspace no-hook test**

Append to `elixir/test/symphony_elixir/workflow_controller_test.exs`:

```elixir
test "issue dispatch metadata computes root workspace without running workspace create hooks" do
  workspace_root =
    Path.join(System.tmp_dir!(), "workflow-controller-root-workspace-no-hook-#{System.unique_integer([:positive])}")

  hook_marker = Path.join(workspace_root, "hook-ran")

  write_workflow_file!(Workflow.workflow_file_path(),
    tracker_kind: "memory",
    workspace_root: workspace_root,
    hook_after_create: "touch #{hook_marker}",
    orchestration: %{enabled: true, artifact_dir: ".symphony"}
  )

  root_issue = %Issue{id: "root-no-hook", identifier: "YQE-NO-HOOK", title: "root", state: "In Progress"}
  derived_issue = %Issue{id: "derived-no-hook", identifier: "YQE-NO-HOOK-1", title: "derived", state: "Todo"}

  root_issue
  |> Registry.new_root()
  |> Registry.put_node("implementation", %{
    "node_key" => "implementation",
    "issue_id" => derived_issue.id,
    "issue_identifier" => derived_issue.identifier,
    "agent_id" => "codex",
    "task_type" => "implementation",
    "workflow_semantics" => "executable",
    "status" => "ready",
    "dependencies" => []
  })
  |> Map.put("status", "planning_complete")
  |> Registry.save!()

  assert {:ok, metadata} = Controller.issue_dispatch_metadata(derived_issue.id)
  assert metadata.workflow_context["root_workspace"] == Path.join(workspace_root, root_issue.identifier)
  refute File.exists?(hook_marker)
end
```

- [ ] **Step 3: Run tests and verify at least root workspace test fails**

Run:

```bash
cd elixir
mise exec -- mix test test/symphony_elixir/workflow_artifacts_test.exs test/symphony_elixir/workflow_controller_test.exs
```

Expected: root workspace test FAILS because `root_workspace_for_registry/1` currently calls `Workspace.create_for_issue/1`.

- [ ] **Step 4: Implement atomic registry save**

Replace `Registry.save!/1` in `elixir/lib/symphony_elixir/workflow/registry.ex`:

```elixir
@spec save!(map()) :: :ok
def save!(registry) when is_map(registry) do
  path = registry_path(registry["root_issue_identifier"])
  dir = Path.dirname(path)
  File.mkdir_p!(dir)

  tmp_path = Path.join(dir, ".#{Path.basename(path)}.#{System.unique_integer([:positive])}.tmp")
  File.write!(tmp_path, Jason.encode_to_iodata!(registry, pretty: true))
  File.rename!(tmp_path, path)
  :ok
after
  if is_binary(tmp_path) and File.exists?(tmp_path), do: File.rm(tmp_path)
end
```

If the compiler rejects the `after` variable scope, use:

```elixir
@spec save!(map()) :: :ok
def save!(registry) when is_map(registry) do
  path = registry_path(registry["root_issue_identifier"])
  dir = Path.dirname(path)
  File.mkdir_p!(dir)

  tmp_path = Path.join(dir, ".#{Path.basename(path)}.#{System.unique_integer([:positive])}.tmp")

  try do
    File.write!(tmp_path, Jason.encode_to_iodata!(registry, pretty: true))
    File.rename!(tmp_path, path)
    :ok
  after
    if File.exists?(tmp_path), do: File.rm(tmp_path)
  end
end
```

- [ ] **Step 5: Add deterministic workspace path helper**

In `elixir/lib/symphony_elixir/workflow/registry.ex`, add:

```elixir
@spec root_workspace_path(map()) :: Path.t() | nil
def root_workspace_path(%{"root_issue_identifier" => identifier}) when is_binary(identifier) do
  Path.join(Config.settings!().workspace.root, identifier)
end

def root_workspace_path(_registry), do: nil
```

- [ ] **Step 6: Remove workspace creation from workflow context**

In `elixir/lib/symphony_elixir/workflow/controller.ex`, replace `root_workspace_for_registry/1` with:

```elixir
defp root_workspace_for_registry(registry) when is_map(registry) do
  Registry.root_workspace_path(registry)
end

defp root_workspace_for_registry(_registry), do: nil
```

Remove unused `alias SymphonyElixir.Workspace` if no longer needed.

- [ ] **Step 7: Run registry/controller tests**

Run:

```bash
cd elixir
mise exec -- mix test test/symphony_elixir/workflow_artifacts_test.exs test/symphony_elixir/workflow_controller_test.exs
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add elixir/lib/symphony_elixir/workflow/registry.ex elixir/lib/symphony_elixir/workflow/controller.ex elixir/test/symphony_elixir/workflow_artifacts_test.exs elixir/test/symphony_elixir/workflow_controller_test.exs
git commit -m "fix: make workflow registry writes and context pure"
```

---

### Task 6: Add Realistic Workflow Smoke Coverage

**Files:**
- Modify: `elixir/test/symphony_elixir/workflow_smoke_test.exs`

- [ ] **Step 1: Add a direct execution smoke test**

Append to `elixir/test/symphony_elixir/workflow_smoke_test.exs`:

```elixir
test "真实 Orchestrator treats simple issue as direct_execution workflow node" do
  stop_default_orchestrator()

  workspace_root =
    Path.join(System.tmp_dir!(), "workflow-smoke-direct-workspaces-#{System.unique_integer([:positive])}")

  agent_script =
    "import json, os, sys; " <>
      "p=sys.argv[1]; os.makedirs('.symphony', exist_ok=True); " <>
      "phase='plan' if 'workflow_plan.json' in p else ('completion' if 'completion_packet.json' in p else ('review' if 'review_decision.json' in p else '')); " <>
      "payloads={" <>
      "'plan': {'kind':'direct_execution','summary':'simple issue can run as root node','confidence':'high','agent_id':'codex'}, " <>
      "'completion': {'outcome':'completed','summary':'direct execution completed','evidence':['fake cli wrote completion_packet.json'],'decisions':['used direct execution root node'],'open_questions':[],'next_handoff':'review direct execution'}, " <>
      "'review': {'decision':'pass','summary':'direct execution review passed','confidence':'high'}}; " <>
      "paths={'plan':'.symphony/workflow_plan.json','completion':'.symphony/completion_packet.json','review':'.symphony/review_decision.json'}; " <>
      "phase or sys.exit(2); open(paths[phase], 'w', encoding='utf-8').write(json.dumps(payloads[phase]))"

  write_workflow_file!(Workflow.workflow_file_path(),
    tracker_kind: "memory",
    tracker_active_states: ["Todo", "In Progress"],
    tracker_terminal_states: ["Done", "Closed", "Cancelled", "Canceled", "Duplicate"],
    poll_interval_ms: 50,
    workspace_root: workspace_root,
    workspace_preserve_terminal: true,
    max_concurrent_agents: 2,
    max_turns: 1,
    agents: %{codex: %{kind: "cli_run", command: "/usr/bin/env", args: ["python3", "-c", agent_script], timeout_ms: 10_000}},
    routing: %{default_agent: "codex"},
    orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony", planning_max_turns: 1, review_max_turns: 1},
    prompt: "Smoke issue {{ issue.identifier }} {{ issue.title }}"
  )

  root_issue = %Issue{
    id: "workflow-smoke-direct-root",
    identifier: "SMOKE-DIRECT-1",
    title: "Smoke direct root issue",
    state: "In Progress"
  }

  Application.put_env(:symphony_elixir, :memory_tracker_issues, [root_issue])
  Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

  orchestrator_name = Module.concat(__MODULE__, :SmokeDirectOrchestrator)
  {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

  on_exit(fn ->
    if Process.alive?(pid), do: Process.exit(pid, :normal)
    restart_default_orchestrator()
    File.rm_rf(workspace_root)
  end)

  unless eventually?(fn ->
           issues = Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
           root = Enum.find(issues, &(&1.id == root_issue.id))

           root && root.state == "Done" && orchestrator_idle?(orchestrator_name)
         end) do
    flunk("""
    direct workflow smoke did not close

    issues:
    #{inspect(Application.get_env(:symphony_elixir, :memory_tracker_issues, []), pretty: true)}

    registry:
    #{inspect(Registry.load_by_root_identifier(root_issue.identifier), pretty: true)}

    snapshot:
    #{inspect(Orchestrator.snapshot(orchestrator_name, 1_000), pretty: true)}
    """)
  end

  assert {:ok, registry} = Registry.load_by_root_identifier(root_issue.identifier)
  assert registry["status"] == "completed"
  assert Registry.node(registry, "root")["task_type"] == "direct_execution"
  assert Registry.node(registry, "root")["status"] == "completed"
end
```

- [ ] **Step 2: Add a missing evidence smoke test**

Append:

```elixir
test "真实 Orchestrator blocks execution when completion packet has no evidence" do
  stop_default_orchestrator()

  workspace_root =
    Path.join(System.tmp_dir!(), "workflow-smoke-missing-evidence-#{System.unique_integer([:positive])}")

  agent_script =
    "import json, os, sys; " <>
      "p=sys.argv[1]; os.makedirs('.symphony', exist_ok=True); " <>
      "phase='plan' if 'workflow_plan.json' in p else ('completion' if 'completion_packet.json' in p else 'review'); " <>
      "payloads={" <>
      "'plan': {'kind':'direct_execution','summary':'simple issue','confidence':'high','agent_id':'codex'}, " <>
      "'completion': {'outcome':'completed','summary':'claims done without evidence','evidence':[],'decisions':[],'open_questions':[],'next_handoff':'review'}, " <>
      "'review': {'decision':'pass','summary':'should not run','confidence':'high'}}; " <>
      "paths={'plan':'.symphony/workflow_plan.json','completion':'.symphony/completion_packet.json','review':'.symphony/review_decision.json'}; " <>
      "open(paths[phase], 'w', encoding='utf-8').write(json.dumps(payloads[phase]))"

  write_workflow_file!(Workflow.workflow_file_path(),
    tracker_kind: "memory",
    tracker_active_states: ["Todo", "In Progress"],
    tracker_terminal_states: ["Done", "Closed", "Cancelled", "Canceled", "Duplicate"],
    poll_interval_ms: 50,
    workspace_root: workspace_root,
    workspace_preserve_terminal: true,
    max_concurrent_agents: 2,
    max_turns: 1,
    agents: %{codex: %{kind: "cli_run", command: "/usr/bin/env", args: ["python3", "-c", agent_script], timeout_ms: 10_000}},
    routing: %{default_agent: "codex"},
    orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony", planning_max_turns: 1, review_max_turns: 1},
    prompt: "Smoke issue {{ issue.identifier }} {{ issue.title }}"
  )

  root_issue = %Issue{
    id: "workflow-smoke-no-evidence-root",
    identifier: "SMOKE-NO-EVIDENCE-1",
    title: "Smoke no evidence root issue",
    state: "In Progress"
  }

  Application.put_env(:symphony_elixir, :memory_tracker_issues, [root_issue])
  orchestrator_name = Module.concat(__MODULE__, :SmokeMissingEvidenceOrchestrator)
  {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

  on_exit(fn ->
    if Process.alive?(pid), do: Process.exit(pid, :normal)
    restart_default_orchestrator()
    File.rm_rf(workspace_root)
  end)

  unless eventually?(fn ->
           snapshot = Orchestrator.snapshot(orchestrator_name, 1_000)
           Enum.any?(snapshot.blocked, &(&1.workflow_phase == :execution and String.contains?(&1.error, "invalid_completion_packet")))
         end) do
    flunk("""
    missing evidence smoke did not block

    snapshot:
    #{inspect(Orchestrator.snapshot(orchestrator_name, 1_000), pretty: true)}

    registry:
    #{inspect(Registry.load_by_root_identifier(root_issue.identifier), pretty: true)}
    """)
  end
end
```

- [ ] **Step 3: Add `needs_human` and `fail` smoke tests**

Add two smoke tests following the existing rework/replan structure:

```elixir
test "真实 Orchestrator blocks workflow on review needs_human" do
  stop_default_orchestrator()

  workspace_root =
    Path.join(System.tmp_dir!(), "workflow-smoke-needs-human-#{System.unique_integer([:positive])}")

  agent_script =
    "import json, os, sys; " <>
      "p=sys.argv[1]; os.makedirs('.symphony', exist_ok=True); " <>
      "phase='plan' if 'workflow_plan.json' in p else ('completion' if 'completion_packet.json' in p else 'review'); " <>
      "payloads={" <>
      "'plan': {'kind':'direct_execution','summary':'human decision smoke','confidence':'high','agent_id':'codex'}, " <>
      "'completion': {'outcome':'completed','summary':'needs policy decision','evidence':['fake evidence'],'decisions':[],'open_questions':['policy unclear'],'next_handoff':'review policy'}, " <>
      "'review': {'decision':'needs_human','summary':'need human policy decision','confidence':'high','reason':'policy unclear','requested_input':'confirm policy'}}; " <>
      "paths={'plan':'.symphony/workflow_plan.json','completion':'.symphony/completion_packet.json','review':'.symphony/review_decision.json'}; " <>
      "open(paths[phase], 'w', encoding='utf-8').write(json.dumps(payloads[phase]))"

  write_workflow_file!(Workflow.workflow_file_path(),
    tracker_kind: "memory",
    tracker_active_states: ["Todo", "In Progress"],
    tracker_terminal_states: ["Done", "Closed", "Cancelled", "Canceled", "Duplicate"],
    poll_interval_ms: 50,
    workspace_root: workspace_root,
    workspace_preserve_terminal: true,
    max_concurrent_agents: 2,
    max_turns: 1,
    agents: %{codex: %{kind: "cli_run", command: "/usr/bin/env", args: ["python3", "-c", agent_script], timeout_ms: 10_000}},
    routing: %{default_agent: "codex"},
    orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony", planning_max_turns: 1, review_max_turns: 1},
    prompt: "Smoke issue {{ issue.identifier }} {{ issue.title }}"
  )

  root_issue = %Issue{id: "workflow-smoke-human-root", identifier: "SMOKE-HUMAN-1", title: "Smoke human root", state: "In Progress"}
  Application.put_env(:symphony_elixir, :memory_tracker_issues, [root_issue])

  orchestrator_name = Module.concat(__MODULE__, :SmokeNeedsHumanOrchestrator)
  {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

  on_exit(fn ->
    if Process.alive?(pid), do: Process.exit(pid, :normal)
    restart_default_orchestrator()
    File.rm_rf(workspace_root)
  end)

  unless eventually?(fn ->
           {:ok, registry} = Registry.load_by_root_identifier(root_issue.identifier)
           registry["status"] == "blocked"
         rescue
           _ -> false
         end) do
    flunk("needs_human smoke did not block registry")
  end

  assert {:ok, registry} = Registry.load_by_root_identifier(root_issue.identifier)
  assert registry["human_input_request"] == "confirm policy"
end
```

For `fail`, use the same structure but `review` payload:

```json
{"decision":"fail","summary":"review failed smoke","confidence":"high","reason":"expected failure"}
```

Expected final assertions:

```elixir
assert {:ok, registry} = Registry.load_by_root_identifier(root_issue.identifier)
assert registry["status"] == "failed"
assert registry["failure_reason"] == "review failed smoke"
```

- [ ] **Step 4: Run smoke tests**

Run:

```bash
cd elixir
mise exec -- mix test test/symphony_elixir/workflow_smoke_test.exs
```

Expected: PASS after Tasks 2-4 are implemented.

- [ ] **Step 5: Commit**

```bash
git add elixir/test/symphony_elixir/workflow_smoke_test.exs
git commit -m "test: cover real workflow orchestration outcomes"
```

---

### Task 7: Add Durable Recovery For In-Flight Workflow State

**Files:**
- Modify: `elixir/lib/symphony_elixir/workflow/registry.ex`
- Modify: `elixir/lib/symphony_elixir/workflow/controller.ex`
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Modify: `elixir/test/symphony_elixir/workflow_orchestrator_test.exs`
- Modify: `elixir/test/symphony_elixir/workflow_smoke_test.exs`

- [ ] **Step 1: Write failing restart recovery test**

Append to `elixir/test/symphony_elixir/workflow_orchestrator_test.exs`:

```elixir
test "orchestrator restart reconstructs blocked workflow state from registry" do
  workspace_root =
    Path.join(System.tmp_dir!(), "workflow-orchestrator-restart-blocked-#{System.unique_integer([:positive])}")

  write_workflow_file!(Workflow.workflow_file_path(),
    tracker_kind: "memory",
    workspace_root: workspace_root,
    orchestration: %{enabled: true, artifact_dir: ".symphony"}
  )

  root_issue = %Issue{id: "root-restart-blocked", identifier: "YQE-RESTART-BLOCKED", title: "root", state: "In Progress"}

  root_issue
  |> Registry.new_root()
  |> Map.put("status", "blocked")
  |> Map.put("blocked_reason", "needs human after restart")
  |> Map.put("human_input_request", "provide missing scope")
  |> Registry.save!()

  Application.put_env(:symphony_elixir, :memory_tracker_issues, [root_issue])

  assert {:block, metadata} = Orchestrator.workflow_dispatch_decision_for_test(root_issue, workflow_state())
  assert metadata.error =~ "needs human after restart"
  assert metadata.error =~ "provide missing scope"
end
```

Append a second test for in-flight node reconstruction:

```elixir
test "ready registry node is dispatchable after orchestrator state is empty" do
  workspace_root =
    Path.join(System.tmp_dir!(), "workflow-orchestrator-restart-ready-#{System.unique_integer([:positive])}")

  write_workflow_file!(Workflow.workflow_file_path(),
    tracker_kind: "memory",
    workspace_root: workspace_root,
    orchestration: %{enabled: true, artifact_dir: ".symphony"}
  )

  root_issue = %Issue{id: "root-restart-ready", identifier: "YQE-RESTART-READY", title: "root", state: "In Progress"}
  derived_issue = %Issue{id: "derived-restart-ready", identifier: "YQE-RESTART-READY-1", title: "derived", state: "Todo"}

  root_issue
  |> Registry.new_root()
  |> Registry.put_node("implementation", %{
    "node_key" => "implementation",
    "issue_id" => derived_issue.id,
    "issue_identifier" => derived_issue.identifier,
    "agent_id" => "codex",
    "task_type" => "implementation",
    "workflow_semantics" => "executable",
    "status" => "ready",
    "dependencies" => []
  })
  |> Map.put("status", "planning_complete")
  |> Registry.save!()

  assert {:dispatch, metadata} = Orchestrator.workflow_dispatch_decision_for_test(derived_issue, workflow_state())
  assert metadata.workflow_phase == :execution
  assert metadata.workflow_context["node_key"] == "implementation"
end
```

- [ ] **Step 2: Run orchestrator tests**

Run:

```bash
cd elixir
mise exec -- mix test test/symphony_elixir/workflow_orchestrator_test.exs
```

Expected: the ready node test may already pass; blocked restart should pass after Task 4. If both pass, keep them as regression tests and continue to the smoke restart test.

- [ ] **Step 3: Add registry status timestamps**

In `elixir/lib/symphony_elixir/workflow/registry.ex`, add:

```elixir
@spec put_status(map(), String.t(), map()) :: map()
def put_status(registry, status, attrs \\ %{}) when is_map(registry) and is_binary(status) and is_map(attrs) do
  registry
  |> Map.merge(attrs)
  |> Map.put("status", status)
  |> Map.put("updated_at", DateTime.utc_now() |> DateTime.to_iso8601())
end
```

Update controller transitions to use `Registry.put_status/3` for statuses:

```elixir
Registry.put_status(registry, "planning_complete")
Registry.put_status(registry, "needs_human_input", %{"human_input_request" => plan["request"]})
Registry.put_status(registry, "blocked", %{"blocked_reason" => decision["summary"]})
Registry.put_status(registry, "failed", %{"failure_reason" => decision["summary"]})
Registry.put_status(registry, "replanning", %{"replan_request" => decision["summary"]})
Registry.put_status(registry, "completed")
```

- [ ] **Step 4: Add a smoke test for restart before ready node dispatch**

Append to `elixir/test/symphony_elixir/workflow_smoke_test.exs`:

```elixir
test "workflow registry lets a new orchestrator continue after planning completed before execution dispatch" do
  stop_default_orchestrator()

  workspace_root =
    Path.join(System.tmp_dir!(), "workflow-smoke-restart-after-planning-#{System.unique_integer([:positive])}")

  agent_script =
    "import json, os, sys; " <>
      "p=sys.argv[1]; os.makedirs('.symphony', exist_ok=True); " <>
      "phase='plan' if 'workflow_plan.json' in p else ('completion' if 'completion_packet.json' in p else 'review'); " <>
      "payloads={" <>
      "'plan': {'kind':'issue_graph','summary':'restart planning created child','confidence':'high','nodes':[{'node_key':'implementation','task_type':'implementation','title':'Restart child','goal':'continue after restart','agent_id':'codex'}],'edges':[]}, " <>
      "'completion': {'outcome':'completed','summary':'restart child completed','evidence':['fake evidence'],'decisions':[],'open_questions':[],'next_handoff':'review'}, " <>
      "'review': {'decision':'pass','summary':'restart review passed','confidence':'high'}}; " <>
      "paths={'plan':'.symphony/workflow_plan.json','completion':'.symphony/completion_packet.json','review':'.symphony/review_decision.json'}; " <>
      "open(paths[phase], 'w', encoding='utf-8').write(json.dumps(payloads[phase]))"

  write_workflow_file!(Workflow.workflow_file_path(),
    tracker_kind: "memory",
    tracker_active_states: ["Todo", "In Progress"],
    tracker_terminal_states: ["Done", "Closed", "Cancelled", "Canceled", "Duplicate"],
    poll_interval_ms: 50,
    workspace_root: workspace_root,
    workspace_preserve_terminal: true,
    max_concurrent_agents: 1,
    max_turns: 1,
    agents: %{codex: %{kind: "cli_run", command: "/usr/bin/env", args: ["python3", "-c", agent_script], timeout_ms: 10_000}},
    routing: %{default_agent: "codex"},
    orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony", planning_max_turns: 1, review_max_turns: 1},
    prompt: "Smoke issue {{ issue.identifier }} {{ issue.title }}"
  )

  root_issue = %Issue{id: "workflow-smoke-restart-root", identifier: "SMOKE-RESTART-1", title: "Smoke restart root", state: "In Progress"}
  Application.put_env(:symphony_elixir, :memory_tracker_issues, [root_issue])

  first_name = Module.concat(__MODULE__, :SmokeRestartFirstOrchestrator)
  {:ok, first_pid} = Orchestrator.start_link(name: first_name)

  unless eventually?(fn ->
           {:ok, registry} = Registry.load_by_root_identifier(root_issue.identifier)
           registry["status"] == "planning_complete" and Registry.node(registry, "implementation")
         rescue
           _ -> false
         end) do
    flunk("planning did not persist before restart")
  end

  if Process.alive?(first_pid), do: Process.exit(first_pid, :normal)

  second_name = Module.concat(__MODULE__, :SmokeRestartSecondOrchestrator)
  {:ok, second_pid} = Orchestrator.start_link(name: second_name)

  on_exit(fn ->
    if Process.alive?(second_pid), do: Process.exit(second_pid, :normal)
    restart_default_orchestrator()
    File.rm_rf(workspace_root)
  end)

  unless eventually?(fn ->
           issues = Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
           root = Enum.find(issues, &(&1.id == root_issue.id))
           derived = Enum.find(issues, &(&1.id != root_issue.id))
           root && derived && root.state == "Done" && derived.state == "Done" && orchestrator_idle?(second_name)
         end) do
    flunk("workflow did not continue after orchestrator restart")
  end
end
```

- [ ] **Step 5: Run restart tests**

Run:

```bash
cd elixir
mise exec -- mix test test/symphony_elixir/workflow_orchestrator_test.exs test/symphony_elixir/workflow_smoke_test.exs
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add elixir/lib/symphony_elixir/workflow/registry.ex elixir/lib/symphony_elixir/workflow/controller.ex elixir/lib/symphony_elixir/orchestrator.ex elixir/test/symphony_elixir/workflow_orchestrator_test.exs elixir/test/symphony_elixir/workflow_smoke_test.exs
git commit -m "test: prove workflow restart recovery"
```

---

### Task 8: Convert Live E2E To Actual Orchestration

**Files:**
- Modify: `elixir/test/symphony_elixir/live_e2e_test.exs`

- [ ] **Step 1: Inspect existing live E2E guards**

Run:

```bash
cd elixir
sed -n '1,260p' test/symphony_elixir/live_e2e_test.exs
```

Expected: identify existing environment variables that gate live Linear/Codex tests.

- [ ] **Step 2: Add a gated live orchestration test**

Add a test that only runs when the same live test env vars are present plus:

```elixir
@live_orchestration_enabled System.get_env("SYMPHONY_LIVE_ORCHESTRATION_E2E") == "1"
```

Use this skip guard:

```elixir
unless @live_orchestration_enabled do
  @tag :skip
end
```

The live test must:

```elixir
test "live Linear issue runs through real workflow orchestration", context do
  root_issue = create_live_linear_issue!(context, "Live workflow orchestration E2E")

  write_workflow_file!(Workflow.workflow_file_path(),
    tracker_kind: "linear",
    workspace_root: context.workspace_root,
    tracker_required_labels: context.required_labels,
    orchestration: %{
      enabled: true,
      planner_agent: "codex",
      reviewer_agent: "codex",
      artifact_dir: ".symphony",
      planning_max_turns: 1,
      review_max_turns: 1
    },
    prompt: "Run this as a workflow orchestration E2E. For simple work, choose direct_execution and produce valid artifacts."
  )

  orchestrator_name = Module.concat(__MODULE__, :LiveWorkflowOrchestrator)
  {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

  on_exit(fn ->
    if Process.alive?(pid), do: Process.exit(pid, :normal)
  end)

  assert eventually_live?(fn ->
           {:ok, registry} = Registry.load_by_root_identifier(root_issue.identifier)
           registry["status"] in ["completed", "blocked", "failed"]
         end)

  assert {:ok, registry} = Registry.load_by_root_identifier(root_issue.identifier)
  assert map_size(registry["nodes"]) >= 1
end
```

Use the existing helper names in `live_e2e_test.exs`; if helpers differ, keep the same assertion shape but reuse local helper functions instead of creating a second live Linear client path.

- [ ] **Step 3: Ensure the old direct `AgentRunner.run/3` live test is not the only live proof**

If the file currently has only direct runner coverage, keep that test but rename its description to make scope explicit:

```elixir
test "live AgentRunner can execute a single issue without orchestration", context do
```

The new orchestration test must start `Orchestrator` and assert registry state.

- [ ] **Step 4: Run non-live compilation path**

Run:

```bash
cd elixir
mise exec -- mix test test/symphony_elixir/live_e2e_test.exs
```

Expected: PASS with live orchestration test skipped unless `SYMPHONY_LIVE_ORCHESTRATION_E2E=1` is set.

- [ ] **Step 5: Commit**

```bash
git add elixir/test/symphony_elixir/live_e2e_test.exs
git commit -m "test: add gated live workflow orchestration e2e"
```

---

### Task 9: Final Verification And Cleanup

**Files:**
- All files changed by Tasks 1-8.

- [ ] **Step 1: Run targeted workflow suite**

Run:

```bash
cd elixir
mise exec -- mix test \
  test/symphony_elixir/workflow_artifacts_test.exs \
  test/symphony_elixir/workflow_controller_test.exs \
  test/symphony_elixir/workflow_orchestrator_test.exs \
  test/symphony_elixir/workflow_smoke_test.exs \
  test/symphony_elixir/workflow_prompt_contract_test.exs
```

Expected: PASS.

- [ ] **Step 2: Run full test suite**

Run:

```bash
cd elixir
mise exec -- mix test
```

Expected: PASS with the known skipped tests only.

- [ ] **Step 3: Search for forbidden old truth-source language**

Run:

```bash
rg -n "source of truth|persistent Linear comment|single persistent|scratchpad|workpad" elixir/WORKFLOW.md elixir/lib/symphony_elixir elixir/test/symphony_elixir
```

Expected:

- No line says Linear comment/workpad is authoritative.
- Any remaining `workpad` references explicitly describe visibility or non-authoritative notes.
- Test assertions may contain rejected strings in `refute` checks.

- [ ] **Step 4: Confirm no uncommitted accidental files**

Run:

```bash
git status --short
```

Expected: only intended files are modified before the final commit; no temp workspaces or generated artifacts are staged.

- [ ] **Step 5: Commit final cleanup if needed**

If Step 3 or Step 4 required small cleanup:

```bash
git add elixir/WORKFLOW.md elixir/lib/symphony_elixir elixir/test/symphony_elixir elixir/test/support
git commit -m "chore: align workflow orchestration cleanup"
```

- [ ] **Step 6: Report verification**

Final report must include:

```md
Implemented unified workflow orchestration.

Verification:
- `mise exec -- mix test <targeted workflow suite>`: PASS
- `mise exec -- mix test`: PASS

Design alignment:
- Simple issue path is `direct_execution` within workflow.
- Complex issue path is `issue_graph`.
- Linear comments/workpads are visibility only.
- Registry and JSON artifacts own control state.
```

---

## Self-Review

**Spec coverage:** This plan covers the original design requirements that were violated or weakly enforced: unified workflow state machine, artifact-first control signals, direct execution as a workflow node, review outcomes, Completion Packet evidence, registry durability, restart recovery, and actual orchestration smoke tests.

**Placeholder scan:** The plan contains concrete file paths, commands, expected results, and code snippets. There are no open-ended implementation placeholders.

**Type consistency:** The plan uses existing modules and names: `SymphonyElixir.Workflow.Artifacts`, `Registry`, `Controller`, `Orchestrator.workflow_dispatch_decision_for_test/2`, `Workflow.Prompts.append/4`, and existing ExUnit support helpers.
