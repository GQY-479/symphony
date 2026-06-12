# Multi-Agent Backends Design

## Purpose

Symphony should orchestrate work across multiple coding agents as peer workers. Codex, MiMo-Code, and OpenCode should be modeled as agent backends that can own issue work, rather than modeling one agent as a tool invoked by another agent.

The first implementation should add enough backend abstraction to keep existing Codex behavior unchanged while allowing MiMo-Code to run issue work from Linear assignment or explicit workflow routing. OpenCode should fit the same backend shape after MiMo-Code is working.

## Product Model

Symphony's unit of work remains a tracker issue. A running issue is assigned to one agent backend for the lifetime of an attempt. That backend owns the workspace, prompt, command execution, retries, and completion reporting for that attempt.

Delegation between agents should happen through the tracker instead of direct nested tool calls. For example, Codex can create, update, label, or assign a Linear issue to the MiMo-Code assignee; Symphony then polls Linear and dispatches that issue to the MiMo-Code backend. This preserves an auditable task lifecycle and keeps agent ownership visible in Linear.

Dynamic tools still have a place for narrow host capabilities such as Linear GraphQL operations. They should not be the first-class mechanism for asking another coding agent to complete an issue.

## Scope

The first version includes:

- A generic agent backend abstraction in the Elixir implementation.
- A Codex backend wrapper around the current `SymphonyElixir.Codex.AppServer` behavior.
- A CLI backend that can run MiMo-Code through `mimo run --format json`.
- Workflow config for named agents and issue routing.
- Linear-assignee-based routing, with label/default routing as fallback.
- Orchestrator state that records which agent backend owns a running issue.
- Tests using fake Codex and fake MiMo/OpenCode commands.

The first version does not include:

- ACP transport support for MiMo-Code/OpenCode.
- A full dashboard terminology migration from `codex_*` to `agent_*`.
- Automatic installation or authentication setup for MiMo-Code.
- Nested agent invocation as a Codex dynamic tool.
- Multi-agent work splitting inside one Linear issue.

## Configuration

The workflow front matter should support a new `agents` section while preserving the existing `codex` section for compatibility.

Example:

```yaml
agents:
  codex:
    kind: codex_app_server
    command: "codex app-server"
    assignee: "codex-bot@example.com"
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
    assignee: "mimo-bot@example.com"
    timeout_ms: 600000
    max_output_bytes: 200000
routing:
  default_agent: codex
  by_assignee:
    "codex-bot@example.com": codex
    "mimo-bot@example.com": mimocode
  by_label:
    "agent:mimo": mimocode
    "agent:codex": codex
```

Compatibility rule: if `agents` is absent, Symphony should synthesize a single `codex` agent from the existing `codex` config. Existing `WORKFLOW.md` files should keep working.

Assignee matching should initially use fields already available on `Linear.Issue`: `assignee_id` and any additional assignee fields added by the Linear client. If the workflow uses an email/name that Linear issue payloads do not expose, the design should prefer resolving the configured assignee to a Linear user id during config/runtime setup rather than doing fuzzy matching.

## Routing

Routing chooses an `agent_id` before dispatch.

Priority order:

1. Explicit label route from `routing.by_label`.
2. Assignee route from `routing.by_assignee`.
3. `routing.default_agent`.
4. Compatibility fallback to `codex`.

If routing resolves to an unknown or disabled agent, the issue should not be dispatched. The orchestrator should log a clear error and leave the issue unclaimed so the operator can fix configuration or issue metadata.

Existing routability checks still apply:

- The issue must be assigned to this Symphony worker when `tracker.assignee` is configured.
- The issue must include all `tracker.required_labels`.
- The issue state must be active and not terminal.
- Blocking dependencies must still prevent Todo dispatch when applicable.

## Backend Interface

Introduce an internal backend contract with one main operation:

```elixir
run_issue(workspace, issue, prompt, backend_config, opts) ::
  {:ok, backend_result} | {:error, reason}
```

The backend emits normalized runtime events through the same callback path the orchestrator already uses for Codex updates. The event shape should include:

- `agent_id`
- `agent_kind`
- `event`
- `timestamp`
- `session_id` when available
- `app_server_pid` or `process_pid` when available
- `payload`
- `usage` when the backend reports token usage

