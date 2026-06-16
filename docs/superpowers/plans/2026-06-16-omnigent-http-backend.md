# Omnigent HTTP Backend Implementation Plan

> **面向 agent worker：** 实施本计划时必须使用 `superpowers:subagent-driven-development`（推荐）或 `superpowers:executing-plans`，并按任务逐项执行。步骤使用 checkbox（`- [ ]`）语法跟踪进度。

**目标:** 新增 `omnigent_http` session backend，让 Linear issue 可以通过 `agent:omnigent` 路由给 Omnigent 顶层 session 执行。

**架构:** Symphony 仍然以 Linear issue 和 worker attempt 为顶层任务边界；Omnigent 只作为一个平级 backend 承接 issue。Omnigent HTTP 协议细节封装在 `SymphonyElixir.Agent.Omnigent.Client` 与 `Sse` helper 内，backend module 只负责适配 `start_session/3`、`run_turn/5`、`stop_session/1` 和 backend-neutral event。

**技术栈:** Elixir、ExUnit、Req、Bandit/Plug fake server、Jason、Omnigent `/v1/sessions` HTTP API、SSE、Linear label routing。

---

## 本轮范围

包含：
- 新增 `omnigent_http` agent backend kind。
- 支持配置 `base_url`、`host.mode: external`、`host.host_id`、`host.workspace`、`agent.type: agent_id | bundle_path`、`timeout_ms`、`stream_timeout_ms`。
- 新增 Omnigent HTTP client，覆盖 create session、post message、stream、snapshot、interrupt 和 stop。
- 新增 fake Omnigent server，稳定测试 Symphony 侧行为，不依赖真实 Omnigent。
- `AgentRunner` 通过已有 session backend contract 复用同一 Omnigent session 做 continuation。
- 文档给出本地 Omnigent server / host / Linear issue smoke 步骤。

不包含：
- 自动安装、登录或启动 Omnigent。
- `host.mode: managed`。
- 自动发现多个 host 并做复杂调度。第一版只允许显式 `host.host_id`，或 fake/test 中不需要 host。
- 把 Omnigent child session 映射成 Linear 子 issue。
- 给 Omnigent 注入 Symphony `linear_graphql` 或 Linear MCP tools。
- 改造 dashboard 历史 `codex_*` 字段命名。

## 文件结构

- Modify: `elixir/lib/symphony_elixir/config.ex`
  - 将 `omnigent_http` 加入支持的 backend kind，并校验 kind-specific 配置。

- Modify: `elixir/lib/symphony_elixir/agent/backend.ex`
  - 将 `"omnigent_http"` 映射到 `SymphonyElixir.Agent.Backend.OmnigentHttp`。

- Create: `elixir/lib/symphony_elixir/agent/omnigent/sse.ex`
  - 负责把 SSE 字节流解析成 `%{event: ..., data: ...}`，支持拆包、注释行、`[DONE]`。

- Create: `elixir/lib/symphony_elixir/agent/omnigent/client.ex`
  - 负责 Omnigent HTTP 请求、SSE stream 消费、超时、错误摘要和停止动作。

- Create: `elixir/lib/symphony_elixir/agent/backend/omnigent_http.ex`
  - 实现 Symphony session backend contract，做配置解析、事件标注和 turn result 映射。

- Create: `elixir/test/support/fake_omnigent_server.exs`
  - 提供 per-test HTTP server，模拟 `/v1/sessions`、`/events`、`/stream`、`GET /v1/sessions/{id}`。

- Modify: `elixir/test/support/test_support.exs`
  - 编译测试 support 时加载 fake Omnigent server 文件；如当前 test helper 自动加载 support 文件，则只需确认不重复。

- Modify: `elixir/test/symphony_elixir/agent_backend_test.exs`
  - 覆盖 backend dispatcher 注册。

- Modify: `elixir/test/symphony_elixir/core_test.exs`
  - 覆盖 `omnigent_http` 配置解析和错误校验。

- Create: `elixir/test/symphony_elixir/omnigent_sse_test.exs`
  - 覆盖 SSE parser 的边界。

- Create: `elixir/test/symphony_elixir/omnigent_client_test.exs`
  - 覆盖 Omnigent HTTP client 协议行为。

- Create: `elixir/test/symphony_elixir/omnigent_backend_test.exs`
  - 覆盖 backend event annotation、turn completion/failure/cancel、child event。

- Create: `elixir/test/symphony_elixir/omnigent_agent_runner_test.exs`
  - 覆盖 `AgentRunner` 通过 `agent:omnigent` 路由到 `omnigent_http` 并复用 session。

- Create: `elixir/docs/omnigent_http_backend.md`
  - 写配置示例、本地启动前置条件和 smoke test 步骤。

- Modify: `elixir/docs/agent_runtime_capability_matrix.md`
  - 追加 Omnigent HTTP backend 的能力边界摘要。

## 关键协议约定

第一版使用 Omnigent external host 模型：

```json
{
  "agent_id": "ag_abc123",
  "title": "YQE-123: issue title",
  "labels": {"symphony_agent_id": "omnigent", "symphony_issue_id": "issue-id"},
  "host_type": "external",
  "host_id": "host_abc123",
  "workspace": "/absolute/workspace"
}
```

发送 prompt：

```json
{
  "type": "message",
  "data": {
    "role": "user",
    "content": [{"type": "input_text", "text": "rendered issue prompt"}]
  }
}
```

停止 session：

```json
{"type": "interrupt", "data": {}}
```

必要时再发送：

```json
{"type": "stop_session", "data": {}}
```

---

### Task 1: 配置校验与 backend 注册

**Files:**
- Modify: `elixir/lib/symphony_elixir/config.ex`
- Modify: `elixir/lib/symphony_elixir/agent/backend.ex`
- Modify: `elixir/test/symphony_elixir/core_test.exs`
- Modify: `elixir/test/symphony_elixir/agent_backend_test.exs`

- [ ] **Step 1: 写失败测试，允许 `omnigent_http` 配置**

在 `elixir/test/symphony_elixir/core_test.exs` 的 agent config 测试附近加入：

```elixir
test "workflow config accepts omnigent_http agents" do
  write_workflow_file!(Workflow.workflow_file_path(),
    agents: %{
      codex: %{kind: "codex_app_server", command: "codex app-server"},
      omnigent: %{
        kind: "omnigent_http",
        command: "omnigent",
        base_url: "http://127.0.0.1:6767",
        host: %{
          mode: "external",
          host_id: "host_local",
          workspace: "{{workspace}}"
        },
        agent: %{
          type: "agent_id",
          id: "ag_polly"
        },
        timeout_ms: 3_600_000,
        stream_timeout_ms: 600_000
      }
    },
    routing: %{default_agent: "codex", by_label: %{"agent:omnigent" => "omnigent"}}
  )

  settings = Config.settings!()

  assert :ok = Config.validate!()
  assert settings.agents["omnigent"]["kind"] == "omnigent_http"
  assert settings.agents["omnigent"]["base_url"] == "http://127.0.0.1:6767"
  assert settings.agents["omnigent"]["host"] == %{
           "mode" => "external",
           "host_id" => "host_local",
           "workspace" => "{{workspace}}"
         }

  assert settings.agents["omnigent"]["agent"] == %{"type" => "agent_id", "id" => "ag_polly"}
  assert settings.routing.by_label == %{"agent:omnigent" => "omnigent"}
end
```

- [ ] **Step 2: 写失败测试，拒绝无效 Omnigent 配置**

