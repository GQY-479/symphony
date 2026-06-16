# Multi-Agent Backends Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 Symphony 从 Codex-only worker 演进为支持 Codex、MiMo-Code、OpenCode 等平级 agent backend 的编排系统。

**Architecture:** 保留现有 Codex app-server 行为不变，在其外层引入 backend/router 抽象。第一版新增 `codex_app_server` 和 `cli_run` 两类 backend，通过 Linear assignee/label/default routing 为 issue 选择 agent。

**Tech Stack:** Elixir, Ecto embedded schema, GenServer orchestrator, Port subprocess, Linear GraphQL tracker, ExUnit.

---

## 文件结构

- Modify: `elixir/lib/symphony_elixir/config/schema.ex`
  - 负责解析 `agents` 和 `routing` 新配置，并在缺省时从旧 `codex` 配置合成默认 `codex` agent。
- Modify: `elixir/lib/symphony_elixir/config.ex`
  - 负责新增 backend/routing 语义校验和 agent runtime settings helper。
- Create: `elixir/lib/symphony_elixir/agent/backend.ex`
  - 定义 backend behaviour 和通用结果/事件约定。
- Create: `elixir/lib/symphony_elixir/agent/backend/codex_app_server.ex`
  - 包装现有 `SymphonyElixir.Codex.AppServer`。
- Create: `elixir/lib/symphony_elixir/agent/backend/cli_run.ex`
  - 运行 `mimo run --format json` 或兼容 OpenCode CLI 的 backend。
- Create: `elixir/lib/symphony_elixir/agent/router.ex`
  - 根据 issue labels、assignee、default agent 解析 `agent_id`。
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`
  - 从直接调用 Codex 改为根据 `agent_id` 调用 backend。
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
  - dispatch 前解析 agent；running/retry/blocked/snapshot 中记录 agent identity。
- Modify: `elixir/lib/symphony_elixir_web/presenter.ex`
  - API payload 增加 `agent_id` 和 `agent_kind`。
- Modify: `elixir/lib/symphony_elixir/status_dashboard.ex`
  - running table 显示 agent id。
- Modify: `elixir/test/support/test_support.exs`
  - 测试 workflow helper 支持 `agents` 和 `routing` 覆盖。
- Modify: `elixir/test/symphony_elixir/core_test.exs`
  - 增加配置、routing、orchestrator 集成测试。
- Create: `elixir/test/symphony_elixir/agent_backend_test.exs`
  - 覆盖 Codex backend wrapper 和 CLI backend。
- Modify: `elixir/test/symphony_elixir/orchestrator_status_test.exs`
  - 覆盖 snapshot/presenter agent 字段。
- Modify: `elixir/WORKFLOW.md`
  - 增加中文示例注释或文档段落，说明 multi-agent 配置。

---

### Task 1: 配置层测试先行

**Files:**
- Modify: `elixir/test/support/test_support.exs`
- Modify: `elixir/test/symphony_elixir/core_test.exs`

- [ ] **Step 1: 扩展测试 helper 以便写新配置**

在 `workflow_content/1` 的默认 keyword 中加入：

```elixir
agents: nil,
routing: nil,
```

在 `sections` 里追加到旧 `codex:` section 之后：

```elixir
agents_yaml(Keyword.get(config, :agents)),
routing_yaml(Keyword.get(config, :routing)),
```

在文件底部加入：

```elixir
defp agents_yaml(nil), do: nil
defp agents_yaml(agents), do: "agents: #{yaml_value(agents)}"

defp routing_yaml(nil), do: nil
defp routing_yaml(routing), do: "routing: #{yaml_value(routing)}"
```

- [ ] **Step 2: 写失败测试：旧配置合成默认 Codex agent**

在 `elixir/test/symphony_elixir/core_test.exs` 的 config 测试附近加入：

```elixir
test "legacy codex config synthesizes the default codex agent" do
  write_workflow_file!(Workflow.workflow_file_path(),
    codex_command: "custom-codex app-server",
    codex_approval_policy: "never",
    codex_thread_sandbox: "workspace-write",
    codex_turn_sandbox_policy: %{type: "dangerFullAccess"}
  )

  settings = Config.settings!()

  assert settings.routing.default_agent == "codex"
  assert settings.agents["codex"]["kind"] == "codex_app_server"
  assert settings.agents["codex"]["command"] == "custom-codex app-server"
  assert settings.agents["codex"]["approval_policy"] == "never"
  assert settings.agents["codex"]["thread_sandbox"] == "workspace-write"
  assert settings.agents["codex"]["turn_sandbox_policy"] == %{"type" => "dangerFullAccess"}
end
```

- [ ] **Step 3: 写失败测试：显式 agents/routing 配置可解析**

继续加入：

```elixir
test "multi-agent config parses named agents and routing" do
  write_workflow_file!(Workflow.workflow_file_path(),
    agents: %{
      codex: %{kind: "codex_app_server", command: "codex app-server"},
      mimocode: %{
        kind: "cli_run",
        command: "mimo",
        args: ["run", "--format", "json", "--dir", "{{workspace}}"],
        assignee: "mimo-user-id",
        timeout_ms: 600_000,
        max_output_bytes: 200_000
      }
    },
    routing: %{
      default_agent: "codex",
      by_label: %{"agent:mimo" => "mimocode"},
      by_assignee: %{"mimo-user-id" => "mimocode"}
    }
  )

  settings = Config.settings!()

  assert Map.keys(settings.agents) |> Enum.sort() == ["codex", "mimocode"]
  assert settings.agents["mimocode"]["kind"] == "cli_run"
  assert settings.agents["mimocode"]["args"] == ["run", "--format", "json", "--dir", "{{workspace}}"]
  assert settings.routing.by_label == %{"agent:mimo" => "mimocode"}
  assert settings.routing.by_assignee == %{"mimo-user-id" => "mimocode"}
