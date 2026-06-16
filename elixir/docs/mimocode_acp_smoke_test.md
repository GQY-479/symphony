# MiMo-Code ACP Smoke Test

## 调研结论

- ACP 官方流程是 `initialize` -> `session/new` -> `session/prompt`，运行中通过 `session/update` 推送事件，取消通过 `session/cancel`。
- ACP permission 请求由 agent 调用 client 的 `session/request_permission`。
- MiMo-Code 源码中的 `acp` 命令使用 `@agentclientprotocol/sdk` 的 `AgentSideConnection` 和 `ndJsonStream`。
- MiMo-Code 源码中的 `acp` 命令支持通过 `--cwd` 设置工作目录。

## 源码复核

复核时间：2026-06-14。

复核来源：

- 仓库：`https://github.com/XiaomiMiMo/MiMo-Code.git`
- HEAD：`42e7da3d51dba1129cd3abfa214e29f7385924a3`
- 本机包：`@mimo-ai/cli@0.1.0`
- 文件：`packages/opencode/src/cli/cmd/acp.ts`
- 文件：`packages/opencode/src/acp/agent.ts`

结论：

- `acp` 命令确实通过 `AgentSideConnection` 和 `ndJsonStream` 暴露 ACP stdio。
- `acp` 命令声明了 `--cwd` 参数，但当前 handler 调用的是 `bootstrap(process.cwd(), ...)`，没有直接使用 `args.cwd`。因此 Symphony 不能只依赖 `--cwd {{workspace}}`，必须把 ACP 子进程的 cwd 也设置为 issue workspace。
- `session/new` 使用 `params.cwd` 创建 ACP session，因此 Symphony 仍应在 `session/new` 中传入 workspace 绝对路径。
- 真实 `@mimo-ai/cli@0.1.0` 还要求 `session/new.params.mcpServers` 是数组；Symphony 需要发送 `mcpServers: []`，否则 MiMo 返回 `Invalid params`。
- 真实 `@mimo-ai/cli@0.1.0` 的 `initialize.result.agentCapabilities` 未声明 `sessionCapabilities.close`，直接调用 `session/close` 会返回 `Method not found`。Symphony 需要按 capability 协商，只有 agent 明确声明 close 能力时才发送 `session/close`。
- MiMo-Code 当前 permission options 使用 `optionId: "once" | "always" | "reject"`，其中 `kind` 为 `allow_once`、`allow_always`、`reject_once`。Symphony 的 `permission_policy: allow` 应选择 agent 实际提供的 `allow_once` optionId，而不是硬编码 `allow_once`。
- 本机 WSL 已安装 `mimo`，但当前 PATH 没有 `/home/gqy47/.npm-global/bin`。直接执行 `command -v mimo` 会失败；使用绝对路径 `/home/gqy47/.npm-global/bin/mimo` 可以启动。
- Symphony fake ACP server 已更新为校验 permission reply 的 `optionId`，并覆盖 MiMo-Code 当前的 `optionId: "once"` 行为和自定义 allow optionId 行为。
- ACP `session/prompt` 返回的 `usage` 已在 Symphony backend 中提升到 `turn_completed.usage`，以复用现有 Orchestrator token accounting。
- 对于 Symphony 未支持的 agent -> client request，ACP client 会返回 JSON-RPC `method not found` error，并记录 `unsupported_request`，避免真实 agent 等待 response 导致 turn timeout。
- ACP client 已支持 ndjson 拆包缓冲：同一 JSON line 被拆成多个 stdout chunk 时会等待换行后再解析，不会误报 malformed 或卡到 timeout。
- ACP client 已支持处理与目标 response 同 chunk 到达的后续完整 notification/client request，避免命中 response 后丢弃后续事件。
- ACP client 已支持 handshake 失败清理：`initialize` 或 `session/new` 返回 error 时，会关闭已经启动的 ACP 子进程，避免真实 agent runtime 残留。
- ACP client 已支持真实 MiMo 的 `session/new` schema：启动 session 时发送 `mcpServers: []`。
- ACP client 已支持 close capability 协商：只有 `initialize.result.agentCapabilities.sessionCapabilities.close` 存在时才发送 `session/close`；真实 MiMo 未声明该能力时直接关闭 port。
- ACP client 已支持 `permission_policy: fail` 的 drain 行为：发出 permission reply 后会继续读到当前 `session/prompt` response，再返回 `permission_required` 错误，避免 stdout 残留污染后续 request。
- ACP backend 已支持 timeout cancel 语义：prompt 超时时由 client 发送一次 `session/cancel`，backend 记录 `turn_cancelled`，不会重复发送 cancel。
- ACP client 已支持 turn 级绝对 timeout：持续到达的 `session/update` 不会延长 `session/prompt` 的总超时时间，避免真实 MiMo-Code 长时间只输出进度但不完成时绕过超时回收。
- ACP client 已将 timeout 语义按请求阶段区分：只有 `session/prompt` 超时会发送 `session/cancel`；`initialize`、`session/new` 和 `session/close` 超时只返回错误并清理子进程，避免在 session 尚未建立或正在关闭时发送无效 cancel。
- ACP backend 已支持配置化 close timeout：`close_timeout_ms` 会从 agent config 进入 ACP session；`session/close` 超时后会关闭 port，并用 TERM/KILL 兜底回收 ACP 子进程。
- ACP client 已支持 session 级配置：agent config 中的 `config_options` 会在 `session/new` 成功后逐项通过 `session/set_config_option` 发送。请求参数使用 ACP 官方字段 `configId` 和 `value`，例如 `config_options: %{model: "mimo/mimo-auto"}` 会发送 `configId: "model"`、`value: "mimo/mimo-auto"`。
- AgentRunner 已覆盖 ACP continuation 端到端行为：同一个 worker attempt 内只创建一次 ACP session，连续发送两次 `session/prompt`；第二轮 continuation prompt 使用 backend-neutral 的 `previous agent turn` 文案，不再给 MiMo-Code 发送 Codex 专用措辞。
- 真实 MiMo-Code MCP smoke 发现：`@mimo-ai/cli@0.1.0` 不接受 stdio MCP descriptor 的 `command/args/env` 形态。它返回 `Invalid params`，错误显示 MCP server 必须是 `type: "http"` 或 `type: "sse"`，并包含 `url`、`headers` 数组和 `env` 数组。因此 Symphony 默认改为注入 HTTP MCP endpoint：`http://127.0.0.1:<port>/mcp/linear-tools`。
- 同轮复测还发现：`WORKFLOW.local.md` prompt 中包含中文时，Solid 渲染后的 prompt 曾出现非法 UTF-8，导致 ACP JSON-RPC `Jason.EncodeError`。当前 `PromptBuilder` 已增加有效 UTF-8 防线，本地 smoke workflow 暂时保持 ASCII prompt，后续可单独修复中文模板渲染的根因。

## 本机命令探测

### 2026-06-14 复核：PATH 探测

执行命令：

```powershell
wsl.exe -e bash -lc 'set -o pipefail; echo WSL; command -v mimo || true; command -v mimocode || true; command -v mimo-code || true; command -v opencode || true; if command -v mimo >/dev/null 2>&1; then mimo acp --help 2>&1 | head -80; fi'
```

输出：

```text
WSL
```

执行命令：

```powershell
$ErrorActionPreference='SilentlyContinue'; 'Windows'; Get-Command mimo,mimocode,mimo-code,opencode | Select-Object Name,Source,CommandType | Format-Table -AutoSize
```

输出：

```text
Windows
```

结论：当前 Windows 和 WSL PATH 中仍未发现 `mimo`、`mimocode`、`mimo-code` 或 `opencode` 命令。

### 2026-06-14 复核：本机绝对路径

进一步查找后发现：

- `mimo` 路径：`/home/gqy47/.npm-global/bin/mimo`
- npm 包：`@mimo-ai/cli@0.1.0`
- `mimo acp --help` 可启动，并显示 `--cwd` 参数。

