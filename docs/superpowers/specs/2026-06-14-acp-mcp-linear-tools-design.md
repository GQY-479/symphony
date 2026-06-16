# ACP MCP Linear 工具桥接设计

## 目标

MiMo-Code 已经可以通过 `acp_stdio` 作为平级 agent backend 承接 Linear issue，但真实 smoke 中暴露出一个关键缺口：MiMo-Code 能改 workspace 文件，却不能像 Codex app-server 一样稳定使用 Symphony 注入的 `linear_graphql` 工具完成评论、状态流转和最终收尾。

本设计的目标是在不修改 MiMo-Code 本体的前提下，让 MiMo-Code 通过 ACP `session/new.params.mcpServers` 连接一个由 Symphony 提供的 HTTP MCP endpoint。该 endpoint 暴露与 Codex dynamic tool 等价的 `linear_graphql` 能力，使 MiMo-Code 在协议层拥有与 Codex app-server 接近的 Linear 写回能力。

2026-06-14 真实 smoke 纠偏：最初方案假设 MiMo-Code 可以消费 stdio MCP server descriptor，即 `command/args/env`。真实 `@mimo-ai/cli@0.1.0` 返回 `Invalid params`，错误显示它期望 `type: "http"` 或 `type: "sse"`、`url`、`headers` 数组和 `env` 数组。因此本设计从“注入 stdio MCP server”调整为“注入 HTTP MCP endpoint”；既有 stdio MCP loop 保留为本地调试入口，不再作为 MiMo 的默认接入方式。

OpenCode 复用原本可作为后续阶段，用于验证它是否能复用同一套 `acp_stdio + MCP linear_graphql` 方案；本轮明确跳过，只保留为后续验证方向，不进入本设计验收。

## 已知事实

- `SPEC.md` 已把 `linear_graphql` 定义为可选 client-side tool extension，并要求它能处理合法 GraphQL、GraphQL errors、缺失鉴权、transport failure 和 unsupported tool。
- Codex app-server 当前通过 `SymphonyElixir.Codex.DynamicTool` 注入 `linear_graphql`，实际调用 `SymphonyElixir.Linear.Client.graphql/3`。
- ACP 官方 schema 中，`session/new` 的 `cwd` 是必填绝对路径，`mcpServers` 是必填的 `McpServer[]`。当前 `acp_stdio` 已经默认发送 `mcpServers: []`。
- 本机真实 MiMo-Code smoke 证明：MiMo-Code 能通过 `mimo acp` 启动 session、执行 workspace 修改，并经 `agent:mimo` label 被 Symphony 路由。
- 真实 Linear issue smoke 的剩余问题不是调度失败，而是 MiMo-Code 缺少 Codex app-server 那种工具注入通道，导致 Linear 收尾和 push/评论能力不稳定。
- 当前环境尝试直接 clone GitHub 仓库时出现连接重置。实施前仍需要以 ACP 官方 schema 和本机已安装 MiMo-Code 行为作为门禁重新验证 `mcpServers` 字段形态。

## 设计结论

推荐方案：实现 Symphony 内置的 HTTP MCP endpoint，并在 `acp_stdio` 的 `session/new` 中注入该 endpoint。

不推荐的方案：

- 让 MiMo-Code 用 shell/curl 直接访问 Linear。原因是凭据暴露面更大，prompt 依赖更重，错误处理无法复用 SPEC 中的 `linear_graphql` 契约。
- 在 ACP client 中臆造一个 agent-to-client tool request。当前可确认的是 ACP session 可以接收 `mcpServers`，而不是所有 agent 都会通过 ACP 自定义 request 调 Linear。
- 让 MiMo-Code 伪装 Codex app-server。两者协议不同，硬兼容会把适配复杂度放在错误层级。

## 总体架构

```text
Linear issue
  -> Symphony Orchestrator
  -> AgentRunner
  -> AcpStdio backend
  -> MiMo-Code ACP session
  -> injected MCP HTTP endpoint
  -> Symphony Agent Tool
  -> Linear Client GraphQL
```

