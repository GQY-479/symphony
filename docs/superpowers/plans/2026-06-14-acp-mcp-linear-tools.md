# ACP MCP Linear 工具桥接实施计划

> **面向 agent worker：** 实施本计划时必须使用 `superpowers:subagent-driven-development`（推荐）或 `superpowers:executing-plans`，并按任务逐项执行。步骤使用 checkbox（`- [ ]`）语法跟踪进度。

**目标:** 让 `acp_stdio` agent 通过 Symphony 注入的 HTTP MCP endpoint 使用 `linear_graphql`，使 MiMo-Code 能像 Codex 一样稳定完成 Linear 查询、评论和状态收尾。

**架构:** 把 `linear_graphql` 的业务逻辑从 Codex dynamic tool 中提取为 backend-neutral 工具核心。Codex app-server 继续用 `Codex.DynamicTool` 包装该核心；MiMo-Code 通过 ACP `mcpServers` 连接 Symphony 内置 HTTP MCP endpoint，再通过 MCP `tools/call` 使用同一工具核心。

**技术栈:** Elixir、ExUnit、Jason、Erlang Port、ACP v1、MCP JSON-RPC over HTTP、Linear GraphQL、MiMo-Code `mimo acp`。stdio MCP loop 仅保留为本地调试入口。

---

## 范围

本计划只做 MiMo-Code 的 MCP 工具桥接。阶段 4 的 OpenCode 复用本轮跳过，不作为本轮验收项。

本轮包含：

- 提取 backend-neutral `linear_graphql` 工具核心。
- 保持 Codex dynamic tool 外部行为兼容。
- 新增 Symphony HTTP MCP endpoint，暴露 `linear_graphql`。
- 扩展 `acp_stdio`，按配置向 `session/new.params.mcpServers` 注入 MCP server。
- 更新中文文档和 smoke 流程。
- 用真实 MiMo Linear issue 验证文件修改、Linear 查询、评论和状态收尾。

本轮不包含：

- OpenCode smoke。
- OpenCode 配置模板。
- 修改 MiMo-Code 本体。
- 把 Linear token 暴露给 agent shell。
- 通用 MCP server 管理平台。

## 文件结构

- 新增： `elixir/lib/symphony_elixir/agent/tool.ex`
  - backend-neutral 工具入口，提供 `specs/0` 和 `execute/3`。

- 新增： `elixir/lib/symphony_elixir/agent/tool/linear_graphql.ex`
  - 负责 `linear_graphql` 的参数归一化、Linear 调用、GraphQL error 判断和结构化错误。

- 修改： `elixir/lib/symphony_elixir/codex/dynamic_tool.ex`
  - 改为调用 `SymphonyElixir.Agent.Tool`，再包装成 Codex app-server dynamic tool 响应。

- 新增： `elixir/lib/symphony_elixir/agent/mcp_server.ex`
  - MCP 方法分发入口，处理 `initialize`、`tools/list`、`tools/call`。

- 新增： `elixir/lib/symphony_elixir/agent/mcp_server/stdio.ex`
  - stdio JSON-RPC loop，保留为本地调试入口；MiMo 默认使用 HTTP endpoint。

- 新增： `elixir/lib/symphony_elixir_web/controllers/mcp_controller.ex`
  - HTTP JSON-RPC endpoint，处理 MiMo-Code 通过 `mcpServers` 发来的 MCP 请求。

- 新增： `elixir/lib/symphony_elixir/agent/mcp_server/linear_tools.ex`
  - 将 `Agent.Tool` 结果包装成 MCP tool result。

- 修改： `elixir/lib/symphony_elixir/agent/acp_stdio/client.ex`
  - 将 `session_new_params/1` 扩展为接收 config，构造 `mcpServers`。

- 修改： `elixir/lib/symphony_elixir/agent/backend/acp_stdio.ex`
  - 透传 workflow path、escript path、MCP 配置到 ACP client。

- 修改： `elixir/lib/symphony_elixir/config.ex`
  - 校验 `agents.<id>.mcp.linear_tools` 和可选 MCP type/url/headers/env override。

- 修改： `elixir/lib/symphony_elixir/cli.ex`
  - 增加 `mcp linear-tools --workflow <path>` 子命令。

- 新增： `elixir/test/symphony_elixir/agent_tool_test.exs`
  - 覆盖 backend-neutral `linear_graphql` 工具核心。

- 新增： `elixir/test/symphony_elixir/mcp_server_test.exs`
  - 覆盖 MCP initialize、tools/list、tools/call、错误响应和 stdout/stderr 隔离。

- 修改： `elixir/test/symphony_elixir/dynamic_tool_test.exs`
  - 确认 Codex wrapper 行为保持兼容。