执行真实握手 smoke：

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && MIX_ENV=test mise exec -- mix run /tmp/symphony_mimo_smoke.exs'
```

其中 smoke 脚本通过 `SymphonyElixir.Agent.AcpStdio.Client.start_session/3` 启动：

```elixir
%{
  command: "/home/gqy47/.npm-global/bin/mimo",
  args: ["acp", "--cwd", workspace, "--pure"],
  env: [],
  permission_policy: "reject",
  timeout_ms: 15_000,
  config_options: %{"model" => "mimo/mimo-auto"}
}
```

实测结果：

- 修复前：`session/new` 返回 `Invalid params`，原因是缺少 `mcpServers`。
- 添加 `mcpServers: []` 后：`start_session` 成功，返回真实 session id，例如 `ses_13d1e59efffe0EvYRfMVicHu09`。
- `stop_session` 不再发送 `session/close`，因为真实 MiMo 未声明 close capability。

当前剩余现象：直接关闭 stdio port 后，MiMo 仍可能在 stderr 打印 `ACP write error: EPIPE`。这没有阻止 `start_session` / `stop_session` 返回成功，但说明真实 MiMo 的无 close-capability 退出仍不够安静，后续可以继续调研是否存在更温和的退出通知或进程关闭方式。

### 2026-06-14 复核：带模型配置的真实 prompt smoke

执行真实 prompt smoke。当次使用临时脚本 `tmp_mimo_config_smoke.exs`，验证完成后已删除；后续复跑可按下方关键配置重新创建脚本或改成正式 mix task：

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && MIX_ENV=test mise exec -- mix run tmp_mimo_config_smoke.exs'
```

脚本使用的关键配置：

```elixir
%{
  command: "/home/gqy47/.npm-global/bin/mimo",
  args: ["acp", "--cwd", workspace, "--pure"],
  permission_policy: "reject",
  timeout_ms: 15_000,
  config_options: %{"model" => "mimo/mimo-auto"}
}
```

实测结果：

- `start_session` 成功，返回真实 session id，例如 `ses_13d07b764ffeeH7a1G8vbv1IZy`。
- `session/prompt` 成功返回 `stopReason: "end_turn"`。
- MiMo 输出了 `OK`。
- prompt result 返回 usage，例如 `inputTokens: 18033`、`outputTokens: 4`、`thoughtTokens: 10`、`totalTokens: 20095`。
- `stop_session` 返回 `:ok`。
- `session_started.payload.result.configOptions` 中包含 `model` 选项，且可用选项包含 `mimo/mimo-auto`。

结论：`config_options.model = "mimo/mimo-auto"` 后，真实 MiMo-Code ACP prompt 已能完成最小任务。这说明当前剩余重点从“ACP prompt 是否可用”转为“通过 Linear issue 路由后是否能稳定完成真实 issue worker attempt”。

### 2026-06-14 复核：真实 Linear issue smoke

本次使用本地 workflow：

```text
/mnt/c/Users/GQY47/coding/Symphony/elixir/WORKFLOW.local.md
```

关键配置：

```yaml
tracker:
  project_slug: "96f5ac7500e2"
  required_labels:
    - symphony-local-test
workspace:
  root: ~/code/symphony-workspaces-local
  preserve_terminal: true
agents:
  mimocode:
    kind: acp_stdio
    command: /home/gqy47/.npm-global/bin/mimo
    args:
      - acp
      - --cwd
      - "{{workspace}}"
      - --pure
    permission_policy: reject
    config_options:
      model: "mimo/mimo-auto"
routing:
  by_label:
    "agent:mimo": mimocode
```

`workspace.preserve_terminal: true` 是本地 smoke 的可观测性开关。默认生产语义仍是在 issue 进入 terminal state 后清理 workspace；本地开启后，MiMo-Code 把 issue 移到 `Done` 后 evidence workspace 会保留，便于复验文件内容和工具调用结果。长期运行后需要人工清理旧目录。

启动前发现一个关键环境问题：`elixir/start-local.ps1` 启动的是 `elixir/bin/symphony` escript，而该 escript 仍是旧版本，不包含 `acp_stdio`。结构化日志中持续出现：

```text
Invalid WORKFLOW.md config: agents.mimocode.kind must be codex_app_server or cli_run, got "acp_stdio"
```

用 `strings bin/symphony | grep acp_stdio` 也未找到 `acp_stdio`；当前源码编译产物 `_build/dev/.../Elixir.SymphonyElixir.Agent.Backend.beam` 已包含 `AcpStdio`。执行以下命令重建后，`bin/symphony` 才包含 ACP backend：

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix escript.build'
```

本地启动脚本已更新为启动前自动执行 `mix escript.build`，停止脚本也已更新为清理 `mimo acp` / `.mimocode acp` 进程，避免后续继续跑旧 escript 或残留 ACP 子进程。

#### YQE-16

- Linear issue：`YQE-16`
- 初始状态：`In Progress`
- 标签：`agent:mimo`、`symphony-local-test`
- Symphony dashboard/API 观测：
  - `agent_id: "mimocode"`
  - `agent_kind: "acp_stdio"`
  - session id：真实 ACP session，例如 `ses_13cf43e65ffeynlCx617NRDplc`
  - `turn_count` 按 `turn_started` 增长到 3
- workspace：`/home/gqy47/code/symphony-workspaces-local/YQE-16`
- MiMo 写入/更新了 `AGENT_STATUS.md`，其中声明：
  - Agent Name：MiMo Code Agent
  - Model：`mimo/mimo-auto`
  - 环境变量包含 `AGENT=1`、`MIMOCODE=1`、`MIMOCODE_PROCESS_ROLE=main`
- 结构化日志显示：
  - `Dispatching issue to agent ... agent_id=mimocode agent_kind=acp_stdio`
  - 多次 `Completed agent run ... session_id=ses_... turn=.../3`
  - `Reached agent.max_turns ... with issue still active`
  - 后续检测到 `Issue moved to terminal state ... state=Done`

结论：YQE-16 证明 Linear issue 能通过 `agent:mimo` 路由到 MiMo-Code ACP backend，并最终进入 Linear `Done`。

#### YQE-17

- Linear issue：`YQE-17`
- 初始状态：`Todo`
- 标签：`agent:mimo`、`symphony-local-test`
- 任务要求：创建 `mimo-acp-smoke.txt`
- Symphony dashboard/API 观测：
  - `agent_id: "mimocode"`
  - `agent_kind: "acp_stdio"`
  - session id：真实 ACP session，例如 `ses_13cef44f6ffeharURw7g2627Kv`
  - last message 出现 `agent tool call: mimo-acp-smoke.txt`
- workspace：`/home/gqy47/code/symphony-workspaces-local/YQE-17`
- 文件结果：

```text
mimo-acp-smoke.txt
MiMo ACP smoke passed
```

后续现象：

- MiMo 在完成文件 smoke 后继续尝试提交、推送或 Linear 收尾。
- dashboard 曾显示 `agent tool call: Loaded skill: linear`、`agent tool call: Loaded skill: push`、`agent tool call: Invalid Tool`。
- YQE-17 未在本次观察窗口内稳定进入 `Done`；为避免本地测试 issue 继续重复 continuation，已停止本地 Symphony 服务。

结论：YQE-17 证明 `acp_stdio` 可以把新 Linear issue 派给 MiMo-Code，并完成 workspace 文件变更。它也暴露出下一阶段差距：MiMo-Code ACP backend 尚未像 Codex app-server 一样稳定获得 `linear_graphql` / push 等 client-side 工具能力，因此真实收尾动作不如 Codex 稳定。

这个结果不推翻 `acp_stdio` 总体方案，但说明“像 Codex 一样丝滑”的下一步不只是 session backend，还需要设计 ACP/MCP 侧的工具注入或等价的 Linear 收尾能力。

### 初次探测

执行命令：

```powershell
wsl.exe -e bash -lc 'set -o pipefail; echo WSL; command -v mimo || true; command -v mimocode || true; command -v mimo-code || true; if command -v mimo >/dev/null 2>&1; then mimo acp --help 2>&1 | head -80; fi'
```

输出：

```text
WSL
```

执行命令：

```powershell
$ErrorActionPreference='SilentlyContinue'; 'Windows'; Get-Command mimo,mimocode,mimo-code | Select-Object Name,Source,CommandType | Format-Table -AutoSize
```

输出：

```text
Windows
```

结论：当前 Windows 和 WSL PATH 中都未发现 `mimo`、`mimocode` 或 `mimo-code` 命令。后续已通过绝对路径找到 WSL 安装位置。

## 方案门禁

当前探测结果不推翻 ACP stdio 方案。原因是：

- MiMo-Code 源码已经暴露 ACP stdio 命令。
- Symphony 侧可以先用 fake ACP server 锁定协议适配和 orchestration 行为。
- Symphony 侧已经同时设置 ACP 子进程 cwd 和 `session/new.cwd`，可以规避当前源码中 `--cwd` 未被 handler 使用的风险。
- 真实 MiMo-Code session 启动握手已通过。
- 带 `config_options.model = "mimo/mimo-auto"` 的真实 prompt smoke 已通过。
- 真实 Linear issue smoke 已证明 issue 能路由到 MiMo-Code ACP backend，并能完成 workspace 文件变更；稳定 Linear 收尾仍需补齐工具能力。

如果后续安装后的 `mimo acp` 不支持 ACP v1 的 `initialize`、`session/new`、`session/prompt`，或不能以非交互方式启动，需要暂停实现并回到设计文档修订。

## 后续 smoke 命令

如果 WSL PATH 已加入 `/home/gqy47/.npm-global/bin`，可以执行：

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mimo acp --help'
```

