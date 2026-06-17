# Issue 驱动动态任务编排（第一版）实施计划

> **面向 agent worker：** 实施本计划时必须使用 `superpowers:subagent-driven-development`（推荐）或 `superpowers:executing-plans`，并按任务逐项执行。步骤使用 checkbox（`- [ ]`）语法跟踪进度。

**目标:** 在不破坏现有默认行为的前提下，为 Symphony 增加一个可选开启的第一版动态任务编排闭环：root issue 先进入 planning，复杂任务派生普通 Linear issue，有序执行后产出 Completion Packet，再经过 review 推进到 pass、rework、replan、needs_human 或 root closure。

**架构:** 第一版不引入数据库，也不强依赖 Linear sub-issue，而是在 `workspace.root/.symphony/workflows/` 下保存轻量 workflow registry，并要求 agent 在各自 workspace 的 `.symphony/` 目录内写出 `workflow_plan.json`、`completion_packet.json`、`review_decision.json`。Symphony 控制层基于这些结构化文件和现有 Linear 读写能力推进流程；Linear 继续作为用户可见任务载体，所有关键结果通过评论和 issue 描述回写。

**技术栈:** Elixir、ExUnit、Ecto embedded schema、Jason、文件型 workflow registry、现有 `AgentRunner` / `Orchestrator`、Linear GraphQL、Memory tracker。

---

## 范围收敛

这份计划只覆盖设计文档里的**第一版/MVP**，不尝试一次做完整 workflow engine。

包含：

- `orchestration.enabled` 的可选开启配置。
- root issue -> planning -> derived issue -> execution -> review -> closure 主链。
- `Tracker.create_issue/1` 写能力。
- 文件型 workflow registry。
- `Workflow Plan`、`Completion Packet`、`Review Decision` 三类结构化工件。
- readiness gating、内部 review 阶段、自动 closure / rework / replan / needs_human。
- Linear 评论回写和最小 observability 字段。

不包含：

- 完整 DAG 可视化。
- Linear sub-issue 强依赖。
- comment 反向读取作为主恢复机制。
- 完整 DSL / 条件分支语言。
- 多层嵌套 workflow。
- 通用审批平台。

## 文件结构

- Modify: `elixir/lib/symphony_elixir/config/schema.ex`
  - 新增 `orchestration` 配置 schema。

- Modify: `elixir/lib/symphony_elixir/config.ex`
  - 增加 orchestration 语义校验。

- Modify: `elixir/test/support/test_support.exs`
  - workflow helper 支持 `orchestration` front matter。

- Modify: `elixir/test/symphony_elixir/core_test.exs`
  - 覆盖 orchestration 配置、prompt phase 行为和 root/derived dispatch 基础路径。

- Modify: `elixir/lib/symphony_elixir/tracker.ex`
  - 扩展 tracker callback，支持创建 derived issue。

- Modify: `elixir/lib/symphony_elixir/linear/adapter.ex`
  - 增加 project/team/state 解析和 `issueCreate` 写能力。

- Modify: `elixir/lib/symphony_elixir/tracker/memory.ex`
  - 支持在测试中可变地创建 issue、更新状态并发送事件。

- Modify: `elixir/test/symphony_elixir/extensions_test.exs`
  - 覆盖 tracker `create_issue/1` 的线性和内存实现。

- Create: `elixir/lib/symphony_elixir/workflow/artifacts.ex`
  - 定义三类结构化工件的路径、读写和校验。

- Create: `elixir/lib/symphony_elixir/workflow/registry.ex`
  - 定义 root workflow registry 的持久化、索引与 readiness 计算。

- Create: `elixir/lib/symphony_elixir/workflow/prompts.ex`
  - 为 planning / execution / review 三种 phase 生成附加提示和 artifact contract。

- Create: `elixir/lib/symphony_elixir/workflow/controller.ex`
  - 承担 workflow 级控制逻辑：dispatch mode 判断、planning 成果物物化、packet ingest、review 结果解释、closure。

- Modify: `elixir/lib/symphony_elixir/prompt_builder.ex`
  - 支持把 phase/context 注入 prompt。

- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`
  - 支持 `workflow_phase`、`workflow_context`、phase-specific max turns 和 artifact file contract。

- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
  - 接入 workflow dispatch mode、readiness gating、phase completion hooks 和 root closure。

- Modify: `elixir/lib/symphony_elixir_web/presenter.ex`
  - 暴露 workflow 字段到 API。

- Modify: `elixir/lib/symphony_elixir/status_dashboard.ex`
  - 展示 workflow phase、blocked reason、root issue 标识。

- Modify: `elixir/test/symphony_elixir/orchestrator_status_test.exs`
  - 覆盖 workflow observability payload。

- Create: `elixir/test/symphony_elixir/workflow_artifacts_test.exs`
  - 覆盖 plan / packet / decision 校验和 registry 持久化。

- Create: `elixir/test/symphony_elixir/workflow_controller_test.exs`
  - 覆盖 planning materialization、completion ingest、review action。

- Create: `elixir/test/symphony_elixir/workflow_orchestrator_test.exs`
  - 覆盖 planning dispatch、derived readiness、review/closure。

- Create: `elixir/docs/issue_driven_dynamic_workflow.md`
  - 写明 opt-in 配置、artifact contract、smoke 流程。

- Modify: `elixir/README.md`
  - 链接新文档。

- Modify: `elixir/WORKFLOW.md`
  - 增加可选 orchestration 配置示例与中文说明。

## 关键实现选择

第一版先采用这些具体约束，避免计划在实现时发散：

1. **默认关闭编排**
   - 只有 `orchestration.enabled: true` 时才启用新行为。
   - 保证现有用户继续走“issue 直接执行”的旧路径。

2. **workflow registry 用文件保存**
   - registry 存放在 `<workspace.root>/.symphony/workflows/<root-identifier>.json`。
   - derived issue 的 mapping、readiness、closure 状态都由 registry 驱动。

3. **工件用 workspace 文件交接**
   - planning: `<issue-workspace>/.symphony/workflow_plan.json`
   - execution: `<issue-workspace>/.symphony/completion_packet.json`
   - review: `<issue-workspace>/.symphony/review_decision.json`

4. **Review 第一版默认内部阶段**
   - review 先不物化为独立 Linear issue。
   - 由控制层用 reviewer agent 对同一 issue workspace 发起单独 review turn。
   - Review 结果仍通过 Linear comment 回写。

5. **derived issue 是普通 Linear issue**
   - 不依赖 sub-issue。
   - 通过 title/description/comment 回写人类可见的 root 关系和任务摘要。

6. **第一版不依赖 comment 读取恢复状态**
   - 控制逻辑只依赖 tracker issue 列表、workspace artifacts 和 workflow registry。
   - 评论只做可见性，不做恢复真相源。

---

### Task 1: Orchestration 配置与测试支撑

**Files:**
- Modify: `elixir/lib/symphony_elixir/config/schema.ex`
- Modify: `elixir/lib/symphony_elixir/config.ex`
- Modify: `elixir/test/support/test_support.exs`
- Modify: `elixir/test/symphony_elixir/core_test.exs`

- [ ] **Step 1: 在 test helper 中加入 orchestration front matter**

在 `elixir/test/support/test_support.exs` 的默认 config keyword 中加入：

```elixir
orchestration: nil,
```

在 `sections` 中 `routing_yaml(routing)` 后面追加：

```elixir
orchestration_yaml(orchestration),
```

并在文件底部加入：

```elixir
defp orchestration_yaml(nil), do: nil

defp orchestration_yaml(orchestration) do
  [
    "orchestration:",
    "  enabled: #{yaml_value(Map.get(orchestration, :enabled) || Map.get(orchestration, "enabled") || false)}",
    "  planner_agent: #{yaml_value(Map.get(orchestration, :planner_agent) || Map.get(orchestration, "planner_agent") || "codex")}",
    "  reviewer_agent: #{yaml_value(Map.get(orchestration, :reviewer_agent) || Map.get(orchestration, "reviewer_agent") || "codex")}",
    "  artifact_dir: #{yaml_value(Map.get(orchestration, :artifact_dir) || Map.get(orchestration, "artifact_dir") || ".symphony")}",
    "  planning_max_turns: #{yaml_value(Map.get(orchestration, :planning_max_turns) || Map.get(orchestration, "planning_max_turns") || 1)}",
    "  review_max_turns: #{yaml_value(Map.get(orchestration, :review_max_turns) || Map.get(orchestration, "review_max_turns") || 1)}"
  ]
  |> Enum.join("\n")