end
```

- [ ] **Step 4: 写失败测试：未知 route target 验证失败**

加入：

```elixir
test "routing to an unknown agent fails workflow validation" do
  write_workflow_file!(Workflow.workflow_file_path(),
    agents: %{codex: %{kind: "codex_app_server", command: "codex app-server"}},
    routing: %{default_agent: "missing-agent"}
  )

  assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
  assert message =~ "routing.default_agent"
  assert message =~ "missing-agent"
end
```

- [ ] **Step 5: 运行测试确认失败**

Run:

```powershell
cd C:\Users\GQY47\coding\Symphony\elixir
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/core_test.exs'
```

Expected: 新增 multi-agent 配置相关测试失败，因为 schema 尚未实现 `agents` 和 `routing`。

- [ ] **Step 6: Commit**

```bash
git add elixir/test/support/test_support.exs elixir/test/symphony_elixir/core_test.exs
git commit -m "test: cover multi-agent workflow config"
```

---

### Task 2: 实现 agents/routing 配置解析和校验

**Files:**
- Modify: `elixir/lib/symphony_elixir/config/schema.ex`
- Modify: `elixir/lib/symphony_elixir/config.ex`

- [ ] **Step 1: 在 schema 中新增 Routing embedded schema**

`agents` 是动态 key map，不使用 `embeds_many`。只为固定结构的 `routing` 增加 embedded schema。在 `Codex` module 后加入：

```elixir
defmodule Routing do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:default_agent, :string, default: "codex")
    field(:by_assignee, :map, default: %{})
    field(:by_label, :map, default: %{})
  end

  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:default_agent, :by_assignee, :by_label], empty_values: [])
  end
end
```

- [ ] **Step 2: 在主 schema 加字段**

在 `embedded_schema do` 内加入：

```elixir
field(:agents, :map, default: %{})
embeds_one(:routing, Routing, on_replace: :update, defaults_to_struct: true)
```

在 `changeset/1` 中加入：

```elixir
|> cast(attrs, [:agents])
|> cast_embed(:routing, with: &Routing.changeset/2)
```

注意保留其他 `cast_embed`。

- [ ] **Step 3: 在 finalize_settings/1 中合成并规范化 agent map**

在 `finalize_settings/1` 里构造 `codex` 后加入：

```elixir
agents =
  settings.agents
  |> normalize_agent_map(codex)
  |> normalize_keys()

routing = %{
  settings.routing
  | by_assignee: normalize_route_map(settings.routing.by_assignee),
    by_label: normalize_label_route_map(settings.routing.by_label)
}

%{settings | tracker: tracker, workspace: workspace, codex: codex, agents: agents, routing: routing}
```

并新增 helper：

```elixir
defp normalize_agent_map(nil, codex), do: legacy_codex_agent(codex)
defp normalize_agent_map(agents, codex) when agents == %{}, do: legacy_codex_agent(codex)

defp normalize_agent_map(agents, codex) when is_map(agents) do
  agents
  |> Enum.into(%{}, fn {agent_id, attrs} ->
    normalized_attrs =
      attrs
      |> normalize_keys()
      |> Map.put_new("enabled", true)

    {to_string(agent_id), normalize_agent_attrs(normalized_attrs, codex)}
  end)
end

defp legacy_codex_agent(codex) do
  %{
    "codex" => %{
      "kind" => "codex_app_server",
      "command" => codex.command,
      "approval_policy" => codex.approval_policy,
      "thread_sandbox" => codex.thread_sandbox,
      "turn_sandbox_policy" => codex.turn_sandbox_policy,
      "timeout_ms" => codex.turn_timeout_ms,
      "read_timeout_ms" => codex.read_timeout_ms,
      "stall_timeout_ms" => codex.stall_timeout_ms,
      "enabled" => true
    }
  }
end

defp normalize_agent_attrs(%{"kind" => "codex_app_server"} = attrs, codex) do
  attrs
  |> Map.put_new("command", codex.command)
  |> Map.put_new("approval_policy", codex.approval_policy)
  |> Map.put_new("thread_sandbox", codex.thread_sandbox)
  |> Map.put_new("turn_sandbox_policy", codex.turn_sandbox_policy)
  |> Map.put_new("timeout_ms", codex.turn_timeout_ms)
  |> Map.put_new("read_timeout_ms", codex.read_timeout_ms)
  |> Map.put_new("stall_timeout_ms", codex.stall_timeout_ms)
end

defp normalize_agent_attrs(attrs, _codex), do: attrs

defp normalize_route_map(nil), do: %{}
defp normalize_route_map(routes) when is_map(routes), do: normalize_keys(routes)

defp normalize_label_route_map(nil), do: %{}
defp normalize_label_route_map(routes) when is_map(routes) do
  Enum.into(routes, %{}, fn {label, agent_id} ->
    {String.downcase(String.trim(to_string(label))), to_string(agent_id)}
  end)
end
```

- [ ] **Step 4: 在 Config.validate!/0 中验证 routing target**

在 `Config.validate_semantics/1` 的 tracker 校验后加入：

```elixir
      invalid_agent_config(settings) ->
        {:error, {:invalid_workflow_config, invalid_agent_config_message(settings)}}

      invalid_agent_route(settings) ->
        {:error, {:invalid_workflow_config, invalid_agent_route_message(settings)}}
```

并新增 private helpers：

```elixir
defp invalid_agent_config(settings) do
  settings.agents
  |> Enum.any?(fn {_agent_id, config} ->
    invalid_agent_kind?(config) or invalid_agent_command?(config) or invalid_agent_numbers?(config)
  end)
end

defp invalid_agent_config_message(settings) do
  settings.agents
  |> Enum.find(fn {_agent_id, config} ->
    invalid_agent_kind?(config) or invalid_agent_command?(config) or invalid_agent_numbers?(config)
  end)
  |> case do
    {agent_id, config} ->
      cond do
        invalid_agent_kind?(config) ->
          "agents.#{agent_id}.kind must be one of codex_app_server or cli_run"

        invalid_agent_command?(config) ->
          "agents.#{agent_id}.command can't be blank"

        true ->
          "agents.#{agent_id} numeric limits must be positive"
      end

    nil ->
      "agents contains invalid configuration"
  end