当前环境也可以直接用绝对路径执行：

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && /home/gqy47/.npm-global/bin/mimo acp --help'
```

再执行最小启动探测：

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && timeout 5s mimo acp --cwd "$PWD" < /dev/null || true'
```

## MiMo + MCP `linear_graphql` smoke

目标：验证 `mimocode/acp_stdio` 不只能够承接 issue 和修改 workspace，还能通过 Symphony 注入的 MCP `linear_graphql` 工具完成 Linear 查询、评论和状态收尾。

### 前置配置

本地 workflow 使用：

```text
C:\Users\GQY47\coding\Symphony\elixir\WORKFLOW.local.md
```

关键配置：

```yaml
agents:
  mimocode:
    kind: acp_stdio
    command: /home/gqy47/.npm-global/bin/mimo
    args:
      - acp
      - --cwd
      - "{{workspace}}"
      - --pure
    permission_policy: reject
    config_options:
      model: "mimo/mimo-auto"
    mcp:
      linear_tools: true
routing:
  by_label:
    "agent:mimo": mimocode
```

`mcp.linear_tools: true` 会让 Symphony 在 ACP `session/new.params.mcpServers` 中注入 `symphony-linear` HTTP MCP server descriptor。该 endpoint 只暴露 Linear 相关工具：`linear_issue_read`、`linear_comment_create`、`linear_issue_update_state` 和 raw fallback `linear_graphql`，不暴露 shell、文件系统或通用网络工具。

注入形态应类似：

```json
{
  "name": "symphony-linear",
  "type": "http",
  "url": "http://127.0.0.1:4000/mcp/linear-tools",
  "headers": [],
  "env": []
}
```

### 启动服务

先停止旧服务和残留 ACP 子进程：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\elixir\stop-local.ps1
```

重新构建并启动本地服务：

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix escript.build'
powershell -NoProfile -ExecutionPolicy Bypass -File .\elixir\start-local.ps1 -Workflow .\elixir\WORKFLOW.local.md -Port 4000
```

触发一次刷新：

```powershell
curl.exe -sS -X POST http://127.0.0.1:4000/api/v1/refresh
```

查看状态：

```powershell
curl.exe -sS http://127.0.0.1:4000/api/v1/state
```

### Linear issue 要求

在测试项目中创建 issue：

```text
https://linear.app/yqeeqy/project/symphony-96f5ac7500e2/issues
```

issue 必须满足：

- 状态在 active state 中，例如 `Todo` 或 `In Progress`。
- label 包含 `agent:mimo`。
- label 包含 `symphony-local-test`。

建议 issue 描述：

```markdown
请执行 MiMo + MCP linear_graphql smoke：

1. 在 workspace 根目录创建 `mimo-mcp-linear-smoke.txt`，内容写入 `MiMo MCP linear smoke passed`。
2. 使用可用的 `linear_graphql` MCP 工具查询当前 issue 的 identifier、title、state 和 labels。
3. 使用 `linear_graphql` 在当前 issue 下评论：说明文件已创建，并写明查询到的 issue identifier 和当前状态。
4. 使用 `linear_graphql` 将当前 issue 移出 active state，例如移动到 `Done`。
5. 不要把任何 Linear API token 写入文件、日志、提交信息或 issue 评论。
```

### 需要记录的结果

完成后在本文追加记录：

- issue identifier。
- ACP session id。
- dashboard/API 中的 `agent_id` 和 `agent_kind`。
- workspace 文件是否存在，文件内容是什么。
- 如果开启 `workspace.preserve_terminal: true`，确认 issue 进入 terminal state 后 workspace 仍可复验。
- MiMo 是否成功调用 `linear_graphql`。
- Linear issue 是否出现 smoke 评论。
- Linear issue 是否离开 active state。
- 若失败，记录失败事件、最后一条 dashboard message 和相关日志文件路径。

### 2026-06-14 实测记录

#### 本地 workflow 修正

YQE-19 复测前后修正了几项本地 smoke 配置问题：

- `after_create` 从 `git clone --depth 1 https://github.com/openai/symphony .` 改为 `git clone --depth 1 file:///mnt/c/Users/GQY47/coding/Symphony .`。原因是 GitHub clone 曾在本地 smoke 中卡住 workspace 初始化；本机 `file://` clone 已单独验证成功。
- `before_remove` 从 `cd elixir && mise exec -- mix workspace.before_remove` 改为 `echo "local smoke cleanup"`。原因是该 mix task 会尝试用 `gh` 关闭当前分支 PR，适合默认工作流，但会让本地 smoke 的终态 cleanup 依赖外部 GitHub/gh 状态。
- `workspace.preserve_terminal` 设为 `true`。原因是 YQE-24 这类完整 smoke 在 MiMo-Code 成功把 issue 移到 `Done` 后，Orchestrator 会立即清理 workspace，导致完成后无法复验文件内容；本地 smoke 保留 terminal workspace 后可以验证 evidence 文件。默认配置仍保持 `false`。

这些修改只作用于 `elixir/WORKFLOW.local.md`，不改变默认 `elixir/WORKFLOW.md` 的生产/示例语义。

#### YQE-18：部分通过

- Linear issue：`YQE-18`
- 标题：`MiMo MCP linear_graphql smoke 20260614-083400`
- 标签：`agent:mimo`、`symphony-local-test`
- backend：`mimocode/acp_stdio`
- ACP session：`ses_13c70fe12ffeW5bILh3sqQ73p8`
- workspace：`/home/gqy47/code/symphony-workspaces-local/YQE-18`
- workspace 文件：`mimo-mcp-linear-smoke.txt`
- 文件内容：`MiMo MCP linear smoke passed`
- Linear 最终状态：`Done`
- Linear 评论：未观察到 smoke 评论
- 日志观察：dashboard 出现多次 `agent tool call: symphony-linear_linear_g...`，说明 MiMo-Code 已调用注入的 MCP `linear_graphql` 工具；同时也出现过 `agent tool call: Invalid Tool`。

结论：YQE-18 证明了 HTTP MCP descriptor 可被真实 MiMo-Code 消费，并且 MiMo-Code 能通过 MCP raw GraphQL 完成状态流转；但评论路径当次没有通过，不能作为完整验收。

#### YQE-19：完整通过

- Linear issue：`YQE-19`
- Linear id：`952c8e4d-5312-4053-9f25-2ff11c1a95cd`
- 标题：`MiMo MCP raw GraphQL comment smoke 20260614-084513`
- 标签：`agent:mimo`、`symphony-local-test`
- backend：`mimocode/acp_stdio`
- ACP session：`ses_13c538809ffe0RnBdkHcH3RfMv`
- workspace：`/home/gqy47/code/symphony-workspaces-local/YQE-19`
- workspace 文件：`mimo-mcp-linear-comment-smoke.txt`
- 文件内容：`MiMo MCP comment smoke passed`
- dashboard/API 观测：
  - `agent_id: "mimocode"`
  - `agent_kind: "acp_stdio"`
  - `turn_count: 1`
  - `last_event: "notification"`
- 日志观察：
  - 出现 `agent tool call: write`
  - 出现 `agent tool call: mimo-mcp-linear-comment-...`
  - 多次出现 `agent tool call: symphony-linear_linear_g...`
  - 仍出现少量 `agent tool call: Invalid Tool`，说明 MiMo-Code 还会尝试非暴露工具，但没有阻断任务完成