职责边界：

- `AcpStdio` 仍只负责 ACP session 生命周期、prompt、事件和 `mcpServers` 注入。
- MCP endpoint 只负责 MCP JSON-RPC 协议、tools/list、tools/call 和结果格式。
- backend-neutral 工具模块负责 `linear_graphql` 的参数校验、Linear 调用和错误归一化。
- `Codex.DynamicTool` 保留 Codex app-server 的响应包装，但不再独占 Linear 工具业务逻辑。
- Orchestrator 不理解 MCP，也不直接执行业务写回；它只调度 issue 和维护运行状态。

## 配置模型

第一版使用默认注入，避免每个 workflow 都手写 MCP server 细节。

推荐配置：

```yaml
agents:
  mimocode:
    kind: acp_stdio
    command: "/home/gqy47/.npm-global/bin/mimo"
    args:
      - "acp"
      - "--cwd"
      - "{{workspace}}"
    permission_policy: reject
    config_options:
      model: "mimo/mimo-auto"
    mcp:
      linear_tools: true
```

解析后注入到 ACP 的概念形态：

```json
{
  "cwd": "/abs/path/to/issue/workspace",
  "mcpServers": [
    {
      "name": "symphony-linear",
      "type": "http",
      "url": "http://127.0.0.1:4000/mcp/linear-tools",
      "headers": [],
      "env": []
    }
  ]
}
```

真实 MiMo-Code smoke 已确认发布版接受 HTTP/SSE MCP descriptor，不接受默认 stdio descriptor。因此默认注入使用 HTTP；如后续 OpenCode 支持 stdio，可在 provider-specific 配置中重新评估。

安全边界：

- 默认只注入 `linear_graphql`，不暴露 shell、文件系统或通用网络工具。
- MCP server 从 Symphony 配置和环境解析 Linear 鉴权，不把 token 写入日志、dashboard 或文档。
- `mcp.linear_tools` 默认为 `false` 还是 `true` 需要按部署风险决定。当前建议对 `acp_stdio` 默认 `false`，本地 workflow 显式开启，避免无意给所有 ACP agent 写 Linear 权限。

## 工具核心抽象

新增 backend-neutral 工具层：

```elixir
SymphonyElixir.Agent.Tool
SymphonyElixir.Agent.Tool.LinearGraphql
```

接口：

```elixir
@spec specs() :: [map()]
@spec execute(String.t() | nil, term(), keyword()) :: {:ok, map()} | {:error, map()}
```

统一返回内部结果：

```elixir
%{
  name: "linear_graphql",
  success: boolean(),
  output: binary(),
  payload: map()
}
```

`Codex.DynamicTool` 将该结果包装成 Codex app-server 需要的：

```elixir
%{
  "success" => success,
  "output" => output,
  "contentItems" => [%{"type" => "inputText", "text" => output}]
}
```

MCP endpoint 将该结果包装成 MCP `tools/call` 需要的 content result。这样 Codex 和 MiMo-Code 共用同一份 Linear GraphQL 校验和错误处理，不出现两套工具语义。

## MCP endpoint 行为

新增模块：

```elixir
SymphonyElixir.Agent.McpServer
SymphonyElixir.Agent.McpServer.Stdio
SymphonyElixir.Agent.McpServer.LinearTools
SymphonyElixirWeb.McpController
```

第一版 HTTP endpoint 位于：

```text
POST /mcp/linear-tools
```

HTTP body 是 JSON-RPC request。第一版支持最小 MCP 方法：

- `initialize`
- `notifications/initialized`
- `tools/list`
- `tools/call`

`tools/list` 返回一个工具：

```json
{
  "name": "linear_graphql",
  "description": "Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.",
  "inputSchema": {
    "type": "object",
    "additionalProperties": false,
    "required": ["query"],
    "properties": {
      "query": {"type": "string"},
      "variables": {"type": ["object", "null"], "additionalProperties": true}
    }
  }
}
```