end

defp invalid_agent_kind?(config) do
  Map.get(config, "kind") not in ["codex_app_server", "cli_run"]
end

defp invalid_agent_command?(config) do
  case Map.get(config, "command") do
    command when is_binary(command) -> String.trim(command) == ""
    _ -> true
  end
end

defp invalid_agent_numbers?(config) do
  [
    {"timeout_ms", 1},
    {"read_timeout_ms", 1},
    {"stall_timeout_ms", 0},
    {"max_output_bytes", 1}
  ]
  |> Enum.any?(fn {field, min} ->
    case Map.get(config, field) do
      nil -> false
      value when is_integer(value) -> value < min
      _ -> true
    end
  end)
end

defp invalid_agent_route(settings) do
  known_agents = Map.keys(settings.agents || %{}) |> MapSet.new()
  route_targets = route_targets(settings)

  Enum.any?(route_targets, fn {_field, agent_id} ->
    not MapSet.member?(known_agents, agent_id)
  end)
end

defp invalid_agent_route_message(settings) do
  known_agents = Map.keys(settings.agents || %{}) |> MapSet.new()

  settings
  |> route_targets()
  |> Enum.find(fn {_field, agent_id} -> not MapSet.member?(known_agents, agent_id) end)
  |> case do
    {field, agent_id} -> "#{field} references unknown agent #{inspect(agent_id)}"
    nil -> "routing references unknown agent"
  end
end

defp route_targets(settings) do
  routing = settings.routing

  [{"routing.default_agent", routing.default_agent}] ++
    Enum.map(routing.by_label || %{}, fn {label, agent_id} -> {"routing.by_label[#{label}]", agent_id} end) ++
    Enum.map(routing.by_assignee || %{}, fn {assignee, agent_id} -> {"routing.by_assignee[#{assignee}]", agent_id} end)
end
```

- [ ] **Step 5: 运行 Task 1 测试**

Run:

```powershell
cd C:\Users\GQY47\coding\Symphony\elixir
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/core_test.exs'
```

Expected: Task 1 新增配置测试通过；若其他 core tests 因 map struct 差异失败，调整测试断言读取 string-key map。

- [ ] **Step 6: Commit**

```bash
git add elixir/lib/symphony_elixir/config/schema.ex elixir/lib/symphony_elixir/config.ex
git commit -m "feat: parse multi-agent workflow config"
```

---

### Task 3: Agent routing resolver

**Files:**
- Create: `elixir/lib/symphony_elixir/agent/router.ex`
- Modify: `elixir/test/symphony_elixir/core_test.exs`

- [ ] **Step 1: 写失败测试：label 优先于 assignee**

在 `core_test.exs` 加入：

```elixir
test "agent routing chooses label route before assignee route" do
  write_workflow_file!(Workflow.workflow_file_path(),
    agents: %{
      codex: %{kind: "codex_app_server", command: "codex app-server"},
      mimocode: %{kind: "cli_run", command: "mimo"}
    },
    routing: %{
      default_agent: "codex",
      by_label: %{"agent:mimo" => "mimocode"},
      by_assignee: %{"codex-user" => "codex"}
    }
  )

  issue = %Issue{
    id: "issue-route",
    identifier: "MT-ROUTE",
    labels: ["Agent:MiMo"],
    assignee_id: "codex-user"
  }

  assert {:ok, %{id: "mimocode", kind: "cli_run"}} =
           SymphonyElixir.Agent.Router.resolve(issue, Config.settings!())
end
```

- [ ] **Step 2: 写失败测试：assignee 和 default route**

加入：

```elixir
test "agent routing falls back from assignee to default agent" do
  write_workflow_file!(Workflow.workflow_file_path(),
    agents: %{
      codex: %{kind: "codex_app_server", command: "codex app-server"},
      mimocode: %{kind: "cli_run", command: "mimo"}
    },
    routing: %{
      default_agent: "codex",
      by_assignee: %{"mimo-user" => "mimocode"}
    }
  )

  assert {:ok, %{id: "mimocode"}} =
           SymphonyElixir.Agent.Router.resolve(%Issue{assignee_id: "mimo-user"}, Config.settings!())

  assert {:ok, %{id: "codex"}} =
           SymphonyElixir.Agent.Router.resolve(%Issue{assignee_id: "someone-else"}, Config.settings!())