继续在 `core_test.exs` 加入：

```elixir
test "workflow config rejects invalid omnigent_http config" do
  write_workflow_file!(Workflow.workflow_file_path(),
    agents: %{omnigent: %{kind: "omnigent_http", command: "omnigent"}},
    routing: %{default_agent: "omnigent"}
  )

  assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
  assert message =~ "agents.omnigent.base_url must be a non-empty string"

  write_workflow_file!(Workflow.workflow_file_path(),
    agents: %{
      omnigent: %{
        kind: "omnigent_http",
        command: "omnigent",
        base_url: "http://127.0.0.1:6767",
        host: %{mode: "managed"},
        agent: %{type: "agent_id", id: "ag_polly"}
      }
    },
    routing: %{default_agent: "omnigent"}
  )

  assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
  assert message =~ "agents.omnigent.host.mode must be external"

  write_workflow_file!(Workflow.workflow_file_path(),
    agents: %{
      omnigent: %{
        kind: "omnigent_http",
        command: "omnigent",
        base_url: "http://127.0.0.1:6767",
        host: %{mode: "external", workspace: "{{workspace}}"},
        agent: %{type: "bundle_path", path: ""}
      }
    },
    routing: %{default_agent: "omnigent"}
  )

  assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
  assert message =~ "agents.omnigent.agent.path must be a non-empty string"
end
```

- [ ] **Step 3: 写失败测试，注册 dispatcher**

在 `elixir/test/symphony_elixir/agent_backend_test.exs` 的 `module_for` 测试里加入：

```elixir
assert Backend.module_for("omnigent_http") == SymphonyElixir.Agent.Backend.OmnigentHttp
```

Expected: 测试失败，因为尚未支持 `omnigent_http`。

- [ ] **Step 4: 实现配置校验**

在 `elixir/lib/symphony_elixir/config.ex` 中修改：

```elixir
@supported_agent_kinds ["codex_app_server", "cli_run", "acp_stdio", "omnigent_http"]
```

在 `validate_kind_specific_agent_config/2` 附近加入：

```elixir
defp validate_kind_specific_agent_config(agent_id, %{"kind" => "omnigent_http"} = agent) do
  with :ok <- validate_required_string(agent_id, agent, "base_url"),
       :ok <- validate_optional_map(agent_id, agent, "host"),
       :ok <- validate_optional_map(agent_id, agent, "agent"),
       :ok <- validate_agent_integer(agent_id, agent, "stream_timeout_ms", greater_than: 0),
       :ok <- validate_omnigent_host(agent_id, Map.get(agent, "host", %{})) do
    validate_omnigent_agent(agent_id, Map.get(agent, "agent", %{}))
  end
end
```

同文件加入 helper：

```elixir
defp validate_required_string(agent_id, agent, field) do
  case Map.fetch(agent, field) do
    {:ok, value} when is_binary(value) ->
      if String.trim(value) == "",
        do: invalid_config("agents.#{agent_id}.#{field} must be a non-empty string"),
        else: :ok

    {:ok, value} ->
      invalid_config("agents.#{agent_id}.#{field} must be a non-empty string, got #{inspect(value)}")

    :error ->
      invalid_config("agents.#{agent_id}.#{field} must be a non-empty string")
  end
end

defp validate_omnigent_host(agent_id, host) when is_map(host) do
  mode = Map.get(host, "mode", "external")

  cond do
    mode != "external" ->
      invalid_config("agents.#{agent_id}.host.mode must be external")

    not is_nil(Map.get(host, "host_id")) and not is_binary(Map.get(host, "host_id")) ->
      invalid_config("agents.#{agent_id}.host.host_id must be a string")

    Map.has_key?(host, "workspace") and not is_binary(Map.get(host, "workspace")) ->
      invalid_config("agents.#{agent_id}.host.workspace must be a string")

    true ->
      :ok
  end
end

defp validate_omnigent_host(agent_id, host) do
  invalid_config("agents.#{agent_id}.host must be a map, got #{inspect(host)}")
end

defp validate_omnigent_agent(agent_id, %{"type" => "agent_id"} = agent) do
  case Map.get(agent, "id") do
    id when is_binary(id) and id != "" -> :ok
    _ -> invalid_config("agents.#{agent_id}.agent.id must be a non-empty string")
  end
end

defp validate_omnigent_agent(agent_id, %{"type" => "bundle_path"} = agent) do
  case Map.get(agent, "path") do
    path when is_binary(path) and path != "" -> :ok
    _ -> invalid_config("agents.#{agent_id}.agent.path must be a non-empty string")
  end
end

defp validate_omnigent_agent(agent_id, %{"type" => type}) do
  invalid_config("agents.#{agent_id}.agent.type must be one of agent_id, bundle_path, got #{inspect(type)}")
end

defp validate_omnigent_agent(agent_id, agent) when is_map(agent) do
  invalid_config("agents.#{agent_id}.agent.type must be one of agent_id, bundle_path")
end

defp validate_omnigent_agent(agent_id, agent) do
  invalid_config("agents.#{agent_id}.agent must be a map, got #{inspect(agent)}")
end
```

- [ ] **Step 5: 注册 backend dispatcher**

在 `elixir/lib/symphony_elixir/agent/backend.ex` 加入：

```elixir
def module_for("omnigent_http"), do: SymphonyElixir.Agent.Backend.OmnigentHttp
```

先创建空 backend module 让编译通过：

```elixir
defmodule SymphonyElixir.Agent.Backend.OmnigentHttp do
  @moduledoc false
  @behaviour SymphonyElixir.Agent.Backend

  @impl true
  def run_issue(_workspace, _issue, _prompt, _resolved_agent, _opts), do: {:error, :omnigent_http_session_backend_only}
end
```

- [ ] **Step 6: 验证 Task 1**

Run:

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/core_test.exs test/symphony_elixir/agent_backend_test.exs'
```

Expected: 新增 `omnigent_http` 配置和 dispatcher 测试通过。

- [ ] **Step 7: Commit**

```bash
git add elixir/lib/symphony_elixir/config.ex elixir/lib/symphony_elixir/agent/backend.ex elixir/lib/symphony_elixir/agent/backend/omnigent_http.ex elixir/test/symphony_elixir/core_test.exs elixir/test/symphony_elixir/agent_backend_test.exs
git commit -m "feat(agent): register omnigent http backend"
```

---

### Task 2: SSE parser 和 fake Omnigent server

**Files:**
- Create: `elixir/lib/symphony_elixir/agent/omnigent/sse.ex`
- Create: `elixir/test/support/fake_omnigent_server.exs`
- Create: `elixir/test/symphony_elixir/omnigent_sse_test.exs`

- [ ] **Step 1: 写 SSE parser 失败测试**

创建 `elixir/test/symphony_elixir/omnigent_sse_test.exs`：

```elixir
defmodule SymphonyElixir.OmnigentSseTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.Omnigent.Sse

  test "parses named SSE events and keeps incomplete frames buffered" do
    state = Sse.new()

    assert {[], state} = Sse.feed(state, "event: response.output_text.delta\n")

    assert {events, state} =
             Sse.feed(state, "data: {\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}\n\n")

    assert [%{event: "response.output_text.delta", data: %{"type" => "response.output_text.delta", "delta" => "hi"}}] =
             events

    assert state.buffer == ""
  end

  test "parses data-only events, comments, and done marker" do
    {events, _state} =
      Sse.new()
      |> Sse.feed(": heartbeat\n\ndata: {\"type\":\"session.status\",\"status\":\"running\"}\n\ndata: [DONE]\n\n")

    assert [
             %{event: nil, data: %{"type" => "session.status", "status" => "running"}},
             %{event: nil, data: "[DONE]"}
           ] = events
  end

  test "marks malformed json without crashing" do
    {events, _state} = Sse.feed(Sse.new(), "event: response.error\ndata: {not-json}\n\n")

    assert [%{event: "response.error", data: %{"raw" => "{not-json}", "malformed" => true}}] = events
  end
