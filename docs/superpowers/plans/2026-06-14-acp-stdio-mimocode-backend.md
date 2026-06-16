# ACP Stdio MiMo-Code Backend 实施计划

> **面向 agent worker：** 实施本计划时必须使用 `superpowers:subagent-driven-development`（推荐）或 `superpowers:executing-plans`，并按任务逐项执行。步骤使用 checkbox（`- [ ]`）语法跟踪进度。

**目标:** 让 MiMo-Code 通过 ACP stdio 作为与 Codex 平级的 agent backend 接入 Symphony，并能通过 Linear issue 路由承接任务。

**架构:** 在现有多 agent 编排模型上新增 `acp_stdio` session backend。Symphony 仍然以 Linear issue 为任务边界，Orchestrator 负责调度、并发、重试和 workspace 生命周期，AgentRunner 只依赖 `start_session/3`、`run_turn/5`、`stop_session/1` 这类 session backend contract。MiMo-Code 的 ACP 协议细节封装在 `AcpStdio.Client` 中，避免污染 Codex app-server backend 和 Orchestrator。

**技术栈:** Elixir、ExUnit、Jason、Erlang Port、ACP v1 JSON-RPC over ndjson stdio、MiMo-Code `mimo acp`、Linear issue routing。

---

## 本轮范围

本轮只做 MiMo-Code 的 ACP stdio 接入闭环。

包含：
- 新增 `acp_stdio` agent backend kind。
- 实现 ACP stdio client 和 `AcpStdio` session backend。
- 通过 `agent:mimo -> mimocode` 这类路由规则把 Linear issue 派给 MiMo-Code。
- 用 fake ACP server 覆盖协议行为。
- 做真实 `mimo acp` smoke test，并记录真实环境差异。

不包含：
- OpenCode 复用同一 backend（仅保留为后续占位）。
- OpenCode 的 `acp` / `serve` 能力验证。
- HTTP server backend。
- 将 dashboard 历史字段从 `codex_*` 一次性迁移到 `agent_*`。
- 修改 MiMo-Code 本体实现。

OpenCode 复用只作为后续占位保留，本轮明确跳过，不进入执行任务，也不作为本轮验收条件。

## 阶段执行原则

本轮纳入执行的阶段只有阶段 0、1、2、3 和 3B。每个阶段都按“前期调研 -> 设计 -> 实现 -> 验证”的顺序推进；如果真实 MiMo-Code 行为推翻当前假设，先修订方案文档，再继续后续实现。OpenCode 复用只作为原阶段 4 占位保留，本轮跳过，也不允许在本轮验收中要求 OpenCode smoke 通过。

## 设计依据

`SPEC.md` 对 Symphony 的定位是 scheduler/runner，而不是 agent 互相嵌套调用的工具层。按这个模型，Codex、MiMo-Code 和后续其他 agent 应该在配置与调度层平级：

```yaml
agents:
  codex:
    kind: codex_app_server
    command: "codex app-server"

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
    timeout_ms: 3600000
    read_timeout_ms: 60000
    close_timeout_ms: 3000

routing:
  default_agent: codex
  by_label:
    "agent:mimo": mimocode
    "agent:codex": codex
```

如果 Codex 要把工作交给 MiMo-Code，推荐动作是创建或更新 Linear issue，并打上 `agent:mimo` 标签。Symphony 下一轮轮询后会根据路由规则把该 issue 派给 `mimocode` backend。这样任务边界、状态变更和审计记录仍保留在 Linear 中，符合 SPEC 的编排模型。

## 已知真实 MiMo-Code 差异

当前真实环境中的 MiMo-Code 入口为：

```text
/home/gqy47/.npm-global/bin/mimo
```

