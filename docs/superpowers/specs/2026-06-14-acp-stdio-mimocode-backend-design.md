# ACP Stdio MiMo-Code Backend 设计

## 目的

Symphony 需要让 MiMo-Code 以平级 agent 的身份接入当前编排体系。目标不是让 Codex 把 MiMo-Code 当作工具调用，也不是让 MiMo-Code 伪装成 Codex app-server，而是在 Symphony 内部新增一个通用的 ACP stdio backend，把 MiMo-Code 暴露出的 ACP 能力映射到 Symphony 已有的 agent session 抽象。

本设计聚焦 MiMo-Code。OpenCode 复用同一 backend 的工作作为原阶段 4 后续占位保留，本轮先跳过，不纳入实现范围或验收条件。

## 背景

当前 Symphony 的 SPEC 把 Codex app-server 作为 Codex 集成的协议事实来源。Elixir 实现中，`SymphonyElixir.AgentRunner` 已经支持两类 backend：

- 一次性 backend：实现 `run_issue/5`。
- session backend：实现 `start_session/3`、`run_turn/5`、`stop_session/1`。

Codex app-server backend 已经采用 session backend 形态。MiMo-Code 当前通过 `cli_run` 可以作为兜底 runner 承接 Linear issue，但 `cli_run` 缺少长期 session、协议级 completion、permission、cancel、结构化事件等能力。因此，若目标是让 MiMo-Code 像 Codex 一样稳定承接 Symphony issue，下一步应该接入 ACP stdio，而不是继续强化一次性 CLI runner。

## 范围

本轮包含：

- 新增 `acp_stdio` agent backend kind。
- 实现 MiMo-Code 的 ACP stdio session backend。
- 在同一个 worker attempt 内保持 ACP session，用于 Symphony continuation turn。
- 将 ACP session、prompt、update、permission、cancel、completion 映射到 Symphony backend 结果和 agent event。
- 支持通过现有 Linear label/assignee/default routing 把 issue 分配给 MiMo-Code。
- 提供 fake ACP server 测试，优先验证 Symphony 侧协议行为。
- 提供真实 `mimo acp` smoke test 文档或脚本入口，用于人工验证。

本轮不包含：

- OpenCode 接入。
- HTTP server backend。
- 把 Codex dynamic tool 原样暴露给 MiMo-Code。
- MiMo-Code 自动安装、登录或模型配置。
- 多 agent 在同一个 Linear issue 内直接互相嵌套调用。
- 完整 dashboard 命名迁移，例如把历史 `codex_*` 字段一次性改成 `agent_*`。

## 产品模型

Symphony 的工作单元仍然是 Linear issue。一个 issue 在一次 worker attempt 内只由一个 agent backend 拥有。MiMo-Code 和 Codex 在配置上是平级 agent：

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
    timeout_ms: 3600000

routing:
  default_agent: codex
  by_label:
    "agent:mimo": mimocode
    "agent:codex": codex