end
```

- [ ] **Step 2: 实现 SSE parser**

创建 `elixir/lib/symphony_elixir/agent/omnigent/sse.ex`：

```elixir
defmodule SymphonyElixir.Agent.Omnigent.Sse do
  @moduledoc """
  解析 Omnigent session SSE stream。
  """

  defstruct buffer: ""

  @type t :: %__MODULE__{buffer: String.t()}
  @type event :: %{event: String.t() | nil, data: map() | String.t()}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec feed(t(), binary()) :: {[event()], t()}
  def feed(%__MODULE__{buffer: buffer} = state, chunk) when is_binary(chunk) do
    combined = buffer <> chunk
    parts = String.split(combined, "\n\n")
    {frames, rest} = Enum.split(parts, max(length(parts) - 1, 0))
    events = frames |> Enum.flat_map(&parse_frame/1)
    {events, %{state | buffer: List.first(rest) || ""}}
  end

  defp parse_frame(frame) do
    lines =
      frame
      |> String.split("\n")
      |> Enum.map(&String.trim_trailing(&1, "\r"))
      |> Enum.reject(&String.starts_with?(&1, ":"))

    event =
      Enum.find_value(lines, fn
        "event: " <> value -> value
        _ -> nil
      end)

    data =
      lines
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map(fn "data:" <> value -> String.trim_leading(value) end)
      |> Enum.join("\n")

    if data == "" do
      []
    else
      [%{event: event, data: decode_data(data)}]
    end
  end

  defp decode_data("[DONE]"), do: "[DONE]"

  defp decode_data(data) do
    case Jason.decode(data) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> %{"raw" => data, "malformed" => true}
    end
  end