已确认：
- `mimo acp --help` 可用。
- 包版本为 `@mimo-ai/cli@0.1.0`。
- `session/new.params.mcpServers` 必须是数组；即使没有 MCP server，也应发送 `mcpServers: []`。
- `initialize.result.agentCapabilities` 当前未声明 `sessionCapabilities.close`；未声明时不能无条件发送 `session/close`，应直接关闭 stdio port。
- 真实 prompt smoke 曾进入 `session/prompt` 后持续收到 `session/update` 但未完成。Symphony 需要支持 ACP `session/set_config_option`，通过 `config_options` 设置例如 `model: "mimo/mimo-auto"` 的 coding model。
- permission 的 `allow_once` 不应硬编码为固定字符串，应优先使用 agent 返回的 option 中 `kind == "allow_once"` 的 `optionId`，再回退到 `"once"`。
- 真实 prompt smoke 已能进入 `session/prompt` 并收到 `session/update`，但曾在 60 秒内未完成；当前实现已支持通过 ACP `session/set_config_option` 设置 coding model，后续真实 smoke 应继续验证该配置是否能改善 completion。
- 真实 ACP 写文件探测显示，`mimo acp --pure` 加 `permission_policy: reject` 仍能通过 MiMo-Code 自身 `edit` 工具创建并读回临时文件；当前没有证据表明简单 workspace 文件写入被 `--pure` 或 `reject` 阻断。

---

## 文件结构

- Modify: `elixir/lib/symphony_elixir/config.ex`
  - 校验 `agents.<id>.kind = acp_stdio`、`args`、`permission_policy`、`close_timeout_ms` 等配置。

- Modify: `elixir/lib/symphony_elixir/agent/backend.ex`
  - 将 `"acp_stdio"` 映射到 `SymphonyElixir.Agent.Backend.AcpStdio`。

- Create/Modify: `elixir/lib/symphony_elixir/agent/acp_stdio/client.ex`
  - 管理 ACP stdio 子进程、JSON-RPC request id、ndjson buffering、response 匹配、notification 转发、permission reply、timeout、cancel 和 close。

- Create/Modify: `elixir/lib/symphony_elixir/agent/backend/acp_stdio.ex`
  - 实现 Symphony session backend contract，并将 ACP 事件映射为 backend-neutral agent event。

- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`
  - 确保 session backend 可按 `agent:mimo` 路由承接 issue，并在同一 worker attempt 内复用 ACP session。

- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
  - 对 `acp_stdio` 按 `turn_started` 计数，避免把 ACP session 数误当成 turn 数。

- Modify: `elixir/lib/symphony_elixir/status_dashboard.ex`
  - 对 ACP `session/update` 做最小可读化，例如 `agent update: ...`、`agent tool call: ...`。

- Modify: `elixir/test/support/fake_acp_server.exs`
  - 提供 fake ACP server，用于稳定覆盖协议边界，不依赖真实 MiMo-Code。

- Modify: `elixir/test/symphony_elixir/acp_stdio_client_test.exs`
  - 覆盖 client 启动、prompt、permission、unsupported request、拆包、timeout、close timeout、usage 等行为。

- Modify: `elixir/test/symphony_elixir/acp_stdio_backend_test.exs`
  - 覆盖 backend event annotation、turn result、permission policy、错误传播。

- Modify: `elixir/test/symphony_elixir/acp_agent_runner_test.exs`
  - 覆盖 `AgentRunner` 使用 `acp_stdio` session backend。

- Modify: `elixir/test/symphony_elixir/core_test.exs`
  - 覆盖配置解析和校验。

- Modify: `elixir/test/symphony_elixir/orchestrator_status_test.exs`
  - 覆盖 turn count、usage aggregation、dashboard 可读事件。

- Modify: `elixir/docs/mimocode_acp_smoke_test.md`
  - 记录真实 MiMo-Code smoke test 命令、结果和阻塞项。

- Modify: `elixir/docs/multi_agent_backends.md`
  - 说明 `acp_stdio` 的配置方式和能力边界。

- Modify: `elixir/docs/agent_runtime_capability_matrix.md`
  - 对比 Codex app-server、MiMo-Code ACP、`cli_run` 的能力差异。

---

## 阶段 0：前期调研门禁

**目标:** 确认方案不是建立在错误事实上。

**交付物:**
- `elixir/docs/mimocode_acp_smoke_test.md`
- MiMo-Code ACP 能力记录。
- 本机/WSL 可执行路径记录。

- [x] **Step 1: 确认真实命令存在**

Run:

```powershell
wsl.exe -e bash -lc 'test -x /home/gqy47/.npm-global/bin/mimo && /home/gqy47/.npm-global/bin/mimo acp --help'
```

Expected: 输出 `mimo acp` 帮助，不要求 prompt 成功。

- [x] **Step 2: 记录 ACP 基础能力**

在 `elixir/docs/mimocode_acp_smoke_test.md` 记录：

```markdown
## ACP 能力结论

