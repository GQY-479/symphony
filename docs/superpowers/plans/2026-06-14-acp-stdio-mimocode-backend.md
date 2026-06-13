# ACP Stdio MiMo-Code Backend 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 MiMo-Code 通过 ACP stdio 作为平级 session backend 接入 Symphony，并能通过 `agent:mimo` 路由承接 Linear issue。

**Architecture:** 在现有 multi-agent 架构上新增 `acp_stdio` backend kind。`AgentRunner` 已经能识别实现 `start_session/3`、`run_turn/5`、`stop_session/1` 的 session backend，因此本计划把 ACP client 做成独立模块，再由 `AcpStdio` backend 映射 Symphony 的 session/turn/event 语义。真实 MiMo-Code 验证必须作为阶段门禁；如果实测 ACP 行为与官方协议或源码明显不一致，暂停实现并回到设计文档修订。

**Tech Stack:** Elixir、ExUnit、Jason、Erlang Port、ACP v1 JSON-RPC over ndjson stdio、MiMo-Code `mimo acp`。

---

## 阶段门禁

每个阶段都遵循：前期调研 -> 局部设计 -> 实现 -> 验证。

- 阶段 1：确认真实 `mimo acp` 能启动，且官方 ACP 基础方法与 MiMo-Code 源码一致。
- 阶段 2：配置层允许 `kind: acp_stdio`，并能拒绝错误配置。
- 阶段 3：backend dispatcher 能解析 `acp_stdio`。
- 阶段 4：ACP client 能通过 fake ACP server 完成 initialize、session/new、session/prompt、session/cancel。
- 阶段 5：`AcpStdio` backend 能被 `AgentRunner` 当作 session backend 使用。
- 阶段 6：真实 `mimo acp` smoke test 能证明 Linear issue 可被 MiMo-Code 承接，或给出明确阻塞原因。

如果任一阶段发现事实推翻设计，例如 `mimo acp` 不使用 ACP v1 方法、不能以非交互方式启动、或必须依赖 HTTP server 才能 prompt，则停止后续代码实现，更新 `docs/superpowers/specs/2026-06-14-acp-stdio-mimocode-backend-design.md` 后重新评审。

## 文件结构

- Modify: `elixir/lib/symphony_elixir/config.ex`
  - 负责语义校验，新增 `acp_stdio` kind、`args` 类型校验、`permission_policy` 校验。
- Modify: `elixir/lib/symphony_elixir/agent/backend.ex`
  - 负责 backend kind 到模块的分发，新增 `acp_stdio`。
- Create: `elixir/lib/symphony_elixir/agent/acp_stdio/client.ex`
  - 负责 ACP JSON-RPC over stdio：启动子进程、发送 request/notification、读取 response/notification、处理 permission request、timeout 和 cancel。
- Create: `elixir/lib/symphony_elixir/agent/backend/acp_stdio.ex`
  - 负责实现 Symphony session backend contract，包装 `AcpStdio.Client`，并统一 annotation agent event。
- Modify: `elixir/test/symphony_elixir/core_test.exs`
  - 覆盖配置解析和验证。
- Modify: `elixir/test/symphony_elixir/agent_backend_test.exs`
  - 覆盖 dispatcher、ACP client 和 backend 行为。
- Create: `elixir/docs/mimocode_acp_smoke_test.md`
  - 记录真实 MiMo-Code 调研和 smoke test 命令。
- Modify: `elixir/docs/multi_agent_backends.md`
  - 增加 `acp_stdio` 配置示例和当前能力边界。

---

### Task 1: 真实 ACP 前期调研门禁

**Files:**
- Create: `elixir/docs/mimocode_acp_smoke_test.md`

- [ ] **Step 1: 确认官方 ACP 基础方法**

依据：

- `https://agentclientprotocol.com/protocol/v1/overview`
- `https://agentclientprotocol.com/protocol/v1/schema`
- `https://raw.githubusercontent.com/XiaomiMiMo/MiMo-Code/main/packages/opencode/src/cli/cmd/acp.ts`

已知事实：

- ACP 使用 JSON-RPC 2.0。
- 典型流程是 `initialize` -> `session/new` -> `session/prompt`。
- prompt 过程中 agent 会发送 `session/update`。
- cancel 使用 `session/cancel` notification。
- permission 请求由 agent 调 client 的 `session/request_permission`。
- MiMo-Code `acp` 命令使用 `@agentclientprotocol/sdk` 的 `AgentSideConnection` 和 `ndJsonStream`，并支持 `--cwd`。

- [ ] **Step 2: 在本机确认 `mimo acp` 可发现**

Run:

```powershell
wsl.exe -e bash -lc 'command -v mimo && mimo acp --help'
```