end
```

- [ ] **Step 3: 创建 fake Omnigent server**

创建 `elixir/test/support/fake_omnigent_server.exs`。使用 `Bandit` 启动一个 per-test HTTP server，进程内保存收到的 requests：

```elixir
defmodule SymphonyElixir.FakeOmnigentServer do
  @moduledoc false

  import Plug.Conn
  use Plug.Router

  plug(:match)
  plug(Plug.Parsers, parsers: [:json, :multipart], json_decoder: Jason)
  plug(:dispatch)

  def start!(behavior \\ %{}) do
    owner = self()
    table = :ets.new(:fake_omnigent_requests, [:public, :bag])
    ref = make_ref()

    plug_opts = %{owner: owner, behavior: behavior, table: table, ref: ref}
    {:ok, pid} = Bandit.start_link(plug: {__MODULE__, plug_opts}, port: 0)
    port = pid |> Bandit.Pipeline.runner_info() |> Keyword.fetch!(:port)

    %{pid: pid, port: port, base_url: "http://127.0.0.1:#{port}", table: table, ref: ref}
  end

  def stop!(%{pid: pid, table: table}) do
    if Process.alive?(pid), do: GenServer.stop(pid)
    :ets.delete(table)
    :ok
  end

  def requests(%{table: table}) do
    :ets.tab2list(table)
    |> Enum.map(fn {_ref, request} -> request end)
  end

  post "/v1/sessions" do
    opts = conn.private.plug_session_fetch
    behavior = opts.behavior
    record(opts, conn, "create_session", conn.body_params)

    status = Map.get(behavior, :create_status, 201)
    body = Map.get(behavior, :create_body, %{"id" => "conv_fake_1", "session_id" => "conv_fake_1"})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  get "/v1/sessions/:session_id" do
    opts = conn.private.plug_session_fetch
    behavior = opts.behavior
    record(opts, conn, "get_session", %{"session_id" => session_id})

    body =
      Map.get(behavior, :snapshot_body, %{
        "id" => session_id,
        "status" => "idle",
        "items" => [],
        "runner_id" => "runner_fake",
        "host_id" => "host_fake",
        "runner_online" => true,
        "host_online" => true
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(body))
  end

  post "/v1/sessions/:session_id/events" do
    opts = conn.private.plug_session_fetch
    record(opts, conn, "post_event", %{"session_id" => session_id, "body" => conn.body_params})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(202, Jason.encode!(%{"queued" => conn.body_params["type"] == "message"}))
  end

  get "/v1/sessions/:session_id/stream" do
    opts = conn.private.plug_session_fetch
    behavior = opts.behavior
    record(opts, conn, "stream", %{"session_id" => session_id})

    events =
      Map.get(behavior, :stream_events, [
        {"session.status", %{"type" => "session.status", "status" => "running"}},
        {"response.output_text.delta", %{"type" => "response.output_text.delta", "delta" => "hello"}},
        {"response.completed", %{"type" => "response.completed", "response" => %{"id" => "resp_fake"}}},
        {nil, "[DONE]"}
      ])

    body =
      Enum.map_join(events, "", fn
        {nil, data} -> "data: #{encode_sse_data(data)}\n\n"
        {event, data} -> "event: #{event}\ndata: #{encode_sse_data(data)}\n\n"
      end)

    conn
    |> put_resp_content_type("text/event-stream")
    |> send_resp(200, body)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp record(opts, conn, name, body) do
    :ets.insert(opts.table, {opts.ref, %{name: name, method: conn.method, path: conn.request_path, body: body}})
  end

  defp encode_sse_data(data) when is_binary(data), do: data
  defp encode_sse_data(data), do: Jason.encode!(data)
end
```

如果 `Bandit.Pipeline.runner_info/1` 在当前 Bandit 版本不可用，改用 `Bandit.start_link(plug: ..., port: port)` 与可用随机端口 helper。实施时先用 `iex -S mix` 或小测试确认取端口 API，再提交。

- [ ] **Step 4: 验证 Task 2**

Run:

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/omnigent_sse_test.exs'
```

Expected: SSE parser 测试通过。

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/agent/omnigent/sse.ex elixir/test/support/fake_omnigent_server.exs elixir/test/symphony_elixir/omnigent_sse_test.exs
git commit -m "feat(agent): add omnigent sse parser"
```

---

### Task 3: Omnigent HTTP client

**Files:**
- Create: `elixir/lib/symphony_elixir/agent/omnigent/client.ex`
- Create: `elixir/test/symphony_elixir/omnigent_client_test.exs`
- Modify: `elixir/test/support/fake_omnigent_server.exs`

- [ ] **Step 1: 写 create session 测试**

创建 `elixir/test/symphony_elixir/omnigent_client_test.exs`：

```elixir
defmodule SymphonyElixir.OmnigentClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.Omnigent.Client

  test "creates an existing-agent session with external host and workspace" do
    server = SymphonyElixir.FakeOmnigentServer.start!()

    try do
      assert {:ok, session} =
               Client.create_session(%{
                 base_url: server.base_url,
                 agent: %{"type" => "agent_id", "id" => "ag_polly"},
                 host: %{"mode" => "external", "host_id" => "host_local", "workspace" => "/tmp/work"},
                 title: "YQE-1: test",
                 labels: %{"symphony_issue_id" => "issue-1"},
                 timeout_ms: 5_000
               })

      assert session.session_id == "conv_fake_1"
      assert session.base_url == server.base_url

      assert Enum.any?(SymphonyElixir.FakeOmnigentServer.requests(server), fn request ->
               request.name == "create_session" and
                 request.body["agent_id"] == "ag_polly" and
                 request.body["host_type"] == "external" and
                 request.body["host_id"] == "host_local" and
                 request.body["workspace"] == "/tmp/work"
             end)
    after
      SymphonyElixir.FakeOmnigentServer.stop!(server)
    end
  end
end
```

- [ ] **Step 2: 写 post message + stream completion 测试**

在同一文件加入：

```elixir
test "posts a user message and consumes stream until completion" do
  server =
    SymphonyElixir.FakeOmnigentServer.start!(%{
      stream_events: [
        {"session.status", %{"type" => "session.status", "status" => "running"}},
        {"response.output_text.delta", %{"type" => "response.output_text.delta", "delta" => "done"}},
        {"response.completed", %{"type" => "response.completed", "response" => %{"id" => "resp_1"}}},
        {nil, "[DONE]"}
      ]
    })

  try do
    session = %{base_url: server.base_url, session_id: "conv_fake_1", stream_timeout_ms: 1_000}
    parent = self()

    assert {:ok, result} =
             Client.run_turn(session, "hello omnigent",
               timeout_ms: 5_000,
               on_event: fn event -> send(parent, {:omnigent_event, event}) end
             )

    assert result.session_id == "conv_fake_1"
    assert result.output_text == "done"
    assert result.raw["type"] == "response.completed"

    assert_receive {:omnigent_event, %{type: "session.status", status: "running"}}
    assert_receive {:omnigent_event, %{type: "response.output_text.delta", delta: "done"}}
    assert_receive {:omnigent_event, %{type: "response.completed"}}

    assert Enum.any?(SymphonyElixir.FakeOmnigentServer.requests(server), fn request ->
             request.name == "post_event" and
               request.body["body"]["type"] == "message" and
               get_in(request.body, ["body", "data", "content"]) == [%{"type" => "input_text", "text" => "hello omnigent"}]
           end)
  after
    SymphonyElixir.FakeOmnigentServer.stop!(server)
  end
end
```

- [ ] **Step 3: 写 failure、incomplete 和 stop 测试**

加入：

```elixir
test "maps failed and incomplete stream events" do
  failed_server =
    SymphonyElixir.FakeOmnigentServer.start!(%{
      stream_events: [
        {"response.failed", %{"type" => "response.failed", "error" => %{"message" => "boom"}}}
      ]
    })

  try do
    assert {:error, {:omnigent_failed, %{"message" => "boom"}}} =
             Client.run_turn(%{base_url: failed_server.base_url, session_id: "conv_failed"}, "prompt",
               timeout_ms: 5_000,
               on_event: fn _event -> :ok end
             )
  after
    SymphonyElixir.FakeOmnigentServer.stop!(failed_server)
  end

  incomplete_server =
    SymphonyElixir.FakeOmnigentServer.start!(%{
      stream_events: [
        {"response.incomplete", %{"type" => "response.incomplete", "reason" => "user_interrupt"}}
      ]
    })

  try do
    assert {:error, {:omnigent_incomplete, "user_interrupt"}} =
             Client.run_turn(%{base_url: incomplete_server.base_url, session_id: "conv_incomplete"}, "prompt",
               timeout_ms: 5_000,
               on_event: fn _event -> :ok end
             )
  after
    SymphonyElixir.FakeOmnigentServer.stop!(incomplete_server)
  end
end

test "sends interrupt and stop_session events" do
  server = SymphonyElixir.FakeOmnigentServer.start!()

  try do
    session = %{base_url: server.base_url, session_id: "conv_fake_1"}

    assert :ok = Client.interrupt(session)
    assert :ok = Client.stop_session(session)

    requests = SymphonyElixir.FakeOmnigentServer.requests(server)

    assert Enum.any?(requests, fn request ->
             request.name == "post_event" and request.body["body"] == %{"type" => "interrupt", "data" => %{}}
           end)

    assert Enum.any?(requests, fn request ->
             request.name == "post_event" and request.body["body"] == %{"type" => "stop_session", "data" => %{}}
           end)
  after
    SymphonyElixir.FakeOmnigentServer.stop!(server)
  end
end
```

- [ ] **Step 4: 实现 client JSON 请求**

创建 `elixir/lib/symphony_elixir/agent/omnigent/client.ex`，先实现非 streaming 部分：

```elixir
defmodule SymphonyElixir.Agent.Omnigent.Client do
  @moduledoc """
  Omnigent HTTP session API client。
  """

  alias SymphonyElixir.Agent.Omnigent.Sse

  @spec create_session(map()) :: {:ok, map()} | {:error, term()}
  def create_session(config) when is_map(config) do
    base_url = required!(config, :base_url)
    agent = required!(config, :agent)
    host = Map.get(config, :host, %{})

    body =
      agent
      |> create_session_agent_payload()
      |> Map.merge(%{
        "title" => Map.get(config, :title),
        "labels" => Map.get(config, :labels, %{}),
        "host_type" => "external"
      })
      |> maybe_put("host_id", Map.get(host, "host_id"))
      |> maybe_put("workspace", Map.get(host, "workspace"))

    case Req.post(url: url(base_url, "/v1/sessions"), json: body, receive_timeout: Map.get(config, :timeout_ms, 5_000), retry: false) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        session_id = Map.get(body, "session_id") || Map.get(body, "id")
        {:ok, %{session_id: session_id, base_url: base_url, raw: body}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:omnigent_http_error, status, body}}

      {:error, reason} ->
        {:error, {:omnigent_transport_error, reason}}
    end
  end

  @spec interrupt(map()) :: :ok | {:error, term()}
  def interrupt(session), do: post_control_event(session, "interrupt")

  @spec stop_session(map()) :: :ok | {:error, term()}
  def stop_session(session), do: post_control_event(session, "stop_session")

  defp post_control_event(session, type) do
    body = %{"type" => type, "data" => %{}}

    case Req.post(url: session_event_url(session), json: body, receive_timeout: 5_000, retry: false) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:omnigent_http_error, status, body}}
      {:error, reason} -> {:error, {:omnigent_transport_error, reason}}
    end
  end

  defp create_session_agent_payload(%{"type" => "agent_id", "id" => agent_id}) do
    %{"agent_id" => agent_id, "initial_items" => []}
  end

  defp create_session_agent_payload(%{"type" => "bundle_path", "path" => path}) do
    raise ArgumentError, "bundle_path upload is implemented in Task 6, got #{inspect(path)}"
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp required!(map, key), do: Map.fetch!(map, key)
  defp url(base_url, path), do: String.trim_trailing(base_url, "/") <> path
  defp session_event_url(session), do: url(session.base_url, "/v1/sessions/#{session.session_id}/events")
