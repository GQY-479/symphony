# Live Issue Monitoring Regression Run - 2026-06-22

## Context

- Branch: `codex/linear-project-repositories`
- HEAD: `3068d556d8836d2e923074ae19e3b32eb3e17f46`
- Workflow: `elixir/WORKFLOW.local.md`
- Dashboard: `http://127.0.0.1:4000/`
- Log: `/tmp/symphony-local-4000.log`
- Workspace root: `~/code/symphony-workspaces-local`
- Project slug: `96f5ac7500e2`
- Project: `symphony`
- Team: `YQE`
- Default agent: `mimocode`
- Max concurrent agents: `3`
- Candidate filter for this run: temporary workflow copy requires normal Linear label `Improvement`

## Preflight

- Linear token file exists: yes
- Local preflight: pass after stopping existing Symphony pid `224058`
- Existing Symphony status before stop: port `4000` was occupied by `./bin/symphony`
- Pre-existing retry signal: `YQE-57` was in backoff attempt `14`
- Project context: one project, one team, `Backlog` and `Todo` states resolved

## Dirty Worktree At Start

```text
M  elixir/README.md
MM elixir/WORKFLOW.local.md
M  elixir/WORKFLOW.md
 M elixir/lib/symphony_elixir/agent/tool/linear_issue_update_state.ex
 M elixir/lib/symphony_elixir/agent_runner.ex
 M elixir/lib/symphony_elixir/orchestrator.ex
 M elixir/lib/symphony_elixir/workflow/prompts.ex
 M elixir/test/symphony_elixir/acp_agent_runner_test.exs
 M elixir/test/symphony_elixir/agent_tool_test.exs
MM elixir/test/symphony_elixir/core_test.exs
MM elixir/test/symphony_elixir/workflow_prompt_contract_test.exs
?? docs/superpowers/plans/2026-06-20-workflow-orchestration-unification.md
?? docs/superpowers/plans/2026-06-22-live-issue-monitoring-regression.md
```

## Existing Active Candidates Before New Issue Creation

These issues match the current local workflow candidate filter because they are
in project `96f5ac7500e2`, assigned to the current Linear viewer, and in an
active state from `elixir/WORKFLOW.local.md`.

| Issue | State | Labels | Title |
| --- | --- | --- | --- |
| YQE-59 | Todo | symphony-local-test, agent:mimo | Update orchestration behavior, documentation, and regression coverage |
| YQE-58 | Todo | symphony-local-test, agent:mimo | Use issue project context for repository-specific workspaces |
| YQE-57 | In Progress | symphony-local-test, agent:mimo | Implement multi-project config parsing and Linear issue metadata |
| YQE-54 | In Progress | symphony-local-test | 我有很多项目要处理，linear中也由project这个概念。不同的项目有不同的仓库地址，symphony现在好像没有做多项目场景的处理 |

## Created Issues

| Issue | Title | Initial State | Promoted At | Final State | Task Result | Orchestration Result | Integration Result |
| --- | --- | --- | --- | --- | --- | --- | --- |
| YQE-60 | Dashboard shows each issue current workflow phase | Backlog | 2026-06-22T02:48:15+08:00 |  |  |  |  |
| YQE-61 | Workflow orchestration generates an auditable execution summary | Backlog | 2026-06-22T02:48:15+08:00 |  |  |  |  |
| YQE-62 | Missing or invalid workflow artifacts trigger clear repair behavior | Backlog | 2026-06-22T02:48:15+08:00 |  |  |  |  |
| YQE-63 | Linear terminal state is validated against completion evidence | Backlog |  |  |  |  |  |
| YQE-64 | Planner output explains dependencies for multi-step issues | Backlog |  |  |  |  |  |
| YQE-65 | Agent routing logs explain label assignee default or fallback selection | Backlog |  |  |  |  |  |
| YQE-66 | Concurrent issue runs keep workspace artifact log and session data isolated | Backlog |  |  |  |  |  |
| YQE-67 | Failed or blocked issue states include actionable reasons | Backlog |  |  |  |  |  |
| YQE-68 | Continuation retry logs distinguish expected continuation from abnormal retry loops | Backlog |  |  |  |  |  |
| YQE-69 | Live orchestration has a preflight health check | Backlog |  |  |  |  |  |