```

如果 Codex 需要把工作交给 MiMo-Code，推荐方式仍然是通过 Linear 创建、标记或分配 issue。Symphony 轮询后根据路由规则把 issue 派给 `mimocode`。这样任务边界、负责人和状态变化都保留在 Linear 中，符合 SPEC 中对可审计编排的定位。

## 架构

新增 backend：

```elixir
SymphonyElixir.Agent.Backend.AcpStdio
```

该 backend 实现 session backend 接口：

```elixir
start_session(workspace, resolved_agent, opts)
run_turn(session, workspace, issue, prompt, opts)
stop_session(session)
```

内部再拆出 ACP client：

```elixir
SymphonyElixir.Agent.AcpStdio.Client
```

职责边界：

- `AcpStdio` backend 负责适配 Symphony 的 backend contract、agent config、event annotation 和 turn result。
- `AcpStdio.Client` 负责启动 stdio 子进程、发送 ACP JSON-RPC request、匹配 response、接收 notification、维护 request id、处理 read timeout。
- 进程清理和超时兜底可以复用或参考现有 `CliRun` 的 Port 管理方式。

## ACP 启动流程

`start_session/3` 执行以下步骤：

1. 读取 agent config 中的 `command`、`args`、timeout、permission policy。
2. 将 `{{workspace}}` 替换为当前 issue workspace 绝对路径。
3. 在 workspace 目录下启动 ACP 子进程。
4. 发送 ACP `initialize`。
5. 创建新的 ACP session。
6. 返回包含 ACP session id、port、os pid、resolved agent 和配置策略的 session map。

启动失败时返回 `{:error, reason}`，并向 orchestrator callback 发送 `startup_failed` 事件。

## Turn 流程

`run_turn/5` 将 Symphony prompt 发送给当前 ACP session。

第一 turn 使用 `PromptBuilder` 渲染后的完整 issue prompt。后续 continuation turn 使用 `AgentRunner` 已有的 continuation guidance，因此 ACP backend 不需要重新实现 continuation 策略，只需要在同一个 ACP session 中继续发送 prompt。

`run_turn/5` 处理事件直到出现终止条件：

- ACP prompt 完成：返回 `{:ok, %{session_id: ...}}`。
- ACP prompt 失败：返回 `{:error, reason}`。
- ACP prompt 被取消：返回 `{:error, {:cancelled, reason}}`。
- turn timeout：先发送 ACP cancel，再兜底终止进程，返回 timeout error。
- ACP 子进程退出：返回 subprocess error。

## 事件映射

ACP backend 向现有 callback 发送 backend-neutral 事件，并保留兼容字段，避免一次性重构 dashboard。

事件应包含：

- `agent_id`
- `agent_kind`
- `event`
- `timestamp`
- `session_id`
- `codex_app_server_pid`，短期继续复用该字段承载 ACP 子进程 pid，降低 orchestrator 改动
- `payload`
- `usage`，如果 ACP event 中可获得 usage

建议事件映射：

| ACP 侧事件 | Symphony 事件 |
| --- | --- |
| initialize 成功 | `session_started` |
| session 创建成功 | `session_started`，payload 包含 ACP session id |
| prompt 开始 | `turn_started` |
| assistant/text update | `notification` |
| tool call update | `notification`，payload 保留 tool 信息 |
| permission request | `approval_required`、`approval_auto_approved` 或 `permission_rejected` |
| prompt complete | `turn_completed` |
| prompt error | `turn_failed` |
| prompt cancel | `turn_cancelled` |
| JSON 解析失败 | `malformed` |
| 未识别 notification | `other_message` |

长期可以把 `codex_app_server_pid` 正式迁移为 `agent_process_pid`，但本轮不要求。

## 权限策略

ACP permission 不能直接等同 Codex app-server approval。需要为 `acp_stdio` backend 定义独立策略。

第一版支持三种策略：

- `reject`：默认策略。所有 permission request 自动拒绝，并记录 `permission_rejected`。
- `fail`：收到 permission request 后终止当前 turn，返回 `{:error, {:permission_required, payload}}`。
- `allow`：自动允许 permission request，并记录 `approval_auto_approved`。

默认使用 `reject`。原因是 MiMo-Code/OpenCode 的 permission schema 与 Codex approval schema 不同，在没有更细粒度映射前，保守拒绝比无人值守卡住更可控。

后续可以扩展为：

- `allow_read`
- `allow_write`
- `allow_command`
- `reject_unknown`
- 基于 command/path 的规则表

## 配置

配置 schema 需要允许：

```yaml
agents:
  mimocode:
    kind: acp_stdio
    command: "mimo"
    args: ["acp", "--cwd", "{{workspace}}"]
    permission_policy: reject
    timeout_ms: 3600000
    read_timeout_ms: 60000
    stall_timeout_ms: 600000