end
```

- [ ] **Step 3: 实现 Router module**

创建 `elixir/lib/symphony_elixir/agent/router.ex`：

```elixir
defmodule SymphonyElixir.Agent.Router do
  @moduledoc """
  Resolves the configured agent backend for an issue.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue

  @type resolved_agent :: %{
          id: String.t(),
          kind: String.t(),
          config: map()
        }

  @spec resolve(Issue.t(), Schema.t()) :: {:ok, resolved_agent()} | {:error, term()}
  def resolve(%Issue{} = issue, %Schema{} = settings) do
    agent_id =
      label_route(issue, settings) ||
        assignee_route(issue, settings) ||
        settings.routing.default_agent ||
        "codex"

    case Map.get(settings.agents, agent_id) do
      %{"enabled" => false} ->
        {:error, {:agent_disabled, agent_id}}

      %{"kind" => kind} = config ->
        {:ok, %{id: agent_id, kind: kind, config: config}}

      _ ->
        {:error, {:unknown_agent, agent_id}}
    end
  end

  defp label_route(%Issue{labels: labels}, settings) when is_list(labels) do
    routes = settings.routing.by_label || %{}

    Enum.find_value(labels, fn label ->
      Map.get(routes, normalize_label(label))
    end)
  end

  defp label_route(_issue, _settings), do: nil

  defp assignee_route(%Issue{assignee_id: assignee_id}, settings) when is_binary(assignee_id) do
    Map.get(settings.routing.by_assignee || %{}, assignee_id)
  end

  defp assignee_route(_issue, _settings), do: nil

  defp normalize_label(label) when is_binary(label) do
    label |> String.trim() |> String.downcase()
  end
end
```

- [ ] **Step 4: 运行 routing 测试**

Run:

```powershell
cd C:\Users\GQY47\coding\Symphony\elixir
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/core_test.exs'
```

Expected: routing resolver tests pass.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/agent/router.ex elixir/test/symphony_elixir/core_test.exs
git commit -m "feat: resolve issue agent routing"
```

---

### Task 4: Backend behaviour 和 Codex wrapper

**Files:**
- Create: `elixir/lib/symphony_elixir/agent/backend.ex`
- Create: `elixir/lib/symphony_elixir/agent/backend/codex_app_server.ex`
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`
- Create: `elixir/test/symphony_elixir/agent_backend_test.exs`

- [ ] **Step 1: 写失败测试：Codex backend 复用 app-server**

创建 `agent_backend_test.exs`：

```elixir
defmodule SymphonyElixir.AgentBackendTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.Backend.CodexAppServer

  test "codex backend runs a prompt through the existing app-server client" do
    test_root = Path.join(System.tmp_dir!(), "symphony-codex-backend-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-CODEX")
      fake_codex = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(workspace)
      System.put_env("SYMP_TEST_CODEX_BACKEND_TRACE", trace_file)
      on_exit(fn -> System.delete_env("SYMP_TEST_CODEX_BACKEND_TRACE") end)

      File.write!(fake_codex, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEX_BACKEND_TRACE}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"
        case "$count" in
          1) printf '%s\\n' '{"id":1,"result":{}}' ;;
          2) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-backend"}}}' ;;
          3) printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-backend"}}}' ;;
          4) printf '%s\\n' '{"method":"turn/completed"}'; exit 0 ;;
        esac
      done
      """)
      File.chmod!(fake_codex, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agents: %{codex: %{kind: "codex_app_server", command: "#{fake_codex} app-server"}},
        routing: %{default_agent: "codex"}
      )

      issue = %Issue{id: "issue-codex-backend", identifier: "MT-CODEX", title: "Codex backend", state: "In Progress"}

      assert {:ok, %{session_id: "thread-backend-turn-backend"}} =
               CodexAppServer.run_issue(workspace, issue, "backend prompt", %{id: "codex", config: Config.settings!().agents["codex"]})

      assert File.read!(trace_file) =~ "backend prompt"
    after
      File.rm_rf(test_root)
    end
  end
end
```

- [ ] **Step 2: 定义 Backend behaviour**

创建 `agent/backend.ex`：

```elixir
defmodule SymphonyElixir.Agent.Backend do
  @moduledoc """
  Behaviour for peer coding-agent backends.
  """

  alias SymphonyElixir.Linear.Issue

  @type resolved_agent :: %{id: String.t(), kind: String.t(), config: map()}
  @type backend_result :: map()

  @callback run_issue(Path.t(), Issue.t(), String.t(), resolved_agent(), keyword()) ::
              {:ok, backend_result()} | {:error, term()}

  @spec module_for(String.t()) :: module()
  def module_for("codex_app_server"), do: SymphonyElixir.Agent.Backend.CodexAppServer
  def module_for("cli_run"), do: SymphonyElixir.Agent.Backend.CliRun
end
```

- [ ] **Step 3: 实现 Codex wrapper**

创建 `agent/backend/codex_app_server.ex`：

```elixir
defmodule SymphonyElixir.Agent.Backend.CodexAppServer do
  @moduledoc """
  Codex app-server backend adapter.
  """

  @behaviour SymphonyElixir.Agent.Backend

  alias SymphonyElixir.Codex.AppServer

  @impl true
  def run_issue(workspace, issue, prompt, %{id: agent_id, kind: agent_kind}, opts) do
    on_message = Keyword.get(opts, :on_message, & &1)

    wrapped_on_message = fn message ->
      message
      |> Map.put(:agent_id, agent_id)
      |> Map.put(:agent_kind, agent_kind)
      |> on_message.()
    end

    opts = Keyword.put(opts, :on_message, wrapped_on_message)

    with {:ok, session} <- AppServer.start_session(workspace, opts) do
      try do
        case AppServer.run_turn(session, prompt, issue, opts) do
          {:ok, result} -> {:ok, Map.merge(result, %{agent_id: agent_id, agent_kind: agent_kind})}
          {:error, reason} -> {:error, reason}
        end
      after
        AppServer.stop_session(session)
      end
    end
  end
end
```

- [ ] **Step 4: 运行 backend 测试确认 wrapper 通过**

Run:

```powershell
cd C:\Users\GQY47\coding\Symphony\elixir
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/agent_backend_test.exs'
```

Expected: Codex backend wrapper 测试通过。

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/agent/backend.ex elixir/lib/symphony_elixir/agent/backend/codex_app_server.ex elixir/test/symphony_elixir/agent_backend_test.exs
git commit -m "feat: add codex backend adapter"
```

---

### Task 5: CLI backend for MiMo-Code/OpenCode

**Files:**
- Create: `elixir/lib/symphony_elixir/agent/backend/cli_run.ex`
- Modify: `elixir/test/symphony_elixir/agent_backend_test.exs`

- [ ] **Step 1: 写失败测试：CLI backend 调用 fake mimo**

在 `agent_backend_test.exs` 加入：