end
```

- [ ] **Step 5: 实现 `run_turn/3` stream 消费**

在 `Client` 中加入：

```elixir
@spec run_turn(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
def run_turn(session, prompt, opts \\ []) do
  on_event = Keyword.get(opts, :on_event, fn _event -> :ok end)
  timeout_ms = Keyword.get(opts, :timeout_ms, 3_600_000)

  with {:ok, async} <- open_stream(session, timeout_ms),
       :ok <- post_message(session, prompt, timeout_ms) do
    consume_stream(async, Sse.new(), %{output_text: "", session_id: session.session_id}, on_event)
  end
end

defp open_stream(session, timeout_ms) do
  case Req.get(url: url(session.base_url, "/v1/sessions/#{session.session_id}/stream"), into: :self, receive_timeout: timeout_ms, retry: false) do
    {:ok, %{status: status, body: async}} when status in 200..299 -> {:ok, async}
    {:ok, %{status: status, body: body}} -> {:error, {:omnigent_http_error, status, body}}
    {:error, reason} -> {:error, {:omnigent_transport_error, reason}}
  end
end

defp post_message(session, prompt, timeout_ms) do
  body = %{
    "type" => "message",
    "data" => %{"role" => "user", "content" => [%{"type" => "input_text", "text" => prompt}]}
  }

  case Req.post(url: session_event_url(session), json: body, receive_timeout: timeout_ms, retry: false) do
    {:ok, %{status: status}} when status in 200..299 -> :ok
    {:ok, %{status: status, body: body}} -> {:error, {:omnigent_http_error, status, body}}
    {:error, reason} -> {:error, {:omnigent_transport_error, reason}}
  end
end

defp consume_stream(async, sse, acc, on_event) do
  Enum.reduce_while(async, {sse, acc}, fn chunk, {sse_state, current} ->
    {events, next_sse} = Sse.feed(sse_state, chunk)

    case handle_events(events, current, on_event) do
      {:cont, next_acc} -> {:cont, {next_sse, next_acc}}
      {:halt, result} -> {:halt, result}
    end
  end)
  |> case do
    {:ok, result} -> {:ok, result}
    {:error, reason} -> {:error, reason}
    {_sse, result} -> {:ok, result}
  end
end

defp handle_events(events, acc, on_event) do
  Enum.reduce_while(events, {:cont, acc}, fn %{data: data}, {:cont, current} ->
    case normalize_event(data) do
      "[DONE]" ->
        {:halt, {:ok, current}}

      %{"type" => "response.output_text.delta", "delta" => delta} = event ->
        on_event.(event)
        {:cont, {:cont, %{current | output_text: current.output_text <> delta}}}

      %{"type" => "response.completed"} = event ->
        on_event.(event)
        {:halt, {:ok, Map.put(current, :raw, event)}}

      %{"type" => "response.failed", "error" => error} = event ->
        on_event.(event)
        {:halt, {:error, {:omnigent_failed, error}}}

      %{"type" => "response.incomplete", "reason" => reason} = event ->
        on_event.(event)
        {:halt, {:error, {:omnigent_incomplete, reason}}}

      event when is_map(event) ->
        on_event.(event)
        {:cont, {:cont, current}}
    end
  end)
end

defp normalize_event("[DONE]"), do: "[DONE]"
defp normalize_event(%{"type" => _type} = event), do: event
defp normalize_event(%{event: event, data: data}) when is_map(data), do: Map.put_new(data, "type", event)
defp normalize_event(data), do: data
```

如果 `Req.Response.Async` 的 enumerable chunk 形态不是 binary，实施时以 `Req.Response.Async` 文档为准调整 `consume_stream/4`，并保留 `omnigent_client_test.exs` 作为门禁。

- [ ] **Step 6: 验证 Task 3**

Run:

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/omnigent_client_test.exs'
```

Expected: client create、message、stream、failure、incomplete、stop 测试通过。

- [ ] **Step 7: Commit**

```bash
git add elixir/lib/symphony_elixir/agent/omnigent/client.ex elixir/test/symphony_elixir/omnigent_client_test.exs elixir/test/support/fake_omnigent_server.exs
git commit -m "feat(agent): add omnigent http client"
```

---

### Task 4: `OmnigentHttp` session backend

**Files:**
- Modify: `elixir/lib/symphony_elixir/agent/backend/omnigent_http.ex`
- Create: `elixir/test/symphony_elixir/omnigent_backend_test.exs`

- [ ] **Step 1: 写 start/run/stop backend 测试**

创建 `elixir/test/symphony_elixir/omnigent_backend_test.exs`：

```elixir
defmodule SymphonyElixir.OmnigentBackendTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.Backend.OmnigentHttp

  test "starts session, annotates events, and runs a prompt" do
    server = SymphonyElixir.FakeOmnigentServer.start!()

    try do
      workspace = Path.join(System.tmp_dir!(), "symphony-omnigent-workspace")
      File.mkdir_p!(workspace)

      resolved_agent = %{
        id: "omnigent",
        kind: "omnigent_http",
        config: %{
          "kind" => "omnigent_http",
          "base_url" => server.base_url,
          "host" => %{"mode" => "external", "host_id" => "host_local", "workspace" => "{{workspace}}"},
          "agent" => %{"type" => "agent_id", "id" => "ag_polly"},
          "timeout_ms" => 5_000,
          "stream_timeout_ms" => 1_000
        }
      }

      parent = self()

      assert {:ok, session} =
               OmnigentHttp.start_session(workspace, resolved_agent,
                 on_message: fn message -> send(parent, {:omnigent_backend_message, message}) end
               )

      assert {:ok, result} =
               OmnigentHttp.run_turn(
                 session,
                 workspace,
                 %Issue{id: "issue-omnigent-backend", identifier: "YQE-OMNI"},
                 "perform omnigent task",
                 on_message: fn message -> send(parent, {:omnigent_backend_message, message}) end
               )

      assert result.session_id == "conv_fake_1"
      assert result.output_text == "hello"

      assert_receive {:omnigent_backend_message,
                      %{event: :session_started, agent_id: "omnigent", agent_kind: "omnigent_http", session_id: "conv_fake_1"}}

      assert_receive {:omnigent_backend_message,
                      %{event: :turn_started, agent_id: "omnigent", agent_kind: "omnigent_http", session_id: "conv_fake_1"}}

      assert_receive {:omnigent_backend_message,
                      %{event: :turn_completed, agent_id: "omnigent", agent_kind: "omnigent_http", session_id: "conv_fake_1"}}

      assert :ok = OmnigentHttp.stop_session(session)
    after
      SymphonyElixir.FakeOmnigentServer.stop!(server)
      File.rm_rf(Path.join(System.tmp_dir!(), "symphony-omnigent-workspace"))
    end
  end
end
```

- [ ] **Step 2: 写 failure、incomplete、child event 映射测试**

加入：

```elixir
test "maps failure, incomplete, and child session events" do
  server =
    SymphonyElixir.FakeOmnigentServer.start!(%{
      stream_events: [
        {"session.created", %{"type" => "session.created", "child_conversation_id" => "conv_child", "agent_id" => "ag_child"}},
        {"response.failed", %{"type" => "response.failed", "error" => %{"message" => "boom"}}}
      ]
    })

  try do
    workspace = Path.join(System.tmp_dir!(), "symphony-omnigent-failure-workspace")
    File.mkdir_p!(workspace)
    parent = self()
    resolved_agent = omnigent_agent(server.base_url)

    assert {:ok, session} =
             OmnigentHttp.start_session(workspace, resolved_agent,
               on_message: fn message -> send(parent, {:omnigent_backend_message, message}) end
             )

    assert {:error, {:omnigent_failed, %{"message" => "boom"}}} =
             OmnigentHttp.run_turn(session, workspace, %Issue{id: "issue-fail"}, "prompt",
               on_message: fn message -> send(parent, {:omnigent_backend_message, message}) end
             )

    assert_receive {:omnigent_backend_message,
                    %{event: :child_session_observed, payload: %{"child_conversation_id" => "conv_child"}}}

    assert_receive {:omnigent_backend_message, %{event: :turn_failed, payload: %{reason: {:omnigent_failed, %{"message" => "boom"}}}}}
  after
    SymphonyElixir.FakeOmnigentServer.stop!(server)
  end
end

defp omnigent_agent(base_url) do
  %{
    id: "omnigent",
    kind: "omnigent_http",
    config: %{
      "base_url" => base_url,
      "host" => %{"mode" => "external", "host_id" => "host_local", "workspace" => "{{workspace}}"},
      "agent" => %{"type" => "agent_id", "id" => "ag_polly"},
      "timeout_ms" => 5_000,
      "stream_timeout_ms" => 1_000
    }
  }
end
```

- [ ] **Step 3: 实现 backend module**

替换 `elixir/lib/symphony_elixir/agent/backend/omnigent_http.ex`：

```elixir
defmodule SymphonyElixir.Agent.Backend.OmnigentHttp do
  @moduledoc """
  通过 Omnigent HTTP session API 运行顶层 Omnigent agent。
  """

  @behaviour SymphonyElixir.Agent.Backend

  alias SymphonyElixir.Agent.Omnigent.Client

  @default_timeout_ms 3_600_000
  @default_stream_timeout_ms 600_000

  @impl true
  def run_issue(_workspace, _issue, _prompt, _resolved_agent, _opts) do
    {:error, :omnigent_http_session_backend_only}
  end

  @spec start_session(Path.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_session(workspace, resolved_agent, opts) do
    config = agent_config(resolved_agent)
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    client_config = %{
      base_url: Map.fetch!(config, "base_url"),
      agent: Map.fetch!(config, "agent"),
      host: resolve_host_config(Map.get(config, "host", %{}), workspace),
      title: "Symphony issue session",
      labels: %{"symphony_agent_id" => agent_id(resolved_agent), "symphony_agent_kind" => agent_kind(resolved_agent)},
      timeout_ms: Map.get(config, "read_timeout_ms", 5_000)
    }

    case Client.create_session(client_config) do
      {:ok, session} ->
        session =
          session
          |> Map.put(:resolved_agent, resolved_agent)
          |> Map.put(:timeout_ms, Map.get(config, "timeout_ms", @default_timeout_ms))
          |> Map.put(:stream_timeout_ms, Map.get(config, "stream_timeout_ms", @default_stream_timeout_ms))

        annotated_on_message(on_message, resolved_agent).(%{
          event: :session_started,
          session_id: session.session_id,
          payload: session.raw
        })

        {:ok, session}

      other ->
        other
    end
  end

  @spec run_turn(map(), Path.t(), map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, _workspace, _issue, prompt, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, Map.get(session, :timeout_ms, @default_timeout_ms))
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    emit = annotated_on_message(on_message, session.resolved_agent)

    emit.(%{event: :turn_started, session_id: session.session_id, payload: %{}})

    client_session = Map.take(session, [:base_url, :session_id, :stream_timeout_ms])

    case Client.run_turn(client_session, prompt, timeout_ms: timeout_ms, on_event: &emit_omnigent_event(emit, session, &1)) do
      {:ok, result} ->
        emit.(%{event: :turn_completed, session_id: session.session_id, payload: result.raw})
        {:ok, result}

      {:error, {:omnigent_incomplete, "user_interrupt"} = reason} ->
        emit.(%{event: :turn_cancelled, session_id: session.session_id, payload: %{reason: reason}})
        {:error, reason}

      {:error, reason} ->
        emit.(%{event: :turn_failed, session_id: session.session_id, payload: %{reason: reason}})
        {:error, reason}
    end
  end

  @spec stop_session(map()) :: :ok
  def stop_session(session) when is_map(session) do
    _ = Client.interrupt(session)
    _ = Client.stop_session(session)
    :ok
  end

  defp resolve_host_config(host, workspace) do
    host
    |> Map.put("mode", Map.get(host, "mode", "external"))
    |> Map.update("workspace", workspace, &String.replace(&1, "{{workspace}}", workspace))
  end

  defp emit_omnigent_event(emit, session, %{"type" => "response.output_text.delta"} = payload) do
    emit.(%{event: :notification, session_id: session.session_id, payload: payload})
  end

  defp emit_omnigent_event(emit, session, %{"type" => "session.created"} = payload) do
    emit.(%{event: :child_session_observed, session_id: session.session_id, payload: payload})
  end

  defp emit_omnigent_event(emit, session, payload) when is_map(payload) do
    emit.(%{event: :notification, session_id: session.session_id, payload: payload})
  end

  defp annotated_on_message(on_message, resolved_agent) when is_function(on_message, 1) do
    fn message ->
      message
      |> Map.put(:agent_id, agent_id(resolved_agent))
      |> Map.put(:agent_kind, agent_kind(resolved_agent))
      |> Map.put_new(:timestamp, DateTime.utc_now())
      |> on_message.()
    end
  end

  defp agent_id(resolved_agent), do: Map.get(resolved_agent, :id) || Map.get(resolved_agent, "id")
  defp agent_kind(resolved_agent), do: Map.get(resolved_agent, :kind) || Map.get(resolved_agent, "kind")
  defp agent_config(resolved_agent), do: Map.get(resolved_agent, :config) || Map.get(resolved_agent, "config") || %{}
  defp default_on_message(_message), do: :ok
end
```

- [ ] **Step 4: 验证 Task 4**

Run:

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/omnigent_backend_test.exs'
```

Expected: backend 测试通过。

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/agent/backend/omnigent_http.ex elixir/test/symphony_elixir/omnigent_backend_test.exs
git commit -m "feat(agent): add omnigent http session backend"
```

---

### Task 5: AgentRunner 路由与 continuation 集成

**Files:**
- Create: `elixir/test/symphony_elixir/omnigent_agent_runner_test.exs`
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`

- [ ] **Step 1: 写路由执行测试**

创建 `elixir/test/symphony_elixir/omnigent_agent_runner_test.exs`：

```elixir
defmodule SymphonyElixir.OmnigentAgentRunnerTest do
  use SymphonyElixir.TestSupport

  test "AgentRunner routes agent:omnigent labeled issues to omnigent_http backend" do
    server = SymphonyElixir.FakeOmnigentServer.start!()
    test_root = Path.join(System.tmp_dir!(), "symphony-omnigent-runner-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create: "printf ready > READY.txt",
        agents: %{
          codex: %{kind: "codex_app_server", command: "codex app-server"},
          omnigent: %{
            kind: "omnigent_http",
            command: "omnigent",
            base_url: server.base_url,
            host: %{mode: "external", host_id: "host_local", workspace: "{{workspace}}"},
            agent: %{type: "agent_id", id: "ag_polly"},
            timeout_ms: 5_000,
            stream_timeout_ms: 1_000
          }
        },
        routing: %{default_agent: "codex", by_label: %{"agent:omnigent" => "omnigent"}}
      )

      issue = %Issue{
        id: "issue-omnigent-runner",
        identifier: "YQE-OMNI",
        title: "Run Omnigent",
        description: "Route this issue to Omnigent",
        state: "Done",
        labels: ["agent:omnigent"]
      }

      assert :ok = AgentRunner.run(issue, self(), issue_state_fetcher: fn [_id] -> {:ok, [%{issue | state: "Done"}]} end)

      assert Enum.any?(SymphonyElixir.FakeOmnigentServer.requests(server), fn request ->
               request.name == "post_event" and get_in(request.body, ["body", "type"]) == "message"
             end)
    after
      SymphonyElixir.FakeOmnigentServer.stop!(server)
      File.rm_rf(test_root)
    end
  end
end
```

- [ ] **Step 2: 写 continuation 复用 session 测试**

加入：

```elixir
test "AgentRunner reuses one Omnigent session across continuation turns" do
  server = SymphonyElixir.FakeOmnigentServer.start!()
  test_root = Path.join(System.tmp_dir!(), "symphony-omnigent-continuation-#{System.unique_integer([:positive])}")

  try do
    workspace_root = Path.join(test_root, "workspaces")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      agents: %{
        omnigent: %{
          kind: "omnigent_http",
          command: "omnigent",
          base_url: server.base_url,
          host: %{mode: "external", host_id: "host_local", workspace: "{{workspace}}"},
          agent: %{type: "agent_id", id: "ag_polly"},
          timeout_ms: 5_000,
          stream_timeout_ms: 1_000
        }
      },
      routing: %{default_agent: "omnigent"},
      max_turns: 2
    )

    parent = self()

    state_fetcher = fn [_issue_id] ->
      count = Process.get(:omnigent_fetch_count, 0) + 1
      Process.put(:omnigent_fetch_count, count)
      send(parent, {:omnigent_issue_fetch, count})

      state = if count == 1, do: "In Progress", else: "Done"
      {:ok, [%Issue{id: "issue-omnigent-cont", identifier: "YQE-OMNI-CONT", state: state, labels: []}]}
    end

    issue = %Issue{id: "issue-omnigent-cont", identifier: "YQE-OMNI-CONT", title: "Continue", state: "In Progress"}

    assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
    assert_receive {:omnigent_issue_fetch, 1}
    assert_receive {:omnigent_issue_fetch, 2}

    requests = SymphonyElixir.FakeOmnigentServer.requests(server)
    assert Enum.count(requests, &(&1.name == "create_session")) == 1
    assert Enum.count(requests, &(&1.name == "post_event" and get_in(&1.body, ["body", "type"]) == "message")) == 2
  after
    SymphonyElixir.FakeOmnigentServer.stop!(server)
    File.rm_rf(test_root)
  end