The first implementation can keep the existing `{:codex_worker_update, issue_id, message}` message name internally if that reduces churn, but new fields should be backend-neutral. New code should prefer `agent_*` names where practical.

## Codex Backend

The Codex backend wraps the current app-server implementation:

- Start one Codex app-server session per issue worker attempt.
- Run up to `agent.max_turns` continuation turns while the Linear issue remains active and routable.
- Preserve current approval policy, sandbox, dynamic tools, token accounting, stall detection, and retry behavior.

This wrapper should be behavior-preserving. Existing Codex tests should continue to pass after the abstraction is introduced.

## CLI Backend For MiMo-Code And OpenCode

The CLI backend runs a configured command in the issue workspace and passes the issue prompt as the task input.

For MiMo-Code, the command should support:

```bash
mimo run --format json --agent build --dir <workspace> <prompt>
```

The runner should:

- Resolve `{{workspace}}` and other supported template variables before launching.
- Launch with the workspace as `cwd` unless `--dir` is explicitly configured.
- Stream stdout and stderr.
- Parse newline-delimited JSON events when possible.
- Treat non-JSON stdout as agent text output.
- Enforce `timeout_ms`.
- Cap retained output at `max_output_bytes`.
- Return success when the process exits with status `0`.
- Return failure with captured output and exit status otherwise.

OpenCode can use the same `cli_run` backend if its CLI exposes compatible `run` behavior. If OpenCode and MiMo-Code diverge, add a second preset or adapter without changing orchestrator routing.

## Linear Assignment Flow

Codex-to-MiMo delegation should use Linear:

1. Codex uses existing Linear capabilities to create or update an issue.
2. Codex assigns the issue to the configured MiMo-Code assignee or applies a configured route label.
3. Symphony polls Linear.
4. Routing resolves the issue to `mimocode`.
5. The MiMo-Code backend works the issue in its own workspace.

This keeps the delegation visible in the tracker and lets humans reassign, pause, or close the work using normal Linear workflows.

## State And Observability

Running, retrying, and blocked entries should include:

- `agent_id`
- `agent_kind`
- `worker_host`
- `workspace_path`
- `session_id`
- latest normalized agent event/message
- token usage when available

The dashboard should display the agent id for each running issue. Token totals may remain named `codex_totals` in the first version for compatibility, but the presenter/API should expose backend-neutral aliases if the change is small. A full rename can be a follow-up.

## Error Handling

Configuration errors:

- Unknown default agent: validation error.
- Route points to unknown agent: validation error.
- Agent command missing: validation error.
- Unsupported agent kind: validation error.

Runtime errors:

- Missing executable: fail the attempt and schedule retry using existing retry policy.
- CLI timeout: terminate the process and schedule retry.
- Non-zero exit: fail the attempt with captured output.
- Output too large: truncate retained output and continue tracking process status.
- Agent requires unavailable interactive input: fail or block depending on backend signal. For MiMo-Code `run`, prefer non-interactive flags and permission rules that avoid prompts.

## Testing

Tests should cover:

- Existing workflow files without `agents` still synthesize the Codex backend.
- Routing by label chooses MiMo-Code.
- Routing by assignee chooses MiMo-Code.
- Unknown route target fails config validation.
- Codex backend still sends app-server messages as before.
- CLI backend passes prompt/workspace to a fake `mimo` command.
- CLI backend parses JSON output and captures text output.
- CLI backend returns an error on timeout and non-zero exit.
- Orchestrator running snapshots include `agent_id` and `agent_kind`.

## Implementation Order

1. Add config schema support for named agents and routing, preserving Codex compatibility.
2. Introduce backend modules and wrap current Codex behavior.
3. Add routing resolution and store `agent_id` on running entries.
4. Add CLI backend for MiMo-Code/OpenCode style commands.
5. Surface agent identity in API/dashboard snapshots.
6. Add documentation and example workflow snippets.

## Open Questions

- What Linear identity should represent each agent in the user's workspace: bot user, human user, or labels only?
- Should MiMo-Code receive the exact same workflow prompt as Codex, or a backend-specific prompt section?
- Should CLI backend success require the Linear issue to leave an active state, or only process exit `0`?

For the first implementation, use labels plus optional assignee routing, pass the same issue prompt, and keep the existing active-state continuation policy where practical.