end
```

- [ ] **Step 2: 先写失败测试，覆盖 orchestration 缺省值与合法显式配置**

在 `elixir/test/symphony_elixir/core_test.exs` 新增：

```elixir
test "orchestration config defaults to disabled and codex planner/reviewer" do
  settings = Config.settings!()

  assert settings.orchestration.enabled == false
  assert settings.orchestration.planner_agent == "codex"
  assert settings.orchestration.reviewer_agent == "codex"
  assert settings.orchestration.artifact_dir == ".symphony"
  assert settings.orchestration.planning_max_turns == 1
  assert settings.orchestration.review_max_turns == 1
end

test "orchestration config accepts explicit planner and reviewer" do
  write_workflow_file!(Workflow.workflow_file_path(),
    agents: %{
      codex: %{kind: "codex_app_server", command: "codex app-server"},
      mimocode: %{kind: "cli_run", command: "mimo"}
    },
    routing: %{default_agent: "codex"},
    orchestration: %{
      enabled: true,
      planner_agent: "codex",
      reviewer_agent: "mimocode",
      artifact_dir: ".symphony",
      planning_max_turns: 1,
      review_max_turns: 1
    }
  )

  settings = Config.settings!()

  assert settings.orchestration.enabled == true
  assert settings.orchestration.planner_agent == "codex"
  assert settings.orchestration.reviewer_agent == "mimocode"
end
```

- [ ] **Step 3: 再写失败测试，覆盖无效 planner/reviewer 引用**

继续在 `core_test.exs` 新增：

```elixir
test "orchestration config rejects unknown planner or reviewer agent" do
  write_workflow_file!(Workflow.workflow_file_path(),
    agents: %{
      codex: %{kind: "codex_app_server", command: "codex app-server"}
    },
    routing: %{default_agent: "codex"},
    orchestration: %{
      enabled: true,
      planner_agent: "missing-planner",
      reviewer_agent: "codex"
    }
  )

  assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
  assert message =~ "orchestration.planner_agent"

  write_workflow_file!(Workflow.workflow_file_path(),
    agents: %{
      codex: %{kind: "codex_app_server", command: "codex app-server"}
    },
    routing: %{default_agent: "codex"},
    orchestration: %{
      enabled: true,
      planner_agent: "codex",
      reviewer_agent: "missing-reviewer"
    }
  )

  assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
  assert message =~ "orchestration.reviewer_agent"
end
```

- [ ] **Step 4: 在 schema 中加入 orchestration 配置**

在 `elixir/lib/symphony_elixir/config/schema.ex` 的 `Routing` 后面加入：

```elixir
defmodule Orchestration do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field(:enabled, :boolean, default: false)
    field(:planner_agent, :string, default: "codex")
    field(:reviewer_agent, :string, default: "codex")
    field(:artifact_dir, :string, default: ".symphony")
    field(:planning_max_turns, :integer, default: 1)
    field(:review_max_turns, :integer, default: 1)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:enabled, :planner_agent, :reviewer_agent, :artifact_dir, :planning_max_turns, :review_max_turns], empty_values: [])
    |> validate_number(:planning_max_turns, greater_than: 0)
    |> validate_number(:review_max_turns, greater_than: 0)
  end
end
```

在主 schema 的 `embedded_schema do` 中加入：

```elixir
embeds_one(:orchestration, Orchestration, on_replace: :update, defaults_to_struct: true)
```

在 `changeset/2` 里加入：

```elixir
|> cast_embed(:orchestration, with: &Orchestration.changeset/2)
```

- [ ] **Step 5: 在 Config 语义校验中接上 orchestration**

在 `elixir/lib/symphony_elixir/config.ex` 的 `validate_semantics/1` 中，把：

```elixir
with :ok <- validate_agents(settings),
     :ok <- validate_routing(settings) do
```

改成：

```elixir
with :ok <- validate_agents(settings),
     :ok <- validate_routing(settings),
     :ok <- validate_orchestration(settings) do
```

并追加：

```elixir
defp validate_orchestration(settings) do
  orchestration = settings.orchestration

  cond do
    orchestration.enabled != true ->
      :ok

    not Map.has_key?(settings.agents || %{}, orchestration.planner_agent) ->
      invalid_config("orchestration.planner_agent references unknown agent #{inspect(orchestration.planner_agent)}")

    not Map.has_key?(settings.agents || %{}, orchestration.reviewer_agent) ->
      invalid_config("orchestration.reviewer_agent references unknown agent #{inspect(orchestration.reviewer_agent)}")

    String.trim(orchestration.artifact_dir || "") == "" ->
      invalid_config("orchestration.artifact_dir must be a non-empty string")

    true ->
      :ok
  end
end
```

- [ ] **Step 6: 运行配置测试，确认新测试先绿**

Run:

```powershell
cd C:\Users\GQY47\coding\Symphony\elixir
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/core_test.exs'
```

Expected: 新增 orchestration 配置测试通过；若已有其他 config 测试失败，先修正 schema / helper，不进入下一任务。

- [ ] **Step 7: Commit**

```bash
git add elixir/lib/symphony_elixir/config/schema.ex elixir/lib/symphony_elixir/config.ex elixir/test/support/test_support.exs elixir/test/symphony_elixir/core_test.exs
git commit -m "feat: add orchestration workflow config"
```

---

### Task 2: Tracker 写能力与 derived issue 创建

**Files:**
- Modify: `elixir/lib/symphony_elixir/tracker.ex`
- Modify: `elixir/lib/symphony_elixir/linear/adapter.ex`
- Modify: `elixir/lib/symphony_elixir/tracker/memory.ex`
- Modify: `elixir/test/symphony_elixir/extensions_test.exs`

- [ ] **Step 1: 先写失败测试，要求 tracker 支持 create_issue**

在 `elixir/test/symphony_elixir/extensions_test.exs` 的 `FakeLinearClient` 中新增：

```elixir
def fetch_project_for_slug(slug) do
  send(self(), {:fetch_project_for_slug_called, slug})
  {:ok, %{"project_id" => "project-1", "team_id" => "team-1"}}
end
```

在 `tracker delegates to memory and linear adapters` 测试后追加：

```elixir
test "memory tracker can create issues and persist them for later reads" do
  write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
  Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
  Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

  assert {:ok, %Issue{} = issue} =
           SymphonyElixir.Tracker.create_issue(%{
             title: "Derived research task",
             description: "Collect MiMo ACP facts",
             state: "Todo",
             assignee_id: "worker-user"
           })

  assert issue.title == "Derived research task"
  assert issue.state == "Todo"

  assert {:ok, [stored]} = SymphonyElixir.Tracker.fetch_candidate_issues()
  assert stored.title == "Derived research task"
  assert_receive {:memory_tracker_issue_created, %Issue{title: "Derived research task"}}
end
```

继续追加：

```elixir
test "linear adapter creates issues through project lookup and issueCreate" do
  Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

  Process.put(
    {FakeLinearClient, :graphql_results},
    [
      {:ok,
       %{
         "data" => %{
           "projects" => %{
             "nodes" => [
               %{"id" => "project-1", "team" => %{"id" => "team-1"}}
             ]
           }
         }
       }},
      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "team" => %{
               "states" => %{"nodes" => [%{"id" => "state-1"}]}
             }
           }
         }
       }},
      {:ok,
       %{
         "data" => %{
           "issueCreate" => %{
             "success" => true,
             "issue" => %{
               "id" => "issue-created",
               "identifier" => "YQE-321",
               "title" => "Derived design task",
               "description" => "Draft adapter design",
               "url" => "https://linear.app/yqeeqy/issue/YQE-321",
               "state" => %{"name" => "Todo"},
               "labels" => %{"nodes" => []},
               "inverseRelations" => %{"nodes" => []}
             }
           }
         }
       }}
    ]
  )

  assert {:ok, %Issue{} = issue} =
           Adapter.create_issue(%{
             title: "Derived design task",
             description: "Draft adapter design",
             state: "Todo",
             assignee_id: "worker-user"
           })

  assert issue.identifier == "YQE-321"
  assert_receive {:graphql_called, project_lookup_query, %{projectSlug: "project"}}
  assert project_lookup_query =~ "projects"
  assert_receive {:graphql_called, state_lookup_query, %{issueId: "project-1", stateName: "Todo"}}
  assert state_lookup_query =~ "states"
  assert_receive {:graphql_called, create_issue_query, create_issue_vars}
  assert create_issue_query =~ "issueCreate"
  assert create_issue_vars.teamId == "team-1"
  assert create_issue_vars.projectId == "project-1"
  assert create_issue_vars.title == "Derived design task"
  assert create_issue_vars.assigneeId == "worker-user"