- Linear 查询结果：
  - `identifier: "YQE-19"`
  - `state.name: "Done"`
  - comment body：`MiMo MCP comment smoke passed — Issue: YQE-19 — State: Todo (unstarted)`
  - comment createdAt：`2026-06-14T01:10:02.529Z`

结论：YQE-19 证明 `agent:mimo` issue 可以被派给 `mimocode/acp_stdio`，真实 MiMo-Code 能创建 workspace 文件，能调用 Symphony 注入的 HTTP MCP `linear_graphql` 工具查询/写回 Linear，能创建 issue 评论，并能把 issue 移出 active state 到 `Done`。这满足本轮 MiMo-Code ACP + MCP 接入的真实 smoke 验收。

#### YQE-25：无效样本

- Linear issue：`YQE-25`
- backend：`mimocode/acp_stdio`
- workspace：`/home/gqy47/code/symphony-workspaces-local/YQE-25`
- Linear 最终状态：`Done`
- 结果：workspace 保留成功，但不作为文件内容 smoke 结论。

原因：创建 issue 的 PowerShell 描述中误用了反引号，导致 `$file` / `$phrase` 成为字面量。MiMo-Code 创建了 `YQE-25.txt`，不是当次计划验证的目标文件名。因此 YQE-25 只证明 `workspace.preserve_terminal: true` 可以保留终态 workspace，不证明“指定文件名 + 指定内容”的任务链路。

#### YQE-26：有效 preserve-terminal smoke

- Linear issue：`YQE-26`
- Linear id：`953ffa8b-926e-4f6a-822b-d18a3c0f1152`
- URL：`https://linear.app/yqeeqy/issue/YQE-26/mimo-preserve-terminal-valid-smoke-20260614-133801`
- 标签：`agent:mimo`、`symphony-local-test`
- backend：`mimocode/acp_stdio`
- ACP session：`ses_13b5cab70ffetEDo0uZ1zhda1d`
- workspace：`/home/gqy47/code/symphony-workspaces-local/YQE-26`
- workspace 文件：`mimo-preserve-terminal-smoke-20260614-133801.txt`
- 文件内容：`MiMo preserve terminal smoke passed 20260614-133801`
- Linear 最终状态：`Done`
- Linear 评论：`MiMo preserve terminal smoke passed 20260614-133801 file_verified=true workspace_preserve_terminal=true issue=YQE-26`

复验结果：

- issue 进入 `Done` 后，workspace 仍存在。
- 目标文件仍存在。
- 文件内容包含指定 phrase。
- `od` 复验显示文件无尾随换行，字节内容就是指定 phrase。
- `/tmp/symphony-local.log` 显示 issue 被派给 `agent_id=mimocode`、`agent_kind=acp_stdio`。
- `elixir/log/symphony.log.1` 有该 session 的低敏 `ACP session/update` 日志。
- 运行窗口日志抽查中，`lin_api_`、`Authorization`、`commentCreate`、`mutation`、`query` 均为 0 次命中；历史日志仍应按日志安全段落说明单独处理。

结论：YQE-26 证明 `workspace.preserve_terminal: true` 作为本地 smoke/排障开关有效。MiMo-Code 可以在被路由到 `mimocode/acp_stdio` 后创建指定文件、写入指定内容、通过 MCP/Linear 收尾到 `Done`，并在终态后保留 evidence workspace 供人工复验。

YQE-26 之后的补强：

- `acp_stdio` agent 开启 `mcp.linear_tools: true` 时，`AgentRunner` 会在首轮 prompt 自动追加 Linear MCP runtime guidance，明确要求 Linear 查询、评论和状态流转使用 `linear_graphql`，不要用 shell、git、push、skill 或未暴露工具处理 Linear 写回。
- `linear_graphql` 的 MCP tool description 已补充适用范围、`query` / `variables` 参数形态和禁止携带 Linear API token 的说明。
- 这两项改动的目标是降低真实 MiMo-Code 运行中的 `Invalid Tool` 噪音；它们不改变 ACP/MCP 协议路径，也不改变 `linear_graphql` 执行语义。

#### YQE-27：runtime guidance 补强后 smoke

- Linear issue：`YQE-27`
- Linear id：`b39da82d-eef4-4d7b-9882-3c6b77b68e98`
- URL：`https://linear.app/yqeeqy/issue/YQE-27/mimo-guidance-smoke-20260614-141459`
- backend：`mimocode/acp_stdio`
- ACP session：`ses_13b3ab6ecffe7mcSXKgxfXydcZ`
- workspace：`/home/gqy47/code/symphony-workspaces-local/YQE-27`
- workspace 文件：`mimo-guidance-smoke-20260614-141459.txt`
- 文件内容：`MiMo guidance smoke passed 20260614-141459`
- Linear 最终状态：`Done`
- Linear 评论：`MiMo guidance smoke passed 20260614-141459 file_verified=true guidance=true issue=YQE-27`

复验结果：

- issue 被派给 `agent_id=mimocode`、`agent_kind=acp_stdio`。
- 目标文件存在，内容与指定 phrase 完全一致。
- `od` 复验显示文件无尾随换行，字节内容就是指定 phrase。
- dashboard 日志抽查中，`Invalid Tool` 行数为 0。
- session 日志未出现 `Invalid Tool`。
- session 日志仍出现 `symphony-linear_linear_graphql`、`skill`、`Loaded skill: linear`、`bash` 和 `write` 等工具行为；其中 `write` 属于文件任务需要，`linear_graphql` 属于预期 MCP 路径，`skill` / `bash` 仍可作为后续降噪观察项。
- session 日志敏感内容抽查中，`lin_api_`、`Authorization`、`commentCreate`、`mutation`、`query` 均为 0 次命中。

结论：YQE-27 支持当前 `acp_stdio + HTTP MCP linear_graphql` 方案。runtime guidance 和 tool description 补强后，真实 MiMo-Code 能完成文件、评论和状态收尾，并且本次 dashboard/session 中未再出现 `Invalid Tool` 噪音。该结果不推翻总体方案；下一步如果继续优化，应聚焦减少 MiMo-Code 对 `skill` / `bash` 的探索，而不是更换 agent runtime 架构。

YQE-27 之后的提示层收紧：

- runtime guidance 进一步明确：不要为 Linear 工作加载本地 `linear` / `push` skill；`linear_graphql` 是本次运行的 Linear 工具面。
- runtime guidance 进一步区分 workspace 文件修改和 Linear 写回：仓库或文件变更使用 agent 正常 workspace 编辑能力，issue 评论和状态流转使用 `linear_graphql`。
- 该调整仍然只作用于开启 `mcp.linear_tools: true` 的 `acp_stdio` agent 首轮 prompt，不改变 ACP/MCP 协议和 `linear_graphql` 执行语义。

#### YQE-28：runtime guidance 进一步收紧后 smoke

- Linear issue：`YQE-28`
- Linear id：`948aa2a8-f361-436f-b511-bd963ffc2232`
- URL：`https://linear.app/yqeeqy/issue/YQE-28/mimo-guidance-tight-smoke-20260614-074008`
- 标签：`agent:mimo`、`symphony-local-test`
- backend：`mimocode/acp_stdio`
- ACP session：`ses_13aecd032ffeM7anmg73XLue7Y`
- workspace：`/home/gqy47/code/symphony-workspaces-local/YQE-28`
- workspace 文件：`mimo-guidance-tight-smoke-20260614-074008.txt`
- 文件内容：`MiMo guidance tight smoke passed 20260614-074008`
- Linear 最终状态：`Done`
- Linear 评论：`file_verified=true, guidance_tight=true, YQE-28`

复验结果：

- issue 进入 `Done` 后，workspace 仍存在。
- 目标文件存在，内容与指定 phrase 完全一致。
- `od` 复验显示文件无尾随换行，字节内容就是指定 phrase。
- `elixir/log/symphony.log.1` 显示该 issue 被 `mimocode/acp_stdio` 处理，并在 `turn=1/3` 正常完成。
- Linear 评论没有重复完整文件 phrase，但包含 `file_verified=true` 和 `guidance_tight=true` 两个验证标记。
- session 日志中 `symphony-linear_linear_graphql` 命中 22 行，说明 MiMo-Code 确实走了 HTTP MCP `linear_graphql` 工具面。
- 同一时间窗口内 `MCP tools/call tool="linear_graphql"` 共 4 行，其中 `outcome=ok` 为 3 行，`outcome=error` 为 1 行；失败调用没有阻止最终文件验证、评论和状态收尾。
- session 日志中 `write` 命中 2 行、`read` 命中 3 行，符合文件创建和复验路径。
- session 日志中 `Loaded skill: linear`、`Loaded skill: push`、`skill`、`bash` 均为 0 行。
- session 日志中 `Invalid Tool` 命中 2 行，对应一次无效工具探索的开始和完成记录。因此，本次 smoke 不能作为 `Invalid Tool=0` 结论，只能说明进一步收紧后任务仍可完成，并且 `skill` / `bash` 探索已消失。
- session 日志敏感内容抽查中，`lin_api_`、`Authorization`、`commentCreate`、`mutation`、`query` 均为 0 次命中。