## Observations

### OBS-3: Wave 1 promoted

Promoted `YQE-60`, `YQE-61`, and `YQE-62` from `Backlog` to `Todo` at
`2026-06-22T02:48:15+08:00`.

### OBS-4: DEFECT-2 evidence workspaces archived before rerun

After stopping Symphony for DEFECT-2, the contaminated `YQE-60`, `YQE-61`, and
`YQE-62` workspaces were moved to
`/home/gqy47/code/symphony-workspaces-local/_live-regression-archive-20260622-0316-defect2`
so the first wave can rerun from clean workspaces while preserving evidence.

### OBS-5: FIX-2 rerun advanced YQE-60 from planning to execution

After strengthening the planning prompt, `YQE-60` produced only
`.symphony/workflow_plan.json` during planning:

```json
{
  "kind": "direct_execution",
  "summary": "Add workflow_phase column to web dashboard tables (running, blocked, retry queue) and add focused tests for presenter/dashboard state transformation",
  "confidence": "high"
}
```

Symphony then started a new `execution` phase session for `YQE-60`, showing the
planner artifact handoff path is working for at least one first-wave issue.

### OBS-6: Valid YQE-62 planning artifact was present before timeout retry

During the same rerun, `YQE-62` wrote and read back a valid
`.symphony/workflow_plan.json`:

```json
{
  "kind": "direct_execution",
  "summary": "增强工作流产物校验与修复行为：改进 Artifacts 模块的错误信息（包含 issue_id、phase、path、reason），增强 Controller 和 Orchestrator 的日志输出，添加缺失/无效产物的回归测试",
  "confidence": "high",
  "agent_id": "mimocode"
}
```

The turn did not end before the ACP timeout, so Symphony retried the same
planning phase instead of accepting the valid artifact.

### OBS-7: DEFECT-3 evidence workspaces archived before rerun

After fixing DEFECT-3, the current `YQE-60`, `YQE-61`, and `YQE-62`
workspaces were moved to
`/home/gqy47/code/symphony-workspaces-local/_live-regression-archive-20260622-0351-defect3`
so the first wave can rerun from clean workspaces while preserving the timeout
and artifact evidence.

### OBS-8: DEFECT-4 evidence captured before rerun

After the next rerun, `YQE-60`, `YQE-61`, and `YQE-62` all hit the MiMo ACP
turn timeout without producing a valid required workflow artifact. Symphony
scheduled retries for all three issues instead of surfacing a blocked workflow
phase with the missing artifact path.

Evidence was archived at
`/home/gqy47/code/symphony-workspaces-local/_live-regression-archive-20260622-0412-defect4`.
The stopped live workspaces were then moved under that archive's
`stopped-workspaces/` directory so the next rerun creates fresh workspaces.

### OBS-9: DEFECT-5 evidence captured before rerun

After restarting with the timeout and retry fixes, `YQE-60` appeared to jump
from planning to execution while the fresh workspace did not have a matching
planning artifact. The workflow registry files were not under the configured
workspace root. They were written below the repository as a literal tilde path:
`elixir/~/code/symphony-workspaces-local/.symphony/workflows/`.

Evidence was archived at
`/home/gqy47/code/symphony-workspaces-local/_live-regression-archive-20260622-0440-defect5`.
That archive contains the wrong registry files, the stopped `YQE-60`,
`YQE-61`, and `YQE-62` workspaces, and the relevant runtime log snapshot. The
erroneous `elixir/~/...` directory was removed after evidence was preserved.