```elixir
alias SymphonyElixir.Agent.Backend.CliRun

test "cli backend passes workspace and prompt to a fake mimo command" do
  test_root = Path.join(System.tmp_dir!(), "symphony-cli-backend-#{System.unique_integer([:positive])}")

  try do
    workspace = Path.join(test_root, "workspace")
    fake_mimo = Path.join(test_root, "mimo")
    trace_file = Path.join(test_root, "mimo.trace")
    File.mkdir_p!(workspace)

    File.write!(fake_mimo, """
    #!/bin/sh
    printf 'CWD:%s\\n' "$PWD" >> "#{trace_file}"
    printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
    printf '{"type":"message","text":"MiMo completed"}\\n'
    """)
    File.chmod!(fake_mimo, 0o755)

    issue = %Issue{id: "issue-mimo", identifier: "MT-MIMO", title: "Run MiMo", state: "In Progress"}
    agent = %{
      id: "mimocode",
      kind: "cli_run",
      config: %{
        "command" => fake_mimo,
        "args" => ["run", "--format", "json", "--dir", "{{workspace}}"],
        "timeout_ms" => 5_000,
        "max_output_bytes" => 20_000
      }
    }

    assert {:ok, result} = CliRun.run_issue(workspace, issue, "implement task", agent, [])
    assert result.agent_id == "mimocode"
    assert result.exit_status == 0
    assert result.output =~ "MiMo completed"

    trace = File.read!(trace_file)
    assert trace =~ "CWD:#{workspace}"
    assert trace =~ "--dir #{workspace}"
    assert trace =~ "implement task"
  after
    File.rm_rf(test_root)
  end
end
```

- [ ] **Step 2: 写失败测试：non-zero exit 返回错误**

加入：

```elixir
test "cli backend returns error for non-zero exit" do
  test_root = Path.join(System.tmp_dir!(), "symphony-cli-error-#{System.unique_integer([:positive])}")

  try do
    workspace = Path.join(test_root, "workspace")
    fake_mimo = Path.join(test_root, "mimo")
    File.mkdir_p!(workspace)

    File.write!(fake_mimo, """
    #!/bin/sh
    echo "boom" >&2
    exit 7
    """)
    File.chmod!(fake_mimo, 0o755)

    issue = %Issue{id: "issue-mimo-error", identifier: "MT-MIMO-ERR", state: "In Progress"}
    agent = %{id: "mimocode", kind: "cli_run", config: %{"command" => fake_mimo, "args" => ["run"], "timeout_ms" => 5_000}}

    assert {:error, {:cli_exit, 7, output}} = CliRun.run_issue(workspace, issue, "task", agent, [])
    assert output =~ "boom"
  after
    File.rm_rf(test_root)
  end
end
```

- [ ] **Step 3: 实现 CliRun backend**

创建 `agent/backend/cli_run.ex`：

```elixir
defmodule SymphonyElixir.Agent.Backend.CliRun do
  @moduledoc """
  Backend for non-interactive CLI agents such as MiMo-Code and OpenCode.
  """

  @behaviour SymphonyElixir.Agent.Backend

  require Logger

  @default_timeout_ms 3_600_000
  @default_max_output_bytes 200_000

  @impl true
  def run_issue(workspace, issue, prompt, %{id: agent_id, kind: agent_kind, config: config}, opts) do
    on_message = Keyword.get(opts, :on_message, & &1)
    timeout_ms = Map.get(config, "timeout_ms", @default_timeout_ms)
    max_output_bytes = Map.get(config, "max_output_bytes", @default_max_output_bytes)

    with {:ok, executable, args} <- command_args(config, workspace, prompt),
         {:ok, port} <- start_port(executable, args, workspace) do
      emit(on_message, agent_id, agent_kind, :session_started, %{process_pid: port_pid(port)})

      case collect(port, timeout_ms, "", max_output_bytes, on_message, agent_id, agent_kind) do
        {:ok, 0, output} ->
          {:ok, %{agent_id: agent_id, agent_kind: agent_kind, exit_status: 0, output: output}}

        {:ok, status, output} ->
          {:error, {:cli_exit, status, output}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp command_args(%{"command" => command} = config, workspace, prompt) when is_binary(command) do
    args =
      config
      |> Map.get("args", [])
      |> Enum.map(&render_arg(&1, workspace))
      |> Kernel.++([prompt])

    {:ok, command, args}
  end

  defp command_args(_config, _workspace, _prompt), do: {:error, :missing_cli_command}

  defp render_arg(arg, workspace) when is_binary(arg) do
    String.replace(arg, "{{workspace}}", workspace)
  end

  defp start_port(executable, args, workspace) do
    port =
      Port.open({:spawn_executable, String.to_charlist(executable)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: Enum.map(args, &String.to_charlist/1),
        cd: String.to_charlist(workspace),
        line: 1_048_576
      ])

    {:ok, port}
  rescue
    ArgumentError -> {:error, {:cli_executable_not_found, executable}}
  end

  defp collect(port, timeout_ms, output, max_output_bytes, on_message, agent_id, agent_kind) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        text = to_string(line)
        emit_output(on_message, agent_id, agent_kind, text)
        collect(port, timeout_ms, append_output(output, text <> "\n", max_output_bytes), max_output_bytes, on_message, agent_id, agent_kind)

      {^port, {:data, {:noeol, chunk}}} ->
        text = to_string(chunk)
        collect(port, timeout_ms, append_output(output, text, max_output_bytes), max_output_bytes, on_message, agent_id, agent_kind)

      {^port, {:exit_status, status}} ->
        emit(on_message, agent_id, agent_kind, :turn_completed, %{exit_status: status})
        {:ok, status, output}
    after
      timeout_ms ->
        Port.close(port)
        {:error, :cli_timeout}
    end
  end

  defp emit_output(on_message, agent_id, agent_kind, text) do
    payload =
      case Jason.decode(text) do
        {:ok, decoded} -> decoded
        {:error, _} -> %{"text" => text}
      end

    emit(on_message, agent_id, agent_kind, :notification, %{payload: payload})
  end

  defp emit(on_message, agent_id, agent_kind, event, payload) do
    on_message.(
      payload
      |> Map.put(:agent_id, agent_id)
      |> Map.put(:agent_kind, agent_kind)
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())
    )
  end

  defp append_output(existing, next, max_bytes) do
    combined = existing <> next

    if byte_size(combined) > max_bytes do
      binary_part(combined, byte_size(combined) - max_bytes, max_bytes)
    else
      combined
    end
  end

  defp port_pid(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, pid} -> to_string(pid)
      _ -> nil
    end
  end
end
```