结论：YQE-28 继续支持 `acp_stdio + HTTP MCP linear_graphql` 方案。更严格的 runtime guidance 让真实 MiMo-Code 在本次运行中没有再加载本地 `linear` / `push` skill，也没有出现 `bash` 探索；但仍出现一次 `Invalid Tool` 探索。后续优化重点应放在进一步压缩 MiMo-Code 对未暴露工具的探测，而不是改变平级 agent backend 的总体架构。

YQE-28 之后的 namespaced 工具名补强：

- 真实 MiMo-Code 的 session 日志中，有效 MCP 调用显示为 `symphony-linear_linear_graphql`，而不是裸 `linear_graphql`。
- runtime guidance 已补充说明：需要读写 Linear 时使用 `linear_graphql`；如果工具列表展示 namespaced 形式，则使用 `symphony-linear_linear_graphql`。
- `linear_graphql` 的 tool description 也已补充 namespaced 工具名提示，让 MiMo-Code 从工具列表描述中直接看到可用名称。
- 该调整只改变提示层和工具描述，不改变 MCP tools/list 的标准工具名、HTTP MCP endpoint、Linear GraphQL 执行逻辑或鉴权方式。

#### YQE-29：namespaced 工具名补强后 smoke

- Linear issue：`YQE-29`
- Linear id：`f2ea81e3-d7e6-43c3-9ffc-6773039f590a`
- URL：`https://linear.app/yqeeqy/issue/YQE-29/mimo-namespaced-guidance-smoke-20260614-163658`
- 标签：`agent:mimo`、`symphony-local-test`
- backend：`mimocode/acp_stdio`
- ACP session：`ses_13ab6f6dbffe03O08xfTEPQrX1`
- workspace：`/home/gqy47/code/symphony-workspaces-local/YQE-29`
- workspace 文件：`mimo-namespaced-guidance-smoke-20260614-163658.txt`
- 文件内容：`MiMo namespaced guidance smoke passed 20260614-163658`
- Linear 最终状态：`Done`
- Linear 评论标记：`file_verified=true`、`namespaced_guidance=true`、`issue=YQE-29`

复验结果：

- issue 被派给 `agent_id=mimocode`、`agent_kind=acp_stdio`。
- issue 进入 `Done` 后，workspace 仍存在。
- 目标文件存在，内容与指定 phrase 完全一致。
- `od` 复验显示文件无尾随换行，字节内容就是指定 phrase。
- Linear issue 有 1 条评论，包含 `file_verified=true`、`namespaced_guidance=true` 和 `issue=YQE-29`。
- session 日志中 `symphony-linear_linear_graphql` 命中 12 行，说明 MiMo-Code 使用了 namespaced MCP 工具名。
- 同一时间窗口内 `MCP tools/call tool="linear_graphql"` 共 6 行，其中 `outcome=ok` 为 4 行，`outcome=error` 为 2 行；失败调用没有阻止最终文件验证、评论和状态收尾。
- session 日志中 `write` 命中 2 行、`read` 命中 0 行，符合本次文件写入路径。
- session 日志中 `Invalid Tool`、`Loaded skill: linear`、`Loaded skill: push`、`skill`、`bash` 均为 0 行。
- session 日志敏感内容抽查中，`lin_api_`、`Authorization`、`commentCreate`、`mutation`、`query` 均为 0 次命中。

结论：YQE-29 支持 namespaced 工具名补强有效。真实 MiMo-Code 在本次运行中完成文件、Linear 评论和 `Done` 收尾，同时没有出现 `Invalid Tool`、本地 skill 或 `bash` 探索。仍需注意，MCP `linear_graphql` 本身出现了 2 次失败调用，说明后续若继续打磨“像 Codex 一样丝滑”，可以进一步优化 issue prompt 或提供更高层的 Linear 操作模板，减少 GraphQL 查询/变更尝试错误；但这不推翻 `acp_stdio + HTTP MCP linear_graphql` 的总体方案。

YQE-29 之后的 MCP 失败分类补强：

- `MCP tools/call` 低敏摘要日志已增加 `error_category` 字段，用于区分 `invalid_arguments`、`graphql_errors`、`linear_api_status`、`linear_auth`、`linear_api_request`、`unsupported_tool`、`tool_error` 和成功时的 `none`。
- 该分类只从工具结果结构推导，不记录 GraphQL query、variables、GraphQL error message、MCP headers/env 或 Linear token。
- 下一轮真实 smoke 如果仍出现 `outcome=error`，应优先查看 `error_category`，再决定是收紧 prompt、提供 GraphQL 模板，还是补更高层 Linear 工具。

#### YQE-30：MCP error_category 首轮 smoke

- Linear issue：`YQE-30`
- Linear id：`499b2b5d-808b-4e4f-ba09-1e149e986b76`
- URL：`https://linear.app/yqeeqy/issue/YQE-30/mimo-error-category-smoke-20260614-175427`
- backend：`mimocode/acp_stdio`
- ACP session：`ses_13a71efbbffe4iO3mVYLD1Bkso`
- workspace：`/home/gqy47/code/symphony-workspaces-local/YQE-30`
- workspace 文件：`mimo-error-category-smoke-20260614-175427.txt`
- 文件内容：`MiMo error category smoke passed 20260614-175427`
- Linear 最终状态：`Done`
- Linear 评论标记：`file_verified=true`、`error_category_smoke=true`

复验结果：

- issue 进入 `Done` 后，workspace 仍存在。
- 目标文件存在，内容与指定 phrase 完全一致；字节内容为 `4d694d6f206572726f722063617465676f727920736d6f6b65207061737365642032303236303631342d313735343237`。
- Linear issue 有 1 条评论，包含 `file_verified=true` 和 `error_category_smoke=true`。
- session 日志中 `symphony-linear_linear_graphql` 命中 25 行，说明 MiMo-Code 使用了 namespaced MCP 工具名。
- 同一时间窗口内 `MCP tools/call tool="linear_graphql"` 共 7 行，其中 `outcome=ok` 为 4 行，`outcome=error` 为 3 行。
- 3 次失败在首轮分类中均为 `error_category=linear_api_status`。
- session 日志中 `Invalid Tool` 命中 3 行；`Loaded skill: linear`、`Loaded skill: push`、`skill`、`bash` 均为 0 行。
- session 日志敏感内容抽查中，`lin_api_`、`Authorization`、`commentCreate`、`mutation`、`query` 均为 0 次命中。

结论：YQE-30 证明新增 `error_category` 已能在真实 MCP 调用日志中提供低敏失败类别。任务完成、文件和评论均通过，说明这些失败没有阻断 MiMo-Code 收尾。分类结果显示失败集中在 Linear 非 200 分支，下一步应查看 Linear client 对非 200 GraphQL error body 的处理，而不是修改 ACP/MCP 总体架构。

YQE-30 之后的 Linear 非 200 分类修正：

- `Linear.Client.graphql/3` 对非 200 且 body 含 GraphQL `errors` 的响应返回 `{:linear_api_graphql_errors, status}`，不再只返回 `{:linear_api_status, status}`。
- 该分支日志只记录 `status` 和低敏 `error_category=graphql_errors`，不再记录完整 response body、GraphQL error message 或 GraphQL 字段名。
- `linear_graphql` 工具会把该 reason 映射为低敏 payload：`category=graphql_errors` 和 HTTP `status`。
- MCP `tools/call` 日志会将该 payload 归类为 `error_category=graphql_errors`。

#### YQE-31：Linear 非 200 分类修正后 smoke

