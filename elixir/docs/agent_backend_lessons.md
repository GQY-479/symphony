# Agent Backend 经验沉淀

本文沉淀 MiMo-Code 通过 `acp_stdio` 接入 Symphony 时得到的可复用经验。它不是历史复盘，也不替代 `SPEC.md`；目标是帮助后续实现、排障和 smoke 设计时少走弯路。

相关背景文档：

- [`multi_agent_backends.md`](multi_agent_backends.md)：多 agent 配置、路由和 `acp_stdio` 使用说明。
- [`agent_runtime_capability_matrix.md`](agent_runtime_capability_matrix.md)：Codex app-server、`cli_run`、ACP stdio、HTTP server 的能力边界。
- [`mimocode_acp_integration_plan.md`](mimocode_acp_integration_plan.md)：MiMo-Code ACP + MCP 接入方案和阶段结论。
- [`mimocode_acp_smoke_test.md`](mimocode_acp_smoke_test.md)：真实 MiMo-Code smoke 记录、模板和证据清单。

## 架构边界

Symphony 的核心模型是 scheduler/runner，而不是 agent 互相嵌套调用的工具层。Codex、MiMo-Code、OpenCode 这类 coding agent 更适合作为平级 issue runner，通过 `agents` 和 `routing` 选择，而不是把一个 agent 包装成另一个 agent 的私有工具。

当 Codex 需要把工作交给 MiMo-Code 时，优先动作是创建或更新 Linear issue，并打上 `agent:mimo` label 或设置对应 assignee。这样任务边界、状态变化、评论和审计记录都留在 tracker 里，符合 Symphony 的编排模型。

Orchestrator 应保持 provider-neutral。Provider-specific 行为应放在 backend adapter、配置、workflow guidance、smoke 文档或测试中；不要把 MiMo-Code、OpenCode 或 Codex 专属判断写进调度、重试、reconciliation 或 workspace cleanup 核心逻辑。

## Runtime 协议和业务工具分层

Codex app-server、ACP stdio 和未来 HTTP server 都属于 runtime 控制面，负责 session 生命周期、prompt/update、permission、cancel、timeout 和进程清理。

Linear 读写属于业务工具层。ACP agent 需要 Linear 能力时，不应复用 Codex dynamic tool 的协议形态，而应通过 backend-neutral `SymphonyElixir.Agent.Tool` 或 MCP endpoint 暴露，例如当前的 HTTP MCP `linear_issue_read`、`linear_comment_create`、`linear_issue_update_state` 和 raw fallback `linear_graphql`。

这个分层可以避免两类问题：

- 把 Codex app-server 的协议细节泄漏到 ACP backend。
- 为了某个 provider 的工具缺口去改 Orchestrator 或 Linear 工具核心。

## 真实 runtime 优先

Fake ACP server 用来锁定 Symphony 侧协议边界，适合覆盖 handshake、framing、permission、timeout、close、usage 和错误传播。它不能证明真实 MiMo-Code 或 OpenCode 的发布版行为。

真实兼容性判断必须以安装版 smoke 为准。MiMo-Code 接入过程中已经出现过源码和发布版细节需要实测确认的情况，例如：

- `session/new.params.mcpServers` 必须是数组，即使没有 MCP server 也要发送 `[]`。
- `session/close` 只能在 `initialize` 声明 close capability 后发送。
- `permission_policy: allow` 应选择 agent 返回的 `kind == "allow_once"` 的 optionId，不能硬编码为 `"allow_once"`。
- `mimo acp --cwd` 声明存在，但 backend 仍要把 ACP 子进程 cwd 设置为 issue workspace。

后续接 OpenCode 时也应沿用同一原则：先用 fake server 保证 Symphony 侧行为稳定，再用真实 `opencode acp` smoke 判定 provider 兼容性。

## Terminal State 顺序

