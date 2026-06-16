# MiMo-Code ACP + MCP 接入总方案

状态：方案文档。本文作为后续实现和验收的依据；当前阶段只规划 MiMo-Code 接入。原本可作为后续阶段的 OpenCode 复用本轮明确跳过，不进入任务列表，也不作为本轮验收条件。

本文记录 MiMo-Code 以 `acp_stdio` runtime 加 HTTP MCP Linear 工具桥接方式接入 Symphony 的总体方案和任务编排。目标是先把 MiMo-Code 做成与 Codex 平级的 agent backend，并补齐它在 Linear 查询、评论和状态收尾上的工具能力；OpenCode 复用同一 backend 的工作本轮先跳过，只保留为后续方向。

## 目标

- MiMo-Code 作为独立 agent 承接 Linear issue，而不是作为 Codex 的工具被调用。
- Symphony 仍以 Linear issue 作为任务边界，通过 label、assignee 或默认路由选择 agent。
- MiMo-Code backend 通过 ACP stdio 协议获得 session、prompt、update、permission、cancel 等控制面能力。
- MiMo-Code 通过 ACP `mcpServers` 连接 Symphony 暴露的 HTTP MCP endpoint，优先使用高层 Linear MCP 工具，并保留与 Codex dynamic tool 共用业务核心的 `linear_graphql` 作为 raw fallback。
- `cli_run` 继续保留为最小可用兜底，但不作为长期 runtime 目标。
- 本轮不实现 OpenCode 复用、不实现新的 agent HTTP runtime backend、不重做 dashboard 命名体系。

## 本轮任务边界

本轮只交付 MiMo-Code ACP + MCP 接入闭环。阶段编号只覆盖 MiMo-Code 接入；原本可以作为阶段 4 的 OpenCode 复用仅作为后续占位：

| 阶段 | 目标 | 是否纳入本轮 |
| --- | --- | --- |
| 阶段 0 | 调研 MiMo-Code ACP/MCP 能力和本机可执行环境 | 是 |
| 阶段 1 | 配置和 backend 注册 | 是 |
| 阶段 2 | ACP client 和 session backend | 是 |
| 阶段 3 | AgentRunner、Linear 路由与高层 MCP Linear 工具收尾验证 | 是 |
| 阶段 3B | MiMo-Code 文件落盘与任务理解稳定性收敛 | 是，作为阶段 3 的后续门禁 |
| 原阶段 4（后续占位） | OpenCode 复用同一 `acp_stdio + MCP` 方案 | 否，本轮跳过 |

因此，本轮验收不要求 `opencode acp`、`opencode serve` 或 OpenCode Linear issue smoke 通过。实现时仍要保持 `acp_stdio` provider-neutral，避免把接口写死为 MiMo-Code 专用，但真实兼容性门禁只看 MiMo-Code。

每个纳入本轮的阶段都按同一节奏推进：

1. 前期调研：确认真实能力、现有代码边界和失败模式。
2. 设计：明确接口、事件、配置、超时和权限语义。
3. 实现：优先改最小闭环，不把 MiMo-Code 特例泄露进 Orchestrator。
4. 验证：先 fake server/单元测试，再真实 `mimo acp`、HTTP MCP 或 Linear issue smoke。

如果某个阶段的实测结果推翻了既定假设，例如 MiMo-Code 的 ACP 行为与预期不兼容，应先回到本文修订设计，再继续实现。

## 设计依据

`SPEC.md` 对 Symphony 的定位是 scheduler/runner，而不是让 agent 互相嵌套调用。按这个模型：

- Orchestrator 负责轮询、并发、重试、状态协调和 workspace 生命周期。
- Agent Runner 负责为一个 issue 启动一个 agent session 并执行 turn。
- Linear 是任务分发和责任边界的外部事实来源。
- Agent 对 issue 的状态、评论、PR 等操作应通过自身工具或 workflow 约定完成。

因此，Codex、MiMo-Code 和后续其它 agent 应该在配置和调度层平级：

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

routing:
  default_agent: codex
  by_label:
    "agent:mimo": mimocode