- Linear issue：`YQE-31`
- Linear id：`8b26539c-0fb7-431d-9493-0e599834d3ff`
- URL：`https://linear.app/yqeeqy/issue/YQE-31/mimo-error-category-resmoke-20260614-181317`
- backend：`mimocode/acp_stdio`
- ACP session：`ses_13a60a3e6ffecfvRiTuFgY3J2c`
- workspace：`/home/gqy47/code/symphony-workspaces-local/YQE-31`
- workspace 文件：`mimo-error-category-resmoke-20260614-181317.txt`
- 文件内容：`MiMo error category resmoke passed 20260614-181317`
- Linear 最终状态：`Done`
- Linear 评论标记：`file_verified=true`、`error_category_resmoke=true`

复验结果：

- issue 进入 `Done` 后，workspace 仍存在。
- 目标文件存在，内容与指定 phrase 完全一致；字节内容为 `4d694d6f206572726f722063617465676f7279207265736d6f6b65207061737365642032303236303631342d313831333137`。
- Linear issue 有 1 条评论，包含 `file_verified=true` 和 `error_category_resmoke=true`。
- session 日志中 `symphony-linear_linear_graphql` 命中 17 行，说明 MiMo-Code 使用了 namespaced MCP 工具名。
- 同一时间窗口内 `MCP tools/call tool="linear_graphql"` 共 8 行，其中 `outcome=ok` 为 5 行，`outcome=error` 为 3 行。
- 3 次失败均为 `error_category=graphql_errors`，说明 YQE-30 中的 `linear_api_status` 已被细分到 GraphQL error body 类别。
- session 日志中 `Invalid Tool` 命中 1 行；`Loaded skill: linear`、`Loaded skill: push`、`skill`、`bash` 均为 0 行。
- session 日志敏感内容抽查中，`lin_api_`、`Authorization`、`commentCreate`、`mutation`、`query` 均为 0 次命中。

结论：YQE-31 继续支持 `acp_stdio + HTTP MCP linear_graphql` 方案。MiMo-Code 能完成文件、Linear 评论和 `Done` 收尾；剩余 MCP 失败被明确归类为 `graphql_errors`，说明下一步“丝滑化”重点应是减少 raw GraphQL 形状尝试错误，例如进一步收紧 prompt、提供 GraphQL 模板，或增加更高层的 Linear 操作工具，而不是改变平级 agent backend 架构。

### 高层 Linear MCP 工具补强

YQE-30/YQE-31 之后的代码补强把 `/mcp/linear-tools` 从单一 raw `linear_graphql` 扩展为四个工具：

- `linear_issue_read`：用固定 query 读取 issue 的 identifier、title、description、state、labels、project、team 和 URL。
- `linear_comment_create`：先用固定 query 解析 issue internal id，再用固定 mutation 创建评论。
- `linear_issue_update_state`：先用固定 query 解析 issue internal id 和目标 state id，再用固定 mutation 更新 issue 状态。
- `linear_graphql`：保留为 lower-level fallback，只在高层工具覆盖不了的 Linear 操作中使用。

运行时 guidance 已同步调整：开启 `mcp.linear_tools: true` 的 `acp_stdio` agent 应优先使用三个高层工具完成常见 Linear 收尾，不再默认要求 MiMo-Code 自己拼 raw GraphQL。`linear_graphql` 的 tool description 也已标明 fallback 定位，并保留 `symphony-linear_linear_graphql` 这个 namespaced 名称提示。

状态更新工具还有一个重要约束：`linear_issue_update_state` 的 description 和 runtime guidance 都必须说明，移动到 terminal state 只能在 workspace 变更和评论完成后最后执行。原因是 Symphony 会在 issue 进入 terminal state 后停止 active agent；如果 agent 过早把 issue 移到 `Done`，当前 turn 可能在后续文件操作前被停止。

下一次真实 smoke 建议创建新的 `agent:mimo` + `symphony-local-test` issue，描述中明确要求：

1. 在 workspace 创建指定文件并写入指定短语。
2. 使用 `linear_issue_read` 查询当前 issue。
3. 使用 `linear_comment_create` 评论文件验证结果。
4. 使用 `linear_issue_update_state` 将 issue 移到 `Done`。
5. 只有高层工具无法覆盖时才使用 `linear_graphql` fallback。

验收重点从“能否调用 MCP”推进为“raw GraphQL 试错是否减少”：

- `MCP tools/call` 日志中应出现 `linear_issue_read`、`linear_comment_create` 和 `linear_issue_update_state`。
- `linear_graphql` 调用应减少或为 0。
- `error_category=graphql_errors` 数量应低于 YQE-31 的 3 次。
- 日志仍不得出现 Linear token、Authorization header、GraphQL query/mutation 文本或 comment body。

#### YQE-32：高层工具 smoke，暴露 terminal 过早收尾问题

- Linear issue：`YQE-32`
- URL：`https://linear.app/yqeeqy/issue/YQE-32/mimo-high-level-mcp-smoke-20260614-191825`
- backend：`mimocode/acp_stdio`
- workspace：`/home/gqy47/code/symphony-workspaces-local/YQE-32`
- 目标文件：`mimo-high-level-mcp-smoke-20260614-191825.txt`
- 目标内容：`MiMo high-level MCP smoke passed 20260614-191825`
- Linear 最终状态：`Done`
- Linear 评论标记：`file_verified=true`、`high_level_tools_smoke=true`

复验结果：

- `tools/list` 已返回 `linear_issue_read`、`linear_comment_create`、`linear_issue_update_state` 和 `linear_graphql`。
- MiMo-Code 真实调用了 `linear_issue_read`、`linear_comment_create` 和 `linear_issue_update_state`，三次 `MCP tools/call` 均为 `outcome=ok`、`error_category=none`。
- Linear issue 已进入 `Done`，并且存在 marker 评论。
- workspace 保留存在，但目标文件名没有出现；对目标内容做精确搜索也没有命中。

结论：YQE-32 证明高层 MCP 工具可以被真实 MiMo-Code 调用，并且能完成 Linear 读取、评论和状态流转；但本次 smoke 不满足文件验收。根因是 MiMo-Code 过早执行 `linear_issue_update_state` 把 issue 移到 terminal state，Symphony 随后停止 active agent，导致文件创建要求没有落盘。该结果不推翻 `acp_stdio + HTTP MCP Linear tools` 方案，但要求补强工具描述和 runtime guidance：移动 terminal state 必须是最后一步。

#### YQE-33：terminal-last guidance 复测，暴露任务理解和文件写入不稳定

- Linear issue：`YQE-33`
- URL：`https://linear.app/yqeeqy/issue/YQE-33/mimo-terminal-last-mcp-smoke-20260614-193647`
- backend：`mimocode/acp_stdio`
- ACP session：`ses_13a1406faffe2othEpXIACcGO5`
- workspace：`/home/gqy47/code/symphony-workspaces-local/YQE-33`
- 目标文件：`mimo-terminal-last-mcp-smoke-20260614-193647.txt`
- 目标内容：`MiMo terminal-last MCP smoke passed 20260614-193647`
- Linear 最终状态：`Done`
- Linear 评论标记：`file_verified=true`、`terminal_last_smoke=true`

复验结果：

- MiMo-Code 真实调用了 `linear_issue_read`、`linear_comment_create` 和 `linear_issue_update_state`，三类高层工具均为成功调用。
- `Invalid Tool`、本地 `linear` / `push` skill、`bash` 探索均为 0。
- 本次不是 terminal state 中途打断：agent turn 正常完成后才结束。
- MiMo-Code session 数据库显示该会话 `summary_files=0`、`summary_diffs=None`。
- workspace 保留存在，但目标文件不存在；对目标内容做精确搜索也没有命中。
- MiMo-Code 的 reasoning 记录显示，它把 issue 描述中的 `$fileName` / `$phrase` 当成未知变量或字面占位，转而读取并验证已有的 `docs/symphony-smoke-test-one.md`、`docs/symphony-smoke-board-review.md`。
- Linear 评论声称完成了文件验证，但实际验证对象不是本次 smoke 指定的目标文件。

结论：YQE-33 证明 terminal-last guidance 只解决了“过早移动到 Done 导致 agent 被停止”的一类问题；它没有解决 MiMo-Code 对任务描述和文件写入要求的遵循问题。高层 Linear MCP 工具链路已经可用，下一步不应继续优先打磨 Linear 工具，而应调研 MiMo-Code 在 ACP 模式下的文件写入/编辑能力、权限请求语义、`permission_policy: reject` 是否影响写入，以及 prompt 模板中 `$fileName` / `$phrase` 这类变量写法是否会诱发误读。

