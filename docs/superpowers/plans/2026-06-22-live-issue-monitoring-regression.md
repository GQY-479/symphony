# Live Issue Monitoring Regression Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create and monitor 10 real Symphony Linear issues under the local Symphony workflow, fixing real defects discovered during the run.

**Architecture:** This is an operational implementation plan, not a planned product-code change. It uses the existing `elixir/WORKFLOW.local.md` profile, creates normal real issues in the configured project, stages them in `Backlog`, promotes a small number to `Todo`, and monitors Symphony through Linear, local logs, the dashboard, workspaces, and workflow artifacts. Code changes are made only when the live run exposes a diagnosed Symphony-side defect.

**Tech Stack:** Elixir/Mix, Symphony Elixir, Linear GraphQL via `SymphonyElixir.Linear.Client`, PowerShell start scripts, WSL, MiMo ACP stdio, Codex app-server tooling where configured.

---

## File Structure

- Reference: `docs/superpowers/specs/2026-06-22-live-issue-monitoring-regression-design.md`
- Reference: `elixir/WORKFLOW.local.md`
- Reference: `elixir/start-local.ps1`
- Reference: `elixir/stop-local.ps1`
- Create during execution: `docs/superpowers/runs/2026-06-22-live-issue-monitoring-regression.md`
- Modify only if a live defect requires a fix: relevant `elixir/lib/**` and `elixir/test/**` files identified during diagnosis.

The run manifest and final report live under `docs/superpowers/runs/` so they are separate from the stable design and implementation plan. The Linear issues themselves must look like normal product issues and must not include monitoring batch metadata.

## Task 1: Preflight The Local Runtime

**Files:**
- Read: `elixir/WORKFLOW.local.md`
- Read: `elixir/start-local.ps1`
- Create later: `docs/superpowers/runs/2026-06-22-live-issue-monitoring-regression.md`

- [ ] **Step 1: Record the current git context**

Run:

```bash
git rev-parse --abbrev-ref HEAD
git rev-parse HEAD
git status --short
```

Expected:

- Branch and HEAD are printed.
- Dirty files are recorded in the run manifest.
- Do not reset, checkout, stash, or discard any dirty files.

- [ ] **Step 2: Verify the Linear token file exists without printing it**

Run:

```bash
test -s /mnt/c/Users/GQY47/.linear_api_key
```

Expected: exit code `0`.

If this fails, stop and configure Linear auth before continuing.

- [ ] **Step 3: Run the local preflight**

Run from the repository root:

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./elixir/start-local.ps1 -Preflight
```

Expected output includes:

```text
Workflow:
CODEX_API_KEY source:
LINEAR_API_KEY source:
WSL:
Runtime:
Port 4000:
Preflight OK. Symphony was not started.
```

If port `4000` is already in use, either stop the existing Symphony process with `elixir/stop-local.ps1` or run the monitored session on a different port and record that port in the manifest.

- [ ] **Step 4: Confirm the active local workflow shape**

Run:

```bash
sed -n '1,120p' elixir/WORKFLOW.local.md
```

Expected configuration:

```yaml
tracker:
  project_slug: "96f5ac7500e2"
  assignee: "me"
  required_labels: []
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
agent:
  max_concurrent_agents: 1
orchestration:
  enabled: true
  planner_agent: mimocode
  reviewer_agent: mimocode
routing:
  default_agent: mimocode
```

If these values differ, record the actual values in the run manifest before creating issues.

## Task 2: Resolve Linear Project Context

**Files:**
- Read: `elixir/WORKFLOW.local.md`
- Create later: `docs/superpowers/runs/2026-06-22-live-issue-monitoring-regression.md`

- [ ] **Step 1: Query the configured Linear project, team, states, labels, and viewer**

Run:

```bash
cd elixir
LINEAR_API_KEY="$(sed -n '1p' /mnt/c/Users/GQY47/.linear_api_key)" \
  mise exec -- mix run --no-start -e '
Application.ensure_all_started(:req)

query = """
query SymphonyLiveRegressionContext($slug: String!) {
  projects(filter: { slugId: { eq: $slug } }, first: 1) {
    nodes {
      id
      name
      slugId
      teams {
        nodes {
          id
          key
          name
          states {
            nodes { id name type }
          }
          labels(first: 100) {
            nodes { id name }
          }
        }
      }
    }
  }
  viewer { id name }
}
"""