- 启动命令：`/home/gqy47/.npm-global/bin/mimo acp --cwd <workspace>`
- 协议层：ACP v1 JSON-RPC over ndjson stdio
- 基础流程：`initialize` -> `session/new` -> `session/prompt`
- 运行事件：`session/update`
- 取消：`session/cancel`
- 权限请求：`session/request_permission`
- MiMo-Code 兼容点：`session/new.params.mcpServers` 必须为数组，默认传 `[]`
- close 能力：仅当 initialize 声明 `sessionCapabilities.close` 时发送 `session/close`
```

- [x] **Step 3: 判断是否继续**

如果 `mimo acp` 无法启动，可以继续 fake server 开发，但真实验收标记为未通过。

如果 `mimo acp` 不支持 ACP v1 基础方法，暂停后续实现并修订设计文档。

---

## 阶段 1：配置层和 backend 注册

**目标:** 让 Symphony 承认 `acp_stdio` 是合法 backend。

**Files:**
- Modify: `elixir/lib/symphony_elixir/config.ex`
- Modify: `elixir/lib/symphony_elixir/agent/backend.ex`
- Test: `elixir/test/symphony_elixir/core_test.exs`
- Test: `elixir/test/symphony_elixir/agent_backend_test.exs`

- [x] **Step 1: 写失败测试，允许 acp_stdio 配置**

测试应覆盖：

```elixir
agents: %{
  mimocode: %{
    kind: "acp_stdio",
    command: "/home/gqy47/.npm-global/bin/mimo",
    args: ["acp", "--cwd", "{{workspace}}"],
    permission_policy: "reject",
    timeout_ms: 3_600_000,
    read_timeout_ms: 60_000,
    close_timeout_ms: 3_000
  }
},
routing: %{by_label: %{"agent:mimo" => "mimocode"}}
```

Expected: 配置解析成功，路由表保留 `agent:mimo -> mimocode`。

- [x] **Step 2: 写失败测试，拒绝错误配置**

覆盖：
- `args` 不是字符串列表。
- `permission_policy` 不是 `reject`、`fail`、`allow`。
- `close_timeout_ms` 不是正整数。
- 未知 `kind` 报错信息包含允许值。

- [x] **Step 3: 实现配置校验**

实现要求：
- `@supported_agent_kinds` 包含 `"acp_stdio"`。
- `args` 可省略；存在时必须是字符串列表。
- `permission_policy` 默认由 backend 解释为 `reject`。
- `close_timeout_ms` 可省略；存在时必须为正整数。

- [x] **Step 4: 注册 backend**

实现：

```elixir
def module_for("acp_stdio"), do: SymphonyElixir.Agent.Backend.AcpStdio
```

- [x] **Step 5: 验证阶段 1**

Run:

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/core_test.exs test/symphony_elixir/agent_backend_test.exs'
```

Expected: 新增配置和 backend 注册测试通过。

---

## 阶段 2：ACP client 和 session backend

**目标:** 用 fake ACP server 锁定 Symphony 侧协议行为。

**Files:**
- Create/Modify: `elixir/lib/symphony_elixir/agent/acp_stdio/client.ex`
- Create/Modify: `elixir/lib/symphony_elixir/agent/backend/acp_stdio.ex`
- Modify: `elixir/test/support/fake_acp_server.exs`
- Test: `elixir/test/symphony_elixir/acp_stdio_client_test.exs`
- Test: `elixir/test/symphony_elixir/acp_stdio_backend_test.exs`

