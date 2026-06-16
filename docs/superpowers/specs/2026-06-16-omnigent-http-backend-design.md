# Omnigent HTTP Backend 设计

## 目的

Symphony 需要把 Omnigent 接入为一个平级 agent backend。Omnigent 不是单一
CLI agent，而是一个下游编排平台 / meta-harness：它可以在自己的 session 中
运行 Claude Code、Codex、Cursor、Pi、OpenAI Agents、自定义 YAML agent，并
管理子 agent、runner、host、policy、terminal 和 SSE 事件。

本设计的第一阶段目标是：Linear 中只看到一个 `omnigent` agent 承接 issue；
Omnigent 内部如何派给 Codex、Claude、Cursor 等子 agent，先作为 Omnigent
session 内部细节处理，后续再单独设计可观测展开。

## 背景

当前 Symphony 已经具备多 agent backend 基础：

- `codex_app_server`：Codex app-server session backend。
- `cli_run`：一次性 CLI backend，用于快速验证非 Codex agent 承接 issue。
- `acp_stdio`：ACP stdio session backend，当前用于 MiMo-Code。
- backend-neutral Linear 工具层和 MCP Linear tools。
- Linear label / assignee / default agent 路由。

Omnigent 仓库暴露的能力和 MiMo-Code/OpenCode 不同：

- `omnigent run path/to/agent.yaml` 可以运行自定义 agent。
- `omnigent server start` 启动本地 HTTP server 和 web UI。
- `omnigent host` 注册本机为 runner host。
- `/v1/sessions` 是 session-first API，支持创建 session、绑定 runner、
  post event、SSE stream、fork、interrupt、stop。
- Agent YAML 可以声明 executor、model、tools、sub-agent、policy、
  `os_env` 和 terminals。

因此，Omnigent 不应被压扁成普通 `cli_run`，也不应伪装成 Codex app-server
或 ACP runtime。它更适合以 HTTP session backend 的方式接入。

## 产品模型

Symphony 的工作单元仍然是 Linear issue。一个 issue 在一次 worker attempt
内只由一个顶层 backend 拥有。

当 Linear issue 通过 label、assignee 或默认规则路由到 `omnigent` 时：

1. Symphony 创建 issue workspace 并渲染标准 issue prompt。
2. Symphony 创建或复用一个 Omnigent 顶层 session。
3. Symphony 把 prompt 作为 user message 投递给 Omnigent session。
4. Omnigent 在内部运行它自己的 orchestrator agent。
5. Omnigent 内部可以启动 Codex / Claude / Cursor / Pi 等 child sessions。
6. Symphony 第一阶段只记录顶层 Omnigent session 的状态和输出。
7. Linear 的状态流转仍由顶层 attempt 与 issue terminal state 决定。

第一阶段不把 Omnigent child session 映射为 Linear 子 issue，也不让 Symphony
调度 Omnigent 内部子 agent。

## 方案取舍

### 方案 A：`omnigent_http` session backend（推荐）

新增 `omnigent_http` backend，通过 Omnigent Server API 创建 session、发送
message、消费 SSE、interrupt/stop。

优点：

- 符合 Omnigent 作为 meta-harness 的定位。
- 能保留 session id、stream、status、fork、interrupt 等协议能力。
- 与 Symphony 现有 session backend 模型接近。
- 后续可以增量展开 child session 可观测性。

代价：

- 需要实现 HTTP client、SSE reader、snapshot/reconnect、bundle upload。
- 需要明确 Omnigent server / host 的启动前置条件。

### 方案 B：`cli_run` 调用 `omnigent run`

用现有 CLI backend 执行 `omnigent run ... -p <prompt>`。

优点：

- 实现最快。
- 可用于 smoke test，验证 Omnigent 能否完成一个 issue。

代价：

- 缺少稳定 session lifecycle、SSE、interrupt、reconnect、child event。
- 无法体现 Omnigent 作为服务型编排平台的优势。
- 不适合作为正式接入目标。

