# Agent Runtime 能力边界对比

本文用于后续实现和决策：比较 `cli_run`、ACP stdio、HTTP server 三种接入方式与 Codex app-server 的差异，判断它们能满足 Symphony 多 agent 编排需求的程度。

## 结论

当前最稳妥的路线是：

1. 保留 `cli_run` 作为最小可用兜底，用于验证 Linear issue 可以被路由给 MiMo-Code/OpenCode。
2. 已实现通用 `acp_stdio` backend，并以 `mimo acp` 作为本轮真实兼容性门禁；`opencode acp` 复用留到后续阶段。
3. HTTP server backend 适合作为后续增强，用在需要共享常驻服务、远程 attach、或更完整 HTTP 可观测能力的场景。
4. 不建议让 MiMo-Code/OpenCode “伪装成 Codex app-server”。更清晰的模型是：Symphony 内部抽象 backend-neutral 的 agent event，再分别适配 Codex app-server、ACP、HTTP server。

简化判断：

| 接入方式 | 当前状态 | 是否适合现在用 | 是否适合长期平级 agent |
| --- | --- | --- | --- |
| Codex app-server | 已实现 | 是 | 是，当前基准 |
| `cli_run` | 已实现 | 是，兜底 | 部分适合，控制面偏薄 |
| ACP stdio | 已实现，MiMo-Code smoke 已通过 | 是，MiMo-Code 首选 | 是，优先方向 |
| HTTP server | 未实现 | 不建议先做 | 是，但实现和运维复杂度更高 |

## Symphony 需要的能力

从 `SPEC.md` 和当前 Elixir 实现看，Symphony 对 agent backend 的核心要求不是“能跑一个命令”这么简单，而是：

- 每个 Linear issue 拥有独立 workspace。
- issue 在一次 attempt 内由一个明确的 agent backend 承接。
- backend 能接收渲染后的 issue prompt。
- backend 能给出可判定的成功、失败、取消、超时信号。
- backend 能输出结构化事件，供 orchestrator、dashboard、日志和排障使用。
- backend 能在 issue 仍处于 active state 时继续工作，理想情况下复用同一个 live session。
- backend 能处理或明确拒绝审批、权限、用户输入等会导致无人值守运行卡住的请求。
- backend 能暴露 session id、进程 id、token/usage 等可观测信息。
- backend 能在超时、取消、状态变更时被可靠停止。

Codex app-server 是当前基准，因为 `SPEC.md` 明确把 targeted Codex app-server protocol 作为协议 schema、payload、framing 和 method name 的 source of truth。

## Codex app-server

`codex app-server` 是 Codex CLI 自带的协议服务模式。它不是普通交互 CLI，而是由 CLI binary 启动的长期 JSON-RPC runtime。

当前 Symphony 的 `codex_app_server` backend 包装 `SymphonyElixir.Codex.AppServer`，后者通过 stdio 发送：

- `initialize`
- `thread/start`
- `turn/start`

并从 Codex app-server 读取结构化 JSON-RPC 响应和通知。

Codex app-server 的优势：

- 有明确协议 schema，可通过 `codex app-server generate-json-schema --out <dir>` 生成。
- 支持 stdio、unix socket、websocket 等 transport；Symphony 当前使用 stdio。
- 有 thread/turn 身份，适合表达一个 worker attempt 内的多 turn continuation。
- approval、sandbox、cwd、prompt input、dynamic tools 都属于协议控制面。
- Symphony 可以注入 `linear_graphql` 这类 client-side dynamic tool。
- token usage、turn completion、turn failure、input required 等事件可以进入统一可观测链路。

边界：

- 这是 Codex 专用协议，不是通用 agent 标准。
- MiMo-Code/OpenCode 不能直接替换成 `codex.command`，除非它们真的实现兼容 Codex app-server 的 JSON-RPC 协议。

## `cli_run`

`cli_run` 是当前已经实现的最小通用 backend。它的行为是：在 issue workspace 中启动一个配置好的命令，把 prompt 作为最后一个 argv 传入，读取 stdout/stderr，进程退出码为 `0` 时视为成功。

典型配置：

```yaml
agents:
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
```

OpenCode 可使用同类形态：

```yaml
agents:
  opencode:
    kind: cli_run
    command: "opencode"
    args:
      - "run"
      - "--format"
      - "json"
      - "--agent"
      - "build"
      - "--dir"
      - "{{workspace}}"
```