case SymphonyElixir.Linear.Client.graphql(query, %{"slug" => "96f5ac7500e2"}) do
  {:ok, %{"errors" => errors}} ->
    IO.puts(Jason.encode!(%{"status" => "error", "errors" => errors}, pretty: true))
    System.halt(1)

  {:ok, body} ->
    IO.puts(Jason.encode!(body, pretty: true))

  {:error, reason} ->
    IO.inspect(reason, label: "linear_error")
    System.halt(1)
end
'
```

Expected:

- One project is returned for slug `96f5ac7500e2`.
- At least one team is listed.
- Team states include `Backlog` and `Todo`, or equivalents with types that clearly map to non-active staging and active dispatch.
- `viewer.id` is present.

- [ ] **Step 2: Stop if the project context is ambiguous**

Stop before creating issues if any of these are true:

- The project query returns zero projects.
- More than one team is present and it is unclear which team owns normal Symphony work.
- There is no non-active state suitable for staging issues before Symphony sees them.
- There is no `Todo` state or other active state configured in `WORKFLOW.local.md`.

Expected: the worker either has a clear project/team/state mapping or asks the operator to resolve the ambiguity before continuing.

## Task 3: Create The Local Run Manifest

**Files:**
- Create: `docs/superpowers/runs/2026-06-22-live-issue-monitoring-regression.md`

- [ ] **Step 1: Create the runs directory**

Run:

```bash
mkdir -p docs/superpowers/runs
```

Expected: directory exists.

- [ ] **Step 2: Add the initial manifest with the actual branch and HEAD**

Use `apply_patch` to create `docs/superpowers/runs/2026-06-22-live-issue-monitoring-regression.md`. Put the exact branch and HEAD printed in Task 1 into the `Branch` and `HEAD` fields. Keep the result table empty until Linear returns real issue identifiers.

```markdown
# Live Issue Monitoring Regression Run - 2026-06-22

## Context

- Branch:
- HEAD:
- Workflow: `elixir/WORKFLOW.local.md`
- Dashboard: `http://127.0.0.1:4000/`
- Log: `/tmp/symphony-local-4000.log`
- Workspace root: `~/code/symphony-workspaces-local`
- Project slug: `96f5ac7500e2`
- Default agent: `mimocode`
- Max concurrent agents: `1`

## Created Issues

| Issue | Title | Initial State | Promoted At | Final State | Task Result | Orchestration Result | Integration Result |
| --- | --- | --- | --- | --- | --- | --- | --- |

## Observations

## Defects

## Fixes Applied

## Final Summary
```

Expected: manifest exists and does not contain Linear API tokens.

## Task 4: Create 10 Real Linear Issues In Backlog

**Files:**
- Update during execution: `docs/superpowers/runs/2026-06-22-live-issue-monitoring-regression.md`

- [ ] **Step 1: Create the issues in the configured project**

Run:

```bash
cd elixir
LINEAR_API_KEY="$(sed -n '1p' /mnt/c/Users/GQY47/.linear_api_key)" \
  mise exec -- mix run --no-start -e '
Application.ensure_all_started(:req)

context_query = """
query SymphonyLiveRegressionContext($slug: String!) {
  projects(filter: { slugId: { eq: $slug } }, first: 1) {
    nodes {
      id
      name
      slugId
      teams {
        nodes {
          id
          key
          name
          states { nodes { id name type } }
        }
      }
    }
  }
  viewer { id name }
}
"""

create_mutation = """
mutation SymphonyLiveRegressionCreateIssue($input: IssueCreateInput!) {
  issueCreate(input: $input) {
    success
    issue {
      id
      identifier
      title
      url
      state { id name type }
      project { id name slugId }
      team { id key name }
      assignee { id name }
    }
  }
}
"""

