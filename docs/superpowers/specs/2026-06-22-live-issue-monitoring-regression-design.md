# Live Issue Monitoring Regression Design

## Purpose

Run a small batch of real Linear issues through Symphony under active
observation. The goal is not to prove that the system is already stable. The
goal is to expose real planner, orchestration, agent, Linear, workspace, and
observability failures, fix them, and turn repeatable failures into regression
coverage.

## Scope

The first run uses 10 real issues about Symphony itself. They should look like
normal product or engineering work, not synthetic smoke tests. Do not add test
markers, run ids, or special instructions to the issue title or body unless
they would also belong in a normal issue.

The monitoring batch may keep a local manifest that lists the observed issue
keys, branch, workflow file, start time, log locations, workspace roots, and
final findings. That manifest is an operator aid, not a Symphony data model and
not part of the Linear issue content.

## Non-Goals

- Do not add a fixed workflow template that every issue must follow.
- Do not treat final `Done` state as sufficient proof of correct orchestration.
- Do not add this live batch to normal CI.
- Do not create an empty Linear project only for this batch.
- Do not mutate unrelated Linear issues while diagnosing this run.

## Operating Model

The run is a monitored live regression session:

1. Create or select 10 real issues.
2. Start Symphony with the normal workflow file and production-like local
   settings.
3. Allow a small number of issues to run first, usually 2 or 3.
4. Observe Linear state, Symphony logs, dashboard state, workspaces, workflow
   artifacts, and agent output.
5. Pause or reduce concurrency when a serious issue appears.
6. Diagnose the failure layer before changing code.
7. Fix the underlying issue, add focused automated coverage when possible, then
   resume the remaining live issues.

If the first few issues reveal a foundational configuration or routing problem,
the batch should stop until that problem is fixed. Continuing with known broken
basics creates noisy failures and weak evidence.

## Dynamic Orchestration Conformance

Planner output is dynamic. The monitor must not require every issue to follow
the same fixed sequence of phases. Instead, each issue is evaluated against the
plan and contract produced for that issue.

Monitoring checks include:

- The planner creates a clear, executable plan that fits the issue.
- The selected agent matches the routing rules and issue context.
- Runner behavior corresponds to the current planner decision.
- Dependencies are respected when the planner declares them.
- Required workflow artifacts are created and schema-valid.
- Repair turns happen when required artifacts are missing or invalid.
- Terminal Linear states happen only after the relevant completion evidence is
  available.
- Failures enter explicit retry, failed, or blocked paths rather than being
  silently lost.
- A planner revision is visible when runtime evidence invalidates the previous
  plan.

This separates three different outcomes:

- The planner made a poor or incomplete plan.
- The runner or orchestrator did not faithfully execute the plan.
- The agent failed to complete the work even though Symphony routed and
  monitored it correctly.

## Observability Requirements

For every observed issue, collect enough evidence to explain what happened:

- Linear issue key, title, state history, comments, labels, and assignee.
- Chosen agent and why that agent was selected.
- Planner decision or workflow phase progression.
- Agent turn count, session identity when available, and continuation/retry
  events.
- Workspace path and material file changes.
- Workflow artifact paths and validation results.
- Final result, failure reason, and whether the issue needs a code fix,
  prompt/workflow fix, or manual follow-up.

The final batch report should classify each issue across these dimensions:

- `task_result`: whether the issue's intended work was completed.
- `orchestration_result`: whether Symphony planned, routed, advanced, retried,
  and finalized correctly.
- `integration_result`: whether Linear, agent backend, workspace, SSH, auth, and
  local environment behaved correctly.

## Stop Conditions

Stop or pause the batch for these conditions:

- P0: Symphony updates, comments on, closes, or modifies the wrong Linear issue.
- P0: Workspace, artifact, or session data crosses issue boundaries.
- P0: A real issue is closed as complete without required evidence.
- P1: The orchestrator enters an unbounded retry or continuation loop.
- P1: A claim is stuck in a way that prevents normal recovery.
- P1: A repeated planner or runner failure affects multiple issues.

P2 and P3 issues can be logged and batched if they do not corrupt state:

- P2: Agent quality problem while Symphony's orchestration was correct.
- P3: Missing diagnostic detail that makes the run harder to understand.

## Initial 10 Issues

These are real Symphony improvement issues intended to exercise the system:

1. Dashboard shows each issue's current workflow phase.
2. Workflow orchestration generates an auditable execution summary.
3. Missing or invalid workflow artifacts trigger clear repair behavior.
4. Linear terminal state is validated against completion evidence.
5. Planner output explains dependencies for multi-step issues.
6. Agent routing logs explain label, assignee, default, or fallback selection.
7. Concurrent issue runs keep workspace, artifact, log, and session data
   isolated.
8. Failed or blocked issue states include actionable reasons.
9. Continuation retry logs distinguish expected continuation from abnormal
   retry loops.
10. Live orchestration has a preflight health check for token, workflow,
    backend, workspace, and agent availability.

## Expected Output

The first monitored run should produce:

- A local manifest of the 10 observed issues and runtime context.
- A concise report with per-issue result, orchestration result, integration
  result, and evidence links or paths.
- A list of discovered defects, grouped by severity and layer.
- Code fixes for defects that can be corrected during the session.
- Focused automated tests for repeatable Symphony-side bugs.
- Follow-up issues only for findings that cannot be fixed immediately.

## Risks And Controls

Running real issues can change real Linear state. The run must start with low
concurrency, observe early issues closely, and stop on any state-corruption
signal.

Live agent behavior can be nondeterministic. The monitor should avoid
overfitting automated tests to one agent response. Stable Symphony behavior,
contracts, state transitions, artifact validation, and isolation guarantees are
better regression targets than exact natural-language agent output.

Observability gaps are expected. If a failure cannot be diagnosed from current
evidence, improving the diagnostic surface is part of the work rather than a
reason to ignore the failure.