它能满足的需求：

- 可以把 Linear issue 路由给 MiMo-Code/OpenCode。
- 可以保证命令运行在 per-issue workspace。
- 可以捕获 JSON line 或普通文本输出。
- 可以按 timeout 杀进程树。
- 可以根据退出码进入 retry/error 流程。
- 可以从输出中机会性提取 `sessionID`、`session_id` 和 token usage。

它不能很好满足的需求：

- 没有协议级 session 生命周期。当前 `session_id` 主要是 synthetic id 或从输出中机会性提取。
- continuation 不是同一个 live session。`agent.max_turns` 再次触发时会重新启动命令，除非未来显式保存并传递 `--session`。
- 退出码 `0` 不等价于 Linear issue 已完成。agent 可能没有改状态，也可能只输出“完成”。
- 权限/审批/用户输入没有统一协议；如果 CLI 自己等待交互输入，Symphony 只能靠 timeout。
- 工具调用、diff、file edit、bash、permission 等细粒度事件只能看 CLI 输出格式，无法保证稳定。
- token/rate-limit 统计只能依赖 CLI 输出是否包含可识别字段。

适用判断：

- 适合快速验证“MiMo/OpenCode 能不能作为平级 backend 承接 issue”。
- 适合低风险、短任务、非交互、可通过退出码判断的任务。
- 不适合作为长期目标里的完整 agent runtime。

## ACP stdio

MiMo-Code 和 OpenCode 源码都暴露了 `acp` 命令，使用 `@agentclientprotocol/sdk`，通过 stdio 上的 newline-delimited JSON stream 建立 Agent Client Protocol 连接。它们内部会启动或连接自己的 server，再把 ACP 请求映射到内部 session/prompt/event/permission 体系。

已观察到的能力包括：

- `initialize`
- `session/new`
- `session/load`
- `session/list`
- `session/resume`
- `session/close`
- `session/fork`
- `session/prompt`
- `session/cancel`
- set model / set mode / set config option
- `sessionUpdate` 事件
- tool call update
- permission request / reply

它能满足的需求：

- 可以作为真正的 session backend，而不是一次性命令。
- stdio transport 与 Codex app-server 当前部署模型接近，不需要额外端口。
- session id 是协议对象，适合放进 dashboard/log/retry 记录。
- prompt、cancel、permission、tool update 都有明确控制面。
- `session/set_config_option` 可以承载模型等 session 级配置；Symphony 用 `config_options` 映射到 `configId` / `value`。
- 可以在一个 worker attempt 内保持同一 ACP session，并映射 Symphony continuation turn。
- 适合作为 MiMo-Code/OpenCode 平级 agent 的首选接入层。

主要差异和缺口：

- ACP 不是 Codex app-server。method、payload、completion signal、permission schema 都需要 adapter 映射。
- Codex 的 `thread/start` / `turn/start` 概念需要映射到 ACP `session/new` / `session/prompt`。
- Codex dynamic tools 不能原样复用。`linear_graphql` 如果要给 ACP agent 用，需要另走 MCP、内置 HTTP tool、或 ACP client capability 的扩展设计。
- approval/sandbox 语义不同。需要给 `acp_stdio` backend 明确配置：哪些权限自动允许、哪些拒绝、哪些导致 blocked。
- 需要确认 MiMo-Code 当前发布版本与源码能力一致；不能只看仓库源码。

当前 `acp_stdio` 实现保持通用配置形态：

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
    config_options:
      model: "mimo/mimo-auto"
    timeout_ms: 3600000
```

同一个 backend 设计上应保留接 OpenCode 的空间，但本轮不做 OpenCode smoke。后续可用类似配置验证：

```yaml
agents:
  opencode:
    kind: acp_stdio
    command: "opencode"
    args:
      - "acp"
      - "--cwd"
      - "{{workspace}}"