end
```

- [ ] **Step 3: 修改 AgentRunner guidance**

当前 `AgentRunner` 已经通过 session backend contract 识别 `start_session/3`、`run_turn/5`、`stop_session/1`。如果 Task 5 测试失败，优先检查：

```elixir
defp session_backend?(backend_module) when is_atom(backend_module) do
  Code.ensure_loaded?(backend_module) and
    function_exported?(backend_module, :start_session, 3) and
    function_exported?(backend_module, :run_turn, 5) and
    function_exported?(backend_module, :stop_session, 1)
end
```

需要改动时只做最小适配：确保 `OmnigentHttp` 暴露上述三个函数，且 continuation prompt 文案保持 backend-neutral，不出现 `Codex` 专用措辞。

- [ ] **Step 4: 验证 Task 5**

Run:

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/omnigent_agent_runner_test.exs'
```

Expected: `agent:omnigent` 路由和 continuation 复用测试通过。

- [ ] **Step 5: Commit**

```bash
git add elixir/test/symphony_elixir/omnigent_agent_runner_test.exs elixir/lib/symphony_elixir/agent_runner.ex
git commit -m "test(agent): cover omnigent runner routing"
```

---

### Task 6: `bundle_path` 上传支持

**Files:**
- Modify: `elixir/lib/symphony_elixir/agent/omnigent/client.ex`
- Modify: `elixir/test/symphony_elixir/omnigent_client_test.exs`