Expected: 输出 `mimo` 路径，并显示 `acp` 命令帮助，帮助中包含 `--cwd` 或 working directory 相关参数。

如果失败，执行：

```powershell
wsl.exe -e bash -lc 'command -v mimocode || command -v mimo-code || true'
```

Expected: 如果存在替代命令，记录真实命令名；如果没有命令，停止真实 smoke，但继续 fake server 实现。

- [ ] **Step 3: 写调研记录**

Create `elixir/docs/mimocode_acp_smoke_test.md`:

```markdown
# MiMo-Code ACP Smoke Test

## 调研结论

- ACP 官方流程：`initialize` -> `session/new` -> `session/prompt`，运行中通过 `session/update` 推送事件，取消通过 `session/cancel`。
- MiMo-Code 源码中的 `acp` 命令使用 `@agentclientprotocol/sdk` 的 `AgentSideConnection` 和 `ndJsonStream`。
- 本机命令探测结果：
- `mimo` 路径：粘贴 Step 2 的命令输出。
  - `mimo acp --help`：记录是否可启动，以及是否支持 `--cwd`。

## 方案门禁

如果本机 `mimo acp` 无法启动，Symphony 侧仍先用 fake ACP server 实现协议适配，但真实验收保持未通过。

如果 `mimo acp` 不支持 ACP v1 的 `initialize`、`session/new`、`session/prompt`，暂停实现并回到设计文档修订。

## 后续 smoke 命令

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mimo acp --cwd "$PWD"'
```
```

- [ ] **Step 4: 提交调研文档**

Run:

```powershell
git add elixir/docs/mimocode_acp_smoke_test.md
git commit -m "docs: 记录 MiMo-Code ACP 调研门禁"
```

Expected: 只提交 `elixir/docs/mimocode_acp_smoke_test.md`。

---

### Task 2: 配置层支持 `acp_stdio`

**Files:**
- Modify: `elixir/lib/symphony_elixir/config.ex`
- Modify: `elixir/test/symphony_elixir/core_test.exs`

- [ ] **Step 1: 写失败测试：允许 acp_stdio agent 配置**

Modify `elixir/test/symphony_elixir/core_test.exs`，在已有 agent 配置测试附近加入：

```elixir
test "workflow config accepts acp_stdio agents" do
  settings =
    parse!(%{
      agents: %{
        codex: %{kind: "codex_app_server", command: "codex app-server"},
        mimocode: %{
          kind: "acp_stdio",
          command: "mimo",
          args: ["acp", "--cwd", "{{workspace}}"],
          permission_policy: "reject",
          timeout_ms: 3_600_000,
          read_timeout_ms: 5_000,
          stall_timeout_ms: 300_000
        }
      },
      routing: %{default_agent: "codex", by_label: %{"agent:mimo" => "mimocode"}}
    })

  assert settings.agents["mimocode"]["kind"] == "acp_stdio"
  assert settings.agents["mimocode"]["args"] == ["acp", "--cwd", "{{workspace}}"]
  assert settings.agents["mimocode"]["permission_policy"] == "reject"
  assert settings.routing.by_label == %{"agent:mimo" => "mimocode"}
end
```

- [ ] **Step 2: 写失败测试：拒绝错误 ACP 配置**

Modify `elixir/test/symphony_elixir/core_test.exs`:

```elixir
test "workflow config rejects invalid acp_stdio args" do
  write_workflow_file!(Workflow.workflow_file_path(),
    agents: %{
      mimocode: %{
        kind: "acp_stdio",
        command: "mimo",
        args: "acp",
        permission_policy: "reject"
      }
    },
    routing: %{default_agent: "mimocode"}
  )

  assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
  assert message =~ "agents.mimocode.args must be a list of strings"
end
```

- [ ] **Step 3: 写失败测试：拒绝未知 permission policy**

Modify `elixir/test/symphony_elixir/core_test.exs`:

```elixir
test "workflow config rejects invalid acp_stdio permission policy" do
  write_workflow_file!(Workflow.workflow_file_path(),
    agents: %{
      mimocode: %{
        kind: "acp_stdio",
        command: "mimo",
        args: ["acp"],
        permission_policy: "ask"
      }
    },
    routing: %{default_agent: "mimocode"}
  )

  assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
  assert message =~ "agents.mimocode.permission_policy must be one of reject, fail, allow"
end
```

- [ ] **Step 4: 实现配置校验**

Modify `elixir/lib/symphony_elixir/config.ex`:

```elixir
@supported_agent_kinds ["codex_app_server", "cli_run", "acp_stdio"]
@acp_permission_policies ["reject", "fail", "allow"]
```

替换 kind 校验：

```elixir
defp validate_agent_kind(_agent_id, kind) when kind in @supported_agent_kinds, do: :ok