YQE-33 之后的下一步：

- smoke issue 描述改为明确字段，避免 `$fileName`、`$phrase` 这类变量式写法。例如使用“目标文件名：xxx”“精确文件内容：xxx”。
- 明确要求“创建或覆盖指定目标文件”，禁止把已有 `docs/` 文件作为替代验证对象。
- 在评论前要求 agent 先读取目标文件并确认精确内容；在移动 terminal state 前要求文件验证和评论均已完成。
- 调研真实 MiMo-Code ACP 模式下可用的 write/edit 工具、permission request 事件和是否受 `--pure` 或类似隔离模式影响。
- 如果 `permission_policy: reject` 会阻断正常文件写入，需要先设计受限权限策略或 workspace-only 文件工具，再进入实现；不能直接默认放宽权限。

#### 真实 ACP 写文件能力探测

为排除 `--pure` 或 `permission_policy: reject` 直接禁用文件写入，执行了一个不接 Linear 的最小 ACP 探测：

- workspace：`/tmp/mimo-acp-write-probe-6530`
- 启动参数：`mimo acp --cwd <workspace> --pure`
- permission policy：`reject`
- prompt：要求创建 `acp-write-probe.txt`，写入精确内容 `MiMo ACP write probe passed.`，再读回验证。
- ACP session：`ses_139f4cf13ffe7vksWMXcXkEuA0`

结果：

- MiMo-Code 使用自身 `edit` 工具写入文件，并使用 `read` 工具读回验证。
- 未观察到 `permission_rejected` 或 `permission_required` 事件。
- 目标文件存在，内容为 `MiMo ACP write probe passed.`。

结论：在当前本机环境中，`--pure` 加 `permission_policy: reject` 不会阻止 MiMo-Code 完成简单 workspace 文件写入。YQE-33 的主因更偏向 issue 描述中的目标文件/内容语义不清，以及 MiMo-Code 在缺少明确目标时用已有文件替代验证。

#### 阶段 3B runtime guidance 补强

基于 YQE-33 和真实 ACP 写文件探测，`AgentRunner` 的 ACP Linear MCP runtime guidance 已增加以下约束：

- issue 描述中的目标文件名和精确文件内容应作为字面任务数据处理。
- 不要把 `$fileName`、`$phrase` 这类字符串当成需要自行解析的变量。
- 不要用已有仓库文件替代被请求的目标文件。
- 成功评论前必须读回目标文件并验证精确内容。
- 如果目标文件名或精确内容缺失/含糊，应评论 blocked，且不要把 issue 移到 terminal state。

`linear_comment_create` 和 `linear_issue_update_state` 的 MCP tool description 也同步补强：前者要求只在验证 workspace evidence 后报告成功，后者要求 workspace evidence 缺失或未验证时不得移动到 terminal state。

#### 阶段 3B issue 模板生成

为避免再次手工写出 `$fileName` / `$phrase` 这类容易被 MiMo-Code 误读的描述，新增本地模板生成任务：

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix mimo.phase3b_smoke'
```

如需固定时间戳以便复验：

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix mimo.phase3b_smoke --timestamp 20260614-202500'
```

该任务只输出 Linear issue 标题、标签和描述，不读取或写入 Linear API。输出描述使用明确字段：

- `目标文件名：...`
- `精确文件内容：...`

并明确要求按顺序执行：创建/覆盖目标文件、写入精确内容、读回验证、`linear_issue_read`、`linear_comment_create`、最后 `linear_issue_update_state` 移动到 `Done`。如果目标文件名或精确内容缺失/含糊，agent 应评论 blocked，不得移动到 `Done`。

2026-06-14 复核：

- Mix task 模块名使用 `Mix.Tasks.Mimo.Phase3bSmoke`，确保对外命令名是 `mimo.phase3b_smoke`，而不是 Mix 会从 `Phase3BSmoke` 推导出的 `mimo.phase3_b_smoke`。
- `mix test test/mix/tasks/mimo_phase3b_smoke_test.exs` 结果：`4 tests, 0 failures`。
- `mix mimo.phase3b_smoke --timestamp 20260614-202500` 已验证可以直接输出模板，并且输出不包含 `$fileName` 或 `$phrase`。
- 后续带 Linear API key 的真实复测见 YQE-34。

#### YQE-34：阶段 3B 明确字段模板真实 smoke

- Linear issue：`YQE-34`
- Linear id：`a96c5516-18bd-4815-9c04-c80872c5a9e1`
- URL：`https://linear.app/yqeeqy/issue/YQE-34/mimo-phase-3b-guidance-smoke-20260614-212237`
- 标签：`agent:mimo`、`symphony-local-test`
- backend：`mimocode/acp_stdio`
- ACP session：`ses_139b11bc9ffe0hdEdSIOiVHIrk`
- workspace：`/home/gqy47/code/symphony-workspaces-local/YQE-34`
- 目标文件：`mimo-phase-3b-smoke-20260614-212237.txt`
- 目标内容：`MiMo phase 3B smoke passed 20260614-212237`
- 文件 sha256：`ecfe4a0fb1b56da03eb36c2f14bd48d6cbe659c890e9a0a643c9c293c7f56f46`
- Linear 最终状态：`Done`
- Linear 评论标记：`file_verified=true`、`phase_3b_guidance=true`、`identifier=YQE-34`

复验结果：

- 目标文件存在，内容与 issue 描述中的精确内容完全一致。
- MiMo-Code session 数据库显示 `summary_files=1`、`summary_additions=1`、`summary_deletions=0`，目录为 `/home/gqy47/code/symphony-workspaces-local/YQE-34`。
- 低敏结构化日志显示本次 issue 被派给 `agent_id=mimocode`、`agent_kind=acp_stdio`。
- ACP session/update 中出现目标文件写入和读回：`write` 完成 `mimo-phase-3b-smoke-20260614-212237.txt`，随后 `read` 读回同一文件。
- `MCP tools/call` 中 `linear_issue_read`、`linear_comment_create`、`linear_issue_update_state` 均为 `outcome=ok`、`error_category=none`。
- 本次 21:25 时间窗口内 `linear_graphql` 调用为 0；该 session 中未命中 `symphony-linear_linear_graphql` 或 `Invalid Tool`。
- `linear_issue_update_state` 在文件写入、读回、评论之后执行，符合 terminal state 最后收尾的约束。
- worker 正常完成后曾出现一次 continuation retry warning；由于 issue 已经进入 terminal state，后续 running/retrying 会清空。该现象属于可观测噪音，不影响本次 smoke 结论。

后续修正：

- 已按 TDD 修正 terminal issue 正常完成后的 continuation retry 噪音。AgentRunner 会把每轮刷新后的 issue 快照发回 Orchestrator；Orchestrator 在 worker 正常退出时，如果快照已是 terminal state，会直接清理 workspace、标记完成并释放 claim，不再排 1s continuation retry。
- 对应验证覆盖 `AgentRunner` 的刷新 issue 回传，以及 Orchestrator 对“正常退出 + terminal 快照”的无 retry 行为；active issue 正常退出后的 continuation retry 行为保持不变。

结论：YQE-34 通过阶段 3B 验收。明确字段模板、runtime guidance 和高层 Linear MCP 工具描述补强后，真实 MiMo-Code 能先完成 workspace 文件落盘和读回验证，再用高层 Linear 工具评论并移动到 `Done`。该结果不推翻 `acp_stdio + HTTP MCP Linear tools` 方案。

#### YQE-35：terminal no-retry 修复后真实 smoke

- Linear issue：`YQE-35`
- Linear id：`ffc6e2de-ccc7-4076-8877-60a6b64436f2`
- URL：`https://linear.app/yqeeqy/issue/YQE-35/mimo-phase-3b-no-retry-smoke-20260614-144901`
- 标签：`agent:mimo`、`symphony-local-test`
- backend：`mimocode/acp_stdio`
- ACP session：`ses_139644e76ffeJKm2d0lOv9z8zN`
- workspace：`/home/gqy47/code/symphony-workspaces-local/YQE-35`
- 目标文件：`mimo-phase-3b-smoke-20260614-144901.txt`
- 目标内容：`MiMo phase 3B smoke passed 20260614-144901`
- 文件 sha256：`c9f156743332df93204e7dee192649ea46b6f20fc5b2ac7174aea468694616c0`
- Linear 最终状态：`Done`
- Linear 评论标记：`file_verified=true`、`phase_3b_no_retry=true`