- [ ] **Step 4: 运行 CLI backend 测试**

Run:

```powershell
cd C:\Users\GQY47\coding\Symphony\elixir
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/agent_backend_test.exs'
```

Expected: Codex backend 和 CLI backend 测试都通过。

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/agent/backend/cli_run.ex elixir/test/symphony_elixir/agent_backend_test.exs
git commit -m "feat: add cli agent backend"
```

---

### Task 6: AgentRunner 使用 backend abstraction

**Files:**
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`
- Modify: `elixir/test/symphony_elixir/core_test.exs`

- [ ] **Step 1: 写失败测试：AgentRunner 可跑 cli_run agent**

在 `core_test.exs` 加入：

```elixir
test "agent runner dispatches to configured cli backend" do
  test_root = Path.join(System.tmp_dir!(), "symphony-agent-runner-cli-#{System.unique_integer([:positive])}")

  try do
    workspace_root = Path.join(test_root, "workspaces")
    fake_mimo = Path.join(test_root, "mimo")
    trace_file = Path.join(test_root, "mimo.trace")

    File.mkdir_p!(test_root)
    File.write!(fake_mimo, """
    #!/bin/sh
    printf 'ARGV:%s\\n' "$*" >> "#{trace_file}"
    printf '{"type":"message","text":"done"}\\n'
    """)
    File.chmod!(fake_mimo, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      hook_after_create: "printf ready > READY.txt",
      agents: %{
        codex: %{kind: "codex_app_server", command: "codex app-server"},
        mimocode: %{kind: "cli_run", command: fake_mimo, args: ["run", "--format", "json", "--dir", "{{workspace}}"]}
      },
      routing: %{default_agent: "mimocode"}
    )

    issue = %Issue{id: "issue-runner-cli", identifier: "MT-CLI", title: "Run CLI", state: "In Progress"}

    assert :ok = AgentRunner.run(issue, nil, agent_id: "mimocode")
    assert File.read!(trace_file) =~ "Run CLI"
  after
    File.rm_rf(test_root)
  end
end
```

- [ ] **Step 2: 修改 AgentRunner alias**

将：

```elixir
alias SymphonyElixir.Codex.AppServer
```

替换为：

```elixir
alias SymphonyElixir.Agent.Backend
```

- [ ] **Step 3: 将 run_codex_turns/5 泛化为 run_agent_turns/5**

把 `run_codex_turns` 改为：

```elixir
defp run_agent_turns(workspace, issue, update_recipient, opts, worker_host) do
  max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
  issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
  resolved_agent = resolved_agent_for_issue(issue, opts)

  do_run_agent_turns(resolved_agent, workspace, issue, update_recipient, opts, issue_state_fetcher, 1, max_turns, worker_host)
end
```

在 `run_on_worker_host/4` 中调用改为：

```elixir
run_agent_turns(workspace, issue, codex_update_recipient, opts, worker_host)
```

- [ ] **Step 4: 添加 resolved_agent_for_issue/2**

加入：

```elixir
defp resolved_agent_for_issue(issue, opts) do
  settings = Config.settings!()

  case Keyword.get(opts, :agent_id) do
    agent_id when is_binary(agent_id) ->
      config = Map.fetch!(settings.agents, agent_id)
      %{id: agent_id, kind: Map.fetch!(config, "kind"), config: config}

    _ ->
      {:ok, resolved} = SymphonyElixir.Agent.Router.resolve(issue, settings)
      resolved
  end
end
```

- [ ] **Step 5: 添加 do_run_agent_turns/9**

实现：

```elixir
defp do_run_agent_turns(resolved_agent, workspace, issue, update_recipient, opts, issue_state_fetcher, turn_number, max_turns, worker_host) do
  prompt = build_turn_prompt(issue, opts, turn_number, max_turns)
  backend = Backend.module_for(resolved_agent.kind)

  backend_opts =
    opts
    |> Keyword.put(:worker_host, worker_host)
    |> Keyword.put(:on_message, codex_message_handler(update_recipient, issue))

  with {:ok, result} <- backend.run_issue(workspace, issue, prompt, resolved_agent, backend_opts) do
    Logger.info("Completed agent run for #{issue_context(issue)} agent_id=#{resolved_agent.id} session_id=#{result[:session_id] || "n/a"} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

    case continue_with_issue?(issue, issue_state_fetcher) do
      {:continue, refreshed_issue} when turn_number < max_turns ->
        do_run_agent_turns(resolved_agent, workspace, refreshed_issue, update_recipient, opts, issue_state_fetcher, turn_number + 1, max_turns, worker_host)

      {:continue, _refreshed_issue} ->
        :ok

      {:done, _refreshed_issue} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

保留 `codex_message_handler` 和 message tuple 名称，减少 orchestrator 改动。

- [ ] **Step 6: 运行 AgentRunner 相关测试**

Run:

```powershell
cd C:\Users\GQY47\coding\Symphony\elixir
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/core_test.exs test/symphony_elixir/agent_backend_test.exs'
```

Expected: 现有 Codex continuation 测试和新增 CLI runner 测试通过。

- [ ] **Step 7: Commit**

```bash
git add elixir/lib/symphony_elixir/agent_runner.ex elixir/test/symphony_elixir/core_test.exs
git commit -m "feat: run issues through selected agent backend"
```

---

### Task 7: Orchestrator dispatch 记录 agent identity

**Files:**
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Modify: `elixir/test/symphony_elixir/core_test.exs`

- [ ] **Step 1: 写失败测试：dispatch running entry 包含 agent_id**

在适合的 orchestrator dispatch 测试附近加入：

```elixir
test "orchestrator stores selected agent identity on running entries" do
  write_workflow_file!(Workflow.workflow_file_path(),
    tracker_kind: "memory",
    agents: %{
      codex: %{kind: "codex_app_server", command: "codex app-server"},
      mimocode: %{kind: "cli_run", command: "mimo"}
    },
    routing: %{default_agent: "codex", by_label: %{"agent:mimo" => "mimocode"}}
  )

  issue = %Issue{
    id: "issue-agent-id",
    identifier: "MT-AGENT",
    title: "Agent routing",
    state: "In Progress",
    labels: ["agent:mimo"]
  }

  state = %Orchestrator.State{
    running: %{},
    claimed: MapSet.new(),
    retry_attempts: %{},
    codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
    max_concurrent_agents: 10
  }

  assert Orchestrator.selected_agent_for_test(issue, state) == {:ok, %{id: "mimocode", kind: "cli_run"}}
