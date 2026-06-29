# Rich Linear Issue Context Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make issue execution start with a rich Linear issue snapshot, including comments and other visible issue context, instead of only title and description.

**Architecture:** Extend the normalized `Issue` model with a `snapshot` map that carries rich, API-shaped Linear context. Add a prompt builder appendix that renders the snapshot only when present, and make `linear_issue_read` return the same rich query shape.

**Tech Stack:** Elixir, ExUnit, Linear GraphQL, Solid prompt rendering.

---

### Task 1: Add Failing Coverage For Rich Context

**Files:**
- Modify: `elixir/test/symphony_elixir/agent_tool_test.exs`
- Modify: `elixir/test/symphony_elixir/core_test.exs`

- [ ] Add a test asserting `linear_issue_read` query includes comments, attachments, relations, history, and actor fields.
- [ ] Add a test asserting a normalized issue with a `snapshot` appends rich context to the built prompt.
- [ ] Run the two tests and verify they fail before implementation.

### Task 2: Capture Rich Context In Linear Issue Normalization

**Files:**
- Modify: `elixir/lib/symphony_elixir/linear/issue.ex`
- Modify: `elixir/lib/symphony_elixir/linear/client.ex`

- [ ] Add `snapshot` to `Issue`.
- [ ] Expand candidate and by-id GraphQL queries to request rich one-hop issue context.
- [ ] Normalize the raw Linear issue payload into a prompt-safe snapshot map with page info preserved.
- [ ] Keep existing routing/blocker behavior unchanged.

### Task 3: Render Rich Context Automatically

**Files:**
- Modify: `elixir/lib/symphony_elixir/prompt_builder.ex`

- [ ] Append a `Linear issue snapshot` JSON block after the workflow prompt only when `issue.snapshot` is non-empty.
- [ ] Preserve exact output for issues without a snapshot.
- [ ] Ensure DateTime and nested values remain JSON encodable.

### Task 4: Verify

**Files:**
- Test: `elixir/test/symphony_elixir/agent_tool_test.exs`
- Test: `elixir/test/symphony_elixir/core_test.exs`

- [ ] Run targeted tests.
- [ ] Run broader related tests if targeted tests pass.
