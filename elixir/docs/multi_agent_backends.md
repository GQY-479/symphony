# 多 Agent Backend

Symphony 可以把 Linear issue 路由给不同的平级 coding agent backend。Codex、MiMo-Code、OpenCode 都被建模为可以独立承接 issue 的 worker，而不是彼此的工具。

## 推荐模型

通过 Linear 表达委派关系：

1. 上游 agent 创建、更新或分配 Linear issue。
2. Symphony 轮询 Linear。
3. routing 根据 label、assignee 或 default agent 选择 backend。
4. 被选中的 backend 在独立 workspace 中处理该 issue。

## Backend 类型

- `codex_app_server`：包装现有的 Codex app-server 协议，行为与单 agent 时代完全一致。
- `cli_run`：运行非交互式 CLI agent（如 MiMo-Code 的 `mimo run`、或兼容的 OpenCode CLI），按 JSON/文本行收集输出。
- `acp_stdio`：通过 ACP stdio 协议运行兼容 agent，第一目标是 MiMo-Code 的 `mimo acp`。

`cli_run`、ACP stdio、HTTP server 与 Codex app-server 的能力边界和后续实现建议，见 [`agent_runtime_capability_matrix.md`](agent_runtime_capability_matrix.md)。
MiMo-Code 的 ACP 接入总方案和阶段编排，见 [`mimocode_acp_integration_plan.md`](mimocode_acp_integration_plan.md)。

如果 `WORKFLOW.md` 没有 `agents:` 段，Symphony 会自动从旧的 `codex:` 配置合成一个名为 `codex` 的默认 agent，因此现有配置无需改动即可继续工作。

## 配置字段

`agents` 是一个以 agent id 为 key 的 map，每个 agent 支持：

| 字段 | 适用 kind | 说明 |
| --- | --- | --- |
| `kind` | 全部 | `codex_app_server`、`cli_run` 或 `acp_stdio` |
| `command` | 全部 | 可执行命令；`codex_app_server` 缺省继承 `codex.command` |
| `args` | `cli_run` / `acp_stdio` | 参数列表，`{{workspace}}` 会被替换为该 issue 的 workspace 路径 |
| `enabled` | 全部 | 设为 `false` 可禁用该 agent（路由到它会报错） |
| `timeout_ms` | `cli_run` / `acp_stdio` | 单次运行或 turn 超时（毫秒） |
| `close_timeout_ms` | `acp_stdio` | ACP `session/close` 等待时间（毫秒）。超时后会关闭 port 并兜底终止子进程，默认 `1000` |
| `max_output_bytes` | `cli_run` | 捕获输出的上限，超出后保留尾部 |
| `permission_policy` | `acp_stdio` | ACP permission 策略：`reject`、`fail` 或 `allow`，默认 `reject` |
| `config_options` | `acp_stdio` | ACP session 创建后通过 `session/set_config_option` 设置的字符串键值 map，例如 `model: "mimo/mimo-auto"` |
| `mcp` | `acp_stdio` | 可选 MCP 工具注入配置。当前支持 `linear_tools: true`，用于向 agent 暴露 Symphony 内置的 Linear MCP 工具 |

`routing` 决定每个 issue 由谁处理，优先级为 **label > assignee > default**：

| 字段 | 说明 |
| --- | --- |
| `default_agent` | 没有命中其它规则时使用的 agent id（缺省 `codex`） |
| `by_label` | `label -> agent_id`，label 大小写不敏感 |
| `by_assignee` | Linear assignee id `-> agent_id` |

`routing` 中引用的所有 agent id 必须在 `agents` 中存在，否则 `WORKFLOW.md` 校验会失败。

## Workspace 调试开关

默认情况下，Symphony 会在 issue 进入 terminal state 时清理对应 workspace，这符合 `SPEC.md` 中“终态 issue 清理 workspace”的默认运维语义。

本地真实 smoke 或排障时可以开启：

```yaml
workspace:
  root: ~/code/symphony-workspaces-local
  preserve_terminal: true
```

开启后，terminal issue 触发的 workspace cleanup 会被跳过，便于在 MiMo-Code 把 issue 移到 `Done` 后继续复验文件内容、日志证据和 MCP 写回结果。该开关默认是 `false`，生产或长期运行环境应只在明确需要保留 evidence workspace 时开启，并自行清理历史目录。

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

给 Linear issue 添加 `agent:mimo` label 后，Symphony 会把该 issue 交给 MiMo-Code backend；其余 issue 仍由 Codex 处理。OpenCode 可以用同样的 `cli_run` 形态接入，只需把 `command`/`args` 换成对应 CLI。