end
```

- [ ] **Step 2: 增加测试 helper**

在 `Orchestrator` public test helpers 区域加：

```elixir
@doc false
def selected_agent_for_test(%Issue{} = issue, %State{} = state) do
  select_agent_for_issue(issue, state)
end
```

- [ ] **Step 3: 实现 select_agent_for_issue/2**

在 dispatch 相关 private functions 附近加入：

```elixir
defp select_agent_for_issue(%Issue{} = issue, %State{} = _state) do
  SymphonyElixir.Agent.Router.resolve(issue, Config.settings!())
end
```

- [ ] **Step 4: 修改 do_dispatch_issue/4**

把现有：

```elixir
case select_worker_host(state, preferred_worker_host) do
```

包一层：

```elixir
with {:ok, resolved_agent} <- select_agent_for_issue(issue, state) do
  case select_worker_host(state, preferred_worker_host) do
    :no_worker_capacity ->
      Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
      state

    worker_host ->
      spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host, resolved_agent)
  end
else
  {:error, reason} ->
    Logger.error("No agent route for #{issue_context(issue)}: #{inspect(reason)}")
    state
end
```

- [ ] **Step 5: 修改 spawn_issue_on_worker_host/5 为 /6**

将 spawn 调用改为：

```elixir
pid =
  spawn_link(fn ->
    AgentRunner.run(issue, recipient,
      attempt: attempt,
      worker_host: worker_host,
      agent_id: resolved_agent.id
    )
  end)
```

running entry 增加：

```elixir
agent_id: resolved_agent.id,
agent_kind: resolved_agent.kind,
```

retry metadata 也带上：

```elixir
agent_id: Map.get(running_entry, :agent_id),
agent_kind: Map.get(running_entry, :agent_kind),
```

- [ ] **Step 6: retry 时保留 agent_id**

在 `handle_retry_issue_lookup/5` 到 `dispatch_issue/4` 的调用路径上，把 metadata 中的 `agent_id` 作为 preferred agent 传给 `AgentRunner.run`。最小做法是在 `dispatch_issue` opts/metadata 中保留 `agent_id`，如果该字段存在，构造 resolved agent 时优先使用它。

代码片段：

```elixir
preferred_agent_id = metadata[:agent_id]
...
AgentRunner.run(issue, recipient,
  attempt: attempt,
  worker_host: worker_host,
  agent_id: preferred_agent_id || resolved_agent.id
)
```

- [ ] **Step 7: 运行 orchestrator 相关测试**

Run:

```powershell
cd C:\Users\GQY47\coding\Symphony\elixir
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/core_test.exs'
```

Expected: 新增 selected agent 测试通过；现有 dispatch/retry 测试通过。

- [ ] **Step 8: Commit**

```bash
git add elixir/lib/symphony_elixir/orchestrator.ex elixir/test/symphony_elixir/core_test.exs
git commit -m "feat: route dispatches to named agents"
```

---

### Task 8: Snapshot/API/dashboard 暴露 agent 字段

**Files:**
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Modify: `elixir/lib/symphony_elixir_web/presenter.ex`
- Modify: `elixir/lib/symphony_elixir/status_dashboard.ex`
- Modify: `elixir/test/symphony_elixir/orchestrator_status_test.exs`
- Modify: `elixir/test/symphony_elixir/extensions_test.exs`

- [ ] **Step 1: 写失败测试：snapshot 包含 agent_id/agent_kind**

在 `orchestrator_status_test.exs` 加入或扩展现有 snapshot 测试：

```elixir
test "snapshot includes selected agent identity for running issues" do
  issue_id = "issue-agent-snapshot"

  state = %Orchestrator.State{
    running: %{
      issue_id => %{
        pid: self(),
        ref: nil,
        identifier: "MT-SNAP",
        issue: %Issue{id: issue_id, identifier: "MT-SNAP", state: "In Progress"},
        agent_id: "mimocode",
        agent_kind: "cli_run",
        started_at: DateTime.utc_now(),
        codex_input_tokens: 0,
        codex_output_tokens: 0,
        codex_total_tokens: 0
      }
    },
    codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
    retry_attempts: %{},
    blocked: %{}
  }

  snapshot = Orchestrator.snapshot_from_state_for_test(state)
  [running] = snapshot.running

  assert running.agent_id == "mimocode"
  assert running.agent_kind == "cli_run"
