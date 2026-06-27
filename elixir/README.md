# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls Linear for candidate work
2. Creates a workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

During app-server sessions, Symphony also serves a client-side `linear_graphql` tool so that repo
skills can make raw Linear GraphQL calls.

Issue 驱动的动态任务编排说明见
[`docs/issue_driven_dynamic_workflow.md`](docs/issue_driven_dynamic_workflow.md)。

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

If Codex reports that operator input, approval, or MCP elicitation is required, Symphony keeps the
issue claimed and exposes it as blocked in the runtime state, JSON API, and dashboard. Blocked
entries are in memory only; restarting the orchestrator clears that blocked map, so any still-active
Linear issue can become a dispatch candidate again after restart.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## 本地启动入口（Windows / Codex Desktop）

在当前本地开发环境中，统一使用 `start-local.ps1` 启动 Symphony。不要直接运行临时
`symphony_boot_*.exs` 或手写 `mix run` 启动链路；这样容易漏掉新 agent backend、workflow
路径、端口、日志和环境变量传递。

`WORKFLOW.md` 是唯一共享 workflow 文件。启动时 Symphony 会自动加载同目录的
`WORKFLOW.local.yml`（如果存在），并把它作为本机 YAML overlay 合并到
`WORKFLOW.md` 的 front matter；prompt body 始终只来自 `WORKFLOW.md`。

`WORKFLOW.local.yml` 已被 Git 忽略，只用于本机运行配置，例如 workspace root、clone
来源、端口、agent 命令路径、并发数和 smoke-test hooks。新机器可从
`WORKFLOW.local.example.yml` 复制一份后填入本机差异。

推荐先做预检：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\elixir\start-local.ps1 -Preflight
```

启动或重启服务：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\elixir\start-local.ps1
```

停止服务：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\elixir\stop-local.ps1
```

默认配置如下：

- workflow：`elixir/WORKFLOW.md`
- local overlay：`elixir/WORKFLOW.local.yml`（如果存在）
- dashboard/API 端口：`4000`
- Linear token：优先读取 `LINEAR_API_KEY` 环境变量，其次读取 `$HOME\.linear_api_key`
- 日志：WSL 内 `/tmp/symphony-local-4000.log`
- PID：WSL 内 `/tmp/symphony-local-4000.pid`

如果要用其他端口：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\elixir\start-local.ps1 -Port 4002
powershell -NoProfile -ExecutionPolicy Bypass -File .\elixir\stop-local.ps1 -Port 4002
```

如果不想每次输入 `LINEAR_API_KEY`，可以在 Windows 用户目录保存一次密钥：

```powershell
Set-Content -NoNewline -Path "$HOME\.linear_api_key" -Value "<your-linear-api-key>"
```

不要把真实 token 写入仓库、issue 评论或日志。`start-local.ps1 -Preflight` 只显示密钥来源，
不会打印密钥值。每次启动都会重新执行 `mix escript.build`，确保新增功能已经进入
`bin/symphony` 后再启动服务。

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  projects:
    web:
      slug: "web-app-123abc"
      repository: "git@github.com:your-org/web-app.git"
    api:
      slug: "api-service-456def"
      repository:
        - "/Users/dev/src/api-service"
        - "https://github.com/your-org/api-service"
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    REPOS="${SYMPHONY_PROJECT_REPOSITORIES:-${SYMP_PROJECT_REPOSITORY:-}}"
    OLD_IFS="$IFS"
    IFS=','
    for repo in $REPOS; do
      repo=$(printf '%s' "$repo" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      if [ -d "$repo" ]; then
        cp -r "$repo"/* . 2>/dev/null || true
        cp -r "$repo"/.[!.]* . 2>/dev/null || true
        break
      fi
      case "$repo" in
        http*|git@*) git clone --depth 1 "$repo" . && break ;;
      esac
    done
    IFS="$OLD_IFS"
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Symphony 也可以把 issue 路由给平级 agent backend（Codex、MiMo-Code、OpenCode），而不是只运行
Codex。`agents` 和 `routing` 配置见 [`docs/multi_agent_backends.md`](docs/multi_agent_backends.md)；
MiMo-Code ACP 接入经验和 smoke 证据沉淀见 [`docs/agent_backend_lessons.md`](docs/agent_backend_lessons.md)。

Notes:

- If a value is missing, defaults are used.
- `tracker.required_labels` is optional. When set, an issue must have every
  configured label to dispatch or continue running. Label matching ignores
  case and surrounding whitespace. A blank configured label matches no issue.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- Workflows that run package managers or other commands that resolve external hosts should set
  `networkAccess: true` in `codex.turn_sandbox_policy`; otherwise DNS/network access may be denied
  by the Codex turn sandbox.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `tracker.projects` to watch multiple Linear projects. Each key is an operator-chosen project
  name, `slug` is the Linear project slug from the project URL, and `repository` is either one
  address or an ordered list of addresses. The list can mix local repository paths and remote Git
  URLs; hooks receive the active issue's mapped repositories in
  `SYMPHONY_PROJECT_REPOSITORIES` as a comma-separated value. The legacy
  `SYMP_PROJECT_REPOSITORY` alias is still exported for older hooks.
- Use `hooks.after_create` to bootstrap a fresh workspace. For Git-backed repos, clone or copy from
  `SYMPHONY_PROJECT_REPOSITORIES` so each Linear project seeds workspaces from its own repository.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is `$LINEAR_API_KEY`.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap
- Tracker issue identifiers link to the tracker-provided URL when it uses `http` or `https`

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
