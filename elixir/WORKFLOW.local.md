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
orchestration:
  enabled: true
  planner_agent: codex
  reviewer_agent: codex
  artifact_dir: ".symphony"
  planning_max_turns: 1
  review_max_turns: 1
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
  omnigent:
    kind: omnigent_http
    command: omnigent
    base_url: "http://127.0.0.1:27748"
    host:
      mode: external
      host_id: "host_cbfe34ada4064a3cb4e294896b8cf349"
      workspace: "{{workspace}}"
    agent:
      type: agent_id
      id: "ag_057995d1517418e6839f51d340785dd6"
    timeout_ms: 3600000
    stream_timeout_ms: 600000
    runner_ready_timeout_ms: 60000
    runner_ready_poll_ms: 500
routing:
  default_agent: codex
  by_label:
    "agent:mimo": mimocode
    "agent:omnigent": omnigent
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

Orchestrated run rules:

1. Follow the workflow phase instructions appended by Symphony.
2. Produce the required structured artifact for the current phase:
   `.symphony/workflow_plan.json`, `.symphony/completion_packet.json`, or
   `.symphony/review_decision.json`.
3. Do not move the current Linear issue to a terminal state. Symphony will advance or close issues
   after it reads and validates the structured artifact.
4. Do not touch files outside the provided workspace.
5. Stop and report blocked if required credentials or permissions are missing.
6. When you need to read or comment on Linear, prefer `linear_issue_read` and
   `linear_comment_create`; use `linear_graphql` only as a fallback.
7. Do not write Linear API tokens to files, logs, commits, or issue comments.
8. Final response should summarize completed actions and blockers only.