- 修改： `elixir/test/symphony_elixir/acp_stdio_client_test.exs`
  - 覆盖 `mcpServers` 默认空数组和开启 `linear_tools` 后的注入。

- 修改： `elixir/test/symphony_elixir/core_test.exs`
  - 覆盖 MCP 配置解析和非法配置拒绝。

- 修改： `elixir/docs/mimocode_acp_smoke_test.md`
  - 增加 MiMo + MCP `linear_graphql` 真实 smoke 步骤。

- 修改： `elixir/docs/multi_agent_backends.md`
  - 说明 `acp_stdio` 的 MCP 工具注入配置和限制。

---

## 任务 1：提取 backend-neutral 工具核心

**Files:**
- 新增： `elixir/lib/symphony_elixir/agent/tool.ex`
- 新增： `elixir/lib/symphony_elixir/agent/tool/linear_graphql.ex`
- 修改： `elixir/lib/symphony_elixir/codex/dynamic_tool.ex`
- 新增： `elixir/test/symphony_elixir/agent_tool_test.exs`
- 修改： `elixir/test/symphony_elixir/dynamic_tool_test.exs`

- [x] **步骤 1: 写 `Agent.Tool` 失败测试**

在 `elixir/test/symphony_elixir/agent_tool_test.exs` 增加测试，覆盖：

```elixir
test "specs exposes linear_graphql" do
  assert [%{"name" => "linear_graphql", "inputSchema" => schema}] = Agent.Tool.specs()
  assert schema["required"] == ["query"]
end

test "linear_graphql executes successful GraphQL responses" do
  response =
    Agent.Tool.execute("linear_graphql", %{"query" => "query Viewer { viewer { id } }"},
      linear_client: fn query, variables, _opts ->
        send(self(), {:linear_called, query, variables})
        {:ok, %{"data" => %{"viewer" => %{"id" => "viewer-id"}}}}
      end
    )

  assert {:ok, %{success: true, output: output}} = response
  assert output =~ "viewer-id"
  assert_received {:linear_called, "query Viewer { viewer { id } }", %{}}
end
```

运行：

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/agent_tool_test.exs'
```

预期：编译失败，提示 `SymphonyElixir.Agent.Tool` 不存在。

- [x] **步骤 2: 实现 `Agent.Tool` 和 `LinearGraphql`**

实现要点：

```elixir
defmodule SymphonyElixir.Agent.Tool do
  @moduledoc "backend-neutral agent client tool registry."

  alias SymphonyElixir.Agent.Tool.LinearGraphql

  @spec specs() :: [map()]
  def specs, do: [LinearGraphql.spec()]

  @spec execute(String.t() | nil, term(), keyword()) :: {:ok, map()} | {:error, map()}
  def execute("linear_graphql", arguments, opts), do: LinearGraphql.execute(arguments, opts)

  def execute(other, _arguments, _opts) do
    {:error,
     %{
       name: other,
       success: false,
       output: Jason.encode!(%{"error" => %{"message" => "Unsupported tool: #{inspect(other)}"}}, pretty: true),
       payload: %{"error" => %{"message" => "Unsupported tool: #{inspect(other)}"}}
     }}
  end
end
```

`LinearGraphql.execute/2` 从当前 `Codex.DynamicTool` 迁移参数校验和错误归一化，返回 `%{name: "linear_graphql", success: boolean, output: binary, payload: map}`。

- [x] **步骤 3: 改造 Codex wrapper**

`Codex.DynamicTool.execute/3` 改为：

```elixir
case SymphonyElixir.Agent.Tool.execute(tool, arguments, opts) do
  {:ok, result} -> dynamic_tool_response(result.success, result.output)
  {:error, result} -> dynamic_tool_response(false, result.output)
end
```

`tool_specs/0` 改为代理 `Agent.Tool.specs/0`。

- [x] **步骤 4: 验证兼容性**

运行：

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/agent_tool_test.exs test/symphony_elixir/dynamic_tool_test.exs'
```

预期：新工具测试通过，原 Codex dynamic tool 测试不需要改断言。

---

## 任务 2：实现 Symphony MCP 工具 endpoint

**Files:**
- 新增： `elixir/lib/symphony_elixir/agent/mcp_server.ex`
- 新增： `elixir/lib/symphony_elixir/agent/mcp_server/stdio.ex`
- 新增： `elixir/lib/symphony_elixir/agent/mcp_server/linear_tools.ex`
- 新增： `elixir/test/symphony_elixir/mcp_server_test.exs`

- [x] **步骤 1: 写 MCP server 失败测试**

测试覆盖：