### 方案 C：双层编排映射

把 Omnigent child session 映射为 Symphony 子运行记录，甚至同步成 Linear
子 issue 或 comment thread。

优点：

- 长期可观测性最好。
- 可以让人类看到 Omnigent 内部每个 agent 的任务边界。

代价：

- 会打破当前“一次 attempt 一个 backend owner”的简单模型。
- 需要重新设计 child ownership、失败归因、权限、状态同步和 Linear 表达。
- 第一阶段范围过大。

结论：第一阶段采用方案 A，并为方案 C 预留事件字段和 raw payload。

## 架构

新增 backend：

```elixir
SymphonyElixir.Agent.Backend.OmnigentHttp
```

新增协议 client：

```elixir
SymphonyElixir.Agent.Omnigent.Client
```

职责边界：

- `OmnigentHttp` 负责适配 Symphony backend contract、agent config、事件标注
  和 turn result。
- `Omnigent.Client` 负责 Omnigent HTTP / SSE 协议、请求构造、响应解析、
  stream 消费、snapshot 和重连。
- `AgentRunner` 继续负责 Linear active-state continuation、workspace 生命周期、
  retry 和顶层 attempt 状态。
- Omnigent server / host 的启动不由第一版 backend 自动管理；第一版要求用户
  已经通过 `omnigent server start` 和必要的 `omnigent host` 准备好运行环境。

backend 实现 session backend 接口：

```elixir
start_session(workspace, resolved_agent, opts)
run_turn(session, workspace, issue, prompt, opts)
stop_session(session)
```

## 配置

第一版新增 agent kind：

```yaml
agents:
  omnigent:
    kind: omnigent_http
    base_url: "http://127.0.0.1:6767"
    host:
      mode: external
      host_id: null
      workspace: "{{workspace}}"
    agent:
      type: bundle_path
      path: "C:/Users/GQY47/coding/omnigent/examples/polly"
    timeout_ms: 3600000
    stream_timeout_ms: 600000

routing:
  by_label:
    "agent:omnigent": omnigent
```

字段语义：

- `kind`: 必须是 `omnigent_http`。
- `base_url`: Omnigent server base URL。
- `host.mode`: 第一版支持 `external`，表示使用已经通过 `omnigent host`
  注册到 server 的机器。
- `host.host_id`: 可选。设置时直接传给 Omnigent session create；未设置时，
  backend 查询 Omnigent hosts，并且只有在恰好一个 online host 可用时自动选择。
- `host.workspace`: Omnigent host 侧的绝对工作目录。默认使用 Symphony issue
  workspace，适合 Symphony 与 Omnigent host 在同一文件系统上运行的本地场景。
- `agent.type`: 第一版支持 `bundle_path`。
- `agent.path`: 本地 Omnigent agent 目录或 bundle 源路径。
- `timeout_ms`: 单个 Symphony turn 的总超时。
- `stream_timeout_ms`: SSE 没有有效事件时的等待上限。

后续可以增加：

- `agent.type: agent_id`，复用 Omnigent 已注册 agent。
- `host.mode: managed`，让 Omnigent server 按自身 sandbox 配置创建 managed host。
- `model_override` / `reasoning_effort`，映射到 Omnigent session metadata 或
  PATCH 字段。
- `auth`，用于远程或开启认证的 Omnigent server。

## 运行流程

### 启动 session

`start_session/3` 执行：

1. 读取 `base_url`、agent bundle 配置和 timeout 配置。
2. 解析 host。若配置了 `host.host_id`，直接使用；否则查询 Omnigent hosts，
   并且只有恰好一个 online host 时自动选择。
3. 解析 `host.workspace`，把 `{{workspace}}` 替换为 Symphony issue workspace。
4. 如果 `agent.type == "bundle_path"`，把 agent 目录打包为 Omnigent bundle。
5. 调用 `POST /v1/sessions` 创建 session，并传入 `host_id` 与 `workspace`。
6. 保存 Omnigent session id。
7. 返回包含 session id、base URL、host id、workspace、agent identity 和 timeout
   的 session map。