## MiMo-Code ACP 示例

```yaml
agents:
  codex:
    kind: codex_app_server
    command: "codex app-server"
  mimocode:
    kind: acp_stdio
    command: "mimo"
    args:
      - "acp"
      - "--cwd"
      - "{{workspace}}"
    permission_policy: reject
    config_options:
      model: "mimo/mimo-auto"
    mcp:
      linear_tools: true
    timeout_ms: 3600000
    close_timeout_ms: 1000
routing:
  default_agent: codex
  by_label:
    "agent:mimo": mimocode
```

`acp_stdio` 是 session backend，会在一次 worker attempt 内保持同一个 ACP session，并把 Symphony continuation turn 映射为同一 session 中的后续 `session/prompt`。真实 MiMo-Code smoke 结果见 [`mimocode_acp_smoke_test.md`](mimocode_acp_smoke_test.md)。

注意：ACP session 是 agent runtime 的上下文容器，不等同于 Symphony 的 turn。每次 continuation 都应该产生独立的 `turn_started` / `turn_completed` 事件；dashboard 的 `turn_count` 应按 turn 事件统计，而不是按 `session_started` 统计。

注意：当前 MiMo-Code 源码虽然声明了 `mimo acp --cwd`，但 ACP 命令启动时仍依赖进程 cwd。Symphony 的 `acp_stdio` backend 会把子进程 cwd 设置为 issue workspace，并在 `session/new.cwd` 中再次传入同一路径；配置中保留 `--cwd {{workspace}}` 只是为了兼容后续版本或其它 ACP agent。

真实 `@mimo-ai/cli@0.1.0` 要求 `session/new.params.mcpServers` 是数组。Symphony 会在 `session/new` 中发送 `mcpServers: []`，即使当前 workflow 没有配置 MCP server，也避免真实 MiMo 在握手阶段返回 `Invalid params`。

配置 `mcp.linear_tools: true` 后，Symphony 会在 ACP `session/new.params.mcpServers` 中注入一个名为 `symphony-linear` 的 HTTP MCP server descriptor。该 endpoint 只暴露 Linear 相关工具：`linear_issue_read`、`linear_comment_create`、`linear_issue_update_state` 和 raw fallback `linear_graphql`。它们通过 Symphony 已配置的 Linear 鉴权执行固定 Linear 操作或 GraphQL 查询，不会暴露 shell、文件系统或通用网络工具。

开启 `mcp.linear_tools: true` 的 `acp_stdio` agent 会在首轮 issue prompt 中额外收到一段 Symphony 运行时工具说明。该说明会要求 agent 对常见 Linear 操作优先使用高层 MCP 工具：读取 issue 用 `linear_issue_read`，评论用 `linear_comment_create`，状态流转用 `linear_issue_update_state`；只有这些工具覆盖不了的操作才使用 raw `linear_graphql` fallback。如果工具列表展示的是 MiMo/OpenCode 的 namespaced 形式，则 raw fallback 使用 `symphony-linear_linear_graphql`。说明还会避免 agent 用 shell、git、push、skill、本地 `linear` / `push` skill 或未暴露工具完成 Linear 写回，并把 workspace 文件修改和 Linear 写回分开：文件或仓库变更使用 agent 正常 workspace 编辑能力，issue 评论和状态流转使用高层 Linear MCP 工具。这是为了降低真实 MiMo-Code 运行中出现的 `Invalid Tool` 和 raw GraphQL 形状试错噪音；原始 workflow prompt 仍然是业务任务的主体。

注意：`linear_issue_update_state` 可能把 issue 移到 `Done` 这类 terminal state。terminal state 会让 Symphony 停止 active agent，因此该工具只能在 workspace 变更、必要验证和评论都完成后最后调用。YQE-32 真实 smoke 显示，过早移动 `Done` 会造成 Linear 收尾成功但 workspace 文件未落盘。

真实 `@mimo-ai/cli@0.1.0` 期望 MCP server descriptor 使用 `type: "http"` 或 `type: "sse"`、`url`、`headers` 数组和 `env` 数组。它不接受默认 stdio descriptor 的 `command/args/env` 形态。

如果需要覆盖 MCP endpoint 地址，可以显式配置：

```yaml
mcp:
  linear_tools: true
  type: "http"
  url: "http://127.0.0.1:4000/mcp/linear-tools"
  headers: []
  env: []
```

默认情况下不需要写 `type`、`url`、`headers` 或 `env`；`acp_stdio` backend 会根据当前 Symphony HTTP 服务端口自动构造 URL。日志和 dashboard 不应记录任何敏感 header 或 env 值。