```

Codex 如果要把任务交给 MiMo-Code，推荐动作是创建或更新 Linear issue，并打上 `agent:mimo` label。Symphony 下一轮轮询后会把该 issue 派给 `mimocode` backend。

## 为什么选择 ACP stdio

Codex app-server 是 Codex CLI 自带的协议 runtime，提供 thread、turn、approval、sandbox、dynamic tools 和结构化事件。MiMo-Code 不能直接替换成 Codex app-server，除非它实现完全兼容的 Codex app-server 协议。

MiMo-Code 源码暴露了 `mimo acp`，使用 Agent Client Protocol 的 stdio JSON-RPC 流。它与 Codex app-server不是同一个协议，但处在类似抽象层级：都是“CLI binary 启动的协议服务 runtime”，而不是普通一次性 CLI 命令。

2026-06-14 复核 MiMo-Code `42e7da3d51dba1129cd3abfa214e29f7385924a3` 后，需要额外注意两点：

- `acp` 命令虽然声明 `--cwd`，但当前 handler 调用 `bootstrap(process.cwd(), ...)`，所以 backend 必须把 ACP 子进程 cwd 设为 issue workspace，不能只依赖 argv。
- 真实 `@mimo-ai/cli@0.1.0` 要求 `session/new.params.mcpServers` 是数组；即使没有 MCP server，也必须发送 `mcpServers: []`。
- 真实 `@mimo-ai/cli@0.1.0` 未在 `initialize.result.agentCapabilities` 中声明 `sessionCapabilities.close`。因此 `session/close` 不能作为无条件关闭流程，必须按 capability 协商。
- 真实 prompt smoke 曾卡在 `session/prompt` 未完成，且初始化信息显示默认模型不适合 coding。Symphony 需要支持通过 ACP `session/set_config_option` 设置 session 级配置，例如 `configId: "model"`、`value: "mimo/mimo-auto"`。
- permission option 的稳定选择依据应来自 agent 发来的 `options`。MiMo-Code 当前 `allow_once` 的 `optionId` 是 `once`，不是 `allow_once`。

相比 `cli_run`，ACP stdio 更适合长期接入：

- 有协议级 session，可以在一个 worker attempt 内复用。
- 有明确 prompt completion、cancel 和 error 信号。
- 有结构化 update 和 tool call 事件。
- 有 permission request 控制面，可以由 Symphony 明确拒绝、失败或自动允许。
- stdio 运行方式与当前 Codex app-server 集成方式接近，不需要先引入端口和常驻 HTTP 服务。

## 为什么还需要 HTTP MCP

ACP stdio 解决的是 MiMo-Code 作为平级 runtime 被调度的问题，但它不自动等价于 Codex app-server 的 dynamic tools。Codex 当前可以由 Symphony 注入 `linear_graphql`，所以它能稳定读取 Linear、评论结果、修改 issue 状态；MiMo-Code 如果只有 ACP session，则只能依赖 prompt、内置工具或 shell 能力，Linear 收尾会不稳定。

因此本方案把能力拆成两层：

- `acp_stdio`：负责 session 生命周期、prompt、事件、权限、取消和超时。
- HTTP MCP Linear tools：负责给 MiMo-Code 暴露与 Codex dynamic tool 等价的 Linear 能力。常见 issue 读、评论、状态流转使用高层工具；其它少见操作再回退到 raw `linear_graphql`。

真实 smoke 已推翻最初的 stdio MCP descriptor 假设：`@mimo-ai/cli@0.1.0` 不接受 `command/args/env` 形态，而是要求 MCP server descriptor 使用 `type: "http"` 或 `type: "sse"`、`url`、`headers` 数组和 `env` 数组。因此默认接入方式是注入 Symphony 当前 HTTP 服务上的 endpoint：

```json
{
  "name": "symphony-linear",
  "type": "http",
  "url": "http://127.0.0.1:4000/mcp/linear-tools",
  "headers": [],
  "env": []
}
```

该 endpoint 只暴露 Linear 相关工具，不暴露 shell、文件系统或通用网络工具。当前工具列表为 `linear_issue_read`、`linear_comment_create`、`linear_issue_update_state` 和 raw fallback `linear_graphql`。Linear 鉴权继续由 Symphony 配置和环境提供，不能写入 prompt、日志、dashboard、workspace 文件或 issue 评论。

`/mcp/linear-tools` 不能使用会打印 request params 的 Phoenix route dispatch 日志，因为 params 中包含 agent 发来的 GraphQL query、mutation 和 variables。该 route 只保留 endpoint 基础请求日志和低敏 `MCP tools/call` 摘要日志；摘要只能记录 tool name、outcome、error boolean 和 `error_category`，不能记录 tool arguments。

真实 smoke 中 MiMo-Code 仍会探索不存在的工具，日志表现为 `Invalid Tool`。为降低这类噪音，Symphony 会在 `acp_stdio` agent 开启 `mcp.linear_tools: true` 时，为首轮 issue prompt 自动追加运行时工具说明：读取 Linear issue 优先使用 `linear_issue_read`，评论使用 `linear_comment_create`，状态流转使用 `linear_issue_update_state`；只有高层工具覆盖不了的 Linear 操作才使用 raw `linear_graphql` fallback。如果工具列表展示的是 MiMo/OpenCode 的 namespaced 形式，则 raw fallback 使用 `symphony-linear_linear_graphql`；不要用 shell、git、push、skill 或未暴露工具处理 Linear 写回，也不要为 Linear 工作加载本地 `linear` / `push` skill。该说明同时明确区分两类动作：workspace 内的仓库或文件变更使用 agent 正常文件编辑能力，Linear 评论和状态流转使用高层 Linear MCP 工具。`linear_graphql` 的 MCP tool description 明确说明它是 lower-level fallback、参数形态、适用范围、namespaced 工具名和禁止携带 Linear API token。该补强不改变 workflow prompt 的业务内容，也不影响未开启 Linear MCP 的 agent。

YQE-32 进一步暴露出高层状态工具的顺序风险：MiMo-Code 可以先调用 `linear_comment_create` 和 `linear_issue_update_state` 把 issue 移到 `Done`，但如果 workspace 文件尚未写入，Symphony 会因为 terminal state 停止 active agent，导致本地任务没有完成。因此 `linear_issue_update_state` 的 tool description 和 runtime guidance 都必须明确：移动到 terminal state 必须是最后一步，只能在 workspace 变更和评论完成后执行。

## 总体架构

本轮总体链路如下：

```text
Linear issue
  -> Symphony Orchestrator
  -> AgentRunner
  -> AcpStdio backend
  -> MiMo-Code ACP session
  -> HTTP MCP endpoint /mcp/linear-tools
  -> backend-neutral Agent.Tool.LinearGraphql
  -> Linear GraphQL API