- [x] **Step 1: 扩展 fake ACP server**

fake server 必须支持：
- `initialize`
- `session/new`
- `session/prompt`
- `session/cancel`
- 可选 `session/close`
- `session/request_permission`
- 发送 `session/update`
- 故意拆分 ndjson 行
- 在目标 response 后追加 notification 或 client request
- 返回 usage
- 模拟 prompt timeout 和 close timeout

- [x] **Step 2: 写 client 基础流程测试**

覆盖：
- 启动子进程。
- `initialize` 成功。
- `session/new` 默认携带 `mcpServers: []`。
- `config_options` 会在 `session/new` 后通过 `session/set_config_option` 发送，参数使用 `configId` 和 `value`。
- 返回 `session_started`。
- `session/prompt` 成功后返回 `turn_completed`。
- prompt result 中的 usage 被提升到顶层 event `usage`。

- [x] **Step 3: 写权限策略测试**

覆盖：
- `permission_policy: reject` 自动拒绝并记录 `permission_rejected`。
- `permission_policy: fail` 记录 `approval_required`，drain 当前 prompt response 后返回 `{:error, {:permission_required, payload}}`。
- `permission_policy: allow` 优先选择 `kind == "allow_once"` 的 `optionId`，再回退 `"once"`。

- [x] **Step 4: 写 transport 稳定性测试**

覆盖：
- ndjson 拆包后仍能解析完整 JSON。
- target response 后的 trailing notification 会被处理。
- unsupported agent -> client request 返回 JSON-RPC error，并记录 `unsupported_request`。
- malformed JSON 记录 `malformed`，不直接卡死 session。

- [x] **Step 5: 写 timeout 和清理测试**

覆盖：
- `session/prompt` timeout 按绝对 deadline 计算，不被持续 `session/update` 续期。
- prompt timeout 只发送一次 `session/cancel`。
- startup timeout 和 close timeout 不发送 cancel。
- handshake 失败后清理已启动子进程。
- 未声明 close capability 时不发送 `session/close`，直接关闭 port。
- `close_timeout_ms` 生效，卡住时可兜底回收子进程。

- [x] **Step 6: 实现 `AcpStdio.Client`**

实现要求：
- 使用 Erlang Port 启动 `command + args`。
- ACP 子进程 cwd 必须是 issue workspace。
- 同时在 `session/new` 中传 workspace 绝对路径。
- request id 单调或唯一。
- stdout 按 ndjson buffering 处理。
- stderr 不混入协议流；需要时仅记录摘要。
- JSON-RPC error 保留原始 error payload。

- [x] **Step 7: 实现 `AcpStdio` backend**

实现要求：
- `start_session/3` 包装 client session，并写入 `agent_id`、`agent_kind`、timeout 配置。
- backend 将 agent config 中的 `config_options` 透传给 ACP client。
- `run_turn/5` 发送当前 prompt，发出 `turn_started` 和 `turn_completed` / `turn_failed` / `turn_cancelled`。
- `stop_session/1` 按 close capability 和 `close_timeout_ms` 清理。
- 保留历史兼容字段 `codex_app_server_pid`，同时事件中携带 `agent_id` 和 `agent_kind`。

- [x] **Step 8: 验证阶段 2**