`config_options` 用于在 ACP session 创建后调用 `session/set_config_option`。第一版主要用于设置真实 MiMo-Code 的模型，例如 `model: "mimo/mimo-auto"`。ACP 请求参数使用官方字段名 `configId` 和 `value`；也就是说上面的配置会发送：

```json
{
  "method": "session/set_config_option",
  "params": {
    "sessionId": "<acp-session-id>",
    "configId": "model",
    "value": "mimo/mimo-auto"
  }
}
```

如果 ACP `session/prompt` result 带有 `usage`，Symphony 会把它放到 `turn_completed.usage`，让 dashboard 和 Orchestrator token accounting 走现有统计路径。

如果 ACP `session/close` 卡住，`acp_stdio` 会按 `close_timeout_ms` 超时回收。回收语义不同于 prompt timeout：close timeout 不会发送 `session/cancel`，只会关闭 port 并兜底终止 ACP 子进程。

`session/close` 按 ACP capability 协商发送：只有 `initialize.result.agentCapabilities.sessionCapabilities.close` 存在时，Symphony 才会调用 `session/close`。真实 `@mimo-ai/cli@0.1.0` 当前未声明该能力，因此 Symphony 会直接关闭 stdio port。

ACP `session/prompt` 的 `timeout_ms` 是单个 turn 的总超时时间，不会因为 agent 持续发送 `session/update` 而被续期。超时后 backend 会发送一次 `session/cancel` 并记录 `turn_cancelled`。

如果 ACP agent 请求 Symphony 暂未支持的 client-side 方法，`acp_stdio` 会返回 JSON-RPC error 并记录 `unsupported_request`，避免 agent 等待 response 时卡住。

`acp_stdio` 按 ndjson framing 读取 stdout，并能处理一条 JSON line 被拆成多个 stdout chunk 的情况。
同一个 stdout chunk 中如果目标 response 后还包含完整 notification 或 client request，backend 也会继续处理这些剩余行。

dashboard 会把 ACP `session/update` 转成可读状态文本：文本更新显示为 `agent update: ...`，tool call 更新显示为 `agent tool call: ...`。这保证 MiMo-Code 运行时不会只在 EVENT 列显示原始 `session/update` 方法名。

ACP `session/update` 同时会写入低敏结构化日志，包含 `agent_id`、`agent_kind`、`session_id`、`update_kind`、`tool_name`、`tool_status` 和 `error_category`。日志不会记录 update 文本、tool arguments、GraphQL query、MCP headers/env 或 Linear token。

HTTP MCP `tools/call` 日志会包含低敏 `error_category`。常见值包括 `none`、`invalid_arguments`、`graphql_errors`、`linear_api_status`、`linear_auth`、`linear_api_request`、`unsupported_tool` 和 `tool_error`。Linear 非 200 响应如果 body 中含 GraphQL `errors`，也会归入 `graphql_errors`，日志只保留 HTTP status 和类别。这些日志只用于判断失败类别，不记录 GraphQL query、variables、GraphQL error message、comment body、MCP headers/env 或 Linear token。

当前真实 Linear smoke 结论：`agent:mimo` issue 可以被派给 `mimocode/acp_stdio`，MiMo-Code 能执行 ACP session，并已多次通过 HTTP MCP 写回 Linear。YQE-29 到 YQE-31 证明 namespaced 工具名补强和 `error_category` 日志能降低并定位 raw GraphQL 试错；`linear_issue_read`、`linear_comment_create`、`linear_issue_update_state` 三个高层工具在 YQE-32/YQE-33 中已能被真实 MiMo-Code 调用，完成 Linear 读、评、改状态。

YQE-32/YQE-33 暴露过两个真实问题：terminal state 过早移动会导致文件未落盘，以及变量式 issue 描述容易让 MiMo-Code 误读目标文件名和内容。YQE-34 使用明确字段模板复测通过：真实 MiMo-Code 先创建并读回指定 workspace 文件，再调用 `linear_issue_read`、`linear_comment_create`、`linear_issue_update_state` 完成 Linear 收尾；本次 `linear_graphql` 调用为 0，session 未出现 `Invalid Tool`。因此当前建议继续使用 `acp_stdio + mcp.linear_tools` 架构；如果继续打磨，应聚焦压缩 MiMo-Code 对非暴露工具的探索和保持 smoke 模板清晰，而不是更换 Linear 工具通路或引入 OpenCode 复用。

## 可观测性

running、retry、blocked 的快照、HTTP API payload 以及终端 dashboard 的 running 表都会带上 `agent_id` / `agent_kind`，便于确认每个 issue 实际由哪个 backend 处理。