### OBS-10: DEFECT-6 evidence captured before rerun

After FIX-5, the first wave restarted cleanly with concurrency `3`.
`YQE-60`, `YQE-61`, and `YQE-62` all started in `planning` from fresh
workspaces. `YQE-60` and `YQE-62` both wrote valid
`.symphony/workflow_plan.json` files. `YQE-62` returned control to the
orchestrator and advanced to `execution`, which proved the registry path and
basic phase handoff were working.

`YQE-60` did not stop after writing and reading the planning artifact. It
continued running in `planning`, loaded the local `pull` skill, fetched from
origin, and then modified
`elixir/lib/symphony_elixir_web/live/dashboard_live.ex` while Symphony still
reported `workflow_phase: planning`.

Evidence was archived at
`/home/gqy47/code/symphony-workspaces-local/_live-regression-archive-20260622-0457-defect6`.
That archive contains the stopped `YQE-60`, `YQE-61`, and `YQE-62` workspaces,
the valid `YQE-60` and `YQE-62` plan artifacts, the contaminated `YQE-60`
workspace diff, workflow registry snapshots, and `symphony.log.3`.

### OBS-2: Created 10 controlled Backlog issues

Created `YQE-60` through `YQE-69` in `Backlog`. All are assigned to the current
Linear viewer and carry the normal `Improvement` label used by this run's
temporary workflow candidate filter.

### OBS-1: Existing active candidates would mix with the planned batch

Starting Symphony with the current workflow would allow `YQE-54`, `YQE-57`,
`YQE-58`, and `YQE-59` to run before or alongside the 10 new planned issues.
`YQE-57` is especially important because it already has completion comments and
artifacts but remained `In Progress`, then entered repeated retry/backoff. This
is useful evidence, but it should be treated as a pre-existing live issue rather
than silently mixed into the new 10-issue batch.

Decision: use a temporary workflow copy with `tracker.required_labels:
["Improvement"]` and add the normal `Improvement` label to the new 10 issues.
This keeps the issue titles/descriptions normal while preventing pre-existing
active issues without that label from being claimed by this run.

## Defects

### DEFECT-1: MiMo ACP startup command was stale and failed before planning artifacts

- Severity: P1
- Exposed by: Wave 1, `YQE-60`, `YQE-61`, `YQE-62`
- Stage: planning
- Symptom: all three issues were dispatched to `mimocode/acp_stdio`, then failed with `{:acp_exit, 1}` before any `.symphony` workflow artifacts were generated.
- Evidence:
  - `/tmp/symphony-local-4000.log` printed `mimo acp` usage for each workspace, then queued retries.
  - `elixir/log/symphony.log.3` recorded repeated `Agent run failed ... {:acp_exit, 1}` for `YQE-60`, `YQE-61`, and `YQE-62`.
  - Manual reproduction: `mimo --agent compose acp --cwd /tmp --pure` exits `1` with usage, while `mimo acp --cwd /tmp --pure` starts successfully.
- Root cause: checked-in and local workflow configs used stale MiMo args, `--agent compose acp`, but the current MiMo ACP CLI expects `acp` as the subcommand.
- Scope: configuration/example regression, not an orchestrator concurrency failure.

### DEFECT-2: Planner phase can perform implementation work before orchestration advances

- Severity: P1 for orchestration correctness
- Exposed by: Wave 1 resumed run, especially `YQE-61`
- Stage: planning
- Symptom: while Symphony still reported `workflow_phase: planning` and `turn_count: 1`, the MiMo planner created implementation code in the workspace.
- Evidence:
  - `YQE-61` state from `/api/v1/state`: `workflow_phase: planning`, last message `agent tool call: elixir/lib/symphony_elixir/workflow/execution_summary.ex`.
  - Workspace status for `/home/gqy47/code/symphony-workspaces-local/YQE-61`: untracked `.symphony/` and `elixir/lib/symphony_elixir/workflow/execution_summary.ex`.
  - `YQE-61` did produce `.symphony/workflow_plan.json`, but the same planning turn continued into implementation before Symphony validated the plan and advanced to execution.