`tools/call` 行为：

- `name == "linear_graphql"`：调用 backend-neutral `Agent.Tool.execute/3`。
- 不支持的工具名：返回结构化 MCP error 或 `isError: true` result，不能卡住 session。
- 参数不是 map、缺少 `query`、`variables` 非对象：返回 `isError: true`。
- GraphQL body 顶层包含 `errors`：返回 `isError: true`，但保留完整 body 文本。
- Linear 鉴权缺失：返回 `isError: true`，错误文本说明缺少配置，但不打印 token。

## CLI 入口

stdio MCP loop 仍保留为本地调试入口：

```powershell
.\elixir\bin\symphony mcp linear-tools --workflow .\elixir\WORKFLOW.local.md
```

运行逻辑：

1. 加载 workflow，用现有配置解析获取 `tracker.api_key` 和 Linear endpoint。
2. 启动 stdio MCP server，stdin/stdout 只传协议消息。
3. 日志输出走 stderr，避免污染 MCP JSON-RPC。
4. 收到 EOF 或 parent 进程退出时自然结束。

MiMo-Code 默认不通过该 CLI 子命令接入；它通过 HTTP URL 连接当前 Symphony 服务。

## ACP 注入流程

`AcpStdio.Client.session_new_params/2` 从固定 `mcpServers: []` 扩展为：

```elixir
%{
  "cwd" => Path.expand(workspace),
  "mcpServers" => build_mcp_servers(config, workspace)
}
```

`build_mcp_servers/2` 规则：

- 未开启 `mcp.linear_tools`：返回 `[]`。
- 开启后构造 `symphony-linear` HTTP server。
- 默认 `type` 为 `http`。
- 默认 `url` 为 `http://127.0.0.1:<server_port>/mcp/linear-tools`。
- `headers` 和 `env` 默认都是空数组；不在事件 payload 中记录任何敏感值。

## 文档和 prompt 约定

MiMo-Code 需要知道可以使用 `linear_graphql`。更新 `WORKFLOW.local.md` 或多 agent 文档时，给 ACP agent 的通用说明应是：

```markdown
当你需要读取或更新 Linear issue 时，优先使用可用的 `linear_graphql` MCP 工具。
不要把 Linear API token 写入文件、日志、提交信息或 issue 评论。
完成任务后，用 Linear mutation 更新 issue 状态，并用评论总结结果和验证命令。
```

这段说明不应写成 Codex 专用措辞，也不应假设工具来自 Codex dynamic tool。

## 分阶段任务

### 阶段 0：协议门禁

目标：确认 ACP `mcpServers` 注入和 MiMo-Code MCP 连接假设成立。

验收：

- ACP schema 中 `session/new.params.mcpServers` 仍为必填数组。
- 真实 `mimo acp` 在收到包含空数组的 `mcpServers` 时可创建 session。
- fake ACP server 能断言 `mcpServers` 被按配置注入。
- 若真实 MiMo-Code 不消费 `mcpServers`，暂停实现，改为评估 ACP client request 或 HTTP tool bridge。

### 阶段 1：提取工具核心

目标：让 Codex dynamic tool 和 MCP server 共用一份 `linear_graphql` 业务逻辑。

验收：

- `DynamicTool.execute/3` 外部行为不变。
- 原有 `dynamic_tool_test.exs` 全部通过。
- 新增 `Agent.Tool` 测试覆盖成功响应、GraphQL errors、缺失 query、非法 variables、缺失 Linear auth、transport failure。

### 阶段 2：实现 MCP 工具 endpoint

目标：提供可由 MiMo-Code 连接的 `linear_graphql` MCP endpoint。

验收：

- MCP fake client 可以完成 `initialize -> tools/list -> tools/call`。
- `tools/list` 只返回 `linear_graphql`。
- `tools/call` 对成功和失败都返回结构化结果。
- HTTP endpoint 能通过 POST JSON-RPC 完成 `initialize -> tools/list -> tools/call`。
- 保留 stdio loop 作为本地调试入口，stdout 只包含 JSON-RPC 协议行；日志只走 stderr。

