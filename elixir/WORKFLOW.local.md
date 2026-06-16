---
tracker:
  kind: linear
  project_slug: "96f5ac7500e2"
  required_labels:
    - symphony-local-test
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 10000
workspace:
  root: ~/code/symphony-workspaces-local
  preserve_terminal: true
hooks:
  timeout_ms: 180000
  after_create: |
    git clone --depth 1 file:///mnt/c/Users/GQY47/coding/Symphony .
    if command -v mise >/dev/null 2>&1; then
      cd elixir && mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    echo "local smoke cleanup"
agent:
  max_concurrent_agents: 1
  max_turns: 3
codex:
  command: codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true
agents:
  codex:
    kind: codex_app_server
    command: codex app-server
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
    timeout_ms: 600000
    read_timeout_ms: 15000
    close_timeout_ms: 1000
routing:
  default_agent: codex
  by_label:
    "agent:mimo": mimocode
server:
  port: 4000
---

You are working on a Linear ticket `{{ issue.identifier }}`.

This is a local Symphony evaluation run. Work only inside the provided issue workspace.

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. Make the smallest safe change needed for this ticket.
2. Do not touch files outside the provided workspace.
3. Stop and report blocked if required credentials or permissions are missing.
4. When you need to read or update Linear, prefer `linear_issue_read`, `linear_comment_create`, and `linear_issue_update_state`; use `linear_graphql` only as a fallback.
5. Move the Linear issue to a terminal state such as `Done` only after all workspace file changes are complete and verified.
6. Do not write Linear API tokens to files, logs, commits, or issue comments.
7. Final response should summarize completed actions and blockers only.