```elixir
test "lists Linear tools and the raw GraphQL fallback" do
  assert {:ok, response} =
           McpServer.handle(%{"id" => 1, "method" => "tools/list", "params" => %{}}, [])

  assert %{
           "tools" => [
             %{"name" => "linear_issue_read"},
             %{"name" => "linear_comment_create"},
             %{"name" => "linear_issue_update_state"},
             %{"name" => "linear_graphql"}
           ]
         } = response
end

test "calls linear_graphql through Agent.Tool" do
  request = %{
    "id" => 2,
    "method" => "tools/call",
    "params" => %{
      "name" => "linear_graphql",
      "arguments" => %{"query" => "query Viewer { viewer { id } }"}
    }
  }

  assert {:ok, response} = McpServer.handle(request, linear_client: fn _, _, _ -> {:ok, %{"data" => %{}}} end)
  assert response["isError"] == false
  assert [%{"type" => "text"}] = response["content"]
end
```

运行：

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/mcp_server_test.exs'
```

预期：编译失败，提示 MCP server 模块不存在。

- [x] **步骤 2: 实现 MCP 方法分发**

`McpServer.handle/2` 处理：

- `initialize` 返回 protocol version、server info 和 tools capability。
- `notifications/initialized` 返回 `:noreply`。
- `tools/list` 返回 `Agent.Tool.specs/0`。
- `tools/call` 调用 `LinearTools.call/2`。
- 未知 method 返回 JSON-RPC `-32601`。

- [x] **步骤 3: 实现 `LinearTools.call/2`**

结果包装：

```elixir
%{
  "content" => [%{"type" => "text", "text" => result.output}],
  "isError" => result.success == false
}
```

unsupported tool 使用同样结构返回 `isError: true`。

- [x] **步骤 4: 实现 stdio loop**

`McpServer.Stdio.run/1` 要求：

- 从 stdin 按行读取 JSON-RPC。
- stdout 每行只输出 JSON-RPC response。
- stderr 输出诊断日志。
- request parse 失败返回 `-32700`。
- method 参数非法返回 `-32602`。

- [x] **步骤 5: 实现并验证 HTTP MCP endpoint**

运行：

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/mcp_server_test.exs test/symphony_elixir/extensions_test.exs'
```

预期：MCP server 单元测试和 HTTP endpoint 测试通过。

---

## 任务 3：增加 CLI 子命令

**Files:**
- 修改： `elixir/lib/symphony_elixir/cli.ex`
- 测试： `elixir/test/symphony_elixir/cli_test.exs` 或现有 CLI 测试文件

- [x] **步骤 1: 写 CLI 失败测试**

覆盖：

```powershell
bin/symphony mcp linear-tools --workflow /abs/path/WORKFLOW.md
```

预期：

- CLI 不启动 orchestrator。
- CLI 调用 `McpServer.Stdio.run/1`。
- 缺少 `--workflow` 返回非零状态和中文错误。

- [x] **步骤 2: 实现 CLI 分支**

解析规则：

```elixir
["mcp", "linear-tools", "--workflow", workflow_path]
```

行为：

- 设置 workflow path 到 MCP server options。
- 调用 `SymphonyElixir.Agent.McpServer.Stdio.run(opts)`。
- stdout 不打印非协议文本。

- [x] **步骤 3: 验证 CLI**

运行：

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/cli_test.exs'
```

预期：CLI 子命令测试通过。

---

## 任务 4：扩展 ACP `mcpServers` 注入

**Files:**
- 修改： `elixir/lib/symphony_elixir/config.ex`
- 修改： `elixir/lib/symphony_elixir/agent/acp_stdio/client.ex`
- 修改： `elixir/lib/symphony_elixir/agent/backend/acp_stdio.ex`
- 修改： `elixir/test/symphony_elixir/core_test.exs`
- 修改： `elixir/test/symphony_elixir/acp_stdio_client_test.exs`
- 修改： `elixir/test/symphony_elixir/acp_stdio_backend_test.exs`

- [x] **步骤 1: 写配置测试**

合法配置：

```yaml
agents:
  mimocode:
    kind: acp_stdio
    command: /home/gqy47/.npm-global/bin/mimo
    args: ["acp", "--cwd", "{{workspace}}"]
    mcp:
      linear_tools: true