复验结果：

- 目标文件存在，内容与 issue 描述中的精确内容完全一致。
- MiMo-Code session 数据库显示 `summary_files=1`、`summary_additions=1`、`summary_deletions=0`，目录为 `/home/gqy47/code/symphony-workspaces-local/YQE-35`。
- Dashboard 日志显示本次 issue 被派给 `mimocode`，并出现 `write`、目标文件名、`read`、`symphony-linear_linear_comment_create`、`symphony-linear_linear_issue_update_state` 等关键动作。
- 本地 `/api/v1/state` 在完成后显示 `running=[]`、`retrying=[]`、`blocked=[]`。
- `/tmp/symphony-local.log` 中按 `continuation` 和 `Retrying issue_id=ffc6e2de` 搜索均无命中，说明 terminal issue 正常完成后没有再排 1s continuation retry。

结论：YQE-35 证明 terminal no-retry 修复在真实 `mimocode/acp_stdio` 运行中生效。MiMo-Code 仍能完成文件落盘、读回验证、Linear 评论和 `Done` 收尾；Orchestrator 在 terminal 快照下直接释放 claim，不再产生短暂 retry 噪音。

#### 日志安全补强

YQE-19 之后继续复核真实服务日志，发现两类可观测性风险：

- Linear request error 分支曾直接 `inspect(reason)`，当底层 HTTP client 把无效 Authorization header 放进错误结构时，日志可能包含 `lin_api_` 形式的 token。
- Phoenix route dispatch 日志会记录 `/mcp/linear-tools` 的完整 request params，其中包含 `linear_graphql` 的 GraphQL query、mutation 和 variables。

修复口径：

- `Linear.Client.graphql/3` 在 request error 日志中对 `lin_api_...` 和 Authorization header 值做脱敏，调用方收到的错误 term 保持不变。
- `/mcp/linear-tools` 独立放入 `log: false` 的 Phoenix scope，关闭该 route 的参数日志；保留 endpoint 基础请求日志和 `MCP tools/call tool="linear_graphql" outcome=... error_category=...` 低敏摘要日志。
- 保持 MCP tool call 日志不记录 GraphQL query、tool arguments、MCP headers/env 或 Linear token。

新增回归验证：

```powershell
wsl.exe -e bash -lc "cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir/extensions_test.exs"
```

结果：`60 tests, 0 failures`。

扩展验证：

```powershell
wsl.exe -e bash -lc "cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/acp_backend_registration_test.exs test/symphony_elixir/acp_stdio_client_test.exs test/symphony_elixir/acp_stdio_backend_test.exs test/symphony_elixir/acp_agent_runner_test.exs test/symphony_elixir/core_test.exs test/symphony_elixir/orchestrator_status_test.exs test/symphony_elixir/dynamic_tool_test.exs test/symphony_elixir/agent_tool_test.exs test/symphony_elixir/mcp_server_test.exs test/symphony_elixir/extensions_test.exs test/symphony_elixir/workspace_and_config_test.exs"
```

结果：`240 tests, 0 failures`。

```powershell
wsl.exe -e bash -lc "cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix specs.check"
```

结果：`specs.check: all public functions have @spec or exemption`。

注意：历史日志文件中已经写入的旧泄漏行不会被代码修复自动清除。生产或长期保留环境应按运维策略轮转、归档或删除旧日志；新代码的目标是阻止同类泄漏再次写入。

磁盘日志补充验证：

- `SymphonyElixir.LogFile` 使用 OTP wrap disk log handler，配置路径为 `log/symphony.log` 时，实际内容文件是 `log/symphony.log.1`，旁边还有 `.idx` / `.siz` 管理文件。
- 临时探测确认 info 级低敏日志会写入 wrap 文件，例如 `MCP tools/call tool="linear_graphql" outcome=ok is_error=false error_category=none`。
- 因此如果真实服务日志中未看到新的 `ACP session/update` 或 `MCP tools/call` 行，优先检查服务是否已经重启到新 escript、是否触发了对应事件，以及是否查看了当前 wrap 文件，而不是只检查裸 `log/symphony.log` 路径。

## 稳定 smoke issue 模板

后续创建真实 `agent:mimo` smoke issue 时，优先使用本节模板，避免手写出 `$fileName`、`$phrase` 这类容易被 MiMo-Code 当作变量或占位符的描述。

标题：

```text
MiMo phase 3B smoke <YYYYMMDD-HHMMSS>
```

标签：

```text
agent:mimo
symphony-local-test
```

描述：

```text
这是 Symphony 本地 MiMo-Code ACP + MCP Linear 工具 smoke。

目标文件名：mimo-phase-3b-smoke-<YYYYMMDD-HHMMSS>.txt
精确文件内容：MiMo phase 3B smoke passed <YYYYMMDD-HHMMSS>

请按顺序执行：

1. 在当前 issue workspace 中创建或覆盖目标文件。
2. 写入上面给出的精确文件内容，不要添加额外文本。
3. 读回目标文件，确认内容与精确文件内容完全一致。
4. 使用 linear_issue_read 读取当前 issue。
5. 使用 linear_comment_create 评论验证结果，评论中包含 file_verified=true、目标文件名和内容匹配结论。
6. 最后使用 linear_issue_update_state 将 issue 移动到 Done。

限制：

- 不要使用已有 docs/ 文件替代目标文件。
- 不要把目标文件名或精确文件内容当作变量、shell 占位符或模板表达式。
- 只有高层 Linear MCP 工具无法覆盖时，才使用 linear_graphql fallback。
- 如果目标文件名或精确文件内容缺失、含糊，评论 blocked，并且不要移动到 Done。
- 在目标文件创建、读回验证和评论完成前，不要调用 linear_issue_update_state。
```

也可以用本地 mix task 生成模板：

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix mimo.phase3b_smoke'
```

固定时间戳复验：

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix mimo.phase3b_smoke --timestamp 20260614-202500'
```

## 失败时证据清单

真实 smoke 失败时，不要只记录“MiMo 没成功”。至少采集下列证据，方便判断是路由、runtime、工具、任务理解、workspace 还是 terminal 顺序问题：

- Linear issue identifier、Linear id、URL、初始状态、最终状态、labels。
- dashboard/API 中的 `agent_id`、`agent_kind`、`session_id`、`turn_count`、last message。
- workspace 绝对路径，目标文件是否存在，目标文件内容和 sha256。
- MiMo-Code session 数据库摘要：`summary_files`、`summary_additions`、`summary_deletions`、session cwd。
- ACP `session/update` 中是否出现目标文件 `write` / `read`。
- MCP `tools/call` 中是否出现 `linear_issue_read`、`linear_comment_create`、`linear_issue_update_state`，以及各自的 `outcome` 和 `error_category`。
- 是否出现 `linear_graphql` fallback、`Invalid Tool`、本地 `linear` / `push` skill、shell/git/push 探索。
- `/api/v1/state` 完成后是否仍有 `running`、`retrying` 或 `blocked` 残留。
- 日志中是否出现 continuation retry，尤其是 terminal issue 正常完成后是否仍被安排 1s retry。
- 日志中是否包含敏感信息；如果出现 token、GraphQL body、headers/env、comment body 或 tool args，应先修复低敏日志问题。

判断口径：

- 如果 issue 没有被 `mimocode/acp_stdio` 承接，先查 `WORKFLOW.local.md`、label、routing 和服务是否重启到新 escript。
- 如果 ACP session 无法创建，先查真实 MiMo-Code 版本、`mcpServers` schema、cwd 和 `config_options.model`。
- 如果 Linear 工具没有出现，先查 MCP descriptor 注入和 `mcp.linear_tools: true`，不要先改 Linear 工具核心。
- 如果 Linear 收尾成功但目标文件不存在，优先查 terminal state 是否过早移动，以及 smoke 描述是否使用了含糊变量式字段。
- 如果目标文件存在但 issue 未收尾，优先查高层 Linear MCP 工具调用结果、permission 请求和 timeout。

如果实测显示 MiMo-Code 无法消费 ACP `mcpServers` 或无法调用 MCP tool，需要暂停实现并回到 `docs/superpowers/specs/2026-06-14-acp-mcp-linear-tools-design.md` 重新评估总体方案。