```

新增一个通用 backend：

```text
SymphonyElixir.Agent.Backend.AcpStdio
```

它实现现有 session backend contract：

```text
start_session(workspace, resolved_agent, opts)
run_turn(session, workspace, issue, prompt, opts)
stop_session(session)
```

内部再拆出 ACP client：

```text
SymphonyElixir.Agent.AcpStdio.Client
```

职责边界：

- `AcpStdio` backend：把 Symphony 的 agent config、session backend contract、event annotation 和 turn result 映射到 ACP client。
- `AcpStdio.Client`：管理 stdio 子进程、JSON-RPC request id、response 匹配、notification 读取、permission reply、timeout 和 cancel。
- ACP 子进程必须以 issue workspace 作为进程 cwd 启动，同时 `session/new.cwd` 也传同一个 workspace 绝对路径。
- `session/new` 必须携带 `mcpServers` 数组。缺省为 `[]`；当 agent config 开启 `mcp.linear_tools: true` 时，注入 `symphony-linear` HTTP MCP descriptor。
- `SymphonyElixir.Agent.McpServer` 与 `SymphonyElixirWeb.McpController`：提供 `/mcp/linear-tools` JSON-RPC endpoint，只支持 `initialize`、`notifications/initialized`、`tools/list` 和 `tools/call` 的最小 MCP 子集。
- `SymphonyElixir.Agent.Tool`：承载 backend-neutral Linear 工具注册表。当前暴露 `linear_issue_read`、`linear_comment_create`、`linear_issue_update_state` 和 raw fallback `linear_graphql`，Codex dynamic tool 与 MCP endpoint 共用同一套业务核心，避免 Linear 工具语义分叉。
- `AgentRunner`：当 resolved agent 是 `acp_stdio` 且开启 `mcp.linear_tools` 时，首轮 prompt 追加 backend runtime guidance，帮助 MiMo-Code 把 Linear 查询、评论和状态流转集中到高层 Linear MCP 工具；如果必须使用 raw fallback，并且 MiMo/OpenCode 的工具面展示为 namespaced 名称，则明确使用 `symphony-linear_linear_graphql`，减少无效工具探索。
- `linear_issue_update_state`：描述和 runtime guidance 必须说明 terminal state 更新是最后一步；否则 Orchestrator 可能停止 active run，造成 workspace 工作未落盘。
- 如果 agent config 中存在 `config_options`，backend 必须在 `session/new` 成功后逐项调用 `session/set_config_option`。请求参数使用 ACP 字段 `sessionId`、`configId` 和 `value`；`config_options.model = "mimo/mimo-auto"` 会发送 `configId: "model"`、`value: "mimo/mimo-auto"`。
- `AgentRunner`：不关心底层是 Codex app-server 还是 ACP stdio，只识别 session backend contract。
- `Orchestrator`：继续按 issue 状态、并发和 retry 策略调度，不内置 MiMo-Code 业务逻辑。

## 事件映射

第一版保留现有可观测字段，同时补充 backend-neutral 字段：

| ACP 侧信号 | Symphony 事件 |
| --- | --- |
| initialize/session new 成功 | `session_started` |
| prompt 开始 | `turn_started` |
| session/update | `notification` |
| tool call update | `notification`，payload 保留 tool 信息 |
| permission request + reject | `permission_rejected` |
| permission request + fail | `approval_required` 后 turn failed |
| permission request + allow | `approval_auto_approved` |
| prompt complete | `turn_completed` |
| prompt error | `turn_failed` |
| cancel | `turn_cancelled` |
| malformed JSON | `malformed` |

事件 payload 应包含：

- `agent_id`
- `agent_kind`
- `session_id`
- `event`
- `timestamp`
- `payload`
- 可用时的 `usage`

当 ACP `session/prompt` 返回 `usage` 时，backend 必须把它提升到 `turn_completed` 事件顶层的 `usage` 字段，同时保留在 payload/raw 中。这样 Orchestrator 可以复用现有 token accounting，不需要为 ACP 单独开一条统计链路。

ACP session 与 Symphony turn 不能混为一谈。`acp_stdio` 会在同一个 worker attempt 内复用同一个 ACP session；每次 `run_turn/5` 都必须发出独立的 `turn_started`，完成时再发 `turn_completed`。Dashboard 和 Orchestrator 的 `turn_count` 应按 turn 事件递增，而不是按 `session_started` 递增。这样才能同时满足两个目标：同一个 issue 的多轮 continuation 保留上下文，状态页又能正确显示实际执行了几轮。

如果 agent 发起 Symphony 未支持的 client-side JSON-RPC request，backend 必须返回 JSON-RPC error，并记录 `unsupported_request`。禁止静默忽略带 `id` 的 request，因为这会让真实 agent 等待 response，最终把 turn 拖到 timeout。

stdio transport 必须按 ndjson framing 处理。backend 不能假设一次 port data 就是一条完整 JSON line；当 JSON line 被拆成多个 stdout chunk 时，client 需要缓冲尾部片段，直到收到换行后再解析。

如果同一个 stdout chunk 中目标 response 后面还跟着完整 notification 或 client request，backend 也必须处理这些剩余行，不能在命中 response 后直接丢弃。否则会造成可观测事件丢失，或者让 agent 发起的后续 request 得不到响应。

状态页需要对 ACP `session/update` 做最小 humanize：文本类 update 显示为 `agent update: ...`，tool call 类 update 显示为 `agent tool call: ...`。这样操作者能从 dashboard 直接判断 MiMo-Code 当前动作，而不是只看到原始协议方法名。

`acp_stdio` 还需要为 ACP `session/update` 记录低敏结构化日志，字段只包含 `agent_id`、`agent_kind`、`session_id`、`update_kind`、`tool_name`、`tool_status` 和 `error_category`。日志不得记录 update 文本、tool arguments、GraphQL query、MCP headers/env 或 Linear token。这样真实 MiMo-Code 出现 `Invalid Tool`、MCP 调用失败或长时间卡住时，可以从日志定位工具名和状态，而不扩大凭据或业务内容泄露面。

HTTP MCP `tools/call` 日志也需要写入低敏 `error_category`。当前分类包括：`none`、`invalid_arguments`、`graphql_errors`、`linear_api_status`、`linear_auth`、`linear_api_request`、`unsupported_tool` 和 `tool_error`。分类只能从工具结果结构推导，不得把 GraphQL query、variables、GraphQL error message、MCP headers/env、comment body 或 Linear token 写入日志。Linear 非 200 响应如果 body 中含 GraphQL `errors`，也归入 `graphql_errors`，日志只保留 HTTP status 和类别。这样 YQE-29/YQE-30 中类似 `outcome=error` 的失败调用可以继续细分原因，而不扩大日志泄漏面。

Linear request error 日志也必须先脱敏再写入。特别是 HTTP client 抛出的 header 校验错误可能携带 Authorization header 或 `lin_api_...` token 片段；日志中只能保留脱敏后的错误类别和安全上下文，调用方收到的原始错误 term 可以保持不变。

短期可以继续复用历史 `codex_app_server_pid` 字段承载子进程 pid，避免一次性重构 dashboard；长期再迁移为 `agent_process_pid`。

## 权限策略

ACP permission schema 与 Codex approval schema 不同，第一版不要隐式继承 Codex 策略。`acp_stdio` 单独支持：

| 策略 | 行为 |
| --- | --- |
| `reject` | 默认值。所有 permission request 自动拒绝，并记录 `permission_rejected`。 |
| `fail` | 收到 permission request 后当前 turn 失败，交给 retry/人工处理。 |
| `allow` | 自动允许 permission request，并记录 `approval_auto_approved`。 |

默认用 `reject`，原因是无人值守环境下 MiMo-Code/OpenCode 的权限语义尚未细分，保守拒绝比默认放行更可控。

当 `permission_policy: fail` 命中时，client 不应在发出 permission reply 后立刻停止读取 stdout。真实 agent 可能仍会继续发送当前 `session/prompt` 的 `session/update` 和最终 response；如果这些消息残留在 BEAM mailbox 中，会污染后续 `session/close` 或下一次 request。正确行为是记录待返回的 `permission_required` 错误，继续 drain 到当前 prompt 的目标 response，然后再向 backend 返回错误。

## 任务编排

### 阶段 0：前期调研门禁

目标：确认方案不会基于错误事实。

交付物：

- `elixir/docs/mimocode_acp_smoke_test.md`
- 记录 ACP 官方基本流程。
- 记录 MiMo-Code 源码中的 `acp` 命令能力。
- 记录真实 MiMo-Code 发布版对 `session/new.params.mcpServers` 的 schema 要求。
- 记录本机或 worker 环境是否存在 `mimo` 可执行文件。

验收：

- 如果 `mimo acp` 本机不可用，可以继续 fake server 开发，但真实验收标记为未通过。
- 如果 `mimo acp` 不支持 ACP v1 基本方法，暂停后续实现，回到设计文档修订。
- 如果真实 MiMo-Code 不接受 HTTP/SSE MCP descriptor，暂停 MCP 注入实现，回到设计文档重新评估工具通道。

### 阶段 1：配置和 backend 注册

目标：让 Symphony 配置层承认 `acp_stdio` 是合法 backend。

任务：

- `Config` 支持 `agents.<id>.kind = acp_stdio`。
- 校验 `args` 必须是字符串列表。
- 校验 `permission_policy` 只能是 `reject`、`fail`、`allow`。
- `Backend.module_for("acp_stdio")` 返回 `AcpStdio` backend。

验收：

- 错误配置会在 workflow validation 阶段失败。
- 正确配置可以被路由层解析。

### 阶段 2：ACP client 和 session backend

目标：用 fake ACP server 锁定 Symphony 侧协议行为。

任务：

- 实现 stdio JSON-RPC client。
- 支持 `initialize`、`session/new`、`session/prompt`、`session/cancel`、`session/close`。
- `session/new` 缺省发送 `mcpServers: []`，并在 `mcp.linear_tools: true` 时发送 HTTP `symphony-linear` descriptor。
- `session/close` 只在 agent 通过 `initialize.result.agentCapabilities.sessionCapabilities.close` 声明能力时发送；未声明时直接关闭 stdio port。
- 支持 notification 事件转发。
- 支持 permission policy。
- 支持 ACP prompt result usage，并将其映射到 Symphony `turn_completed.usage`。
- 支持对未知 client-side request 返回 JSON-RPC error，避免 agent 等待响应时卡死。
- 支持 stdio JSON line 拆包缓冲，避免半条 JSON 被误判为 malformed。
- 支持处理与目标 response 同 chunk 到达的后续完整 notification/client request。
- 支持 timeout 语义分层：`session/prompt` 超时后由 client 发送一次 `session/cancel`，backend 记录 `turn_cancelled`；`initialize`、`session/new` 和 `session/close` 超时不发送 cancel，只返回错误并清理子进程。
- `session/prompt` 的 timeout 必须按单个 turn 的总耗时计算，不能被持续到达的 `session/update` 续期；否则真实 agent 只要持续输出进度就可能绕过 turn timeout。
- 支持 `close_timeout_ms`：`session/close` 卡住时按配置超时，并用关闭 port、TERM、KILL 兜底回收 ACP 子进程。
- 支持 handshake 失败清理：`initialize` 或 `session/new` 失败后必须关闭已经启动的 ACP 子进程，避免留下孤儿 runtime。
- 实现 `AcpStdio.start_session/3`、`run_turn/5`、`stop_session/1`。

验收：

- fake ACP server 能完成启动、prompt、completion。
- fake ACP server 能断言 `mcpServers` 缺省为空数组，开启后包含 HTTP `symphony-linear` descriptor。
- malformed JSON 不会直接卡死 session。
- permission 的 `reject`、`fail`、`allow` 行为都有测试。
- ACP usage 会进入 backend 事件，供 Orchestrator token accounting 使用。
- 未支持的 agent -> client request 会产生 `unsupported_request` 事件并收到 JSON-RPC error response。
- 拆分到多个 stdout chunk 的 ACP JSON line 能正常合并解析，且不会产生误报 `malformed`。
- 与目标 response 同 chunk 的后续 `session/update` 能被记录为 `notification`。
- prompt timeout 会发送一次 cancel，记录 `turn_cancelled`，并返回明确错误；session startup/close timeout 不发送无效 cancel。
- 持续发送 `session/update` 但不返回 prompt response 的 fake server 仍会在配置的 turn timeout 到点后触发 `session/cancel`。
- close timeout 会在配置时间内返回，并确认 ACP 子进程被回收。
- 未声明 close capability 的 fake/真实 ACP server 不应收到 `session/close`。
- `initialize` 或 `session/new` 返回 error 时，backend/client 返回错误且 fake ACP 子进程退出。

### 阶段 3：AgentRunner、Linear 路由和 MCP 收尾验证

目标：证明 issue 可以被派给 MiMo-Code backend 承接，并且 MiMo-Code 可以通过高层 Linear MCP 工具完成 Linear 查询、评论和状态收尾；raw `linear_graphql` 保留为少见操作 fallback。

任务：

- 覆盖 `AgentRunner` 使用 `acp_stdio` session backend 的测试。
- 配置 `agent:mimo -> mimocode`。
- 使用 fake ACP server 做端到端 runner 测试。
- 提取 `linear_graphql` 为 backend-neutral `Agent.Tool` fallback，并新增 `linear_issue_read`、`linear_comment_create`、`linear_issue_update_state` 高层工具，让 Codex dynamic tool 和 MCP endpoint 共用。
- 实现 HTTP MCP endpoint `POST /mcp/linear-tools`，支持 `initialize`、`notifications/initialized`、`tools/list`、`tools/call`。
- 配置 `mcp.linear_tools: true` 时，在 ACP `session/new.params.mcpServers` 注入 HTTP MCP descriptor。
- 覆盖同一 ACP session 内连续两个 continuation turn 的状态计数测试，确保 `turn_count` 按 turn 递增。
- 覆盖 continuation guidance 使用 backend-neutral 文案，避免给 MiMo-Code 发送 Codex 专用措辞。
- 使用真实 `mimo` 执行 Linear issue smoke，issue 描述必须要求创建文件、优先用高层 Linear MCP 工具查询自身、评论结果并移出 active state。

验收：

- dashboard 或日志能看到 `agent_id=mimocode`、`agent_kind=acp_stdio`。
- 同一 worker attempt 内 continuation turn 复用同一个 ACP session。
- 同一 ACP session 内连续两个 `run_turn/5` 后，状态页和 Orchestrator snapshot 的 `turn_count` 显示为 2，而不是只显示 session 数。
- continuation prompt 不包含 `previous Codex turn` 这类 Codex 专用措辞，而是使用 `previous agent turn`。
- HTTP MCP endpoint 只暴露 `linear_issue_read`、`linear_comment_create`、`linear_issue_update_state` 和 raw fallback `linear_graphql`。
- MiMo-Code 能在 workspace 中创建或修改目标文件。
- MiMo-Code 能通过 MCP `linear_issue_read` 查询当前 issue。
- MiMo-Code 能通过 MCP `linear_comment_create` 评论 smoke 结果。
- MiMo-Code 能通过 MCP `linear_issue_update_state` 把 issue 移出 active state。
- 如果真实 MiMo-Code 不能调用 MCP tool，必须记录 session id、最后事件、workspace 结果和日志路径，并回到设计文档修订方案。

### 阶段 3B：MiMo-Code 文件落盘与任务理解稳定性收敛

目标：在高层 Linear MCP 工具已经可用的前提下，确认 MiMo-Code 能可靠完成 workspace 变更，再把 Linear issue 移出 active state。

背景：

- YQE-32 证明 `linear_issue_read`、`linear_comment_create`、`linear_issue_update_state` 可以被真实 MiMo-Code 调用，且 Linear 读、评、改状态均成功；但 MiMo-Code 过早移动到 `Done`，导致目标文件未落盘。
- YQE-33 在补强 terminal-last guidance 后不再是“terminal state 中途打断”问题，agent turn 正常完成；但目标文件仍未创建，MiMo-Code 会话摘要显示 `summary_files=0`，并且它把 issue 描述中的 `$fileName` / `$phrase` 当成字面变量或未知占位，转而验证已有 smoke 文件。
- 单独的真实 ACP 写文件探测显示，`mimo acp --pure` 加 `permission_policy: reject` 仍能通过 MiMo-Code 自身 `edit` 工具创建并读回临时文件，未触发权限拒绝。因此当前没有证据表明简单文件写入被 `--pure` 或 `reject` 阻断。
- YQE-34 使用明确字段模板复测通过：目标文件存在且内容精确一致，MiMo-Code session 数据库显示 `summary_files=1`，`linear_issue_read`、`linear_comment_create`、`linear_issue_update_state` 均成功，`linear_graphql` 和 `Invalid Tool` 未成为主路径。
- YQE-35 在 terminal no-retry 修复后再次复测通过：真实 `mimocode/acp_stdio` 仍能完成文件落盘、读回验证、Linear 评论和 `Done` 收尾；Orchestrator 在 terminal issue 快照下直接释放 claim，不再安排 1s continuation retry。
- 因此阶段 3B 的当前结论是：Linear MCP 工具通路可用，文件写入能力本身可用；通过明确字段模板和更直接的 runtime guidance，可以让 MiMo-Code 完成“文件先落盘、Linear 最后收尾”的闭环。

任务：

- 调研真实 MiMo-Code 在 ACP 模式下的文件写入/编辑工具、permission request、`--pure` 或等价隔离模式、cwd 处理和 `permission_policy: reject` 对写入行为的影响。
- 调整真实 smoke issue 描述模板，避免 `$fileName`、`$phrase` 这类容易被当作 shell/template 变量的写法；改用明确字段，例如“目标文件名：xxx”和“精确文件内容：xxx”。
- 在 smoke 描述中明确禁止用已有 `docs/` 文件替代目标文件，要求先创建或覆盖目标文件，再读取验证，最后评论和移动 terminal state。
- 将 runtime guidance 中的顺序约束表达为更直接的工作流：目标文件名和精确内容是字面任务数据，不得把 `$fileName` / `$phrase` 当成待解析变量；workspace 文件变更和验证完成前，不得调用 `linear_comment_create` 报告成功；所有 workspace 证据和评论完成前，不得调用 `linear_issue_update_state` 移动到 terminal state。
- 如果确认 `permission_policy: reject` 阻断了 MiMo-Code 的正常文件写入，需要先设计受限 permission 策略或 workspace-only 文件工具，再按 TDD 实现；不能直接把权限默认放宽。
- 如果确认 MiMo-Code ACP 模式无法可靠写 workspace 文件，再评估是否由 Symphony 暴露受限文件 MCP 工具。该方案会改变安全边界，必须单独设计和验收。

验收：

- 真实 `agent:mimo` issue 由 `mimocode/acp_stdio` 承接，dashboard 或日志能看到对应 `agent_id`、`agent_kind` 和 ACP session id。
- workspace 中存在 smoke 指定的目标文件，内容与 issue 描述中的精确内容完全一致。
- MiMo-Code 会话摘要或实际文件复验能证明本次运行产生了目标 workspace 变更；不能只验证历史已有文件。
- `linear_issue_read`、`linear_comment_create` 和 `linear_issue_update_state` 均能成功调用；`linear_issue_update_state` 必须是 terminal 收尾的最后一步。
- `linear_graphql` 调用应为 0 或仅作为明确 fallback；`Invalid Tool`、本地 `linear` / `push` skill 和 `bash` 探索不应成为完成任务的主路径。
- 如果 smoke 失败，必须记录 Linear issue、ACP session id、workspace 路径、目标文件复验结果和 MiMo-Code session 数据库摘要，再回到本文修订方案。

实测状态：

- YQE-34 已满足阶段 3B 验收，详细记录见 `elixir/docs/mimocode_acp_smoke_test.md`。
- YQE-35 已验证 terminal no-retry 修复在真实 `mimocode/acp_stdio` 路径生效，详细记录同样见 `elixir/docs/mimocode_acp_smoke_test.md`。
- 当前不需要为 MiMo-Code 设计受限文件 MCP 工具，也不需要放宽 `permission_policy: reject`。
- terminal issue 正常完成后的短暂 continuation retry 噪音已按 TDD 修正：AgentRunner 会把刷新后的 issue 快照回传给 Orchestrator；Orchestrator 在 worker 正常退出时若看到该 issue 已是 terminal state，会直接清理/释放 claim，不再排 continuation retry。active issue 的正常 continuation retry 行为保持不变。

### 原阶段 4：OpenCode 复用（本轮跳过）

本轮跳过。

原因：

- 当前目标是先把 MiMo-Code 跑通，避免同时处理两个 agent runtime 的差异。
- `acp_stdio` 应保持通用设计，但不把 OpenCode smoke 和兼容性调整纳入本轮验收。
- 等 MiMo-Code 的 ACP backend 稳定后，再用相同 backend 评估 `opencode acp`。如果只需配置即可复用，则新增文档和 smoke；如果行为不同，再补 provider-specific quirk。

执行口径：

- 本轮不创建 OpenCode 专项实现任务。
- 本轮不要求 `opencode acp`、`opencode serve` 或 OpenCode Linear issue smoke 通过。
- 任何 OpenCode 相关发现只记录为后续输入，不阻塞 MiMo-Code ACP 接入验收。
- `acp_stdio` 的接口设计仍保持 provider-neutral，避免写死 MiMo-Code 专用字段；但真实兼容性只以 MiMo-Code 为门禁。

## 验证命令

实现阶段至少运行：

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/acp_backend_registration_test.exs test/symphony_elixir/acp_stdio_client_test.exs test/symphony_elixir/acp_stdio_backend_test.exs test/symphony_elixir/acp_agent_runner_test.exs test/symphony_elixir/core_test.exs test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/dynamic_tool_test.exs test/symphony_elixir/agent_tool_test.exs test/symphony_elixir/mcp_server_test.exs test/symphony_elixir/extensions_test.exs'
```