defp validate_agent_kind(agent_id, kind) do
  invalid_config(
    "agents.#{agent_id}.kind must be one of #{Enum.join(@supported_agent_kinds, ", ")}, got #{inspect(kind)}"
  )
end
```

在 `validate_agent/3` 中把最后一行改为：

```elixir
validate_kind_specific_agent_config(agent_id, agent)
```

新增：

```elixir
defp validate_kind_specific_agent_config(agent_id, %{"kind" => "codex_app_server"} = agent) do
  with :ok <- validate_optional_string_or_map(agent_id, agent, "approval_policy"),
       :ok <- validate_optional_string(agent_id, agent, "thread_sandbox") do
    validate_optional_map(agent_id, agent, "turn_sandbox_policy")
  end
end

defp validate_kind_specific_agent_config(agent_id, %{"kind" => "acp_stdio"} = agent) do
  with :ok <- validate_optional_string_list(agent_id, agent, "args") do
    validate_optional_enum(agent_id, agent, "permission_policy", @acp_permission_policies)
  end
end

defp validate_kind_specific_agent_config(_agent_id, _agent), do: :ok
```

保留旧的 `validate_codex_agent_config/2` 逻辑时，必须避免两个函数同时被调用。推荐直接改名为 `validate_kind_specific_agent_config/2`。

新增 helper：

```elixir
defp validate_optional_string_list(agent_id, agent, field) do
  case Map.fetch(agent, field) do
    :error ->
      :ok

    {:ok, value} when is_list(value) ->
      if Enum.all?(value, &is_binary/1) do
        :ok
      else
        invalid_config("agents.#{agent_id}.#{field} must be a list of strings")
      end

    {:ok, value} ->
      invalid_config("agents.#{agent_id}.#{field} must be a list of strings, got #{inspect(value)}")
  end
end

defp validate_optional_enum(agent_id, agent, field, allowed) do
  case Map.fetch(agent, field) do
    :error ->
      :ok

    {:ok, value} when value in allowed ->
      :ok

    {:ok, value} ->
      invalid_config("agents.#{agent_id}.#{field} must be one of #{Enum.join(allowed, ", ")}, got #{inspect(value)}")
  end
end
```

- [ ] **Step 5: 运行配置测试**

Run:

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/core_test.exs'
```

Expected: core test 文件通过。

- [ ] **Step 6: 提交配置层变更**

Run:

```powershell
git add elixir/lib/symphony_elixir/config.ex elixir/test/symphony_elixir/core_test.exs
git commit -m "feat: 支持 acp_stdio agent 配置"
```

Expected: 只提交配置和配置测试。

---

### Task 3: 注册 `acp_stdio` backend

**Files:**
- Modify: `elixir/lib/symphony_elixir/agent/backend.ex`
- Modify: `elixir/test/symphony_elixir/agent_backend_test.exs`
- Create: `elixir/lib/symphony_elixir/agent/backend/acp_stdio.ex`

- [ ] **Step 1: 写失败测试：dispatcher 支持 acp_stdio**

Modify `elixir/test/symphony_elixir/agent_backend_test.exs`:

```elixir
test "module_for resolves supported backend kinds and rejects unknown kinds" do
  assert Backend.module_for("codex_app_server") == SymphonyElixir.Agent.Backend.CodexAppServer
  assert Backend.module_for("cli_run") == SymphonyElixir.Agent.Backend.CliRun
  assert Backend.module_for("acp_stdio") == SymphonyElixir.Agent.Backend.AcpStdio

  assert_raise ArgumentError, ~r/unknown agent backend kind/, fn ->
    Backend.module_for("not-real")
  end
end
```

- [ ] **Step 2: 实现 dispatcher 映射**

Modify `elixir/lib/symphony_elixir/agent/backend.ex`:

```elixir
def module_for("acp_stdio"), do: SymphonyElixir.Agent.Backend.AcpStdio
```

- [ ] **Step 3: 创建最小 backend 模块**

Create `elixir/lib/symphony_elixir/agent/backend/acp_stdio.ex`:

```elixir
defmodule SymphonyElixir.Agent.Backend.AcpStdio do
  @moduledoc """
  Agent backend that runs an ACP-compatible agent over stdio.
  """

  @behaviour SymphonyElixir.Agent.Backend

  @impl true
  def run_issue(_workspace, _issue, _prompt, _resolved_agent, _opts) do
    {:error, :acp_stdio_session_backend_only}
  end

  @spec start_session(Path.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_session(_workspace, _resolved_agent, _opts) do
    {:error, :acp_stdio_not_implemented}
  end

  @spec run_turn(map(), Path.t(), map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(_session, _workspace, _issue, _prompt, _opts) do
    {:error, :acp_stdio_not_implemented}
  end

  @spec stop_session(map()) :: :ok
  def stop_session(_session), do: :ok
end
```