Run:

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/acp_stdio_client_test.exs test/symphony_elixir/acp_stdio_backend_test.exs'
```

Expected: ACP client/backend 测试通过。

---

## 阶段 3：AgentRunner、Linear 路由和观测

**目标:** 证明 Linear issue 可以被派给 MiMo-Code backend 执行。

**Files:**
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Modify: `elixir/lib/symphony_elixir/status_dashboard.ex`
- Test: `elixir/test/symphony_elixir/acp_agent_runner_test.exs`
- Test: `elixir/test/symphony_elixir/orchestrator_status_test.exs`
- Test: `elixir/test/symphony_elixir/core_test.exs`

- [x] **Step 1: 写 AgentRunner 集成测试**

测试场景：
- 配置 `routing.by_label.agent:mimo = mimocode`。
- issue 带 `agent:mimo` 标签。
- `AgentRunner` 启动 `acp_stdio` session backend。
- fake server 收到 prompt。
- worker attempt 正常结束或按 issue 状态继续下一 turn。

- [x] **Step 2: 写 continuation 测试**

覆盖：
- 同一 worker attempt 内连续两个 `run_turn/5` 复用同一个 ACP session。
- `turn_count` 按 `turn_started` 增加为 2，而不是按 `session_started` 只计 1。
- continuation prompt 使用 backend-neutral 文案，例如 `previous agent turn`，不包含 `previous Codex turn`。

- [x] **Step 3: 写 dashboard humanize 测试**

覆盖：
- ACP 文本更新显示为 `agent update: ...`。
- ACP tool call 更新显示为 `agent tool call: ...`。
- running row 中能看到 `agent_id=mimocode`、`agent_kind=acp_stdio`。

- [x] **Step 4: 实现 AgentRunner 和 Orchestrator 适配**

实现要求：
- `AgentRunner` 不根据 backend kind 写死 Codex 逻辑，只依赖 session backend contract。
- Orchestrator 对 `acp_stdio` 按 turn event 更新计数。
- token usage 继续进入现有 aggregate 逻辑。

- [x] **Step 5: 执行真实 MiMo-Code smoke**

建议命令：

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && /home/gqy47/.npm-global/bin/mimo acp --help'
```

如果需要最小 prompt smoke，应记录：
- 使用的 workspace。
- 使用的 model/config option。
- 是否收到 `session/update`。
- 是否收到 prompt completion。
- 如果超时，记录 timeout 时间、最后一条 update 和疑似原因。

- [x] **Step 6: 验证阶段 3**

Run:

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/acp_agent_runner_test.exs test/symphony_elixir/core_test.exs test/symphony_elixir/orchestrator_status_test.exs'
```

Expected: runner、路由和观测测试通过。

---

## 阶段 3B：MiMo-Code 文件落盘与任务理解稳定性收敛

**目标:** 在高层 Linear MCP 工具已经可用的前提下，确认 MiMo-Code 能可靠完成 workspace 变更，再把 Linear issue 移出 active state。

**背景证据:**
- YQE-32 证明高层 Linear MCP 工具可用，但 MiMo-Code 过早调用 `linear_issue_update_state` 移到 `Done`，导致目标文件未落盘。
- YQE-33 证明 terminal-last guidance 生效后，MiMo-Code 仍可能把 `$fileName` / `$phrase` 当成未知变量，转而验证已有 `docs/` 文件，最终 `summary_files=0`。
- 单独真实 ACP 写文件探测证明，`--pure` 加 `permission_policy: reject` 不会阻断简单文件写入；失败主因更偏任务描述和执行顺序。
- YQE-34 证明明确字段模板和阶段 3B guidance 生效：目标文件内容精确匹配，session summary 显示 `summary_files=1`，三个高层 Linear MCP 工具均调用成功。
- YQE-35 证明 terminal no-retry 修复在真实 `mimocode/acp_stdio` 路径生效：目标文件和 Linear 收尾仍成功，且 terminal issue 正常完成后没有再安排 1s continuation retry。

- [x] **Step 1: 写 failing guidance 测试**

在 `elixir/test/symphony_elixir/acp_agent_runner_test.exs` 中扩展 Linear MCP guidance 断言：

```elixir
assert prompt_line =~ "Treat target file names and exact file contents in the issue description as literal task data"
assert prompt_line =~ "do not treat strings such as `$fileName` or `$phrase` as variables to resolve"
assert prompt_line =~ "Do not substitute an existing repository file for a requested target file"
assert prompt_line =~ "Before creating a success comment, read back the exact target file"
assert prompt_line =~ "If the target file name or exact content is missing or ambiguous, report blocked"
```

Run:

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/acp_agent_runner_test.exs test/symphony_elixir/agent_tool_test.exs'
```

Expected: FAIL，因为旧 guidance 没有阶段 3B 防误读约束。

- [x] **Step 2: 写 failing tool description 测试**