issues = [
  %{
    title: "Dashboard shows each issue current workflow phase",
    description: """
    Context:
    Symphony operators need to understand where each active issue is in the dynamic workflow without reconstructing state from raw logs.

    Goal:
    Show each issue current workflow phase in the dashboard active issue list. Include the responsible agent, latest turn status, and the relevant workflow artifact path when available.

    Acceptance criteria:
    - Active issues show a current workflow phase or a clear unavailable value.
    - Completed, failed, or blocked issues still expose the last known phase in the runtime state or dashboard detail.
    - The implementation does not assume every issue follows the same fixed phase sequence.
    - Add focused tests for the presenter or dashboard state transformation.
    """
  },
  %{
    title: "Workflow orchestration generates an auditable execution summary",
    description: """
    Context:
    A completed issue can be hard to audit because planner decisions, agent turns, artifacts, and final Linear state are spread across logs and workspace files.

    Goal:
    Generate a concise local execution summary for each orchestrated issue after completion or failure.

    Acceptance criteria:
    - The summary includes issue identifier, selected agent, planner decision, turn count, artifact paths, final issue state, and failure reason when present.
    - The summary is written inside the issue workspace or another deterministic Symphony-owned location.
    - The summary does not include Linear API tokens or other secrets.
    - Add tests that cover successful and failed orchestration summaries.
    """
  },
  %{
    title: "Missing or invalid workflow artifacts trigger clear repair behavior",
    description: """
    Context:
    Required workflow artifacts are central to orchestration, but an agent may omit them or write invalid JSON.

    Goal:
    Make missing or invalid artifacts produce an explicit repair turn and observable reason.

    Acceptance criteria:
    - Missing plan, completion, or review artifacts are logged with issue id, phase, path, and validation reason.
    - A repair turn is attempted when the phase allows repair.
    - Repair success resumes the workflow.
    - Repair failure moves the issue into an explicit failed or blocked path with an actionable reason.
    - Add regression tests for missing artifact and invalid artifact paths.
    """
  },
  %{
    title: "Linear terminal state is validated against completion evidence",
    description: """
    Context:
    An agent or external user may move a Linear issue to Done before the workflow has produced the required evidence.

    Goal:
    Detect terminal Linear state that arrives before the required completion evidence is present.

    Acceptance criteria:
    - Symphony records a diagnostic when terminal state is observed before required artifacts or workspace evidence exist.
    - The diagnostic distinguishes external terminal movement from normal Symphony finalization.
    - The system does not silently mark orchestration as successful only because Linear is terminal.
    - Add tests for terminal state with missing completion evidence.
    """
  },
  %{
    title: "Planner output explains dependencies for multi-step issues",
    description: """
    Context:
    Dynamic planner output needs to be understandable when an issue requires multiple dependent steps.

    Goal:
    Have planner artifacts describe step dependencies and completion conditions for multi-step issues.

    Acceptance criteria:
    - The workflow plan artifact can represent dependencies between planned steps.
    - Existing simple plans remain valid.
    - Runner or monitoring output can explain which dependency blocked a later step.
    - Add schema or parser tests that cover dependency-bearing and dependency-free plans.
    """
  },
  %{
    title: "Agent routing logs explain label assignee default or fallback selection",
    description: """
    Context:
    When an issue is dispatched, operators need to know why a specific agent was selected.

    Goal:
    Log the routing reason whenever Symphony dispatches an issue to an agent.

    Acceptance criteria:
    - Dispatch logs identify whether routing came from label, assignee, default agent, or fallback.
    - The log includes issue identifier, selected agent id, selected agent kind, and the matched label or assignee when applicable.
    - Existing routing behavior is unchanged.
    - Add tests for label route, assignee route, and default route diagnostics.
    """
  },
  %{
    title: "Concurrent issue runs keep workspace artifact log and session data isolated",
    description: """
    Context:
    Symphony must keep issue workspaces and runtime state isolated even when multiple issues are active or resumed.

    Goal:
    Strengthen or verify isolation across workspace paths, workflow artifacts, logs, and agent session identifiers.

    Acceptance criteria:
    - Each active issue has a deterministic workspace path that cannot collide with another issue.
    - Artifact reads and writes are scoped to the correct issue workspace.
    - Runtime status does not display another issue session id or artifact path.
    - Add tests that simulate two active issues and prove their artifacts and statuses do not cross.
    """
  },
  %{
    title: "Failed or blocked issue states include actionable reasons",
    description: """
    Context:
    Operators need to know why Symphony marked an issue failed or blocked without reading every raw log line.

    Goal:
    Store and expose a concise actionable reason for failed and blocked issue states.

    Acceptance criteria:
    - Failed and blocked runtime entries include a reason category and short message.
    - Dashboard or JSON state exposes the reason.
    - Reasons avoid secrets and long raw stack traces.
    - Add tests for agent failure, missing credentials, artifact validation failure, and operator-input-needed paths.
    """
  },
  %{
    title: "Continuation retry logs distinguish expected continuation from abnormal retry loops",
    description: """
    Context:
    A normal continuation and an abnormal retry loop can look similar in logs.

    Goal:
    Make continuation and retry logging distinguish expected follow-up turns from repeated failure loops.

    Acceptance criteria:
    - Logs for normal continuation include issue identifier, turn count, max turns, and why another turn is needed.
    - Logs for retry after error include error reason, attempt, and backoff.
    - Repeated retries are easy to identify from a short log excerpt.
    - Add tests for normal continuation and retry-after-error logging paths.
    """
  },
  %{
    title: "Live orchestration has a preflight health check",
    description: """
    Context:
    Real issue runs can fail late because token, workflow, backend, workspace, or agent availability problems were not checked up front.

    Goal:
    Provide a preflight health check for local live orchestration runs.

    Acceptance criteria:
    - The check verifies Linear auth availability without printing the token.
    - The check validates workflow file parsing and active tracker project lookup.
    - The check verifies configured agent backend commands are available where practical.
    - The check verifies the workspace root can be created or written.
    - The check exits nonzero with actionable messages on failure.
    - Add tests for success and at least two failure cases.
    """
  }
]