以及：

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix specs.check'
```

真实 MiMo-Code smoke 在安装 `mimo` 后执行：

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mimo acp --help'
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && timeout 5s mimo acp --cwd "$PWD" < /dev/null || true'
```

真实 MiMo + MCP Linear issue smoke 需要在本地 Symphony 服务启动后执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\elixir\start-local.ps1 -Workflow .\elixir\WORKFLOW.local.md -Port 4000
curl.exe -sS -X POST http://127.0.0.1:4000/api/v1/refresh
curl.exe -sS http://127.0.0.1:4000/api/v1/state
```

测试 issue 必须带 `agent:mimo` 和 `symphony-local-test` label，并在描述中明确要求 MiMo-Code 优先使用 `linear_issue_read`、`linear_comment_create`、`linear_issue_update_state` 查询、评论和移动 issue 状态；`linear_graphql` 只作为 fallback。具体 smoke 流程见 `elixir/docs/mimocode_acp_smoke_test.md`。

本地真实 smoke 建议在 `elixir/WORKFLOW.local.md` 中开启：

```yaml
workspace:
  preserve_terminal: true
```

该开关只用于保留 terminal issue 的 evidence workspace，便于 MiMo-Code 把 issue 移到 `Done` 后继续复验文件内容。默认值为 `false`，因此不改变生产默认清理语义。

## 风险和处理

- MiMo-Code 发布版能力与源码不一致：先用 fake server 验证 Symphony 侧，再用真实 smoke 做门禁。
- ACP payload 与预期不一致：把差异记录到 smoke 文档，再调整 adapter，不改 Orchestrator。
- MiMo-Code 不调用 HTTP MCP endpoint：先确认注入的 descriptor 是否符合真实发布版 schema，再检查 MCP result wrapper，不改 Linear 工具核心。
- HTTP MCP endpoint 在 Windows/WSL 混合环境不可达：优先调整 `mcp.url`、服务端口或 bind host，不回退到 MiMo 当前不接受的 stdio MCP descriptor。
- permission 默认放行风险：第一版默认 `reject`。
- Windows/WSL PATH 和 cwd 差异：文档中明确运行环境和命令探测结果。
- dashboard 历史字段命名偏 Codex：第一版不重构，只保证新增事件带 `agent_id` 和 `agent_kind`。

## 相关文档

- `docs/superpowers/specs/2026-06-14-acp-mcp-linear-tools-design.md`：HTTP MCP `linear_graphql` 工具桥接的详细设计。
- `docs/superpowers/plans/2026-06-14-acp-mcp-linear-tools.md`：工具桥接实施计划和测试任务。
- `elixir/docs/mimocode_acp_smoke_test.md`：真实 MiMo-Code ACP 与 MiMo + MCP Linear issue smoke 记录。
- `elixir/docs/multi_agent_backends.md`：多 agent 配置、路由和 `acp_stdio` 使用说明。

## 当前结论

按 SPEC 的理念，最自洽的实现仍然是 `acp_stdio` session backend 加 HTTP MCP Linear 工具桥接。前者把 MiMo-Code 放在与 Codex 同一类“可调度 agent runtime”的位置，后者补齐 Codex dynamic tool 已经具备的 Linear 写回能力。YQE-29 到 YQE-31 证明 MiMo-Code 可以经 `agent:mimo` 路由承接 issue，并通过 HTTP MCP 写回 Linear；YQE-32/YQE-33 证明高层 Linear MCP 工具可被真实 MiMo-Code 调用，同时暴露了 terminal state 顺序和任务描述误读问题；YQE-34 进一步证明阶段 3B 补强有效，真实 MiMo-Code 能先完成目标文件落盘和读回验证，再使用 `linear_issue_read`、`linear_comment_create`、`linear_issue_update_state` 完成 Linear 收尾；YQE-35 证明 terminal no-retry 修复在真实 `mimocode/acp_stdio` 路径下生效。

因此，当前方案不需要回退到 `cli_run`，也不需要让 MiMo-Code 伪装成 Codex app-server。下一步如果继续打磨，应聚焦继续压缩 MiMo-Code 对非暴露工具的探索。OpenCode 复用只保留为后续占位，本轮不进入执行任务，也不作为验收条件。