在 `elixir/test/symphony_elixir/agent_tool_test.exs` 中断言：

```elixir
assert comment_description =~ "verified the requested workspace evidence"
assert update_description =~ "Do not move to a terminal state when required workspace evidence is missing"
```

Expected: FAIL，因为旧高层工具描述只强调 terminal-last，没有覆盖 workspace evidence 缺失时不得报告成功或移动终态。

- [x] **Step 3: 实现最小 guidance 和 tool description 补强**

修改：
- `elixir/lib/symphony_elixir/agent_runner.ex`
- `elixir/lib/symphony_elixir/agent/tool/linear_comment_create.ex`
- `elixir/lib/symphony_elixir/agent/tool/linear_issue_update_state.ex`

实现要求：
- 目标文件名和精确内容按字面任务数据处理。
- 不把 `$fileName` / `$phrase` 当成待解析变量。
- 不用已有仓库文件替代请求的目标文件。
- 成功评论前必须读回目标文件并验证精确内容。
- 目标缺失或含糊时评论 blocked，不移动 terminal state。

- [x] **Step 4: 验证阶段 3B 单元行为**

Run:

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/acp_agent_runner_test.exs test/symphony_elixir/agent_tool_test.exs test/symphony_elixir/mcp_server_test.exs test/symphony_elixir/dynamic_tool_test.exs'
```

Expected: PASS。

- [x] **Step 5: 执行真实 Linear smoke**

前置条件：
- 本地服务以 `elixir/WORKFLOW.local.md` 启动。
- `LINEAR_API_KEY` 在启动环境中可用。
- 新 issue 带 `agent:mimo` 和 `symphony-local-test` label。

先生成明确字段版 issue 模板：

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix mimo.phase3b_smoke'
```

issue 描述必须使用模板中的明确字段，不使用 `$fileName` / `$phrase`：

```markdown
目标文件名：mimo-phase-3b-smoke-<timestamp>.txt
精确文件内容：MiMo phase 3B smoke passed <timestamp>

要求：
1. 在 workspace 根目录创建或覆盖“目标文件名”指定的文件。
2. 写入“精确文件内容”指定的完整内容。
3. 读回该目标文件，确认内容完全一致。
4. 使用 `linear_issue_read` 读取当前 issue。
5. 使用 `linear_comment_create` 评论 `file_verified=true`、`phase_3b_guidance=true` 和 issue identifier。
6. 最后才使用 `linear_issue_update_state` 移动到 `Done`。
7. 如果目标文件名或精确文件内容缺失/含糊，评论 blocked，不要移动到 `Done`。
```

验收：
- 目标文件存在，内容精确一致。
- MiMo-Code session summary 显示产生了文件变更，或人工复验能证明目标文件来自本次运行。
- Linear 评论存在并包含 marker。
- issue 最终进入 `Done`。
- `linear_issue_update_state` 是最后的 terminal 收尾动作。

执行结果：
- issue：`YQE-34`
- ACP session：`ses_139b11bc9ffe0hdEdSIOiVHIrk`
- workspace：`/home/gqy47/code/symphony-workspaces-local/YQE-34`
- 目标文件：`mimo-phase-3b-smoke-20260614-212237.txt`
- 文件内容：`MiMo phase 3B smoke passed 20260614-212237`
- 文件 sha256：`ecfe4a0fb1b56da03eb36c2f14bd48d6cbe659c890e9a0a643c9c293c7f56f46`
- MiMo-Code session summary：`summary_files=1`、`summary_additions=1`、`summary_deletions=0`
- Linear 状态：`Done`
- Linear 评论 marker：`file_verified=true`、`phase_3b_guidance=true`、`identifier=YQE-34`
- 工具调用：`linear_issue_read`、`linear_comment_create`、`linear_issue_update_state` 均 `outcome=ok`；本次 `linear_graphql` 调用为 0，session 未出现 `Invalid Tool`。
- 备注：worker 正常完成后曾出现短暂 continuation retry warning；由于 issue 已进入 terminal state，不影响阶段 3B smoke 结论。该可观测噪音已按 TDD 修正：AgentRunner 回传刷新后的 issue 快照，Orchestrator 对正常退出且已 terminal 的 issue 直接清理/释放 claim，不再排 continuation retry。