```

实现要点：

- 启动 stdio subprocess。
- 发送 ACP initialize。
- 创建 session，传入 workspace/cwd、必要 client capabilities 和 `mcpServers` 数组。
- session 创建后按 `config_options` 发送 `session/set_config_option`。
- 对每个 Symphony turn 发送 ACP prompt。
- 监听 `session/update`，映射成 Symphony agent event 和低敏结构化日志。
- 将 ACP stop reason 映射为 success/failure/cancel。
- 将 permission request 映射为 auto approve、reject、blocked 或 fail。
- timeout 时发送 cancel，并兜底 kill 进程。
- 将 ACP session id 暴露为 `session_id`。
- 通过 HTTP MCP endpoint 向 MiMo-Code 暴露 `linear_issue_read`、`linear_comment_create`、`linear_issue_update_state` 和 raw fallback `linear_graphql`。

## HTTP server

MiMo-Code 和 OpenCode 都有 `serve` 命令。OpenCode 当前 OpenAPI 暴露了丰富的 session 与 event 端点，例如：

- `/event`
- `/global/event`
- `/session`
- `/session/status`
- `/session/{sessionID}/message`
- `/session/{sessionID}/prompt_async`
- `/session/{sessionID}/abort`
- `/session/{sessionID}/fork`
- `/permission/{requestID}/reply`

MiMo-Code 的 server 代码也采用相同类型的 Hono route 结构，并有 session、event、permission、question 等路由。

它能满足的需求：

- 可以用 HTTP 明确创建 session、发送 message、abort、fork。
- SSE event stream 适合做实时 dashboard 和排障。
- permission reply 有独立端点，适合无人值守策略化处理。
- 可以选择连接已有 server，而不是每个 issue 启动一个进程。
- 对远程 worker 或桌面 app 场景可能更自然。

主要差异和缺口：

- 相比 stdio，多了端口、认证、服务生命周期和安全边界。
- 需要决定 server 粒度：每个 issue 一个 server、每个 worker 一个 server，还是连接外部常驻 server。
- per-issue workspace 要通过 `--dir`、directory header、或 session 创建参数精确传递，不能依赖 ambient cwd。
- SSE 订阅、断线重连、心跳、事件去重都会增加复杂度。
- 对 SSH worker 更复杂：要么远端启动 server 并转发端口，要么本地只用 stdio 更简单。
- 仍然不是 Codex app-server，需要事件和权限语义映射。

适用判断：

- 不建议作为 MiMo/OpenCode 的第一优先实现。
- 适合后续需要共享常驻 agent server、远程 attach、多客户端 UI、或者比 ACP 更完整 HTTP observability 的场景。

## 能力矩阵

| 需求 | Codex app-server | `cli_run` | ACP stdio | HTTP server |
| --- | --- | --- | --- | --- |
| Linear issue 路由到平级 agent | 已满足 | 已满足 | 可满足 | 可满足 |
| per-issue workspace | 已满足 | 已满足 | 可满足 | 可满足，但要显式传 directory |
| 非交互启动 | 已满足 | 可满足，取决于 CLI 参数 | 可满足 | 可满足 |
| 长期 session 生命周期 | 已满足 | 弱 | 强 | 强 |
| 同一 attempt 内 continuation | 已满足 | 弱，当前会重启命令 | 强 | 强 |
| 结构化事件流 | 已满足 | 部分，依赖 stdout 格式 | 强 | 强 |
| completion/failure/cancel | 已满足 | 部分，主要靠退出码 | 强 | 强 |
| permission/approval | 已满足 | 弱，主要靠 timeout | 强，需要策略映射 | 强，需要策略映射 |
| sandbox/cwd 控制 | 已满足 | 部分，靠 cwd/参数 | 部分，靠 cwd/agent 自身 | 部分，靠 directory/session 参数 |
| dynamic tools / `linear_graphql` | 已满足 | 不支持协议级工具 | 不直接支持，需要另设通道 | 不直接支持，需要另设通道 |
| token/usage 统计 | 已满足 | 弱，机会性提取 | 中到强，需映射 ACP usage | 中到强，需映射 event/schema |
| abort/timeout | 已满足 | 可杀进程树 | 可 cancel + kill | 可 abort + 停 server |
| 实现复杂度 | 已完成 | 已完成 | 中 | 高 |
| 推荐优先级 | 基准 | 兜底 | 已落地，MiMo-Code 首选 | 后续增强 |

## 对当前需求的满足程度

如果目标是“我能在 Linear 上给 issue 打 `agent:mimo`，然后 Symphony 让 MiMo-Code 执行”，当前首选是 `acp_stdio`。`cli_run` 仍可作为兜底，但它的问题不是路由，而是执行质量、session 控制面和完成判定较弱。

如果目标是“MiMo/OpenCode 与 Codex 一样是可编排 agent runtime”，`cli_run` 不够，ACP stdio 是当前已经落地的合理层。它能提供 session、prompt、update、permission、cancel 等控制面，足够支撑平级 agent 的核心模型。

如果目标是“构建一个可被 UI/服务共享的 OpenCode/MiMo runtime，并充分利用其 HTTP API”，HTTP server 能满足更多运维和可观测需求，但不适合作为第一步。

## 推荐实施顺序

1. 已明确保留 `cli_run` 文档定位：兜底 runner，不承诺完整 runtime 能力。
2. 已新增 `acp_stdio` backend：
   - `Backend.module_for("acp_stdio")` 已映射到 ACP backend。
   - 已按现有 `session_backend?` 约定实现 `start_session/3`、`run_turn/5`、`stop_session/1`。
   - 已把 ACP session id、session update、tool update、permission request 映射为 Symphony agent event。
   - 已增加 fake ACP server 测试，不依赖真实 MiMo/OpenCode。
3. 已用真实 `mimo acp` 做 smoke test：
   - 测试 issue 设置 `agent:mimo` label。
   - dashboard/log 中可确认 `agent_id=mimocode` 和 `agent_kind=acp_stdio`。
   - YQE-34 证明 ACP session、事件流、目标文件落盘、Linear 评论和 terminal 状态收尾均可闭环。
4. OpenCode 复用本轮跳过。等 MiMo-Code 的 ACP backend 继续稳定后，再用真实 `opencode acp` 评估是否能直接复用同一 backend。
5. 只有在 ACP 不能满足“远程共享 server / UI 复用 / 更完整 inspect API”时，再实现 HTTP server backend。

## 待确认问题

- OpenCode 的 `acp`/`serve` 真实发布版能力是否能直接复用当前 `acp_stdio` backend。
- ACP permission policy 是否需要在 `reject` / `fail` / `allow` 之外继续细化为更安全的 workspace-only 策略。
- 是否需要把 dashboard/API 中历史遗留的 `codex_*` 字段逐步迁移为 `agent_*`，以降低多 agent 语义噪音。
- 是否需要在真实 smoke 中继续压缩 MiMo-Code 对未暴露工具的探索。

## 经验转设计约束

MiMo-Code 接入过程中暴露的问题不都意味着要更换 backend。后续评估 `cli_run`、ACP stdio 或 HTTP server 时，优先按下列约束判断：

- `cli_run` 能证明 issue 路由和非交互命令执行可用，但不能证明该 agent 已具备长期 runtime 控制面。只要问题涉及 session 复用、permission、cancel、tool event 或 completion 语义，就不应把 `cli_run` 结果视为上限。
- ACP stdio 与 Codex app-server 处在相近抽象层级，但不是同一协议。正确做法是 adapter 映射，而不是让 MiMo-Code/OpenCode 伪装成 Codex app-server。
- Linear 写回能力应作为 backend-neutral 工具暴露。ACP agent 通过 MCP 使用高层 Linear 工具；Codex app-server 通过 dynamic tool 包装同一业务核心。不要把 Linear 工具逻辑写进某个 provider backend。
- terminal tracker state 是 orchestration 控制信号。任何 backend 如果能更新 Linear 状态，都必须把 terminal transition 放在 workspace evidence、验证和评论之后。
- 真实 provider 差异只能通过真实安装版 smoke 定论。Fake server 负责锁定 Symphony 协议行为，不能替代 `mimo acp` 或未来 `opencode acp` 的真实兼容性门禁。
- Provider quirk 优先进入 backend adapter、配置和测试；只有跨 backend 的稳定不变量才应提升到 `SPEC.md`。

## 决策建议

短期：MiMo-Code 优先使用 `acp_stdio + HTTP MCP Linear tools`。`cli_run` 仅作为兜底 runner，不用于衡量 MiMo/OpenCode 作为 runtime 的上限。

中期：继续保持 `acp_stdio` provider-neutral，并在 MiMo-Code 路径稳定后单独验收 OpenCode 复用。

长期：如果需要服务化共享、远程 attach 或更丰富 UI/API，再实现 HTTP server backend。届时应把 server lifecycle、认证、端口、SSE 可靠性作为一等设计问题处理。