- [ ] **Step 1: 写 bundle upload 测试**

在 `omnigent_client_test.exs` 加入：

```elixir
test "creates a session from an uploaded bundle path" do
  server = SymphonyElixir.FakeOmnigentServer.start!()
  test_root = Path.join(System.tmp_dir!(), "symphony-omnigent-bundle-#{System.unique_integer([:positive])}")

  try do
    bundle_dir = Path.join(test_root, "agent")
    File.mkdir_p!(bundle_dir)
    File.write!(Path.join(bundle_dir, "config.yaml"), "name: symphony_test_agent\nprompt: hi\n")

    assert {:ok, session} =
             Client.create_session(%{
               base_url: server.base_url,
               agent: %{"type" => "bundle_path", "path" => bundle_dir},
               host: %{"mode" => "external", "host_id" => "host_local", "workspace" => "/tmp/work"},
               title: "bundle test",
               labels: %{},
               timeout_ms: 5_000
             })

    assert session.session_id == "conv_fake_1"

    assert Enum.any?(SymphonyElixir.FakeOmnigentServer.requests(server), fn request ->
             request.name == "create_session" and request.method == "POST"
           end)
  after
    SymphonyElixir.FakeOmnigentServer.stop!(server)
    File.rm_rf(test_root)
  end
end
```

- [ ] **Step 2: 实现 tar.gz 打包**

在 `Client` 中新增：

```elixir
defp create_session_agent_payload(%{"type" => "bundle_path", "path" => path}) do
  %{bundle_path: path}
end
```

然后在 `create_session/1` 中对 `bundle_path` 分支调用 multipart：

```elixir
case create_session_agent_payload(agent) do
  %{bundle_path: path} ->
    create_session_from_bundle(base_url, path, body, Map.get(config, :timeout_ms, 5_000))

  json_payload ->
    create_session_from_json(base_url, Map.merge(json_payload, body), Map.get(config, :timeout_ms, 5_000))
end
```

实现：

```elixir
defp create_session_from_bundle(base_url, path, metadata, timeout_ms) do
  with {:ok, archive_path} <- build_tar_gz(path) do
    fields = [
      metadata: Jason.encode!(metadata),
      bundle: File.stream!(archive_path, [], 2048)
    ]

    case Req.post(url: url(base_url, "/v1/sessions"), form_multipart: fields, receive_timeout: timeout_ms, retry: false) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> session_from_body(base_url, body)
      {:ok, %{status: status, body: body}} -> {:error, {:omnigent_http_error, status, body}}
      {:error, reason} -> {:error, {:omnigent_transport_error, reason}}
    end
  end
end

defp build_tar_gz(path) do
  archive_path = Path.join(System.tmp_dir!(), "symphony-omnigent-agent-#{System.unique_integer([:positive])}.tar.gz")

  case System.cmd("tar", ["-czf", archive_path, "-C", path, "."], stderr_to_stdout: true) do
    {_output, 0} -> {:ok, archive_path}
    {output, status} -> {:error, {:bundle_pack_failed, status, output}}
  end
end

defp session_from_body(base_url, body) do
  session_id = Map.get(body, "session_id") || Map.get(body, "id")
  {:ok, %{session_id: session_id, base_url: base_url, raw: body}}
end
```

实施时如果 Windows 本地没有 `tar`，保留 `bundle_path` 测试在 WSL 路径运行；真实开发环境当前通过 WSL 执行 Elixir 测试。

- [ ] **Step 3: 验证 Task 6**