如果没有 online host，或者有多个 online host 但未配置 `host.host_id`，backend
应清晰失败并提示用户运行 `omnigent host` 或显式配置 host id。第一版不自动启动
Omnigent server / host。

### 执行 turn

`run_turn/5` 执行：

1. 打开或维护 `GET /v1/sessions/{id}/stream`。
2. POST `message` event 到 `/v1/sessions/{id}/events`。
3. 消费 SSE event。
4. 聚合 assistant text delta 和 response item。
5. 遇到 `response.completed` 时返回 `{:ok, result}`。
6. 遇到 `response.failed` 时返回 `{:error, reason}`。
7. 遇到 `response.incomplete` 时按 reason 映射为 cancelled 或 failed。
8. turn 完成后交回 `AgentRunner`，由现有 Linear active-state 判断是否继续。

continuation turn 必须复用同一个 Omnigent session。

### 停止 session

`stop_session/1` 执行：

1. 如果 turn 正在运行，先 POST `interrupt`。
2. 需要硬停时 POST `stop_session`。
3. 记录停止结果；如果 Omnigent 返回失败，保留错误摘要但不阻塞本地清理。

## 事件映射

Symphony 第一版使用 backend-neutral event：

| Omnigent 事件 | Symphony 事件 |
| --- | --- |
| session 创建成功 | `session_started` |
| `session.status=running` | `turn_started` 或 `notification` |
| `session.status=waiting` | `turn_waiting` 或 `notification` |
| `response.output_text.delta` | `notification` |
| `response.output_item.done` | `notification` |
| `response.completed` | `turn_completed` |
| `response.failed` | `turn_failed` |
| `response.incomplete` | `turn_cancelled` 或 `turn_failed` |
| `session.created` | `child_session_observed` |
| SSE 断线 | `stream_disconnected` |

事件字段：

```elixir
%{
  agent_id: "omnigent",
  agent_kind: "omnigent_http",
  session_id: omnigent_session_id,
  event: :turn_completed,
  payload: payload,
  timestamp: DateTime.utc_now()
}
```

`session.created` 第一版只作为 raw child event 记录，不改变 Symphony 调度状态，
不创建 Linear 子 issue。

## 成功判定

Omnigent turn 完成只表示 Omnigent runtime 完成本轮 prompt。是否继续工作仍由
现有 `AgentRunner` 判断：

1. 刷新 Linear issue。
2. 如果 issue 仍处于 active state 且仍路由到 `omnigent`，进入 continuation。
3. 如果 issue 已 terminal、不可路由或达到 `agent.max_turns`，结束 attempt。

这样可以避免把“Omnigent response completed”误判为“Linear issue 已完成”。

## 错误处理

配置错误：

- 未知 `kind`: 配置验证失败。
- `base_url` 为空或非法：配置验证失败。
- `host.mode` 不是 `external`：第一版配置验证失败。
- `host.workspace` 为空：配置验证失败。
- `agent.type` 未知：配置验证失败。
- `bundle_path` 不存在：配置验证失败或 startup failed。

运行错误：

- Omnigent server 不可达：startup failed，进入现有 retry。
- 没有 online host 或 host 选择不唯一：startup failed，提示配置 `host.host_id`。
- bundle 上传或 session 创建失败：startup failed，记录 HTTP status 和响应摘要。
- stream 建立失败：turn failed 或按 retry 策略重试连接。
- SSE 中断：先重连 stream，再 GET snapshot 做恢复；超过预算后 turn failed。
- turn timeout：先 POST `interrupt`，再 POST `stop_session`，最后返回 timeout error。
- Omnigent 内部 child agent 失败：第一版只作为顶层 response/error 内容处理。
- malformed event：记录 `malformed`，无法继续解析时 turn failed。

## 安全和权限