- Immediate action: stopped Symphony pid `242184` from `/tmp/symphony-local-4000.pid` to preserve evidence and prevent additional phase contamination.
- Root cause: the planning phase prompt required `workflow_plan.json`, but did not explicitly say the planning turn must only write that artifact, must not modify source/test/doc files, must not execute `direct_execution`, and must end after reading the plan back. The base workflow prompt contains execution-oriented instructions, so MiMo continued implementing after writing the plan.

### DEFECT-3: Valid workflow artifact was discarded when ACP timed out afterward

- Severity: P1 for orchestration progress
- Exposed by: FIX-2 rerun, especially `YQE-62`
- Stage: planning
- Symptom: `YQE-62` produced and read back a valid `.symphony/workflow_plan.json`, but the ACP turn timed out afterward and Symphony scheduled a retry of the same planning phase.
- Evidence:
  - `elixir/log/symphony.log.3` recorded `edit` and `read` updates for `YQE-62` `.symphony/workflow_plan.json` at `03:28:33` and `03:28:35`.
  - The same issue then logged `Agent run failed ... :acp_timeout` at `03:31:09` and `Retrying ... attempt 1`.
  - `SymphonyElixir.AgentRunner.do_run_agent_turns/8` only called `ensure_workflow_artifact/6` after `run_turn` returned `{:ok, session}`.
- Root cause: artifact verification was tied to normal ACP turn completion, so a valid phase artifact was ignored when the agent kept running until timeout after writing it.

### DEFECT-4: Workflow phase ACP timeout without artifact retried instead of blocking

- Severity: P1 for live orchestration diagnosability
- Exposed by: FIX-3 rerun, `YQE-60`, `YQE-61`, and `YQE-62`
- Stage: planning/execution
- Symptom: all three active workflow phases hit `:acp_timeout` without a valid required artifact, then Symphony scheduled retries.
- Evidence:
  - `elixir/log/symphony.log.3` recorded `Agent run failed ... :acp_timeout` for all three issues at `04:08:55` to `04:08:56`.
  - The same log immediately recorded `Retrying ... attempt 1` for all three issues.
  - Workspace snapshots showed no `.symphony/workflow_plan.json` or `.symphony/completion_packet.json` artifacts at the stop point.
- Root cause: workflow phase timeout without artifact was classified as a generic agent failure. The orchestrator only blocked artifact repair failures and normal-completion missing artifacts; ACP timeout missing-artifact failures fell through to retry.
- Additional configuration factor: the temporary live workflow inherited `agents.mimocode.timeout_ms: 600000`, while the checked-in base `WORKFLOW.md` uses `3600000`. Ten minutes is too short for these real MiMo workflow turns.

### DEFECT-5: Workflow registry path treated `~` as a literal directory

- Severity: P1 for orchestration correctness
- Exposed by: FIX-4 rerun, especially `YQE-60`
- Stage: workflow registry / phase restoration
- Symptom: Symphony restored phase state from registry files below `elixir/~/code/symphony-workspaces-local/.symphony/workflows/` instead of the configured workspace root at `/home/gqy47/code/symphony-workspaces-local/.symphony/workflows/`.
- Evidence:
  - `YQE-60` resumed in `execution` although the stopped fresh workspace did not have the expected valid planning artifact for that rerun.
  - Wrong registry snapshots were found under `elixir/~/code/symphony-workspaces-local/.symphony/workflows/`.
  - The configured workflow root is `~/code/symphony-workspaces-local`, so registry state must be rooted under the expanded home directory.
- Root cause: `SymphonyElixir.Workflow.Registry.registry_dir/0` joined `.symphony/workflows` onto `Config.settings!().workspace.root` without canonicalizing or expanding `~`.