end
```

- [ ] **Step 2: 扩展 tracker behaviour**

在 `elixir/lib/symphony_elixir/tracker.ex` 中加入 callback 和委托：

```elixir
  @callback create_issue(map()) :: {:ok, term()} | {:error, term()}
```

以及：

```elixir
  @spec create_issue(map()) :: {:ok, term()} | {:error, term()}
  def create_issue(attrs) when is_map(attrs) do
    adapter().create_issue(attrs)
  end
```

- [ ] **Step 3: 让 Memory tracker 真正可变**

在 `elixir/lib/symphony_elixir/tracker/memory.ex` 中加入：

```elixir
  @spec create_issue(map()) :: {:ok, Issue.t()} | {:error, term()}
  def create_issue(attrs) when is_map(attrs) do
    issue = %Issue{
      id: "memory-issue-" <> Integer.to_string(System.unique_integer([:positive])),
      identifier: "MEM-" <> Integer.to_string(System.unique_integer([:positive])),
      title: Map.fetch!(attrs, :title),
      description: Map.get(attrs, :description),
      state: Map.get(attrs, :state, "Todo"),
      assignee_id: Map.get(attrs, :assignee_id),
      labels: Map.get(attrs, :labels, []),
      blocked_by: [],
      assigned_to_worker: true
    }

    issues = configured_issues()
    Application.put_env(:symphony_elixir, :memory_tracker_issues, issues ++ [issue])
    send_event({:memory_tracker_issue_created, issue})
    {:ok, issue}
  end
```

同时把 `update_issue_state/2` 改成真正改写 env 中的 issue：

```elixir
  def update_issue_state(issue_id, state_name) do
    updated =
      configured_issues()
      |> Enum.map(fn
        %Issue{id: ^issue_id} = issue -> %{issue | state: state_name}
        other -> other
      end)

    Application.put_env(:symphony_elixir, :memory_tracker_issues, updated)
    send_event({:memory_tracker_state_update, issue_id, state_name})
    :ok
  end
```

- [ ] **Step 4: 在 Linear adapter 中新增 issueCreate**

在 `elixir/lib/symphony_elixir/linear/adapter.ex` 顶部加入：

```elixir
  @project_lookup_query """
  query SymphonyResolveProjectBySlug($projectSlug: String!) {
    projects(filter: {slugId: {eq: $projectSlug}}, first: 1) {
      nodes {
        id
        team {
          id
        }
      }
    }
  }
  """

  @issue_create_mutation """
  mutation SymphonyCreateIssue(
    $teamId: String!
    $projectId: String!
    $title: String!
    $description: String!
    $stateId: String
    $assigneeId: String
  ) {
    issueCreate(
      input: {
        teamId: $teamId
        projectId: $projectId
        title: $title
        description: $description
        stateId: $stateId
        assigneeId: $assigneeId
      }
    ) {
      success
      issue {
        id
        identifier
        title
        description
        url
        state {
          name
        }
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: 20) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
      }
    }
  }
  """
```

再加入实现：

```elixir
  @spec create_issue(map()) :: {:ok, SymphonyElixir.Linear.Issue.t()} | {:error, term()}
  def create_issue(attrs) when is_map(attrs) do
    with {:ok, %{project_id: project_id, team_id: team_id}} <- resolve_project(),
         {:ok, state_id} <- resolve_state_id(project_id, Map.get(attrs, :state, "Todo")),
         {:ok, response} <-
           client_module().graphql(@issue_create_mutation, %{
             teamId: team_id,
             projectId: project_id,
             title: Map.fetch!(attrs, :title),
             description: Map.get(attrs, :description, ""),
             stateId: state_id,
             assigneeId: Map.get(attrs, :assignee_id)
           }),
         true <- get_in(response, ["data", "issueCreate", "success"]) == true,
         issue when is_map(issue) <- get_in(response, ["data", "issueCreate", "issue"]),
         %SymphonyElixir.Linear.Issue{} = normalized <- SymphonyElixir.Linear.Client.normalize_issue_for_test(issue) do
      {:ok, normalized}
    else
      false -> {:error, :issue_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_create_failed}
    end
  end
```

并加入 project 解析 helper：

```elixir
  defp resolve_project do
    with {:ok, response} <- client_module().graphql(@project_lookup_query, %{projectSlug: SymphonyElixir.Config.settings!().tracker.project_slug}),
         project when is_map(project) <- get_in(response, ["data", "projects", "nodes", Access.at(0)]) do
      {:ok, %{project_id: project["id"], team_id: get_in(project, ["team", "id"])}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :project_not_found}
    end
  end