```

验证规则：

- `kind` 必须允许 `acp_stdio`。
- `command` 必须是非空字符串。
- `args` 如果存在，必须是字符串列表。
- `permission_policy` 如果存在，必须是 `reject`、`fail`、`allow`。
- timeout 字段沿用现有 agent 通用整数校验。

`routing.by_label`、`routing.by_assignee`、`routing.default_agent` 不需要新增语义。

## 成功判定

ACP turn 成功只表示 agent runtime 完成了本轮 prompt。是否继续工作仍由现有 `AgentRunner` 逻辑判断：

1. 刷新 Linear issue。
2. 如果 issue 仍处于 active state 且仍可路由，则继续下一 turn，直到达到 `agent.max_turns`。
3. 如果 issue 已离开 active state 或不再可路由，则 worker attempt 完成。

这保持 Codex 和 MiMo-Code 的行为一致，避免把 “进程退出成功” 错当成 “issue 已完成”。

## 错误处理

配置错误：

- 未知 `kind: acp_stdio` 以外的 kind：配置验证失败。
- `command` 为空：配置验证失败。
- `args` 类型错误：配置验证失败。
- `permission_policy` 未知：配置验证失败。

运行时错误：

- 找不到 `mimo`：worker attempt 失败，进入现有 retry 策略。
- `initialize` 失败：startup failed。
- session 创建失败：startup failed。
- prompt 失败：turn failed。
- permission request 在 `fail` 策略下出现：turn failed，并把 issue 标记为需要人工处理的阻塞事件。
- timeout：先 ACP cancel，再 kill 子进程。
- ACP 输出 malformed JSON：记录 malformed；如果无法继续匹配协议，则失败。
- 子进程提前退出：失败，并记录 exit status 和 stderr 摘要。

## 测试策略

优先用 fake ACP server 验证 Symphony 侧行为，不依赖真实 MiMo-Code 环境。

需要覆盖：

- 配置允许 `kind: acp_stdio`。
- label `agent:mimo` 能路由到 `mimocode`。
- `AcpStdio.start_session/3` 能启动 fake server、initialize、创建 session。
- `AcpStdio.run_turn/5` 能发送 prompt，并在 fake completion 后返回 success。
- continuation turn 复用同一个 ACP session。
- permission policy `reject` 会回复拒绝并记录事件。
- permission policy `fail` 会终止 turn。
- timeout 会发送 cancel 并兜底结束进程。
- malformed JSON 会产生 `malformed` 事件。
- orchestrator running snapshot 能看到 `agent_id=mimocode` 和 `agent_kind=acp_stdio`。

真实 smoke test：

1. 确认 WSL 或 Windows PATH 中存在可运行的 `mimo`。
2. 确认 `mimo acp` 可启动并能完成最小 prompt。
3. 配置 `agent:mimo -> mimocode`。
4. 创建测试 Linear issue 并添加 `agent:mimo`。
5. 观察 dashboard 和日志，确认执行 agent 是 `mimocode`。
6. 确认最终事件包含 ACP session id、turn completion 或明确失败原因。

## 实施顺序

1. 扩展配置 schema 和验证，允许 `acp_stdio`。
2. 新增 backend dispatcher 映射。
3. 实现 fake ACP server 测试夹具。
4. 实现 ACP stdio client 的最小 request/response/notification 循环。
5. 实现 `AcpStdio` backend 的 `start_session/3`。
6. 实现 `run_turn/5` 的 prompt、completion、failure、timeout 处理。
7. 实现 permission policy。
8. 接入事件 annotation，保持 `agent_id`、`agent_kind`、`session_id` 可观测。
9. 增加配置和路由文档示例。
10. 执行真实 `mimo acp` smoke test，并记录能力缺口。

## 风险

- MiMo-Code 发布版本的 ACP 能力可能与源码不同。实现应先用 fake server 锁定 Symphony 侧协议，再做真实 smoke。
- ACP 协议字段可能与 Codex app-server 差异较大。实现时必须做 adapter，不应复用 Codex app-server client。
- permission 默认如果过于宽松，可能带来无人值守执行风险。第一版默认 `reject`。
- dashboard 当前仍有 `codex_*` 命名。第一版允许兼容字段存在，但新事件要携带 backend-neutral 的 `agent_*` 字段。
- Windows 与 WSL 路径、PATH、shell 启动方式可能不同。真实 smoke test 需要明确运行环境。

## 非目标和后续方向

本轮不做 OpenCode。原阶段 4 的 OpenCode 复用只作为后续占位：等 MiMo-Code 的 ACP backend 跑通后，再评估 OpenCode 是否能直接复用 `acp_stdio` 配置。如果能复用，只新增配置和 smoke test；如果 ACP 行为有差异，再补充 provider-specific quirk，而不是新增平行 backend。

HTTP server backend 也不在本轮范围内。只有当需要常驻 server、远程 attach、共享 UI 或更强 HTTP observability 时，再单独设计。

## 验收标准

- `WORKFLOW` 可以声明 `mimocode.kind = acp_stdio`。
- Linear issue 加 `agent:mimo` 后由 `mimocode` backend 执行。
- dashboard 或日志明确显示 `agent_id=mimocode`、`agent_kind=acp_stdio`。
- 一个 worker attempt 内的 continuation turn 复用同一个 ACP session。
- fake ACP server 测试覆盖启动、prompt、completion、permission、timeout。
- 真实 `mimo acp` smoke test 至少能完成一个简单测试 issue，或给出明确的 MiMo-Code 侧阻塞原因。