end
```

如果没有 `snapshot_from_state_for_test/1`，新增只用于测试的 helper，内部复用 snapshot projection。

- [ ] **Step 2: Orchestrator snapshot 增加字段**

在 `handle_call(:snapshot, ...)` 的 running map 中加入：

```elixir
agent_id: Map.get(metadata, :agent_id, "codex"),
agent_kind: Map.get(metadata, :agent_kind, "codex_app_server"),
```

retrying 和 blocked maps 中也加入：

```elixir
agent_id: Map.get(retry, :agent_id),
agent_kind: Map.get(retry, :agent_kind),
```

blocked 同理。

- [ ] **Step 3: Presenter payload 增加字段**

在 `running_entry_payload/1` 加入：

```elixir
agent_id: Map.get(entry, :agent_id),
agent_kind: Map.get(entry, :agent_kind),
```

在 `retry_entry_payload/1`、`blocked_entry_payload/1`、`running_issue_payload/1`、`retry_issue_payload/1`、`blocked_issue_payload/1` 中加入同名字段。

- [ ] **Step 4: StatusDashboard running table 显示 agent**

在 running table header 增加 `AGENT` 列，row 中使用：

```elixir
agent = format_cell(Map.get(running_entry, :agent_id) || "codex", @running_agent_width)
```

设置宽度：

```elixir
@running_agent_width 10
```

确保总宽度没有破坏 snapshot tests；如 snapshot 变动，按新布局更新 fixture。

- [ ] **Step 5: 运行状态/API/dashboard 测试**

Run:

```powershell
cd C:\Users\GQY47\coding\Symphony\elixir
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/extensions_test.exs test/symphony_elixir/status_dashboard_snapshot_test.exs'
```

Expected: snapshot/API 测试通过；dashboard snapshot 如预期更新。

- [ ] **Step 6: Commit**

```bash
git add elixir/lib/symphony_elixir/orchestrator.ex elixir/lib/symphony_elixir_web/presenter.ex elixir/lib/symphony_elixir/status_dashboard.ex elixir/test/symphony_elixir/orchestrator_status_test.exs elixir/test/symphony_elixir/extensions_test.exs elixir/test/fixtures/status_dashboard_snapshots
git commit -m "feat: expose agent identity in observability"
```

---

### Task 9: 文档和示例 workflow

**Files:**
- Modify: `elixir/README.md`
- Modify: `elixir/WORKFLOW.md`
- Create: `elixir/docs/multi_agent_backends.md`

- [ ] **Step 1: 新增中文文档**

创建 `elixir/docs/multi_agent_backends.md`：

```markdown
# 多 Agent Backend

Symphony 可以把 Linear issue 路由给不同的平级 coding agent backend。Codex、MiMo-Code、OpenCode 都被建模为可以独立承接 issue 的 worker，而不是彼此的工具。

## 推荐模型

通过 Linear 表达委派关系：

1. 上游 agent 创建、更新或分配 Linear issue。
2. Symphony 轮询 Linear。
3. routing 根据 label、assignee 或 default agent 选择 backend。
4. 被选中的 backend 在独立 workspace 中处理该 issue。

## MiMo-Code 示例

```yaml
agents:
  codex:
    kind: codex_app_server
    command: "codex app-server"
  mimocode:
    kind: cli_run
    command: "mimo"
    args:
      - "run"
      - "--format"
      - "json"
      - "--agent"
      - "build"
      - "--dir"
      - "{{workspace}}"
    timeout_ms: 600000
    max_output_bytes: 200000
routing:
  default_agent: codex
  by_label:
    "agent:mimo": mimocode
```

给 Linear issue 添加 `agent:mimo` label 后，Symphony 会把该 issue 交给 MiMo-Code backend。
```

- [ ] **Step 2: 在 README 链接文档**

在 `elixir/README.md` 的运行/配置段落加入：

```markdown
多 agent backend 配置见 [`docs/multi_agent_backends.md`](docs/multi_agent_backends.md)。
```

- [ ] **Step 3: 在 WORKFLOW.md 增加注释示例**

在 `elixir/WORKFLOW.md` 的 front matter 中保持默认行为不变，只增加注释或文档段落，不启用 MiMo 默认配置，避免影响现有用户。

- [ ] **Step 4: 运行 docs/spec check**

Run:

```powershell
cd C:\Users\GQY47\coding\Symphony\elixir
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix specs.check'
```

Expected: specs check 通过。

- [ ] **Step 5: Commit**

```bash
git add elixir/README.md elixir/WORKFLOW.md elixir/docs/multi_agent_backends.md
git commit -m "docs: explain multi-agent backend routing"
```

---

### Task 10: 全量验证和本地 smoke test

**Files:**
- No code changes expected.

- [ ] **Step 1: 格式化**

Run:

```powershell
cd C:\Users\GQY47\coding\Symphony\elixir
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix format'
```

Expected: 格式化完成，无错误。

- [ ] **Step 2: 全量测试**

Run:

```powershell
cd C:\Users\GQY47\coding\Symphony\elixir
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test'
```

Expected: 全部 ExUnit 测试通过。

- [ ] **Step 3: build**

Run:

```powershell
cd C:\Users\GQY47\coding\Symphony\elixir
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix build'
```

Expected: `bin/symphony` 成功生成。

- [ ] **Step 4: 本地 MiMo smoke workflow**

创建临时 workflow，不提交：

```yaml
agents:
  codex:
    kind: codex_app_server
    command: "codex app-server"
  mimocode:
    kind: cli_run
    command: "/tmp/fake-mimo"
    args: ["run", "--format", "json", "--dir", "{{workspace}}"]
routing:
  default_agent: codex
  by_label:
    "agent:mimo": mimocode
```

创建 `/tmp/fake-mimo`：

```bash
#!/bin/sh
printf '{"type":"message","text":"fake mimo completed"}\n'
exit 0
```

Run:

```powershell
wsl.exe -e bash -lc 'chmod +x /tmp/fake-mimo'
```

Expected: 给 memory tracker 或测试 issue 添加 `agent:mimo` 后，snapshot 中 `agent_id` 显示为 `mimocode`。

- [ ] **Step 5: 最终状态检查**

Run:

```powershell
cd C:\Users\GQY47\coding\Symphony
git status --short
git log --oneline -5
```

Expected: 只有预期修改；提交历史包含各任务 commit。