- [ ] **Step 4: 运行 backend dispatcher 测试**

Run:

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/agent_backend_test.exs'
```

Expected: 只有未实现行为相关测试失败；dispatcher 测试通过。如果该文件仍只有 dispatcher 新断言，则全文件通过。

- [ ] **Step 5: 提交 backend 注册**

Run:

```powershell
git add elixir/lib/symphony_elixir/agent/backend.ex elixir/lib/symphony_elixir/agent/backend/acp_stdio.ex elixir/test/symphony_elixir/agent_backend_test.exs
git commit -m "feat: 注册 acp_stdio backend"
```

Expected: 只提交 dispatcher、最小 backend 和对应测试。

---

### Task 4: 实现 ACP stdio client

**Files:**
- Create: `elixir/lib/symphony_elixir/agent/acp_stdio/client.ex`
- Modify: `elixir/test/symphony_elixir/agent_backend_test.exs`

- [ ] **Step 1: 写 fake ACP server helper**

Modify `elixir/test/symphony_elixir/agent_backend_test.exs`，新增 helper：

```elixir
defp write_fake_acp_server!(test_root, behavior) do
  executable = Path.join(test_root, "fake-acp-server")
  behavior_json = Jason.encode!(behavior)

  File.write!(executable, """
  #!/bin/sh
  elixir -e '
  behavior = Jason.decode!(System.get_env("FAKE_ACP_BEHAVIOR"))

  read_loop = fn read_loop ->
    case IO.read(:line) do
      :eof ->
        :ok

      line ->
        message = Jason.decode!(String.trim(line))
        method = Map.get(message, "method")
        id = Map.get(message, "id")

        response =
          case method do
            "initialize" ->
              %{"jsonrpc" => "2.0", "id" => id, "result" => %{"protocolVersion" => 1, "agentCapabilities" => %{}, "authMethods" => []}}

            "session/new" ->
              %{"jsonrpc" => "2.0", "id" => id, "result" => %{"sessionId" => Map.get(behavior, "sessionId", "fake-acp-session")}}

            "session/prompt" ->
              if Map.get(behavior, "permission") do
                IO.puts(Jason.encode!(%{"jsonrpc" => "2.0", "id" => 9001, "method" => "session/request_permission", "params" => %{"sessionId" => Map.get(behavior, "sessionId", "fake-acp-session"), "toolCall" => %{"title" => "write"}, "options" => [%{"id" => "allow_once"}, %{"id" => "reject"}]}}))
              end

              IO.puts(Jason.encode!(%{"jsonrpc" => "2.0", "method" => "session/update", "params" => %{"sessionId" => Map.get(behavior, "sessionId", "fake-acp-session"), "update" => %{"kind" => "text", "text" => "working"}}}))
              %{"jsonrpc" => "2.0", "id" => id, "result" => %{"stopReason" => Map.get(behavior, "stopReason", "end_turn")}}

            "session/close" ->
              %{"jsonrpc" => "2.0", "id" => id, "result" => %{}}

            _ ->
              %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => -32601, "message" => "method not found"}}
          end

        if response, do: IO.puts(Jason.encode!(response))
        read_loop.(read_loop)
    end
  end

  read_loop.(read_loop)
  '
  """)

  File.chmod!(executable, 0o755)
  {executable, [{"FAKE_ACP_BEHAVIOR", behavior_json}]}
end
```

- [ ] **Step 2: 写失败测试：client 完成基础流程**

Modify `elixir/test/symphony_elixir/agent_backend_test.exs`:

```elixir
test "acp stdio client starts a session and completes a prompt" do
  test_root = Path.join(System.tmp_dir!(), "symphony-acp-client-#{System.unique_integer([:positive])}")

  try do
    workspace = Path.join(test_root, "workspace")
    File.mkdir_p!(workspace)
    {executable, env} = write_fake_acp_server!(test_root, %{"sessionId" => "fake-acp-session"})

    parent = self()

    assert {:ok, session} =
             SymphonyElixir.Agent.AcpStdio.Client.start_session(
               workspace,
               %{command: executable, args: [], env: env, permission_policy: "reject", timeout_ms: 5_000},
               fn event -> send(parent, {:acp_event, event}) end
             )

    assert session.session_id == "fake-acp-session"

    assert {:ok, result} =
             SymphonyElixir.Agent.AcpStdio.Client.prompt(session, "hello", timeout_ms: 5_000)

    assert Map.get(result, "stop_reason") == "end_turn"

    assert_receive {:acp_event, %{event: :session_started, session_id: "fake-acp-session"}}
    assert_receive {:acp_event, %{event: :notification, payload: %{"method" => "session/update"}}}

    assert :ok = SymphonyElixir.Agent.AcpStdio.Client.stop_session(session)
  after
    File.rm_rf(test_root)
  end