```

非法配置：

- `mcp.linear_tools` 不是 boolean。
- `mcp.url` 不是字符串。
- `mcp.type` 不是 `http` 或 `sse`。
- `mcp.headers` 不是列表。
- `mcp.env` 不是列表。

- [x] **步骤 2: 写 ACP 注入测试**

覆盖：

- 缺省时 `session/new.params.mcpServers == []`。
- `mcp.linear_tools: true` 时包含 `symphony-linear`。
- 注入项包含 `type: "http"`、`url`、`headers: []`、`env: []`。
- emitted event 不包含 env 的 token 值。

- [x] **步骤 3: 实现配置解析**

在 agent config 中允许：

```yaml
mcp:
  linear_tools: true
  type: "http"
  url: "http://127.0.0.1:4000/mcp/linear-tools"
  headers: []
  env: []
```

`type/url/headers/env` 是 override；没有 override 时由 backend 根据当前 Symphony HTTP 服务端口构造本地 URL。

- [x] **步骤 4: 实现 `build_mcp_servers`**

`AcpStdio.Client` 中将：

```elixir
session_new_params(workspace)
```

扩展为：

```elixir
session_new_params(workspace, config)
```

返回：

```elixir
%{
  "cwd" => Path.expand(workspace),
  "mcpServers" => build_mcp_servers(config, workspace)
}
```

- [x] **步骤 5: 验证 ACP 注入**

运行：

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/core_test.exs test/symphony_elixir/acp_stdio_client_test.exs test/symphony_elixir/acp_stdio_backend_test.exs'
```

预期：配置和 ACP 注入测试通过。

---

## 任务 5：文档和真实 smoke

**Files:**
- 修改： `elixir/docs/mimocode_acp_smoke_test.md`
- 修改： `elixir/docs/multi_agent_backends.md`
- 修改： `elixir/WORKFLOW.local.md`，仅当本地 smoke 需要时修改

- [x] **步骤 1: 更新配置文档**

在 `multi_agent_backends.md` 增加：

```yaml
agents:
  mimocode:
    kind: acp_stdio
    command: "/home/gqy47/.npm-global/bin/mimo"
    args: ["acp", "--cwd", "{{workspace}}"]
    config_options:
      model: "mimo/mimo-auto"
    mcp:
      linear_tools: true
```

并说明 `linear_tools` 只暴露 Linear 相关 MCP 工具：`linear_issue_read`、`linear_comment_create`、`linear_issue_update_state` 和 raw fallback `linear_graphql`。

- [x] **步骤 2: 更新 smoke 文档**

在 `mimocode_acp_smoke_test.md` 增加真实验证步骤：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\elixir\start-local.ps1 -Workflow .\elixir\WORKFLOW.local.md -Port 4000
curl -sS -X POST http://127.0.0.1:4000/api/v1/refresh
```

Linear issue 要求：

- project 为当前测试项目。
- label 包含 `agent:mimo`。
- issue 描述要求创建一个小文件、优先调用 `linear_issue_read` 查询自身、用 `linear_comment_create` 评论结果、用 `linear_issue_update_state` 移出 active state；`linear_graphql` 只作为 fallback。

- [x] **步骤 3: 执行真实 MiMo smoke**

记录：

- issue identifier。
- session id。
- dashboard 中的 `agent_id` 和 `agent_kind`。
- MiMo 是否调用高层 Linear MCP 工具，raw `linear_graphql` 调用是否减少。
- issue 是否产生评论。
- issue 是否离开 active state。
- workspace 文件是否存在。

- [x] **步骤 4: 停止服务并清理残留进程**

运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\elixir\stop-local.ps1
```

预期：无残留 `mimo acp`、`.mimocode acp` 或 `bin/symphony` 进程。

---

## 全量验证

运行：

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/acp_backend_registration_test.exs test/symphony_elixir/acp_stdio_client_test.exs test/symphony_elixir/acp_stdio_backend_test.exs test/symphony_elixir/acp_agent_runner_test.exs test/symphony_elixir/core_test.exs test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/dynamic_tool_test.exs test/symphony_elixir/agent_tool_test.exs test/symphony_elixir/mcp_server_test.exs'
```

预期：目标测试集通过。

运行：

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix specs.check'
```

预期：`specs.check: all public functions have @spec or exemption`。

运行：

```powershell
git diff --check
```

预期：无 whitespace error。

## 验收标准

- Codex dynamic tool 的 `linear_graphql` 行为保持兼容。
- MiMo-Code 的 ACP session 创建时可以注入 `symphony-linear` MCP server。
- HTTP MCP endpoint 只暴露 `linear_issue_read`、`linear_comment_create`、`linear_issue_update_state` 和 raw fallback `linear_graphql`。
- MiMo-Code 可以通过高层 MCP 工具查询 Linear issue。
- MiMo-Code 可以通过高层 MCP 工具评论 issue 并把 issue 移出 active state。
- 日志和 dashboard 不泄露 Linear API key。
- OpenCode 没有进入本轮任务，也不影响本轮验收。