{:ok, context} = SymphonyElixir.Linear.Client.graphql(context_query, %{"slug" => "96f5ac7500e2"})
project = get_in(context, ["data", "projects", "nodes"]) |> List.first()
viewer = get_in(context, ["data", "viewer"])

if is_nil(project), do: raise("Linear project slug 96f5ac7500e2 was not found")

team =
  project
  |> get_in(["teams", "nodes"])
  |> List.first()

if is_nil(team), do: raise("Project #{project["slugId"]} has no team")

states = get_in(team, ["states", "nodes"]) || []

backlog_state =
  Enum.find(states, &(&1["name"] == "Backlog")) ||
    Enum.find(states, &(&1["type"] == "backlog"))

if is_nil(backlog_state), do: raise("Team #{team["key"]} has no Backlog state")

created =
  Enum.map(issues, fn issue ->
    input = %{
      "teamId" => team["id"],
      "projectId" => project["id"],
      "stateId" => backlog_state["id"],
      "assigneeId" => viewer["id"],
      "title" => issue.title,
      "description" => String.trim(issue.description),
      "priority" => 0
    }

    case SymphonyElixir.Linear.Client.graphql(create_mutation, %{"input" => input}) do
      {:ok, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => linear_issue}}}} ->
        linear_issue

      {:ok, response} ->
        raise("Issue create failed: #{inspect(response)}")

      {:error, reason} ->
        raise("Linear request failed: #{inspect(reason)}")
    end
  end)

IO.puts(Jason.encode!(%{"created" => created}, pretty: true))
' | tee ../docs/superpowers/runs/2026-06-22-live-issue-monitoring-created.json
```

Expected:

- 10 Linear issues are created.
- Every issue starts in `Backlog`.
- Every issue is assigned to the Linear viewer account used by `LINEAR_API_KEY`.
- No issue title or description contains monitoring run metadata.

- [ ] **Step 2: Add the created issue keys to the manifest**

Use `apply_patch` to add one row per created issue under `## Created Issues`.

Expected: each row uses an actual identifier from `docs/superpowers/runs/2026-06-22-live-issue-monitoring-created.json`, the exact title printed by Linear, initial state `Backlog`, and blank result columns until the issue has run.

## Task 5: Start Symphony For The Monitored Run

**Files:**
- Read: `elixir/start-local.ps1`
- Update during execution: `docs/superpowers/runs/2026-06-22-live-issue-monitoring-regression.md`

- [ ] **Step 1: Stop any existing local Symphony process on port 4000**

Run:

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./elixir/stop-local.ps1
```

Expected: no local Symphony process remains on port `4000`.

- [ ] **Step 2: Start Symphony**

Run:

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./elixir/start-local.ps1
```

Expected output includes:

```text
Symphony started on http://127.0.0.1:4000/
Log: wsl.exe -e bash -lc 'tail -f /tmp/symphony-local-4000.log'
```

- [ ] **Step 3: Verify the process is alive and dashboard responds**

Run:

```bash
test -s /tmp/symphony-local-4000.pid
curl -fsS http://127.0.0.1:4000/ >/tmp/symphony-dashboard.html
wc -c /tmp/symphony-dashboard.html
```

Expected:

- PID file exists.
- `curl` exits `0`.
- `wc -c` prints a positive byte count.

- [ ] **Step 4: Start log monitoring**

Run in a long-lived terminal:

```bash
wsl.exe -e bash -lc 'tail -f /tmp/symphony-local-4000.log'
```

Expected: logs stream without printing secrets.

## Task 6: Promote And Monitor The First Two Issues

**Files:**
- Update during execution: `docs/superpowers/runs/2026-06-22-live-issue-monitoring-regression.md`

- [ ] **Step 1: Move the first two created issues from Backlog to Todo**

Run from `elixir/`. The script reads the first two actual identifiers from the JSON file written in Task 4:

```bash
cd elixir
LINEAR_API_KEY="$(sed -n '1p' /mnt/c/Users/GQY47/.linear_api_key)" \
  mise exec -- mix run --no-start -e '
Application.ensure_all_started(:req)

created_path = Path.expand("../docs/superpowers/runs/2026-06-22-live-issue-monitoring-created.json", File.cwd!())

issue_ids =
  created_path
  |> File.read!()
  |> Jason.decode!()
  |> Map.fetch!("created")
  |> Enum.take(2)
  |> Enum.map(&Map.fetch!(&1, "identifier"))

state_query = """
query SymphonyLiveRegressionResolveTodo($issueId: String!) {
  issue(id: $issueId) {
    id
    identifier
    team {
      states { nodes { id name type } }
    }
  }
}
"""

update_mutation = """
mutation SymphonyLiveRegressionMoveIssue($id: String!, $stateId: String!) {
  issueUpdate(id: $id, input: { stateId: $stateId }) {
    success
    issue { id identifier title state { id name type } url }
  }
}
"""

results =
  Enum.map(issue_ids, fn issue_id ->
    {:ok, context} = SymphonyElixir.Linear.Client.graphql(state_query, %{"issueId" => issue_id})
    issue = get_in(context, ["data", "issue"])
    states = get_in(issue, ["team", "states", "nodes"]) || []
    todo_state = Enum.find(states, &(&1["name"] == "Todo"))
    if is_nil(todo_state), do: raise("Issue #{issue_id} team has no Todo state")

    case SymphonyElixir.Linear.Client.graphql(update_mutation, %{"id" => issue_id, "stateId" => todo_state["id"]}) do
      {:ok, %{"data" => %{"issueUpdate" => %{"success" => true, "issue" => updated}}}} -> updated
      {:ok, response} -> raise("Issue move failed: #{inspect(response)}")
      {:error, reason} -> raise("Linear request failed: #{inspect(reason)}")
    end
  end)

IO.puts(Jason.encode!(%{"moved" => results}, pretty: true))
'
```

Expected:

- Two issues move to `Todo`.
- Symphony picks at most one active issue at a time because `max_concurrent_agents` is `1`.

- [ ] **Step 2: Watch for dispatch and routing**

Run:

```bash
wsl.exe -e bash -lc 'grep -E "Dispatching issue|agent_id|workflow|artifact|retry|blocked|failed" /tmp/symphony-local-4000.log | tail -80'
```

Expected:

- The promoted issue identifier appears.
- Dispatch includes `agent_id=mimocode` and `agent_kind=acp_stdio`, unless routing configuration changed during preflight.

- [ ] **Step 3: Inspect dashboard state**

Open:

```text
http://127.0.0.1:4000/
```

Expected:

- The promoted issue appears as active, running, blocked, failed, or completed.
- If state is unclear, record the dashboard gap in the manifest.

- [ ] **Step 4: Inspect workspace and artifacts for the active issue**

Run:

```bash
find ~/code/symphony-workspaces-local -maxdepth 3 -type f -path '*/.symphony/*' -print
find ~/code/symphony-workspaces-local -maxdepth 2 -type d -print | sort | tail -40
```

Expected:

- Workspace paths are issue-specific.
- `.symphony/workflow_plan.json`, `.symphony/completion_packet.json`, or `.symphony/review_decision.json` appears only under the correct issue workspace when produced.

- [ ] **Step 5: Apply stop conditions**

Stop Symphony immediately if any P0 or P1 condition from the design spec appears.