```

把原 `resolve_state_id/2` 改成接收 project id 也可工作的版本：

```elixir
  defp resolve_state_id(project_id, state_name) do
    with {:ok, response} <- client_module().graphql(@state_lookup_query, %{issueId: project_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end
```

并把 `@state_lookup_query` 的顶层 `issue(id: $issueId)` 改成 `project(id: $issueId)`，字段路径相应改成 `project -> team -> states`。

- [ ] **Step 5: 运行 tracker / adapter 测试**

Run:

```powershell
cd C:\Users\GQY47\coding\Symphony\elixir
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/extensions_test.exs'
```

Expected: Memory tracker 能保存新 issue；Linear adapter 能完成 project lookup、state lookup 和 issueCreate；现有 comment/state 更新测试仍为绿色。

- [ ] **Step 6: Commit**

```bash
git add elixir/lib/symphony_elixir/tracker.ex elixir/lib/symphony_elixir/linear/adapter.ex elixir/lib/symphony_elixir/tracker/memory.ex elixir/test/symphony_elixir/extensions_test.exs
git commit -m "feat: add tracker issue creation for workflow tasks"
```

---

### Task 3: Workflow Artifacts 与 Registry 基座

**Files:**
- Create: `elixir/lib/symphony_elixir/workflow/artifacts.ex`
- Create: `elixir/lib/symphony_elixir/workflow/registry.ex`
- Create: `elixir/test/symphony_elixir/workflow_artifacts_test.exs`

- [ ] **Step 1: 先写失败测试，定义 artifact 路径和最小校验**

创建 `elixir/test/symphony_elixir/workflow_artifacts_test.exs`：

```elixir
defmodule SymphonyElixir.WorkflowArtifactsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Workflow.Artifacts
  alias SymphonyElixir.Workflow.Registry

  test "artifact helpers build planning, completion, and review paths" do
    write_workflow_file!(Workflow.workflow_file_path(),
      orchestration: %{enabled: true, artifact_dir: ".symphony"}
    )

    workspace = Path.join(System.tmp_dir!(), "workflow-artifacts-paths")

    assert Artifacts.workflow_plan_path(workspace) == Path.join([workspace, ".symphony", "workflow_plan.json"])
    assert Artifacts.completion_packet_path(workspace) == Path.join([workspace, ".symphony", "completion_packet.json"])
    assert Artifacts.review_decision_path(workspace) == Path.join([workspace, ".symphony", "review_decision.json"])
  end

  test "validate_plan accepts direct_execution and issue_graph" do
    assert :ok =
             Artifacts.validate_plan(%{
               "kind" => "direct_execution",
               "summary" => "Task is simple enough to execute directly",
               "confidence" => "high"
             })

    assert :ok =
             Artifacts.validate_plan(%{
               "kind" => "issue_graph",
               "summary" => "Need research and implementation tasks",
               "confidence" => "medium",
               "nodes" => [
                 %{
                   "node_key" => "research-1",
                   "task_type" => "research",
                   "title" => "Research MiMo ACP support",
                   "goal" => "Collect evidence for adapter design",
                   "agent_id" => "codex"
                 }
               ],
               "edges" => []
             })
  end

  test "validate_completion_packet requires outcome summary evidence" do
    assert :ok =
             Artifacts.validate_completion_packet(%{
               "outcome" => "completed",
               "summary" => "Implemented adapter",
               "evidence" => ["mix test test/symphony_elixir/workflow_controller_test.exs"]
             })

    assert {:error, :invalid_completion_packet} =
             Artifacts.validate_completion_packet(%{
               "outcome" => "completed",
               "summary" => "Implemented adapter"
             })
  end

  test "registry persists root workflow and finds node by issue id" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(System.tmp_dir!(), "workflow-registry-root"),
      orchestration: %{enabled: true, artifact_dir: ".symphony"}
    )

    root_issue = %Issue{id: "root-1", identifier: "YQE-100", title: "Workflow root", state: "In Progress"}

    registry =
      Registry.new_root(root_issue)
      |> Registry.put_node("research-1", %{
        issue_id: "issue-1",
        issue_identifier: "YQE-101",
        task_type: "research",
        workflow_semantics: "executable",
        status: "ready"
      })

    :ok = Registry.save!(registry)

    assert {:ok, loaded} = Registry.load_by_root_identifier("YQE-100")
    assert Registry.node_by_issue_id(loaded, "issue-1")["task_type"] == "research"
  end
end
```

- [ ] **Step 2: 实现 Artifacts 模块**

创建 `elixir/lib/symphony_elixir/workflow/artifacts.ex`：

```elixir
defmodule SymphonyElixir.Workflow.Artifacts do
  @moduledoc """
  Path helpers and validators for workflow planning, completion, and review artifacts.
  """

  alias SymphonyElixir.Config

  @workflow_plan_filename "workflow_plan.json"
  @completion_packet_filename "completion_packet.json"
  @review_decision_filename "review_decision.json"

  def workflow_plan_path(workspace), do: artifact_path(workspace, @workflow_plan_filename)
  def completion_packet_path(workspace), do: artifact_path(workspace, @completion_packet_filename)
  def review_decision_path(workspace), do: artifact_path(workspace, @review_decision_filename)

  def load_plan(workspace), do: load_json(workflow_plan_path(workspace), &validate_plan/1)
  def load_completion_packet(workspace), do: load_json(completion_packet_path(workspace), &validate_completion_packet/1)
  def load_review_decision(workspace), do: load_json(review_decision_path(workspace), &validate_review_decision/1)

  def validate_plan(%{"kind" => "direct_execution", "summary" => summary, "confidence" => confidence})
      when is_binary(summary) and is_binary(confidence),
      do: :ok

  def validate_plan(%{"kind" => "needs_human_input", "summary" => summary, "questions" => questions})
      when is_binary(summary) and is_list(questions),
      do: :ok

  def validate_plan(%{"kind" => "issue_graph", "summary" => summary, "confidence" => confidence, "nodes" => nodes, "edges" => edges})
      when is_binary(summary) and is_binary(confidence) and is_list(nodes) and is_list(edges),
      do: validate_plan_nodes(nodes)

  def validate_plan(_plan), do: {:error, :invalid_workflow_plan}

  def validate_completion_packet(%{"outcome" => outcome, "summary" => summary, "evidence" => evidence})
      when is_binary(outcome) and is_binary(summary) and is_list(evidence),
      do: :ok

  def validate_completion_packet(_packet), do: {:error, :invalid_completion_packet}

  def validate_review_decision(%{"decision" => decision, "summary" => summary, "confidence" => confidence})
      when decision in ["pass", "needs_rework", "needs_replan", "needs_human", "fail"] and is_binary(summary) and is_binary(confidence),
      do: :ok

  def validate_review_decision(_decision), do: {:error, :invalid_review_decision}

  defp artifact_path(workspace, filename) do
    Path.join([workspace, artifact_dir(), filename])
  end

  defp artifact_dir do
    Config.settings!().orchestration.artifact_dir
  end

  defp load_json(path, validator) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         :ok <- validator.(decoded) do
      {:ok, decoded}
    end
  end

  defp validate_plan_nodes(nodes) do
    if Enum.all?(nodes, &valid_node?/1), do: :ok, else: {:error, :invalid_workflow_plan}
  end

  defp valid_node?(%{"node_key" => node_key, "task_type" => task_type, "title" => title, "goal" => goal, "agent_id" => agent_id})
       when is_binary(node_key) and is_binary(task_type) and is_binary(title) and is_binary(goal) and is_binary(agent_id),
       do: true

  defp valid_node?(_node), do: false
end
```

- [ ] **Step 3: 实现 Registry 模块**

创建 `elixir/lib/symphony_elixir/workflow/registry.ex`：

```elixir
defmodule SymphonyElixir.Workflow.Registry do
  @moduledoc """
  File-backed workflow registry stored under workspace.root/.symphony/workflows.
  """

  alias SymphonyElixir.{Config, Linear.Issue}

  def new_root(%Issue{} = issue) do
    %{
      "root_issue_id" => issue.id,
      "root_issue_identifier" => issue.identifier,
      "root_title" => issue.title,
      "status" => "planning",
      "nodes" => %{},
      "edges" => [],
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  def put_node(registry, node_key, node) do
    put_in(registry, ["nodes", node_key], node)
  end

  def node(registry, node_key) do
    get_in(registry, ["nodes", node_key])
  end

  def add_edge(registry, edge) do
    update_in(registry, ["edges"], &((&1 || []) ++ [edge]))
  end

  def save!(registry) do
    path = registry_path(registry["root_issue_identifier"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode_to_iodata!(registry, pretty: true))
    :ok
  end

  def load_by_root_identifier(root_identifier) do
    path = registry_path(root_identifier)

    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body) do
      {:ok, decoded}
    end
  end

  def node_by_issue_id(registry, issue_id) do
    registry["nodes"]
    |> Map.values()
    |> Enum.find(fn node -> node["issue_id"] == issue_id end)
  end

  def registry_path(root_identifier) do
    Path.join([Config.settings!().workspace.root, ".symphony", "workflows", "#{root_identifier}.json"])
  end
end
```

- [ ] **Step 4: 运行 workflow artifact 测试**

Run:

```powershell
cd C:\Users\GQY47\coding\Symphony\elixir
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/workflow_artifacts_test.exs'
```

Expected: plan / packet / decision 校验和 registry 持久化测试通过；这一步不接 orchestrator。

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/workflow/artifacts.ex elixir/lib/symphony_elixir/workflow/registry.ex elixir/test/symphony_elixir/workflow_artifacts_test.exs
git commit -m "feat: add workflow artifacts and registry substrate"
```

---

### Task 4: Prompt phase 与 AgentRunner artifact contract

**Files:**
- Create: `elixir/lib/symphony_elixir/workflow/prompts.ex`
- Modify: `elixir/lib/symphony_elixir/prompt_builder.ex`
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`
- Modify: `elixir/test/symphony_elixir/core_test.exs`

- [ ] **Step 1: 先写失败测试，定义 planning / execution / review prompt contract**

在 `elixir/test/symphony_elixir/core_test.exs` 新增：

```elixir
test "prompt builder appends workflow planning artifact contract" do
  write_workflow_file!(Workflow.workflow_file_path(),
    orchestration: %{enabled: true, artifact_dir: ".symphony"}
  )

  issue = %Issue{id: "root-1", identifier: "YQE-100", title: "Plan workflow", description: "Need multi-step work", state: "In Progress"}

  prompt =
    PromptBuilder.build_prompt(issue,
      workflow_phase: :planning,
      workflow_context: %{"root_issue_identifier" => "YQE-100"}
    )

  assert prompt =~ "workflow_plan.json"
  assert prompt =~ "direct_execution"
  assert prompt =~ "issue_graph"
end

test "prompt builder appends completion packet contract with upstream context" do
  write_workflow_file!(Workflow.workflow_file_path(),
    orchestration: %{enabled: true, artifact_dir: ".symphony"}
  )

  issue = %Issue{id: "issue-1", identifier: "YQE-101", title: "Implement adapter", description: "Implement it", state: "In Progress"}

  prompt =
    PromptBuilder.build_prompt(issue,
      workflow_phase: :execution,
      workflow_context: %{
        "root_issue_identifier" => "YQE-100",
        "upstream_packets" => [
          %{"summary" => "Research shows MiMo ACP supports stdio sessions"}
        ]
      }
    )

  assert prompt =~ "completion_packet.json"
  assert prompt =~ "MiMo ACP supports stdio sessions"
end
```

- [ ] **Step 2: 新建 Workflow.Prompts 模块**

创建 `elixir/lib/symphony_elixir/workflow/prompts.ex`：

```elixir
defmodule SymphonyElixir.Workflow.Prompts do
  @moduledoc """
  Appends workflow-phase-specific instructions to the base issue prompt.
  """

  alias SymphonyElixir.Workflow.Artifacts

  def append(base_prompt, nil, _context, _workspace), do: base_prompt

  def append(base_prompt, :planning, context, workspace) do
    """
    #{base_prompt}

    Workflow mode: planning

    You are planning work for root issue #{context["root_issue_identifier"]}.
    Write a JSON file to #{Artifacts.workflow_plan_path(workspace)}.
    Valid plan kinds:
    - direct_execution
    - issue_graph
    - needs_human_input
    """
  end

  def append(base_prompt, :execution, context, workspace) do
    upstream_summary =
      context
      |> Map.get("upstream_packets", [])
      |> Enum.map_join("\n", fn packet -> "- " <> Map.get(packet, "summary", "") end)

    """
    #{base_prompt}

    Workflow mode: execution

    Root issue: #{context["root_issue_identifier"]}
    Upstream handoff:
    #{upstream_summary}

    Before ending the turn, write a JSON completion packet to:
    #{Artifacts.completion_packet_path(workspace)}
    Required keys: outcome, summary, evidence, decisions, open_questions, next_handoff
    """
  end

  def append(base_prompt, :review, context, workspace) do
    """
    #{base_prompt}

    Workflow mode: review

    Review the completion packet for issue #{context["issue_identifier"]}.
    Read and evaluate:
    #{Artifacts.completion_packet_path(workspace)}

    Write a JSON review decision to:
    #{Artifacts.review_decision_path(workspace)}
    Allowed decisions: pass, needs_rework, needs_replan, needs_human, fail
    """
  end
end
```

- [ ] **Step 3: 让 PromptBuilder 支持 workflow_phase**

在 `elixir/lib/symphony_elixir/prompt_builder.ex` 中：

1. 增加 alias：

```elixir
  alias SymphonyElixir.Workflow.Prompts
```

2. 在 `build_prompt/2` 末尾，把：

```elixir
    |> ensure_valid_utf8()
```

改成：

```elixir
    |> ensure_valid_utf8()
    |> Prompts.append(
      Keyword.get(opts, :workflow_phase),
      Keyword.get(opts, :workflow_context, %{}),
      Keyword.get(opts, :workspace)
    )
```

- [ ] **Step 4: AgentRunner 传递 phase 和 workspace**

在 `elixir/lib/symphony_elixir/agent_runner.ex` 的 `build_turn_prompt/5` 中，把第一次 turn 的调用改成：

```elixir
  defp build_turn_prompt(issue, opts, 1, _max_turns, resolved_agent) do
    issue
    |> PromptBuilder.build_prompt(
      Keyword.merge(opts,
        workspace: Keyword.get(opts, :workspace),
        workflow_phase: Keyword.get(opts, :workflow_phase),
        workflow_context: Keyword.get(opts, :workflow_context, %{})
      )
    )
    |> append_runtime_guidance(resolved_agent)
  end
```

再在 `do_run_agent_turns/9` 里构造 prompt 时，把：

```elixir
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns, resolved_agent)
```

改成：

```elixir
    prompt =
      build_turn_prompt(
        issue,
        Keyword.put(opts, :workspace, workspace),
        turn_number,
        max_turns,
        resolved_agent
      )
```

- [ ] **Step 5: 运行 prompt / runner 相关测试**

Run:

```powershell
cd C:\Users\GQY47\coding\Symphony\elixir
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/core_test.exs'
```

Expected: prompt 测试通过，原有 PromptBuilder / AgentRunner 相关测试不回退。

- [ ] **Step 6: Commit**

```bash
git add elixir/lib/symphony_elixir/workflow/prompts.ex elixir/lib/symphony_elixir/prompt_builder.ex elixir/lib/symphony_elixir/agent_runner.ex elixir/test/symphony_elixir/core_test.exs
git commit -m "feat: add workflow phase prompts and artifact contract"
```

---

### Task 5: Workflow Controller 的 planning 物化

**Files:**
- Create: `elixir/lib/symphony_elixir/workflow/controller.ex`
- Create: `elixir/test/symphony_elixir/workflow_controller_test.exs`

- [ ] **Step 1: 先写失败测试，要求 Controller 能把 workflow plan 物化成 derived issues**

创建 `elixir/test/symphony_elixir/workflow_controller_test.exs`：

```elixir
defmodule SymphonyElixir.WorkflowControllerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Workflow.Artifacts
  alias SymphonyElixir.Workflow.Controller
  alias SymphonyElixir.Workflow.Registry

  test "planning completion materializes derived issues and persists registry" do
    workspace_root = Path.join(System.tmp_dir!(), "workflow-controller-root")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    root_issue = %Issue{
      id: "root-1",
      identifier: "YQE-100",
      title: "Add MiMo workflow",
      description: "Need research then implement",
      state: "In Progress",
      assignee_id: "worker-user"
    }

    workspace = Path.join(workspace_root, "YQE-100")
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    File.write!(
      Artifacts.workflow_plan_path(workspace),
      Jason.encode!(%{
        "kind" => "issue_graph",
        "summary" => "Need research and implementation",
        "confidence" => "high",
        "nodes" => [
          %{
            "node_key" => "research-1",
            "task_type" => "research",
            "title" => "Research MiMo ACP support",
            "goal" => "Collect evidence for adapter design",
            "agent_id" => "codex"
          },
          %{
            "node_key" => "implementation-1",
            "task_type" => "implementation",
            "title" => "Implement MiMo adapter",
            "goal" => "Add ACP backend support",
            "agent_id" => "codex"
          }
        ],
        "edges" => [
          %{"from" => "research-1", "to" => "implementation-1", "kind" => "handoff"}
        ]
      })
    )

    assert {:ok, registry} = Controller.handle_planning_completion(root_issue, workspace)
    assert registry["status"] == "planned"
    assert {:ok, stored_registry} = Registry.load_by_root_identifier("YQE-100")
    assert map_size(stored_registry["nodes"]) == 2
    assert_receive {:memory_tracker_issue_created, %Issue{title: "Research MiMo ACP support"}}
    assert_receive {:memory_tracker_issue_created, %Issue{title: "Implement MiMo adapter"}}
    assert_receive {:memory_tracker_comment, "root-1", body}
    assert body =~ "Need research and implementation"
  end
end
```

- [ ] **Step 2: 创建 Controller module，先实现 dispatch_mode/1 和 planning completion**

创建 `elixir/lib/symphony_elixir/workflow/controller.ex`：

```elixir
defmodule SymphonyElixir.Workflow.Controller do
  @moduledoc """
  Workflow-aware control logic layered on top of tracker issues and local registry files.
  """

  alias SymphonyElixir.{Config, Tracker}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Workflow.{Artifacts, Registry}

  def dispatch_mode(%Issue{} = issue) do
    orchestration = Config.settings!().orchestration

    cond do
      orchestration.enabled != true ->
        :legacy

      Registry.find_by_issue_id(issue.id) != nil ->
        :workflow_issue

      true ->
        {:planning, %{workflow_phase: :planning, workflow_root_issue_id: issue.id, agent_id: orchestration.planner_agent}}
    end
  end

  def handle_planning_completion(%Issue{} = root_issue, workspace) do
    with {:ok, plan} <- Artifacts.load_plan(workspace),
         registry <- Registry.new_root(root_issue),
         {:ok, registry} <- materialize_plan(registry, root_issue, plan),
         :ok <- Registry.save!(registry),
         :ok <- Tracker.create_comment(root_issue.id, render_plan_comment(root_issue, plan, registry)) do
      {:ok, registry}
    end
  end

  defp materialize_plan(registry, _root_issue, %{"kind" => "direct_execution"}) do
    {:ok,
     Registry.put_node(registry, "root-execution", %{
       "issue_id" => registry["root_issue_id"],
       "issue_identifier" => registry["root_issue_identifier"],
       "task_type" => "implementation",
       "workflow_semantics" => "executable",
       "status" => "ready",
       "agent_id" => Config.settings!().orchestration.planner_agent
     })}
  end

  defp materialize_plan(registry, root_issue, %{"kind" => "issue_graph", "nodes" => nodes, "edges" => edges}) do
    with {:ok, registry_with_nodes} <- create_derived_nodes(registry, root_issue, nodes) do
      resolved_registry =
        Enum.reduce(edges, registry_with_nodes, fn edge, acc ->
          from_node = Registry.node(acc, edge["from"])
          to_node = Registry.node(acc, edge["to"])

          Registry.add_edge(acc, %{
            "from" => edge["from"],
            "to" => edge["to"],
            "kind" => edge["kind"],
            "from_issue_id" => from_node["issue_id"],
            "to_issue_id" => to_node["issue_id"]
          })
        end)

      {:ok, resolved_registry}
    end
  end

  defp materialize_plan(registry, root_issue, %{"kind" => "needs_human_input"} = plan) do
    :ok =
      Tracker.create_comment(
        root_issue.id,
        "Workflow planning needs human input:\n\n" <> plan["summary"]
      )

    {:ok, Map.put(registry, "status", "needs_human")}
  end

  defp create_derived_nodes(registry, root_issue, nodes) do
    Enum.reduce_while(nodes, {:ok, registry}, fn node, {:ok, acc} ->
      description = """
      Root issue: #{root_issue.identifier}

      Goal:
      #{node["goal"]}

      This issue is managed by Symphony workflow orchestration.
      """

      case Tracker.create_issue(%{
             title: node["title"],
             description: description,
             state: "Todo",
             assignee_id: root_issue.assignee_id
           }) do
        {:ok, %Issue{} = issue} ->
          new_registry =
            Registry.put_node(acc, node["node_key"], %{
              "node_key" => node["node_key"],
              "issue_id" => issue.id,
              "issue_identifier" => issue.identifier,
              "task_type" => node["task_type"],
              "workflow_semantics" => "executable",
              "status" => "ready",
              "agent_id" => node["agent_id"],
              "title" => node["title"]
            })

          {:cont, {:ok, new_registry}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp render_plan_comment(root_issue, plan, registry) do
    node_lines =
      registry["nodes"]
      |> Enum.map(fn {_node_key, node} -> "- #{node["issue_identifier"]}: #{node["title"]}" end)
      |> Enum.join("\n")

    """
    ## Symphony Workflow Plan

    Root issue: #{root_issue.identifier}
    Summary: #{plan["summary"]}
    Kind: #{plan["kind"]}

    Derived issues:
    #{node_lines}
    """
  end
end
```

- [ ] **Step 3: 给 Registry 加 `find_by_issue_id/1`**

在 `elixir/lib/symphony_elixir/workflow/registry.ex` 追加：

```elixir
  def find_by_issue_id(issue_id) when is_binary(issue_id) do
    workflow_dir = Path.join([Config.settings!().workspace.root, ".symphony", "workflows"])

    if File.dir?(workflow_dir) do
      workflow_dir
      |> File.ls!()
      |> Enum.map(&Path.join(workflow_dir, &1))
      |> Enum.find_value(fn path ->
        with {:ok, body} <- File.read(path),
             {:ok, decoded} <- Jason.decode(body),
             node when not is_nil(node) <- node_by_issue_id(decoded, issue_id) do
          %{registry: decoded, node: node}
        else
          _ -> nil
        end
      end)
    end
  end
```

- [ ] **Step 4: 运行 Controller 单元测试**

Run:

```powershell
cd C:\Users\GQY47\coding\Symphony\elixir
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/workflow_controller_test.exs test/symphony_elixir/workflow_artifacts_test.exs'
```

Expected: planning artifact 可以被消费并 materialize 成 derived issues，registry 和 root comment 都被写出。

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/workflow/controller.ex elixir/lib/symphony_elixir/workflow/registry.ex elixir/test/symphony_elixir/workflow_controller_test.exs
git commit -m "feat: materialize workflow plans into derived issues"
```

---

### Task 6: Orchestrator 接入 planning 与 readiness gating

**Files:**
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Create: `elixir/test/symphony_elixir/workflow_orchestrator_test.exs`

- [ ] **Step 1: 先写失败测试，验证 orchestration 开启后 root issue 先进入 planning**

创建 `elixir/test/symphony_elixir/workflow_orchestrator_test.exs`：

```elixir
defmodule SymphonyElixir.WorkflowOrchestratorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator

  test "orchestrator dispatches unknown root issues into planning phase" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex"}
    )

    issue = %Issue{
      id: "root-1",
      identifier: "YQE-100",
      title: "Workflow root",
      state: "In Progress",
      labels: []
    }

    state = %Orchestrator.State{
      running: %{},
      claimed: MapSet.new(),
      retry_attempts: %{},
      blocked: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      max_concurrent_agents: 10
    }

    assert {:planning, meta} = SymphonyElixir.Workflow.Controller.dispatch_mode(issue)
    assert meta.workflow_phase == :planning
    assert meta.agent_id == "codex"
  end
end
```

- [ ] **Step 2: 在 choose_issues 路径中接入 workflow dispatch mode**

在 `elixir/lib/symphony_elixir/orchestrator.ex` 中添加 alias：

```elixir
  alias SymphonyElixir.Workflow.Controller
```

在 `choose_issues/2` 里，找到最终准备 dispatch 的分支，把：

```elixir
state = dispatch_issue(state, issue)
```

改成：

```elixir
state =
  case Controller.dispatch_mode(issue) do
    :legacy ->
      dispatch_issue(state, issue)

    {:planning, metadata} ->
      dispatch_issue(state, issue, nil, nil, Map.new(metadata))

    :workflow_issue ->
      if workflow_issue_ready?(issue) do
        dispatch_issue(state, issue)
      else
        remember_blocked_workflow_issue(state, issue)
      end
  end
```

- [ ] **Step 3: 加入 workflow readiness helpers**

在 `orchestrator.ex` 追加：

```elixir
  defp workflow_issue_ready?(%Issue{id: issue_id}) when is_binary(issue_id) do
    Controller.issue_ready?(issue_id)
  end

  defp remember_blocked_workflow_issue(%State{} = state, %Issue{} = issue) do
    blocked =
      Map.put(state.blocked, issue.id, %{
        identifier: issue.identifier,
        issue_url: issue.url,
        state: issue.state,
        error: "workflow waiting on dependencies"
      })

    %{state | blocked: blocked}
  end
```

同时在 `Workflow.Controller` 中加入：

```elixir
  def issue_ready?(issue_id) when is_binary(issue_id) do
    case Registry.find_by_issue_id(issue_id) do
      %{registry: registry, node: node} ->
        node["status"] == "ready" and dependencies_passed?(registry, issue_id)

      nil ->
        false
    end
  end

  defp dependencies_passed?(registry, issue_id) do
    incoming =
      registry["edges"]
      |> Enum.filter(fn edge -> edge["to_issue_id"] == issue_id or edge["to"] == issue_id end)

    Enum.all?(incoming, fn edge ->
      from_issue_id = edge["from_issue_id"] || edge["from"]

      case node_by_issue_id(registry, from_issue_id) do
        %{"status" => "passed"} -> true
        _ -> false
      end
    end)
  end
```

- [ ] **Step 4: 运行 workflow orchestrator 基础测试**

Run:

```powershell
cd C:\Users\GQY47\coding\Symphony\elixir
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/workflow_orchestrator_test.exs test/symphony_elixir/workflow_controller_test.exs'
```

Expected: root issue 的 dispatch mode 先走 planning；未 ready 的 workflow issue 被 blocked，而不是直接执行。

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/orchestrator.ex elixir/test/symphony_elixir/workflow_orchestrator_test.exs
git commit -m "feat: gate workflow issues through planning and readiness"
```

---

### Task 7: Completion Packet、Review Decision 与 root closure

**Files:**
- Modify: `elixir/lib/symphony_elixir/workflow/controller.ex`
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Modify: `elixir/test/symphony_elixir/workflow_controller_test.exs`
- Modify: `elixir/test/symphony_elixir/workflow_orchestrator_test.exs`

- [ ] **Step 1: 先写失败测试，要求 completion packet 被 ingest 后触发 review**

在 `elixir/test/symphony_elixir/workflow_controller_test.exs` 追加：

```elixir
test "execution completion ingests packet, mirrors comment, and asks for review" do
  workspace_root = Path.join(System.tmp_dir!(), "workflow-review-root")

  write_workflow_file!(Workflow.workflow_file_path(),
    tracker_kind: "memory",
    workspace_root: workspace_root,
    orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
  )

  Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
  Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

  issue = %Issue{id: "issue-1", identifier: "YQE-101", title: "Implement adapter", state: "In Progress"}
  workspace = Path.join(workspace_root, "YQE-101")
  File.mkdir_p!(Path.join(workspace, ".symphony"))

  File.write!(
    Artifacts.completion_packet_path(workspace),
    Jason.encode!(%{
      "outcome" => "completed",
      "summary" => "Added ACP backend adapter",
      "evidence" => ["mix test test/symphony_elixir/workflow_controller_test.exs"],
      "decisions" => ["Use acp_stdio backend"],
      "open_questions" => [],
      "next_handoff" => "Review the evidence and adapter wiring"
    })
  )

  assert {:ok, {:queue_review, metadata}} = Controller.handle_execution_completion(issue, workspace)
  assert metadata.workflow_phase == :review
  assert_receive {:memory_tracker_comment, "issue-1", body}
  assert body =~ "Completion Packet"
  assert body =~ "Added ACP backend adapter"
end
```

- [ ] **Step 2: 在 Controller 中实现 completion ingest 和 review dispatch**

在 `elixir/lib/symphony_elixir/workflow/controller.ex` 追加：

```elixir
  def handle_execution_completion(%Issue{} = issue, workspace) do
    with {:ok, packet} <- Artifacts.load_completion_packet(workspace),
         :ok <- Tracker.create_comment(issue.id, render_completion_comment(issue, packet)) do
      {:ok,
       {:queue_review,
        %{
          workflow_phase: :review,
          workflow_root_issue_id: issue.identifier,
          workflow_context: %{
            "issue_identifier" => issue.identifier,
            "root_issue_identifier" => issue.identifier
          },
          agent_id: Config.settings!().orchestration.reviewer_agent
        }}}
    end
  end

  def handle_review_completion(%Issue{} = issue, workspace) do
    with {:ok, decision} <- Artifacts.load_review_decision(workspace),
         :ok <- Tracker.create_comment(issue.id, render_review_comment(issue, decision)) do
      apply_review_decision(issue, decision)
    end
  end

  defp render_completion_comment(issue, packet) do
    """
    ## Completion Packet

    Issue: #{issue.identifier}
    Outcome: #{packet["outcome"]}
    Summary: #{packet["summary"]}

    Evidence:
    #{Enum.map_join(packet["evidence"], "\n", &"- #{&1}")}
    """
  end

  defp render_review_comment(issue, decision) do
    """
    ## Review Decision

    Issue: #{issue.identifier}
    Decision: #{decision["decision"]}
    Confidence: #{decision["confidence"]}
    Summary: #{decision["summary"]}
    """
  end
```

- [ ] **Step 3: 实现 review decision 的最小动作集**

继续在 `workflow/controller.ex` 追加：

```elixir
  defp apply_review_decision(issue, %{"decision" => "pass"}) do
    {:ok, {:pass, issue.id}}
  end

  defp apply_review_decision(issue, %{"decision" => "needs_human", "summary" => summary}) do
    {:ok, {:needs_human, issue.id, summary}}
  end

  defp apply_review_decision(issue, %{"decision" => "needs_replan", "summary" => summary}) do
    {:ok, {:needs_replan, issue.id, summary}}
  end

  defp apply_review_decision(issue, %{"decision" => "needs_rework", "summary" => summary}) do
    {:ok, {:needs_rework, issue.id, summary}}
  end

  defp apply_review_decision(issue, %{"decision" => "fail", "summary" => summary}) do
    {:ok, {:fail, issue.id, summary}}
  end
```

- [ ] **Step 4: 在 orchestrator 的正常退出路径中接 phase completion**

在 `elixir/lib/symphony_elixir/orchestrator.ex` 的 `handle_agent_down(:normal, ...)` 开头加入：

```elixir
    case Map.get(running_entry, :workflow_phase) do
      :planning ->
        handle_workflow_phase_down(state, issue_id, running_entry, :planning)

      :execution ->
        handle_workflow_phase_down(state, issue_id, running_entry, :execution)

      :review ->
        handle_workflow_phase_down(state, issue_id, running_entry, :review)

      _ ->
        existing_normal_agent_down(state, issue_id, running_entry, session_id, terminal_states)
    end
```

把原有 `handle_agent_down(:normal, ...)` 主体提取成：

```elixir
  defp existing_normal_agent_down(state, issue_id, running_entry, session_id, terminal_states) do
    cond do
      input_required_blocker?(running_entry) ->
        block_input_required_agent_down(state, issue_id, running_entry, session_id, :normal)

      running_entry_terminal_issue?(running_entry, terminal_states) ->
        Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; refreshed issue is terminal, releasing claim")
        cleanup_issue_workspace(running_entry.identifier, Map.get(running_entry, :worker_host))
        state
        |> complete_issue(issue_id)
        |> release_issue_claim(issue_id)

      true ->
        Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")
        state
        |> complete_issue(issue_id)
        |> schedule_issue_retry(issue_id, 1, %{
          identifier: running_entry.identifier,
          issue_url: running_entry.issue.url,
          delay_type: :continuation,
          agent_id: Map.get(running_entry, :agent_id),
          agent_kind: Map.get(running_entry, :agent_kind),
          worker_host: Map.get(running_entry, :worker_host),
          workspace_path: Map.get(running_entry, :workspace_path)
        })
    end
  end
```

再追加：

```elixir
  defp handle_workflow_phase_down(state, issue_id, running_entry, :planning) do
    workspace = Map.fetch!(running_entry, :workspace_path)

    case Controller.handle_planning_completion(running_entry.issue, workspace) do
      {:ok, _registry} ->
        state
        |> complete_issue(issue_id)
        |> release_issue_claim(issue_id)

      {:error, reason} ->
        block_issue_from_entry(state, issue_id, running_entry, "planning artifact invalid: #{inspect(reason)}")
    end
  end

  defp handle_workflow_phase_down(state, issue_id, running_entry, :execution) do
    workspace = Map.fetch!(running_entry, :workspace_path)

    case Controller.handle_execution_completion(running_entry.issue, workspace) do
      {:ok, {:queue_review, metadata}} ->
        dispatch_issue(
          complete_issue(state, issue_id),
          running_entry.issue,
          nil,
          Map.get(running_entry, :worker_host),
          Map.merge(metadata, %{
            agent_id: metadata.agent_id,
            workflow_phase: :review,
            workflow_root_issue_id: metadata.workflow_context["root_issue_identifier"]
          })
        )

      {:error, reason} ->
        block_issue_from_entry(state, issue_id, running_entry, "completion packet invalid: #{inspect(reason)}")
    end
  end

  defp handle_workflow_phase_down(state, issue_id, running_entry, :review) do
    workspace = Map.fetch!(running_entry, :workspace_path)

    case Controller.handle_review_completion(running_entry.issue, workspace) do
      {:ok, {:pass, _issue_id}} ->
        state
        |> complete_issue(issue_id)
        |> release_issue_claim(issue_id)

      {:ok, {:needs_human, _issue_id, reason}} ->
        block_issue_from_entry(state, issue_id, running_entry, reason)

      {:ok, {:needs_replan, _issue_id, reason}} ->
        schedule_issue_retry(complete_issue(state, issue_id), issue_id, 1, %{
          identifier: running_entry.identifier,
          issue_url: running_entry.issue.url,
          error: "workflow replan requested: #{reason}",
          delay_type: :continuation,
          agent_id: Config.settings!().orchestration.planner_agent,
          worker_host: Map.get(running_entry, :worker_host)
        })

      {:ok, {:needs_rework, _issue_id, reason}} ->
        block_issue_from_entry(state, issue_id, running_entry, "rework required: #{reason}")

      {:ok, {:fail, _issue_id, reason}} ->
        block_issue_from_entry(state, issue_id, running_entry, "review failed: #{reason}")

      {:error, reason} ->
        block_issue_from_entry(state, issue_id, running_entry, "review decision invalid: #{inspect(reason)}")
    end
  end
```

- [ ] **Step 5: 运行 workflow controller / orchestrator 测试**

Run:

```powershell
cd C:\Users\GQY47\coding\Symphony\elixir
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/workflow_controller_test.exs test/symphony_elixir/workflow_orchestrator_test.exs'
```

Expected: planning -> execution -> review 的 phase completion 主链可跑通；工件缺失或无效时 issue 被 block，而不是静默成功。

- [ ] **Step 6: Commit**

```bash
git add elixir/lib/symphony_elixir/workflow/controller.ex elixir/lib/symphony_elixir/orchestrator.ex elixir/test/symphony_elixir/workflow_controller_test.exs elixir/test/symphony_elixir/workflow_orchestrator_test.exs
git commit -m "feat: drive workflow phases from completion artifacts"
```

---

### Task 8: Observability、文档与最终验证

**Files:**
- Modify: `elixir/lib/symphony_elixir_web/presenter.ex`
- Modify: `elixir/lib/symphony_elixir/status_dashboard.ex`
- Modify: `elixir/test/symphony_elixir/orchestrator_status_test.exs`
- Create: `elixir/docs/issue_driven_dynamic_workflow.md`
- Modify: `elixir/README.md`
- Modify: `elixir/WORKFLOW.md`

- [ ] **Step 1: 给 snapshot/API 暴露 workflow 字段**

在 `elixir/lib/symphony_elixir/orchestrator.ex` 的 running snapshot payload 中加入：

```elixir
workflow_phase: Map.get(metadata, :workflow_phase),
workflow_root_issue_id: Map.get(metadata, :workflow_root_issue_id),
workflow_blocked_reason: Map.get(metadata, :error),
```

在 `elixir/lib/symphony_elixir_web/presenter.ex` 的 running / blocked / retry payload 中加入：

```elixir
workflow_phase: Map.get(entry, :workflow_phase),
workflow_root_issue_id: Map.get(entry, :workflow_root_issue_id),
workflow_blocked_reason: Map.get(entry, :error),
```

在 `elixir/test/symphony_elixir/orchestrator_status_test.exs` 里新增断言：

```elixir
assert running.workflow_phase == :review
assert running.workflow_root_issue_id == "root-1"
```

- [ ] **Step 2: 在 dashboard 上显示 workflow phase 和 blocked reason**

在 `elixir/lib/symphony_elixir/status_dashboard.ex` 的 running table header 加入：

```elixir
@running_phase_width 12
```

并在 header / row 中增加：

```elixir
phase = format_cell(Map.get(running_entry, :workflow_phase) || "-", @running_phase_width)
```

blocked section 加入：

```elixir
reason = Map.get(blocked_entry, :error) || "-"
```

- [ ] **Step 3: 写中文文档和 workflow 示例**

创建 `elixir/docs/issue_driven_dynamic_workflow.md`：

````markdown
# Issue 驱动动态任务编排（第一版）

## 开启方式

```yaml
orchestration:
  enabled: true
  planner_agent: codex
  reviewer_agent: codex
  artifact_dir: ".symphony"
  planning_max_turns: 1
  review_max_turns: 1
```

## Agent 工件约定

- planning: `.symphony/workflow_plan.json`
- execution: `.symphony/completion_packet.json`
- review: `.symphony/review_decision.json`

## 行为概览

1. root issue 首先进入 planning。
2. 如果计划是 `issue_graph`，Symphony 创建普通 Linear derived issue。
3. 只有 readiness 满足的 derived issue 才会执行。
4. 每个执行 issue 都必须写 completion packet。
5. review 阶段读取 packet，写 review decision。
6. 控制层据此 pass、block、replan、rework 或 close root。
```
````

在 `elixir/README.md` 增加链接：

```markdown
- Issue 驱动动态任务编排第一版见 [`docs/issue_driven_dynamic_workflow.md`](docs/issue_driven_dynamic_workflow.md)
```

在 `elixir/WORKFLOW.md` 增加可选示例片段：

```yaml
orchestration:
  enabled: true
  planner_agent: codex
  reviewer_agent: codex
  artifact_dir: ".symphony"
  planning_max_turns: 1
  review_max_turns: 1
```

- [ ] **Step 4: 运行格式化和重点测试**

Run:

```powershell
cd C:\Users\GQY47\coding\Symphony\elixir
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix format'
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/core_test.exs test/symphony_elixir/extensions_test.exs test/symphony_elixir/workflow_artifacts_test.exs test/symphony_elixir/workflow_controller_test.exs test/symphony_elixir/workflow_orchestrator_test.exs test/symphony_elixir/orchestrator_status_test.exs'
```

Expected: 关键模块测试全部通过；格式化后仅有预期文件改动。

- [ ] **Step 5: 运行全量验证**

Run:

```powershell
cd C:\Users\GQY47\coding\Symphony\elixir
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test'
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix build'
```

Expected: 全部 ExUnit 测试通过，`mix build` 成功。

- [ ] **Step 6: Smoke 流程**

使用 memory tracker 做一条最小 smoke：

1. 准备一个 root issue：

```elixir
root_issue = %Issue{
  id: "root-1",
  identifier: "YQE-100",
  title: "Add MiMo orchestration",
  description: "Need research then implement",
  state: "In Progress",
  assignee_id: "worker-user"
}
```

2. 开启 orchestration：

```yaml
orchestration:
  enabled: true
  planner_agent: codex
  reviewer_agent: codex
```

3. 在 root workspace 写入一个 `workflow_plan.json`，包含 research -> implementation 两节点。
4. 确认控制层创建 derived issues。
5. 在 derived issue workspace 写 `completion_packet.json`。
6. 在同一 workspace 写 `review_decision.json`，结果为 `pass`。
7. 验证：
   - root issue 收到 planning summary comment。
   - derived issue 收到 completion/review comments。
   - dashboard/API 中可见 `workflow_phase` 与 blocked reason。

- [ ] **Step 7: Commit**

```bash
git add elixir/lib/symphony_elixir_web/presenter.ex elixir/lib/symphony_elixir/status_dashboard.ex elixir/test/symphony_elixir/orchestrator_status_test.exs elixir/docs/issue_driven_dynamic_workflow.md elixir/README.md elixir/WORKFLOW.md
git commit -m "docs: explain issue-driven workflow orchestration"
```

---

## 自审清单

### Spec 覆盖

- issue 作为任务载体：Task 5 / 6。
- planning 阶段：Task 4 / 5 / 6。
- derived issue 创建：Task 2 / 5。
- Completion Packet：Task 3 / 4 / 7。
- Review Decision：Task 3 / 7。
- readiness gating：Task 6。
- 自动推进、needs_human、replan、rework、closure：Task 7。
- Linear 可见性：Task 5 / 7 / 8。
- opt-in、尽量不破坏现有行为：Task 1 / 6。

### 占位词扫描

本计划中不允许出现常见待办缩写、模糊延后表述或“参考别的任务照做”这类占位表达。执行前再次用：

```powershell
Select-String -Path docs\superpowers\plans\2026-06-18-issue-driven-dynamic-workflow-phase1.md -Pattern @('TO'+'DO', 'TB'+'D', '稍'+'后', '按'+'需', '类似 '+'Task')
```

Expected: 无匹配。

### 类型一致性

- `workflow_phase` 统一使用 `:planning | :execution | :review`。
- `Workflow Plan`、`Completion Packet`、`Review Decision` 文件名固定。
- `orchestration.enabled` 为 opt-in 开关。
- `Tracker.create_issue/1` 是新增统一写接口，Memory 和 Linear 必须都实现。