end
```

- [ ] **Step 3: 实现 client 基础结构**

Create `elixir/lib/symphony_elixir/agent/acp_stdio/client.ex`:

```elixir
defmodule SymphonyElixir.Agent.AcpStdio.Client do
  @moduledoc """
  Minimal ACP JSON-RPC client over newline-delimited stdio.
  """

  @type session :: %{
          port: port(),
          session_id: String.t(),
          os_pid: integer() | nil,
          permission_policy: String.t(),
          on_event: (map() -> term())
        }

  @spec start_session(Path.t(), map(), (map() -> term())) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, config, on_event) when is_binary(workspace) and is_function(on_event, 1) do
    with {:ok, executable} <- resolve_command(Map.fetch!(config, :command)),
         {:ok, port} <- start_port(executable, Map.get(config, :args, []), workspace, Map.get(config, :env, [])),
         session0 <- %{
           port: port,
           session_id: nil,
           os_pid: port_os_pid(port),
           permission_policy: Map.get(config, :permission_policy, "reject"),
           on_event: on_event
         },
         {:ok, _init} <- request(session0, "initialize", initialize_params(), Map.get(config, :timeout_ms, 5_000)),
         {:ok, result} <- request(session0, "session/new", %{"cwd" => Path.expand(workspace)}, Map.get(config, :timeout_ms, 5_000)),
         {:ok, session_id} <- extract_session_id(result) do
      session = %{session0 | session_id: session_id}
      emit(session, :session_started, %{"result" => result})
      {:ok, session}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec prompt(session(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prompt(%{session_id: session_id} = session, prompt, opts) when is_binary(prompt) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 3_600_000)
    params = %{"sessionId" => session_id, "prompt" => [%{"type" => "text", "text" => prompt}]}

    case request(session, "session/prompt", params, timeout_ms) do
      {:ok, result} ->
        {:ok, %{"stop_reason" => Map.get(result, "stopReason"), "raw" => result}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec cancel(session()) :: :ok
  def cancel(%{session_id: session_id} = session) do
    notify(session, "session/cancel", %{"sessionId" => session_id})
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{session_id: session_id} = session) when is_binary(session_id) do
    _ = request(session, "session/close", %{"sessionId" => session_id}, 1_000)
    close_port(session.port)
  end

  def stop_session(%{port: port}), do: close_port(port)

  defp initialize_params do
    %{
      "protocolVersion" => 1,
      "clientInfo" => %{"name" => "Symphony", "version" => "dev"},
      "clientCapabilities" => %{
        "fs" => %{"readTextFile" => false, "writeTextFile" => false},
        "terminal" => false
      }
    }
  end

  defp request(session, method, params, timeout_ms) do
    id = System.unique_integer([:positive])
    send_json(session.port, %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
    await_response(session, id, timeout_ms)
  end

  defp notify(session, method, params) do
    send_json(session.port, %{"jsonrpc" => "2.0", "method" => method, "params" => params})
    :ok
  end

  defp await_response(session, id, timeout_ms) do
    receive do
      {port, {:data, data}} when port == session.port ->
        data
        |> to_string()
        |> String.split("\n", trim: true)
        |> handle_lines(session, id, timeout_ms)

      {port, {:exit_status, status}} when port == session.port ->
        {:error, {:acp_exit, status}}
    after
      timeout_ms ->
        cancel(session)
        {:error, :acp_timeout}
    end
  end

  defp handle_lines([], session, id, timeout_ms), do: await_response(session, id, timeout_ms)

  defp handle_lines([line | rest], session, id, timeout_ms) do
    case Jason.decode(line) do
      {:ok, %{"id" => ^id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^id, "error" => error}} ->
        {:error, {:acp_error, error}}

      {:ok, %{"id" => request_id, "method" => "session/request_permission", "params" => params}} ->
        handle_permission_request(session, request_id, params)
        handle_lines(rest, session, id, timeout_ms)

      {:ok, %{"method" => method} = notification} ->
        emit(session, notification_event(method), notification)
        handle_lines(rest, session, id, timeout_ms)

      {:error, reason} ->
        emit(session, :malformed, %{"line" => line, "reason" => inspect(reason)})
        handle_lines(rest, session, id, timeout_ms)
    end
  end

  defp handle_permission_request(%{permission_policy: "allow"} = session, request_id, params) do
    emit(session, :approval_auto_approved, params)
    send_json(session.port, %{"jsonrpc" => "2.0", "id" => request_id, "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "allow_once"}}})
  end

  defp handle_permission_request(%{permission_policy: "fail"} = session, request_id, params) do
    emit(session, :approval_required, params)
    send_json(session.port, %{"jsonrpc" => "2.0", "id" => request_id, "result" => %{"outcome" => %{"outcome" => "cancelled"}}})
  end

  defp handle_permission_request(session, request_id, params) do
    emit(session, :permission_rejected, params)
    send_json(session.port, %{"jsonrpc" => "2.0", "id" => request_id, "result" => %{"outcome" => %{"outcome" => "rejected"}}})
  end

  defp notification_event("session/update"), do: :notification
  defp notification_event(_method), do: :other_message

  defp send_json(port, payload) do
    Port.command(port, Jason.encode!(payload) <> "\n")
  end

  defp start_port(executable, args, workspace, env) do
    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          args: Enum.map(args, &String.to_charlist(to_string(&1))),
          cd: String.to_charlist(workspace),
          env: Enum.map(env, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
        ]
      )

    {:ok, port}
  rescue
    error in [ArgumentError, ErlangError] ->
      {:error, {:acp_start_failed, executable, Exception.message(error)}}
  end

  defp resolve_command(command) when is_binary(command) do
    cond do
      Path.type(command) == :absolute and File.exists?(command) -> {:ok, command}
      executable = System.find_executable(command) -> {:ok, executable}
      true -> {:error, {:acp_command_not_found, command}}
    end
  end

  defp extract_session_id(%{"sessionId" => session_id}) when is_binary(session_id), do: {:ok, session_id}
  defp extract_session_id(result), do: {:error, {:acp_session_id_missing, result}}

  defp emit(session, event, payload) do
    session.on_event.(%{
      event: event,
      timestamp: DateTime.utc_now(),
      session_id: session.session_id,
      codex_app_server_pid: os_pid_string(session.os_pid),
      payload: payload
    })
  end

  defp port_os_pid(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) -> os_pid
      _ -> nil
    end
  end

  defp os_pid_string(os_pid) when is_integer(os_pid), do: Integer.to_string(os_pid)
  defp os_pid_string(_os_pid), do: nil

  defp close_port(port) when is_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
```

- [ ] **Step 4: 运行 client 测试**

Run:

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/agent_backend_test.exs'
```

Expected: 新增 client 基础流程测试通过。

- [ ] **Step 5: 提交 ACP client**

Run:

```powershell
git add elixir/lib/symphony_elixir/agent/acp_stdio/client.ex elixir/test/symphony_elixir/agent_backend_test.exs
git commit -m "feat: 添加 ACP stdio client"
```

Expected: 只提交 client 和测试。

---

### Task 5: 实现 `AcpStdio` backend

**Files:**
- Modify: `elixir/lib/symphony_elixir/agent/backend/acp_stdio.ex`
- Modify: `elixir/test/symphony_elixir/agent_backend_test.exs`

- [ ] **Step 1: 写失败测试：backend annotation 和 prompt**

Modify `elixir/test/symphony_elixir/agent_backend_test.exs`:

```elixir
test "acp backend starts session, annotates events, and runs prompt" do
  test_root = Path.join(System.tmp_dir!(), "symphony-acp-backend-#{System.unique_integer([:positive])}")

  try do
    workspace = Path.join(test_root, "workspace")
    File.mkdir_p!(workspace)
    {executable, env} = write_fake_acp_server!(test_root, %{"sessionId" => "fake-acp-session"})

    resolved_agent = %{
      id: "mimocode",
      kind: "acp_stdio",
      config: %{
        "command" => executable,
        "args" => [],
        "permission_policy" => "reject",
        "timeout_ms" => 5_000,
        "env" => env
      }
    }

    parent = self()

    assert {:ok, session} =
             Backend.AcpStdio.start_session(
               workspace,
               resolved_agent,
               on_message: fn message -> send(parent, {:acp_backend_message, message}) end
             )

    assert {:ok, result} =
             Backend.AcpStdio.run_turn(
               session,
               workspace,
               %Issue{id: "issue-acp-backend", identifier: "MT-910"},
               "perform acp task",
               on_message: fn message -> send(parent, {:acp_backend_message, message}) end
             )

    assert result.session_id == "fake-acp-session"

    assert_receive {:acp_backend_message,
                    %{
                      event: :session_started,
                      agent_id: "mimocode",
                      agent_kind: "acp_stdio",
                      session_id: "fake-acp-session"
                    }}

    assert_receive {:acp_backend_message,
                    %{
                      event: :turn_completed,
                      agent_id: "mimocode",
                      agent_kind: "acp_stdio",
                      session_id: "fake-acp-session"
                    }}

    assert :ok = Backend.AcpStdio.stop_session(session)
  after
    File.rm_rf(test_root)
  end
end
```

- [ ] **Step 2: 实现 backend**

Modify `elixir/lib/symphony_elixir/agent/backend/acp_stdio.ex`:

```elixir
defmodule SymphonyElixir.Agent.Backend.AcpStdio do
  @moduledoc """
  Agent backend that runs an ACP-compatible agent over stdio.
  """

  @behaviour SymphonyElixir.Agent.Backend

  alias SymphonyElixir.Agent.AcpStdio.Client

  @default_timeout_ms 3_600_000

  @impl true
  def run_issue(_workspace, _issue, _prompt, _resolved_agent, _opts) do
    {:error, :acp_stdio_session_backend_only}
  end

  @spec start_session(Path.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_session(workspace, resolved_agent, opts) do
    config = agent_config(resolved_agent)
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    client_config = %{
      command: Map.get(config, "command"),
      args: build_args(config, workspace),
      env: Map.get(config, "env", []),
      permission_policy: Map.get(config, "permission_policy", "reject"),
      timeout_ms: Map.get(config, "read_timeout_ms", Map.get(config, "timeout_ms", 5_000))
    }

    Client.start_session(workspace, client_config, annotated_on_message(on_message, resolved_agent))
    |> case do
      {:ok, session} ->
        {:ok, Map.merge(session, %{resolved_agent: resolved_agent, timeout_ms: Map.get(config, "timeout_ms", @default_timeout_ms)})}

      error ->
        error
    end
  end

  @spec run_turn(map(), Path.t(), map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, _workspace, _issue, prompt, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, Map.get(session, :timeout_ms, @default_timeout_ms))

    case Client.prompt(session, prompt, timeout_ms: timeout_ms) do
      {:ok, result} ->
        emit_turn_completed(session, result)
        {:ok, %{session_id: session.session_id, stop_reason: Map.get(result, "stop_reason"), raw: result}}

      {:error, :acp_timeout} = error ->
        Client.cancel(session)
        error

      error ->
        error
    end
  end

  @spec stop_session(map()) :: :ok
  def stop_session(session) when is_map(session), do: Client.stop_session(session)

  defp build_args(config, workspace) do
    config
    |> Map.get("args", [])
    |> Enum.map(&String.replace(to_string(&1), "{{workspace}}", workspace))
  end

  defp annotated_on_message(on_message, resolved_agent) do
    fn message ->
      message
      |> Map.put(:agent_id, agent_id(resolved_agent))
      |> Map.put(:agent_kind, agent_kind(resolved_agent))
      |> Map.put_new(:timestamp, DateTime.utc_now())
      |> on_message.()
    end
  end

  defp emit_turn_completed(session, result) do
    session.on_event.(%{
      event: :turn_completed,
      timestamp: DateTime.utc_now(),
      agent_id: agent_id(session.resolved_agent),
      agent_kind: agent_kind(session.resolved_agent),
      session_id: session.session_id,
      codex_app_server_pid: Map.get(session, :codex_app_server_pid),
      payload: result
    })
  end

  defp agent_id(resolved_agent), do: Map.get(resolved_agent, :id) || Map.get(resolved_agent, "id")
  defp agent_kind(resolved_agent), do: Map.get(resolved_agent, :kind) || Map.get(resolved_agent, "kind")
  defp agent_config(resolved_agent), do: Map.get(resolved_agent, :config) || Map.get(resolved_agent, "config") || %{}
  defp default_on_message(_message), do: :ok
end
```

注意：实现时如果 `Client` session 使用字符串 key，就统一改为 atom key。不要混用。

- [ ] **Step 3: 运行 backend 测试**

Run:

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/agent_backend_test.exs'
```

Expected: 新增 ACP backend 测试通过。

- [ ] **Step 4: 提交 backend 实现**

Run:

```powershell
git add elixir/lib/symphony_elixir/agent/backend/acp_stdio.ex elixir/test/symphony_elixir/agent_backend_test.exs
git commit -m "feat: 实现 acp_stdio backend"
```

Expected: 只提交 backend 和测试。

---

### Task 6: AgentRunner 集成验证

**Files:**
- Modify: `elixir/test/symphony_elixir/core_test.exs`
- Modify: `elixir/test/symphony_elixir/agent_backend_test.exs`

- [ ] **Step 1: 写集成测试：session backend 被 AgentRunner 使用**

在现有 `AgentRunner` 相关测试附近增加一条测试。使用 fake ACP executable，并配置 `routing.default_agent: "mimocode"`。

测试形态：

```elixir
test "AgentRunner runs acp_stdio agents as session backends" do
  test_root = Path.join(System.tmp_dir!(), "symphony-acp-runner-#{System.unique_integer([:positive])}")

  try do
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-911-acp-runner")
    File.mkdir_p!(workspace)
    {executable, env} = write_fake_acp_server!(test_root, %{"sessionId" => "fake-acp-session"})

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      agents: %{
        mimocode: %{
          kind: "acp_stdio",
          command: executable,
          args: [],
          permission_policy: "reject",
          timeout_ms: 5_000,
          env: env
        }
      },
      routing: %{default_agent: "mimocode"}
    )

    issue = %Issue{id: "issue-acp-runner", identifier: "MT-911", title: "ACP runner", state: "Done"}
    assert :ok = AgentRunner.run(issue, nil, agent_id: "mimocode", max_turns: 1)
  after
    File.rm_rf(test_root)
  end
end
```

- [ ] **Step 2: 运行相关测试**

Run:

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/agent_backend_test.exs test/symphony_elixir/core_test.exs'
```

Expected: 两个测试文件通过。

- [ ] **Step 3: 提交 AgentRunner 集成测试**

Run:

```powershell
git add elixir/test/symphony_elixir/agent_backend_test.exs elixir/test/symphony_elixir/core_test.exs
git commit -m "test: 验证 AgentRunner 使用 acp_stdio session backend"
```

Expected: 只提交测试文件。

---

### Task 7: 文档和真实 MiMo smoke

**Files:**
- Modify: `elixir/docs/multi_agent_backends.md`
- Modify: `elixir/docs/mimocode_acp_smoke_test.md`

- [ ] **Step 1: 更新 backend 文档**

Modify `elixir/docs/multi_agent_backends.md`，新增 `acp_stdio` 说明：

```markdown
## `acp_stdio`

`acp_stdio` 用于通过 ACP stdio 协议接入 MiMo-Code。它是 session backend，会在一次 worker attempt 内保持同一个 ACP session，并将 Symphony continuation turn 映射为同一 session 内的后续 `session/prompt`。

示例：

```yaml
agents:
  mimocode:
    kind: acp_stdio
    command: "mimo"
    args:
      - "acp"
      - "--cwd"
      - "{{workspace}}"
    permission_policy: reject
    timeout_ms: 3600000

routing:
  by_label:
    "agent:mimo": mimocode
```

第一版权限策略：

- `reject`：默认值，自动拒绝 ACP permission request。
- `fail`：收到 permission request 后失败当前 turn。
- `allow`：自动允许 permission request。

真实 MiMo-Code 验证见 [`mimocode_acp_smoke_test.md`](mimocode_acp_smoke_test.md)。
```

- [ ] **Step 2: 执行真实 MiMo 最小 smoke**

Run:

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && timeout 5s mimo acp --cwd "$PWD" < /dev/null || true'
```

Expected: 命令能启动并在 stdin 关闭后退出，或输出可诊断错误。记录结果。

- [ ] **Step 3: 更新 smoke 文档结果**

Modify `elixir/docs/mimocode_acp_smoke_test.md`，追加：

```markdown
## 本机 smoke 结果

- 命令：`timeout 5s mimo acp --cwd "$PWD" < /dev/null || true`
- 结果：粘贴 Step 2 的命令输出。
- 判断：说明是否支持进入下一阶段 Linear issue smoke。
```

- [ ] **Step 4: 运行 docs/spec 检查**

Run:

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix specs.check'
```

Expected: specs check 通过。

- [ ] **Step 5: 提交文档**

Run:

```powershell
git add elixir/docs/multi_agent_backends.md elixir/docs/mimocode_acp_smoke_test.md
git commit -m "docs: 说明 acp_stdio MiMo-Code 接入"
```

Expected: 只提交文档。

---

### Task 8: 全量验证和方案复核

**Files:**
- Modify only if verification exposes a required correction.

- [ ] **Step 1: 运行目标测试集**

Run:

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/agent_backend_test.exs test/symphony_elixir/core_test.exs test/symphony_elixir/orchestrator_status_test.exs'
```

Expected: 目标测试集通过。

- [ ] **Step 2: 运行 specs check**

Run:

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix specs.check'
```

Expected: specs check 通过。

- [ ] **Step 3: 审查是否需要推翻设计**

检查：

- fake ACP server 是否证明了 Symphony 侧协议闭环。
- 真实 `mimo acp` 是否能启动。
- ACP method 是否仍是 `initialize`、`session/new`、`session/prompt`、`session/cancel`。
- permission request 是否能按策略处理，且不会无限卡住。

如果任一项不成立，更新 `docs/superpowers/specs/2026-06-14-acp-stdio-mimocode-backend-design.md`，说明事实、影响和新方案，然后停止实现等待 review。

- [ ] **Step 4: 记录最终验证结果**

Run:

```powershell
git status --short
```

Expected: 只有预期修改。未跟本任务相关的历史脏改动不纳入提交。

- [ ] **Step 5: 最终提交或说明未提交原因**

如果 Step 1 和 Step 2 通过：

```powershell
git status --short
```

Expected: 当前任务修改已全部提交，或只剩用户已有的无关脏改动。