Run when stopping is required:

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./elixir/stop-local.ps1
```

Expected:

- Symphony stops before processing more issues.
- The manifest records the issue id, log excerpt, workspace path, and suspected failure layer.

## Task 7: Diagnose And Fix Any First-Wave Defects

**Files:**
- Modify only after diagnosis: relevant `elixir/lib/**` files.
- Test only after diagnosis: focused `elixir/test/**` files.
- Update during execution: `docs/superpowers/runs/2026-06-22-live-issue-monitoring-regression.md`

- [ ] **Step 1: Classify each defect before editing code**

For each defect, write one manifest entry with the exact observed issue identifier and a concrete defect name. This is the required shape:

```markdown
### DEFECT-1: Artifact repair loop repeats after valid JSON

- Issue:
- Severity: P0/P1/P2/P3
- Layer: planner/orchestrator/runner/agent/linear/workspace/observability/config
- Symptom:
- Evidence:
- Decision:
```

Expected: every code edit has an evidence-backed reason.

- [ ] **Step 2: Use systematic debugging for real failures**

If a failure is unexpected behavior or a test failure, use `superpowers:systematic-debugging` before proposing a fix.

Expected: the diagnosis identifies where the behavior diverged from the design.

- [ ] **Step 3: Add the smallest repeatable automated test for Symphony-side defects**

Run the focused test file added for the diagnosed defect. Examples of valid focused commands in this repository are:

```bash
cd elixir
mise exec -- mix test test/symphony_elixir/workflow_orchestrator_test.exs
mise exec -- mix test test/symphony_elixir/acp_agent_runner_test.exs
mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs
```

Expected before the fix: the focused test fails for the observed defect.

Expected after the fix: the focused test passes.

- [ ] **Step 4: Run related regression tests**

Choose the smallest related set based on the touched files. Examples:

```bash
cd elixir
mise exec -- mix test test/symphony_elixir/workflow_orchestrator_test.exs
mise exec -- mix test test/symphony_elixir/workflow_controller_test.exs
mise exec -- mix test test/symphony_elixir/acp_agent_runner_test.exs
mise exec -- mix test test/symphony_elixir/orchestrator_status_test.exs
```

Expected: related tests pass before resuming live execution.

- [ ] **Step 5: Commit each verified fix separately**

Run:

```bash
git status --short
git add -p
git diff --cached --stat
git commit
```

Expected:

- Each commit contains one fix plus its tests.
- The commit does not include the run manifest unless intentionally documenting run evidence.

## Task 8: Promote The Remaining Issues In Small Waves

**Files:**
- Update during execution: `docs/superpowers/runs/2026-06-22-live-issue-monitoring-regression.md`

- [ ] **Step 1: Promote the next three Backlog issues**

Run this command to promote issues 3 through 5 from the JSON file:

```bash
cd elixir
LINEAR_API_KEY="$(sed -n '1p' /mnt/c/Users/GQY47/.linear_api_key)" \
  mise exec -- mix run --no-start -e '
Application.ensure_all_started(:req)

created_path = Path.expand("../docs/superpowers/runs/2026-06-22-live-issue-monitoring-created.json", File.cwd!())

issue_ids =
  created_path
  |> File.read!()
  |> Jason.decode!()
  |> Map.fetch!("created")
  |> Enum.drop(2)
  |> Enum.take(3)
  |> Enum.map(&Map.fetch!(&1, "identifier"))

state_query = """
query SymphonyLiveRegressionResolveTodo($issueId: String!) {
  issue(id: $issueId) {
    id
    identifier
    team { states { nodes { id name type } } }
  }
}
"""

update_mutation = """
mutation SymphonyLiveRegressionMoveIssue($id: String!, $stateId: String!) {
  issueUpdate(id: $id, input: { stateId: $stateId }) {
    success
    issue { id identifier title state { id name type } url }
  }
}
"""

results =
  Enum.map(issue_ids, fn issue_id ->
    {:ok, context} = SymphonyElixir.Linear.Client.graphql(state_query, %{"issueId" => issue_id})
    states = get_in(context, ["data", "issue", "team", "states", "nodes"]) || []
    todo_state = Enum.find(states, &(&1["name"] == "Todo"))
    if is_nil(todo_state), do: raise("Issue #{issue_id} team has no Todo state")

    case SymphonyElixir.Linear.Client.graphql(update_mutation, %{"id" => issue_id, "stateId" => todo_state["id"]}) do
      {:ok, %{"data" => %{"issueUpdate" => %{"success" => true, "issue" => updated}}}} -> updated
      {:ok, response} -> raise("Issue move failed: #{inspect(response)}")
      {:error, reason} -> raise("Linear request failed: #{inspect(reason)}")
    end
  end)

IO.puts(Jason.encode!(%{"moved" => results}, pretty: true))
'
```

After issues 3 through 5 finish or are paused with clear evidence, repeat the same command with `Enum.drop(5)` and `Enum.take(3)` for issues 6 through 8. Then repeat it with `Enum.drop(8)` and `Enum.take(2)` for issues 9 through 10.

Expected:

- Only the selected issues move to `Todo`.
- Symphony continues processing at most one issue concurrently under the current local profile.

- [ ] **Step 2: Repeat monitoring checks for every promoted issue**

For each issue, record:

```markdown
### Issue identifier from the created issue JSON

- Linear state:
- Selected agent:
- Routing reason observed:
- Planner artifact:
- Completion artifact:
- Review artifact:
- Workspace path:
- Task result:
- Orchestration result:
- Integration result:
- Notes:
```

Expected: every issue has enough evidence to explain its outcome.

- [ ] **Step 3: Stop on repeated cross-issue patterns**

Stop and diagnose before promoting more issues if the same failure pattern appears twice.

Expected: repeated defects are fixed or explicitly classified before the batch continues.

## Task 9: Produce The Final Run Report

**Files:**
- Modify: `docs/superpowers/runs/2026-06-22-live-issue-monitoring-regression.md`

- [ ] **Step 1: Fill the result table**

Update every row with:

- Final Linear state.
- `task_result`: pass, fail, partial, blocked, or not-run.
- `orchestration_result`: pass, fail, partial, blocked, or not-run.
- `integration_result`: pass, fail, partial, blocked, or not-run.

Expected: no issue row has blank result columns.

- [ ] **Step 2: Summarize defects and fixes**

Add sections:

```markdown
## Defects

| ID | Severity | Layer | Issue | Status | Fix |
| --- | --- | --- | --- | --- | --- |

## Fixes Applied

| Commit | Summary | Tests |
| --- | --- | --- |

## Final Summary

- Issues created:
- Issues promoted:
- Issues completed:
- Issues blocked:
- Issues failed:
- P0 defects:
- P1 defects:
- P2 defects:
- P3 defects:
- Follow-up issues:
```

Expected: the report can be read without opening raw logs first.

- [ ] **Step 3: Run final local verification if code changed**

If code changed during the live run, run:

```bash
cd elixir
mise exec -- mix test
```

Expected: full ExUnit suite passes, or failures are listed in the final summary with exact failing tests and reasons.

## Task 10: Decide Whether To Continue, Pause, Or Expand

**Files:**
- Read: `docs/superpowers/runs/2026-06-22-live-issue-monitoring-regression.md`

- [ ] **Step 1: Review the final report with the operator**

Present:

- The 10 issue outcomes.
- P0/P1 defects and fixes.
- P2/P3 observations.
- Remaining risk.
- Proposed next batch size.

Expected: operator chooses whether to stop, run another 10, or implement follow-up improvements first.

- [ ] **Step 2: Do not leave Symphony running unintentionally**

Run:

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ./elixir/stop-local.ps1
```

Expected: no background local Symphony process remains unless the operator explicitly asks to keep it running.

---

## Self-Review

- Spec coverage: The plan covers real issue creation, non-polluting issue content, local manifest, low-concurrency promotion, dynamic planner conformance checks, observability evidence, stop conditions, defect fixing, automated regression coverage, and final reporting.
- Dynamic-value scan: The plan uses actual project slug `96f5ac7500e2`, local token path `/mnt/c/Users/GQY47/.linear_api_key`, dashboard port `4000`, workflow file `elixir/WORKFLOW.local.md`, and concrete issue titles/descriptions. Runtime issue identifiers are read from `docs/superpowers/runs/2026-06-22-live-issue-monitoring-created.json`.
- Type consistency: The GraphQL snippets use `IssueCreateInput`, `issueCreate`, `issueUpdate`, and state fields already used by the repository's Linear helper patterns.