### 阶段 3：ACP 注入 MCP server 与真实 MiMo smoke

目标：`acp_stdio` 能按 agent 配置向 `session/new` 注入 Symphony HTTP MCP endpoint，并用真实 MiMo-Code Linear issue 验证 `linear_graphql` 收尾能力。

验收：

- `mcp.linear_tools: false` 或缺省时仍发送 `mcpServers: []`。
- `mcp.linear_tools: true` 时发送一个 `symphony-linear` HTTP MCP server descriptor。
- workflow 路径、workspace 路径和 escript 路径均使用绝对路径。
- dashboard 不泄露 MCP env。
- 测试 issue 使用 `agent:mimo` 路由到 `mimocode/acp_stdio`。
- MiMo-Code 能创建或修改 workspace 文件。
- MiMo-Code 能调用 `linear_graphql` 查询当前 issue。
- MiMo-Code 能评论 smoke 结果。
- MiMo-Code 能把 issue 移出 active state。
- dashboard 能显示 `agent_id=mimocode`、ACP session id、MCP tool call 相关 update。

### 阶段 4：OpenCode 复用，本轮跳过

目标：后续验证 OpenCode 是否能复用阶段 1 到阶段 3 形成的 `acp_stdio + MCP linear_graphql` 接入方式。

本轮处理：

- 不创建 OpenCode 专项实现任务。
- 不要求 `opencode acp`、`opencode serve` 或 OpenCode Linear issue smoke 通过。
- 不把 OpenCode 兼容性问题作为 MiMo-Code 接入验收阻塞项。
- 保持 `acp_stdio` 和 MCP 工具核心的接口 provider-neutral，避免把实现写死为 MiMo-Code 专用。

## 验证命令

单元测试：

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/dynamic_tool_test.exs test/symphony_elixir/acp_stdio_client_test.exs test/symphony_elixir/acp_stdio_backend_test.exs'
```

MCP server 测试：

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/mcp_server_test.exs test/symphony_elixir/agent_tool_test.exs'
```

全量目标测试：

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/acp_backend_registration_test.exs test/symphony_elixir/acp_stdio_client_test.exs test/symphony_elixir/acp_stdio_backend_test.exs test/symphony_elixir/acp_agent_runner_test.exs test/symphony_elixir/core_test.exs test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/dynamic_tool_test.exs test/symphony_elixir/agent_tool_test.exs test/symphony_elixir/mcp_server_test.exs'
```

规格检查：

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix specs.check'
```

格式检查：

```powershell
git diff --check
```

## 风险和回滚点

- 如果 MiMo-Code 不实际连接 HTTP `mcpServers`，本方案不能达成目标。回滚点是只保留工具核心提取，暂停 MCP 注入。
- 如果 MCP result 格式与 MiMo-Code 期望不同，需要在 MCP server result wrapper 层调整，不改 Linear 工具核心。
- 如果真实 MiMo-Code 会弹出 MCP tool permission，第一版应在 workflow 中明确授权策略；Symphony 不在 MCP server 内绕过 agent 自身权限。
- 如果 HTTP MCP endpoint 在 WSL/Windows 混合环境中不可访问，优先修正 `mcp.url` 或 server bind host；不回退到 MiMo 当前不接受的 stdio descriptor。

## 参考

- `SPEC.md`：`linear_graphql` client-side tool extension 契约。
- `elixir/lib/symphony_elixir/codex/dynamic_tool.ex`：当前 Codex dynamic tool 实现。
- `elixir/lib/symphony_elixir/agent/acp_stdio/client.ex`：当前 ACP `session/new` 和 `mcpServers: []` 实现。
- ACP 官方文档索引：`https://agentclientprotocol.com/llms.txt`
- ACP schema：`https://agentclientprotocol.com/protocol/v1/schema`