Run:

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/omnigent_client_test.exs'
```

Expected: JSON agent 和 bundle upload 两种 create session 测试都通过。

- [ ] **Step 4: Commit**

```bash
git add elixir/lib/symphony_elixir/agent/omnigent/client.ex elixir/test/symphony_elixir/omnigent_client_test.exs
git commit -m "feat(agent): support omnigent bundle sessions"
```

---

### Task 7: 文档和本地 smoke 指南

**Files:**
- Create: `elixir/docs/omnigent_http_backend.md`
- Modify: `elixir/docs/agent_runtime_capability_matrix.md`

- [ ] **Step 1: 新增中文使用文档**

创建 `elixir/docs/omnigent_http_backend.md`：

```markdown
# Omnigent HTTP Backend

Symphony 可以把 Linear issue 路由给 Omnigent 顶层 session。Linear 中只需要看到一个 `omnigent` agent；Omnigent 内部如何派给 Codex、Claude、Cursor 或其他子 agent，第一阶段作为 Omnigent 内部细节处理。

## 前置条件

1. Omnigent 已安装并能启动本地 server。
2. 用户已手动运行 `omnigent server start`。
3. 用户已手动运行 `omnigent host`，或已经有可用 runner 绑定策略。
4. Symphony 与 Omnigent host 能看到同一个 workspace 路径。

第一阶段不会自动安装、登录或启动 Omnigent。

## WORKFLOW 示例

```yaml
agents:
  codex:
    kind: codex_app_server
    command: "codex app-server"
  omnigent:
    kind: omnigent_http
    command: "omnigent"
    base_url: "http://127.0.0.1:6767"
    host:
      mode: external
      host_id: "host_local"
      workspace: "{{workspace}}"
    agent:
      type: agent_id
      id: "ag_polly"
    timeout_ms: 3600000
    stream_timeout_ms: 600000

routing:
  default_agent: codex
  by_label:
    "agent:omnigent": omnigent
```

## 使用方式

1. 在 Linear issue 上添加 `agent:omnigent` label。
2. 保持 issue 位于 Symphony active state，例如 `Todo` 或 `In Progress`。
3. 等待 Symphony worker 派发 issue。
4. 在 dashboard 或日志中确认 `agent_id=omnigent`、`agent_kind=omnigent_http` 和 Omnigent session id。

## 成功判定

Omnigent 的 `response.completed` 只表示本轮 Omnigent turn 完成，不等于 Linear issue 已完成。Symphony 仍会刷新 Linear issue：如果 issue 还在 active state，并且仍路由到 `omnigent`，同一 worker attempt 会继续下一 turn。

## 当前限制

- 不支持 `host.mode: managed`。
- 不把 Omnigent child session 映射成 Linear 子 issue。
- 不把 Symphony Linear token 或 `linear_graphql` 直接注入 Omnigent。
- 多个 online host 的自动选择不在第一阶段处理；推荐显式配置 `host.host_id`。
```

- [ ] **Step 2: 更新能力矩阵**

在 `elixir/docs/agent_runtime_capability_matrix.md` 的 HTTP server/backend 相关段落后追加 Omnigent 摘要：

```markdown
## Omnigent HTTP backend

Omnigent 与 MiMo-Code/OpenCode 的一次性 CLI 形态不同。它已经暴露 session-first HTTP API、typed SSE stream、interrupt、stop_session、child session event 和 Agent YAML 工具/policy 配置，因此适合作为顶层平级 backend 第一阶段接入。

第一阶段能力边界：
- 满足：Linear issue 路由、per-issue workspace、长生命周期 session、continuation、结构化事件、失败/取消/超时映射、可靠停止。
- 部分满足：权限/审批语义、usage 展示、host 生命周期。
- 不在第一阶段满足：Linear tool bridge、child session 映射为 Linear 子任务、managed host 自动化。
```

- [ ] **Step 3: 验证文档**

Run:

```powershell
$placeholderPattern = ('TB' + 'D') + '|TO' + 'DO|' + ('待' + '定') + '|[?][?]'
rg -n $placeholderPattern elixir/docs/omnigent_http_backend.md elixir/docs/agent_runtime_capability_matrix.md
git diff --check
```

Expected: 无占位符；无 whitespace error。

- [ ] **Step 4: Commit**

```bash
git add elixir/docs/omnigent_http_backend.md elixir/docs/agent_runtime_capability_matrix.md
git commit -m "docs(agent): explain omnigent http backend"
```

---

### Task 8: 全量验证和真实 Omnigent smoke

**Files:**
- No code changes expected unless smoke exposes a defect.

- [ ] **Step 1: 运行目标测试集**

Run:

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/core_test.exs test/symphony_elixir/agent_backend_test.exs test/symphony_elixir/omnigent_sse_test.exs test/symphony_elixir/omnigent_client_test.exs test/symphony_elixir/omnigent_backend_test.exs test/symphony_elixir/omnigent_agent_runner_test.exs'
```

Expected: 目标测试集全部通过。

- [ ] **Step 2: 运行 specs check**

Run:

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix specs.check'
```

Expected: public function spec 检查通过。

- [ ] **Step 3: 运行全量测试**

Run:

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test'
```

Expected: 全部 ExUnit 测试通过。

- [ ] **Step 4: 真实 Omnigent server smoke**

前置：

```powershell
cd C:\Users\GQY47\coding\omnigent
omnigent server start
omnigent host
```

在 `elixir/WORKFLOW.local.md` 或当前本地 workflow 中配置：

```yaml
agents:
  omnigent:
    kind: omnigent_http
    command: "omnigent"
    base_url: "http://127.0.0.1:6767"
    host:
      mode: external
      host_id: "<真实 host id>"
      workspace: "{{workspace}}"
    agent:
      type: agent_id
      id: "<真实 agent id>"
    timeout_ms: 3600000
    stream_timeout_ms: 600000
routing:
  by_label:
    "agent:omnigent": omnigent
```

创建 Linear 测试 issue：
- label: `agent:omnigent`
- state: `In Progress`
- 描述要求 Omnigent 只做一个低风险动作，例如在 workspace 根目录创建 `omnigent-smoke.txt`，内容为固定字符串，然后评论结果。

验收记录写入 `elixir/docs/omnigent_http_backend.md` 的“真实 smoke 记录”：

```markdown
## 真实 smoke 记录

- 日期：2026-06-16
- Linear issue：
- Omnigent session id：
- host id：
- workspace：
- 结果：
- 已知缺口：
```

- [ ] **Step 5: 最终状态检查**

Run:

```powershell
git status --short
git log --oneline -5
```

Expected: 只有预期修改；提交历史包含本计划各任务 commit。

## 验收标准

- `WORKFLOW` 可以声明 `agents.omnigent.kind = omnigent_http`。
- `Backend.module_for("omnigent_http")` 返回 `SymphonyElixir.Agent.Backend.OmnigentHttp`。
- fake server 测试覆盖 session 创建、message、stream completion、failure、incomplete、interrupt、stop 和 child event。
- `AgentRunner` 能通过 `agent:omnigent` label 选择 Omnigent backend。
- 同一 worker attempt 内 continuation turn 复用同一个 Omnigent session。
- backend event 中包含 `agent_id=omnigent`、`agent_kind=omnigent_http`、`session_id=<Omnigent session id>`。
- `session.created` 被记录为 `child_session_observed`，但不会创建 Linear 子 issue。
- Omnigent `response.completed` 不被误判为 Linear issue terminal；是否继续仍由 Linear active/terminal state 决定。
- 本地 smoke 文档说明 server/host 启动、WORKFLOW 配置和 Linear 测试步骤。
