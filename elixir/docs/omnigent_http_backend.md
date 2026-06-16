# Omnigent HTTP Backend

Symphony 可以把 Linear issue 路由给一个顶层 Omnigent session。Linear 侧只需要看到 `omnigent` 这个 agent；Omnigent 内部再把工作派给 Codex、Claude、Cursor 或其他子 agent，是 Omnigent 自己的内部实现细节。

第一阶段的边界是：Symphony 仍然以 Linear issue 和 worker attempt 作为顶层任务边界，Omnigent 作为一个平级 backend 承接 issue，而不是替代 Symphony 的 Linear 编排。

## 前置条件

1. Omnigent 已安装，当前用户已经完成必要登录和本地配置。
2. 本地 Omnigent server 可以通过 HTTP 访问，例如 `http://127.0.0.1:6767`。
3. 已有可用的 external host，并且知道对应的 `host_id`。
4. 已有可用的 Omnigent agent，并且知道对应的 `agent_id`，或已准备好 agent bundle。
5. Symphony worker 和 Omnigent host 能看到同一个 issue workspace 路径；推荐使用 `{{workspace}}` 占位符把实际 workspace 传给 Omnigent。

第一阶段不会自动安装、登录或启动 Omnigent。server、host、登录态和 agent 配置都需要用户在运行 smoke 前手动准备好。

## 本地 server 和 host 启动

在 Omnigent 仓库或用户实际安装环境中启动本地 server：

```powershell
cd C:\Users\GQY47\coding\omnigent
omnigent server start
```

另开一个终端启动或确认 host 在线：

```powershell
cd C:\Users\GQY47\coding\omnigent
omnigent host
```

记录 host id 和 agent id。真实命令名称、参数和输出以当前 Omnigent 安装版为准；Symphony 只依赖 HTTP API 的 `base_url`、`host.host_id`、`host.workspace` 和 agent 配置。

## WORKFLOW 配置示例

```yaml
agents:
  codex:
    kind: codex_app_server
    command: "codex app-server"

  omnigent:
    kind: omnigent_http
    command: "omnigent"
    base_url: "http://127.0.0.1:6767"
    host:
      mode: external
      host_id: "<真实 host id>"
      workspace: "{{workspace}}"
    agent:
      type: agent_id
      id: "ag_polly"
    timeout_ms: 3600000
    stream_timeout_ms: 600000
    runner_ready_timeout_ms: 60000
    runner_ready_poll_ms: 500

routing:
  default_agent: codex
  by_label:
    "agent:omnigent": omnigent
```

说明：

- `agents.omnigent.kind: omnigent_http` 让 Symphony 使用 Omnigent HTTP backend。
- `base_url` 指向已启动的 Omnigent server。
- `host.mode: external` 表示使用用户已经启动或登记的外部 host。
- `host.host_id` 用于绑定本轮 session 使用的 host；示例中的 `<真实 host id>` 必须替换为 Omnigent 当前输出或登记的真实 host id。
- `host.workspace: "{{workspace}}"` 会被替换为 Symphony 为当前 Linear issue 准备的 workspace 路径。
- `agent.type: agent_id` 表示直接引用已有 Omnigent agent；示例中的 `id: "ag_polly"` 需要替换为真实 agent id。
- `timeout_ms` 是本轮 turn 的总超时；`stream_timeout_ms` 是 SSE stream 等待事件的超时。
- `runner_ready_timeout_ms` 表示创建 host-bound session 后最多等待多久，让 Omnigent runner 进入 `runner_online=true` 后再发送 message；默认 backend 会等待，设为 `0` 可禁用。
- `runner_ready_poll_ms` 表示等待 runner 在线时轮询 session snapshot 的间隔。
- `routing.by_label."agent:omnigent": omnigent` 表示 Linear issue 带 `agent:omnigent` label 时路由给这个 backend。

## Linear issue 使用步骤

1. 创建或选择一个低风险测试 issue。
2. 给 issue 添加 `agent:omnigent` label。
3. 确认 issue 处于 Symphony 会处理的 active state，例如 `Todo` 或 `In Progress`。
4. 在 issue 描述中写清楚要做的本地 smoke 动作，例如在 workspace 根目录创建 `omnigent-smoke.txt`，内容为固定字符串，并在 Linear 评论中说明结果。
5. 启动 Symphony worker，让它派发该 issue。
6. 在 dashboard、日志或 worker 输出中确认本轮 attempt 使用的是 `agent_id=omnigent`、`agent_kind=omnigent_http`，并记录 Omnigent session id。
7. 等待 Omnigent 本轮 turn 完成后，刷新 Linear issue 状态和 workspace 文件。

## 成功判定

一次本地 smoke 建议同时满足以下条件：

- Symphony 根据 `agent:omnigent` label 选择 `omnigent` agent。
- Omnigent server 收到创建 session 和发送 message 的请求。
- backend 事件中可看到 Omnigent session id，并带有 `agent_id=omnigent` 与 `agent_kind=omnigent_http`。
- workspace 中出现 issue 要求的验证文件或其他可检查 evidence。
- Linear issue 中有 Omnigent 或 Symphony 写回的结果说明，或者状态变化符合测试预期。
- 停止 session 时，Symphony 会调用 `stop_session` 做清理；`interrupt` 目前是 Omnigent client 已实现的控制事件能力，若要作为 worker 超时或取消的兜底路径，还需要补 runner wiring 和集成测试。

需要特别注意：Omnigent 的 `response.completed` 只表示本轮 Omnigent turn 完成，不等于 Linear issue 已完成。Symphony 仍会刷新 Linear issue；如果 issue 仍处于 active state，并且仍路由到 `omnigent`，同一个 worker attempt 可以继续下一轮 turn。

## 当前限制

- 不自动安装、登录或启动 Omnigent。
- 不支持 `host.mode: managed`。
- 不把 Omnigent child session 映射成 Linear 子 issue。
- 不直接注入 Symphony Linear token 或 `linear_graphql` 给 Omnigent。
- 多个 online host 的自动选择不在第一阶段处理；建议显式配置 `host.host_id`。
- `response.completed` 只表示本轮 turn 完成，不等于 Linear issue 完成。
- Omnigent 内部派给 Codex、Claude、Cursor 或其他子 agent 的细节不会暴露成 Symphony 顶层 agent 路由。

## 当前真实 smoke 结论

- Polly agent 端到端 smoke 已通过。真实 Omnigent server 返回 session 后，Symphony 等到 `runner_online=true`，再发送 message，并收到 `response.output_text.delta` 与 `response.completed`。
- `codex-native-ui` agent 已通过 session 创建、runner online 等待和 turn message 发送路径，但当前失败在 Omnigent native terminal 启动层：runner 报错 `linux_bwrap sandbox requires the 'bwrap' binary on PATH`。
- 这个 `codex-native-ui` 失败不表示 Symphony HTTP adapter 协议路径不可用；它说明当前 Omnigent host runner 在自动创建 Codex terminal 时没有继承 agent YAML 中的 sandbox 配置，或运行环境缺少 `bubblewrap`。
- 如果要继续体验 `codex-native-ui`，需要先在 WSL 环境安装 `bubblewrap`，或修复 Omnigent runner 的 terminal sandbox 继承逻辑。

## 真实 smoke 记录模板

复制以下模板到实际 smoke 记录中，并填写真实值：

```markdown
## 真实 smoke 记录

- 日期：
- Linear issue：
- Omnigent session id：
- host id：
- agent id 或 bundle：
- workspace：
- WORKFLOW 文件：
- 测试动作：
- 结果：
- 已知缺口：
```