### DEFECT-6: Valid workflow artifacts did not immediately end the current phase

- Severity: P1 for orchestration correctness
- Exposed by: FIX-5 rerun, especially `YQE-60`
- Stage: planning / ACP runner phase boundary
- Symptom: `YQE-60` wrote and read back a valid `.symphony/workflow_plan.json`, but the ACP turn continued inside `planning` and modified source code before Symphony could advance to `execution`.
- Evidence:
  - Runtime state still showed `YQE-60` in `workflow_phase: planning` after the valid planning artifact existed.
  - `elixir/log/symphony.log.3` recorded `update_kind=edit tool_name=".symphony/workflow_plan.json" tool_status=completed`, then `read tool_name=".symphony/workflow_plan.json"`, followed by tool activity such as `Loaded skill: pull` and `Fetch latest from origin`.
  - Stopped workspace status for `YQE-60`: `M elixir/lib/symphony_elixir_web/live/dashboard_live.ex` and untracked `.symphony/workflow_plan.json`.
  - `YQE-62` in the same wave wrote a valid plan and advanced to `execution`, narrowing the defect to runner/agent phase-boundary enforcement rather than registry path restoration.
- Root cause: `SymphonyElixir.AgentRunner` only validated required workflow artifacts after `run_turn` returned normally, or after an ACP timeout. It did not observe stream updates and return control as soon as the required artifact became valid, so prompt compliance was the only guard against post-artifact phase contamination.

## Fixes Applied

### FIX-1: Restore supported MiMo ACP args

- Updated `elixir/WORKFLOW.md`, `elixir/WORKFLOW.local.md`, and the temporary run workflow copy to use `args: ["acp", "--cwd", "{{workspace}}", "--pure"]`.
- Added a focused contract test in `elixir/test/symphony_elixir/workflow_prompt_contract_test.exs` so in-repo workflow files cannot regress to `--agent compose acp`.
- Verification:
  - `mise exec -- mix test test/symphony_elixir/workflow_prompt_contract_test.exs`
  - Real ACP start/stop smoke using `agents.mimocode` from `WORKFLOW.local.md`: `session_started`, real `ses_...` id returned, then `ok`.

### FIX-2: Make planning phase artifact-only

- Updated `SymphonyElixir.Workflow.Prompts` planning guidance to explicitly require:
  - only create/update `workflow_plan.json`;
  - do not modify source, tests, docs, or other business files;
  - do not execute `direct_execution` implementation content in the planning turn;
  - do not modify the current Linear issue state;
  - stop immediately after writing and reading back `workflow_plan.json`.
- Extended `workflow_prompt_contract_test.exs` to pin those planning constraints.
- Verification:
  - `mise exec -- mix test test/symphony_elixir/workflow_prompt_contract_test.exs`
  - `mise exec -- mix test test/symphony_elixir/workflow_orchestrator_test.exs`
  - `mise exec -- mix test test/symphony_elixir/acp_agent_runner_test.exs`

### FIX-3: Accept valid workflow artifacts after ACP timeout

- Updated `SymphonyElixir.AgentRunner` so a `:acp_timeout` triggers one artifact validation pass for the current workflow phase.
- If the required phase artifact is already valid, the runner logs a warning and returns control to the orchestrator instead of raising and retrying the same phase.
- Missing/invalid artifacts, non-workflow phases, and non-timeout ACP errors still fail normally.
- Added a regression test where the fake ACP server writes a valid `workflow_plan.json`, delays past `timeout_ms`, emits `turn_cancelled`, and `AgentRunner.run/3` still returns `:ok`.
- Updated the fake ACP server test utility to exit quietly on expected broken pipes after timeout cancellation.
- Verification:
  - `mise exec -- mix test test/symphony_elixir/acp_agent_runner_test.exs test/symphony_elixir/workflow_orchestrator_test.exs test/symphony_elixir/workflow_prompt_contract_test.exs`