第一版不把 Linear token 或 Symphony 内部工具直接注入 Omnigent。Omnigent 如果需要
读写 Linear，应通过它自己的环境、工具或后续单独设计的受控 MCP/tool bridge。

原因：

- Omnigent 是下游编排平台，内部可再调用多个 agent。直接暴露 Symphony 的全部
  Linear 写权限会扩大权限面。
- 当前目标是先验证顶层 session backend，而不是复刻 Codex dynamic tool。
- 后续如果需要 Linear 写回，应复用 backend-neutral Linear tool 层，并设计显式
  授权和最小工具集。

## 测试策略

优先使用 fake Omnigent server，锁定 Symphony 侧行为：

- 配置允许 `kind: omnigent_http`。
- label `agent:omnigent` 路由到 Omnigent backend。
- `start_session/3` 能创建 fake session。
- `run_turn/5` 能 POST message 并消费 fake SSE completion。
- continuation turn 复用同一个 session id。
- `response.failed` 映射为 turn failed。
- `response.incomplete` 映射为 cancelled 或 failed。
- `session.created` 只产生 `child_session_observed`，不创建子 issue。
- timeout 会发送 interrupt / stop。
- orchestrator running snapshot 包含 `agent_id=omnigent`、`agent_kind=omnigent_http`
  和 Omnigent session id。

真实 smoke test 文档覆盖：

1. 启动 `omnigent server start`。
2. 启动或确认 `omnigent host` 可用。
3. 配置 `agent:omnigent -> omnigent`。
4. 创建测试 Linear issue 并添加 `agent:omnigent`。
5. 观察 dashboard / log，确认执行 agent 是 `omnigent_http`。
6. 确认 Omnigent session 收到 prompt，并返回 completion 或明确失败原因。

## 实施顺序

1. 扩展配置 schema 和验证，允许 `omnigent_http`。
2. 新增 backend dispatcher 映射。
3. 增加 fake Omnigent server 测试夹具。
4. 实现 `Omnigent.Client` 的 create session、post event、SSE stream。
5. 实现 `OmnigentHttp.start_session/3`。
6. 实现 `OmnigentHttp.run_turn/5` 的 completion / failure / timeout。
7. 实现 `stop_session/1` 的 interrupt / stop。
8. 接入 backend-neutral 事件 annotation。
9. 增加配置示例和 smoke 文档。
10. 运行真实 Omnigent 本地 smoke，记录能力缺口。

## 非目标

第一阶段不做：

- 自动安装或登录 Omnigent。
- 自动启动 Omnigent server / host。
- 把 Omnigent child session 映射成 Linear 子 issue。
- 让 Symphony 直接调度 Omnigent 内部 Codex / Claude / Cursor 子 agent。
- 把 Symphony `linear_graphql` 工具直接注入 Omnigent。
- 完整 dashboard 命名迁移。

## 验收标准

- `WORKFLOW` 可以声明 `agent.kind = omnigent_http`。
- Linear issue 加 `agent:omnigent` 后由 Omnigent backend 执行。
- dashboard 或日志显示 `agent_id=omnigent`、`agent_kind=omnigent_http`。
- backend 记录 Omnigent session id。
- fake server 测试覆盖 session 创建、message、stream completion、failure、
  timeout、stop 和 child event。
- 一个 worker attempt 内 continuation turn 复用同一个 Omnigent session。
- Omnigent child event 被记录但不会创建 Linear 子 issue。
- 本地 smoke 文档说明 Omnigent server / host 启动和 Linear 测试步骤。

## 后续方向

第二阶段可以单独设计 child session 可观测性：

- 把 Omnigent `session.created` 映射成 Symphony 子运行记录。
- 在 dashboard 展示 Omnigent 内部 child agent、harness、状态和输出摘要。
- 可选地把 child session 摘要写回 Linear comment。
- 评估是否需要把 Omnigent child session 映射成 Linear 子 issue。

这部分应作为独立设计处理，避免第一阶段破坏顶层 issue ownership 模型。