复测结果：
- issue：`YQE-35`
- workspace：`/home/gqy47/code/symphony-workspaces-local/YQE-35`
- 目标文件：`mimo-phase-3b-smoke-20260614-144901.txt`
- 文件内容：`MiMo phase 3B smoke passed 20260614-144901`
- 文件 sha256：`c9f156743332df93204e7dee192649ea46b6f20fc5b2ac7174aea468694616c0`
- MiMo-Code session：`ses_139644e76ffeJKm2d0lOv9z8zN`
- MiMo-Code session summary：`summary_files=1`、`summary_additions=1`、`summary_deletions=0`
- Linear 状态：`Done`
- Linear 评论 marker：`file_verified=true`、`phase_3b_no_retry=true`
- 日志结论：`mimocode/acp_stdio` 执行了写文件、读回验证、Linear 评论和状态流转；未出现 continuation 或 `Retrying issue_id=ffc6e2de` 日志。

- [x] **Step 6: 固化 issue 模板生成器**

新增：
- `elixir/lib/mix/tasks/mimo.phase3b_smoke.ex`
- `elixir/test/mix/tasks/mimo_phase3b_smoke_test.exs`

Run:

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/mix/tasks/mimo_phase3b_smoke_test.exs'
```

Expected: PASS，且输出模板不包含 `$fileName` / `$phrase`。

---

## 原阶段 4：OpenCode 复用（本轮跳过）

本轮跳过。

后续再评估时，原则是：
- 优先复用 `acp_stdio` backend。
- 如果 OpenCode 只需要不同 `command` / `args`，只新增配置和 smoke 文档。
- 如果 OpenCode ACP 行为与 MiMo-Code 存在差异，先记录差异，再补 provider-specific quirk。
- 不因为 OpenCode 差异修改 Orchestrator 调度模型。

本轮验收不要求：
- `opencode acp` 可启动。
- `opencode serve` 可启动。
- OpenCode Linear issue smoke 通过。

---

## 全量验证

阶段 1 到阶段 3B 完成后运行：

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix test test/symphony_elixir/acp_backend_registration_test.exs test/symphony_elixir/acp_stdio_client_test.exs test/symphony_elixir/acp_stdio_backend_test.exs test/symphony_elixir/acp_agent_runner_test.exs test/symphony_elixir/core_test.exs test/symphony_elixir/orchestrator_status_test.exs'
```

Expected: 目标测试集通过。

再运行：

```powershell
wsl.exe -e bash -lc 'cd /mnt/c/Users/GQY47/coding/Symphony/elixir && mise exec -- mix specs.check'
```

Expected: public functions spec 检查通过。

最后运行：

```powershell
git diff --check
```

Expected: 无 whitespace error；如果只有 CRLF warning，需要在最终说明中明确。

## 验收标准

- `WORKFLOW.md` 可以声明 `mimocode.kind = acp_stdio`。
- Linear issue 添加 `agent:mimo` 后由 `mimocode` backend 执行。
- dashboard 或日志明确显示 `agent_id=mimocode`、`agent_kind=acp_stdio`。
- 同一 worker attempt 内的 continuation turn 复用同一 ACP session。
- `turn_count` 按实际 turn 数增长。
- fake ACP server 覆盖启动、prompt、completion、permission、unsupported request、timeout、close timeout、usage。
- 真实 `mimo acp` smoke 已能完成握手和 prompt。
- 真实 `agent:mimo` Linear issue smoke 已证明 MiMo-Code 能通过 `mimocode/acp_stdio` 创建并读回指定 workspace 文件，再用 `linear_issue_read`、`linear_comment_create`、`linear_issue_update_state` 完成 Linear 收尾。
- terminal issue 正常完成后不再出现 1s continuation retry 噪音；active issue 正常退出后的 continuation retry 行为保持不变。
- OpenCode 不作为本轮验收项。
