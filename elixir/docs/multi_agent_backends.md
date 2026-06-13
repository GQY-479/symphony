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

如果 `WORKFLOW.md` 没有 `agents:` 段，Symphony 会自动从旧的 `codex:` 配置合成一个名为 `codex` 的默认 agent，因此现有配置无需改动即可继续工作。

## 配置字段

`agents` 是一个以 agent id 为 key 的 map，每个 agent 支持：

| 字段 | 适用 kind | 说明 |
| --- | --- | --- |
| `kind` | 全部 | `codex_app_server` 或 `cli_run` |
| `command` | 全部 | 可执行命令；`codex_app_server` 缺省继承 `codex.command` |
| `args` | `cli_run` | 参数列表，`{{workspace}}` 会被替换为该 issue 的 workspace 路径 |
| `enabled` | 全部 | 设为 `false` 可禁用该 agent（路由到它会报错） |
| `timeout_ms` | `cli_run` | 单次运行超时（毫秒） |
| `max_output_bytes` | `cli_run` | 捕获输出的上限，超出后保留尾部 |

`routing` 决定每个 issue 由谁处理，优先级为 **label > assignee > default**：

| 字段 | 说明 |
| --- | --- |
| `default_agent` | 没有命中其它规则时使用的 agent id（缺省 `codex`） |
| `by_label` | `label -> agent_id`，label 大小写不敏感 |
| `by_assignee` | Linear assignee id `-> agent_id` |

`routing` 中引用的所有 agent id 必须在 `agents` 中存在，否则 `WORKFLOW.md` 校验会失败。

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

## 可观测性

running、retry、blocked 的快照、HTTP API payload 以及终端 dashboard 的 running 表都会带上 `agent_id` / `agent_kind`，便于确认每个 issue 实际由哪个 backend 处理。