### FIX-4: Block workflow phase timeout without required artifact

- Updated `SymphonyElixir.Orchestrator` so an `AgentRunner.Error` with `reason: :acp_timeout` in `planning`, `execution`, or `review` blocks the issue instead of scheduling a retry.
- The blocked reason now includes the workflow phase, expected artifact path, `agent_id`, `agent_kind`, `session_id`, and `reason=:acp_timeout`.
- Added a regression test for planning timeout without `workflow_plan.json`.
- Restored `agents.mimocode.timeout_ms` to `3600000` in `elixir/WORKFLOW.local.md` and the temporary live workflow copy.
- Rebuilt `elixir/bin/symphony` with `mise exec -- mix escript.build` before restarting the live run.
- Verification:
  - `mise exec -- mix test test/symphony_elixir/workflow_orchestrator_test.exs --trace`
  - `mise exec -- mix test test/symphony_elixir/acp_agent_runner_test.exs test/symphony_elixir/acp_stdio_backend_test.exs test/symphony_elixir/workflow_orchestrator_test.exs test/symphony_elixir/workflow_prompt_contract_test.exs`

### FIX-5: Expand workspace roots before computing workflow registry location

- Updated `SymphonyElixir.Workflow.Registry` so the configured workspace root is expanded and canonicalized before appending `.symphony/workflows`.
- Added a regression test proving a root like `~/code/symphony-workspaces-local` stores registry files under the home directory, not under the current working directory.
- Archived the wrong registry directory and stopped workspaces before removing `elixir/~/...`.
- Rebuilt `elixir/bin/symphony` with `mise exec -- mix escript.build` before restarting the live run.
- Verification:
  - `mise exec -- mix test test/symphony_elixir/workflow_artifacts_test.exs --trace`
  - `mise exec -- mix test test/symphony_elixir/workflow_controller_test.exs test/symphony_elixir/workflow_orchestrator_test.exs test/symphony_elixir/workflow_artifacts_test.exs`
  - `mise exec -- mix test test/symphony_elixir/acp_agent_runner_test.exs test/symphony_elixir/acp_stdio_backend_test.exs test/symphony_elixir/workflow_artifacts_test.exs test/symphony_elixir/workflow_controller_test.exs test/symphony_elixir/workflow_orchestrator_test.exs test/symphony_elixir/workflow_prompt_contract_test.exs`

### FIX-6: End workflow phases as soon as a required artifact is valid

- Updated `SymphonyElixir.AgentRunner` so workflow-phase ACP messages are artifact-aware.
- When an ACP notification arrives and the required artifact for the current phase validates, the runner accepts the artifact and returns control to the orchestrator instead of waiting for the agent to end the turn or time out.
- Non-workflow phases, missing/invalid artifacts, normal turn completion, repair turns, and timeout handling remain on their existing paths.
- Added a regression test where a fake ACP server writes a valid `workflow_plan.json`, keeps streaming updates without returning a prompt response, and `AgentRunner.run/3` must still return promptly.
- Verification:
  - RED before fix: `mise exec -- mix test test/symphony_elixir/acp_agent_runner_test.exs:367 --trace` failed because `Task.yield(task, 2000)` returned `nil`.
  - GREEN after fix: `mise exec -- mix test test/symphony_elixir/acp_agent_runner_test.exs:367 --trace`
  - `mise exec -- mix test test/symphony_elixir/acp_agent_runner_test.exs --trace`
  - `mise exec -- mix test test/symphony_elixir/acp_agent_runner_test.exs test/symphony_elixir/acp_stdio_backend_test.exs test/symphony_elixir/workflow_orchestrator_test.exs test/symphony_elixir/workflow_prompt_contract_test.exs test/symphony_elixir/workflow_artifacts_test.exs test/symphony_elixir/workflow_controller_test.exs`

## Final Summary