Tracker terminal state 是编排控制信号，不只是业务字段。issue 一旦进入 `Done`、`Closed`、`Cancelled` 或其它 terminal state，Symphony 会停止 active agent 并按配置清理 workspace。

因此任何 agent 或工具都必须把 terminal state 作为最后收尾动作。正确顺序是：

1. 完成 workspace 文件或仓库变更。
2. 读回或运行必要验证，确认 evidence 存在。
3. 创建 Linear 评论，说明验证结果和关键证据。
4. 最后调用 `linear_issue_update_state` 移到 terminal state。

YQE-32 证明，如果 agent 过早把 issue 移到 `Done`，Linear 收尾可能成功，但 workspace 文件尚未落盘。YQE-34 和 YQE-35 证明，在明确字段模板和 terminal-last guidance 下，真实 MiMo-Code 可以完成“文件先落盘、Linear 最后收尾”的闭环。

## Smoke 模板

真实 smoke issue 应使用明确字段，不要使用 `$fileName`、`$phrase` 这类容易被 agent 当作变量或占位符的写法。推荐字段是：

- `目标文件名：...`
- `精确文件内容：...`

任务描述还应明确禁止用已有 `docs/` 文件替代目标文件，并要求读回目标文件后再评论成功。如果目标文件名或精确内容缺失、含糊，agent 应评论 blocked，不应移动到 terminal state。

可复制模板和失败证据清单见 [`mimocode_acp_smoke_test.md`](mimocode_acp_smoke_test.md) 的“稳定 smoke issue 模板”和“失败时证据清单”。

## 日志和排障

ACP/MCP/tool 日志应保持低敏。可以记录：

- tool name
- outcome
- error category
- agent id/kind
- issue/session context
- timing

不要记录：

- Linear token 或 Authorization header
- GraphQL query/mutation/variables
- MCP headers/env
- comment body
- tool arguments

排障时优先确认以下证据：

- dashboard/API 中的 `agent_id`、`agent_kind`、`session_id`。
- ACP `session/update` 是否出现目标文件写入和读回。
- MCP `tools/call` 是否出现预期高层工具，以及 `outcome` / `error_category`。
- workspace 目标文件内容和 sha256。
- MiMo-Code session 数据库中的 `summary_files`、`summary_additions`、`summary_deletions`。
- terminal issue 完成后 `/api/v1/state` 是否没有残留 `running`、`retrying`、`blocked`。

如果看不到新的 `ACP session/update` 或 `MCP tools/call` 日志，先确认服务是否重启到新 escript，以及是否查看了 OTP wrap disk log 的实际内容文件，例如 `log/symphony.log.1`。

## 应固化为回归测试的经验

已覆盖或应保持覆盖的回归点：

- `acp_stdio` 配置解析和 backend 注册。
- `session/new` 默认发送 `mcpServers: []`。
- session 创建后按 `config_options` 发送 `session/set_config_option`。
- 只有声明 close capability 时才发送 `session/close`。
- permission `allow` 使用 agent 实际返回的 `allow_once` optionId。
- `permission_policy: fail` drain 当前 prompt response 后返回错误。
- ndjson 拆包和同 chunk 后续 notification 不丢失。
- `session/prompt` timeout 使用绝对 deadline，不被持续 `session/update` 续期。
- prompt timeout 只发送一次 `session/cancel`；initialize/session/new/close timeout 不发送无效 cancel。
- 同一 worker attempt 内 ACP continuation 复用同一 session。
- ACP continuation prompt 使用 backend-neutral 文案，不出现 Codex 专用措辞。
- `linear_issue_update_state` 的 terminal 收尾不早于 workspace evidence 和评论。
- worker 正常退出且刷新后的 issue 已 terminal 时，不再安排 continuation retry。
- ACP/MCP/tool 日志不泄漏 token、GraphQL body、headers/env、comment body 或 tool arguments。

新增 provider 或调整 backend 行为时，优先把发现沉淀到对应测试；只有无法稳定自动化的真实 runtime 差异，才保留在 smoke 文档中。
