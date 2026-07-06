# Report Readability Spike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a local spike that generates inspectable engineering HTML report samples before any Linear, publish, or dashboard integration work continues.

**Architecture:** Add a small `SymphonyElixir.Workflow.ReportSpike` pipeline under the Elixir app: load a fact-only `report_context.json`, derive a `report_brief.json`, render self-contained `index.html` and short `summary.md`, run rule-based readability checks, and write a manifest plus review form. The spike uses checked-in fixtures and a Mix task to generate local `.symphony/report-spikes/<sample-id>/` outputs for human review.

**Tech Stack:** Elixir, ExUnit, Jason, Floki test dependency, local filesystem artifacts, static HTML/CSS.

---

## Scope And Constraints

This plan intentionally does not implement Linear root comments, external publish adapters, dashboard embedding, or full workflow integration. Those remain blocked until the generated samples pass human readability review.

Current workspace may already contain unrelated changes such as `elixir/WORKFLOW.md`, an old spec deletion, or `docs/compose/plans/`. Do not stage those files while executing this plan. Use explicit `git add` paths from each task.

## File Structure

- Create `elixir/test/fixtures/report_spikes/feature_success_context.json`
  A single feature implementation fact package.
- Create `elixir/test/fixtures/report_spikes/workflow_success_context.json`
  A multi-issue workflow fact package with no blocking attention item.
- Create `elixir/test/fixtures/report_spikes/workflow_rework_context.json`
  A multi-issue workflow fact package with `needs_rework`, `blocked`, and missing evidence.
- Create `elixir/lib/symphony_elixir/workflow/report_spike/context.ex`
  Loads and validates the fact package.
- Create `elixir/lib/symphony_elixir/workflow/report_spike/brief.ex`
  Chooses the report kind, reader goal, top questions, sections, and attention policy.
- Create `elixir/lib/symphony_elixir/workflow/report_spike/renderer.ex`
  Renders self-contained HTML and short Markdown from context plus brief.
- Create `elixir/lib/symphony_elixir/workflow/report_spike/quality.ex`
  Runs rule-based readability checks and returns pass/draft quality data.
- Create `elixir/lib/symphony_elixir/workflow/report_spike/runner.ex`
  Writes all spike artifacts to an output directory.
- Create `elixir/lib/mix/tasks/symphony.report_spike.generate.ex`
  CLI entrypoint to generate local sample reports from fixture contexts.
- Create `elixir/test/symphony_elixir/workflow_report_spike_test.exs`
  Targeted test coverage for context loading, brief selection, rendering, quality checks, and runner output.

---

### Task 1: Add Report Context Fixtures

**Files:**
- Create: `elixir/test/fixtures/report_spikes/feature_success_context.json`
- Create: `elixir/test/fixtures/report_spikes/workflow_success_context.json`
- Create: `elixir/test/fixtures/report_spikes/workflow_rework_context.json`

- [ ] **Step 1: Create the fixture directory**

Run:

```powershell
New-Item -ItemType Directory -Force elixir\test\fixtures\report_spikes
```

Expected: directory exists at `elixir/test/fixtures/report_spikes`.

- [ ] **Step 2: Add the feature success context**

Create `elixir/test/fixtures/report_spikes/feature_success_context.json` with this content:

```json
{
  "schema_version": 1,
  "subject": {
    "kind": "issue",
    "id": "YQE-801",
    "title": "Add report artifact protocol",
    "links": [
      {
        "label": "Linear issue",
        "href": "https://linear.app/example/issue/YQE-801"
      }
    ]
  },
  "task": {
    "original_request": "Add a local HTML report artifact protocol for engineering task summaries.",
    "task_type_hint": "feature_implementation",
    "success_criteria": [
      "The report has a stable output directory.",
      "The report includes HTML, Markdown, manifest, and review form files.",
      "The report is generated from structured facts, not free-form chat."
    ]
  },
  "work_items": [
    {
      "id": "YQE-801",
      "title": "Add report artifact protocol",
      "status": "completed",
      "outcome": "completed",
      "summary": "Defined a local artifact directory shape and report context schema for engineering task reports.",
      "evidence": [
        {
          "label": "Design spec",
          "href": "docs/superpowers/specs/2026-07-06-report-readability-spike-design.md"
        },
        {
          "label": "Verification command",
          "href": "commands/git-diff-check.txt"
        }
      ]
    }
  ],
  "verification": {
    "commands": [
      {
        "command": "git diff --check HEAD~1 HEAD",
        "status": "pass",
        "summary": "No whitespace or patch formatting problems were found."
      }
    ],
    "test_results": []
  },
  "risks": [
    "HTML report readability is not proven until the generated sample is reviewed by a human."
  ],
  "open_questions": [],
  "raw_artifacts": [
    {
      "label": "Raw context",
      "path": "report_context.json",
      "kind": "json"
    }
  ]
}
```

- [ ] **Step 3: Add the workflow success context**

Create `elixir/test/fixtures/report_spikes/workflow_success_context.json` with this content:

```json
{
  "schema_version": 1,
  "subject": {
    "kind": "workflow",
    "id": "YQE-900",
    "title": "Generate readable report samples",
    "links": [
      {
        "label": "Root issue",
        "href": "https://linear.app/example/issue/YQE-900"
      }
    ]
  },
  "task": {
    "original_request": "Create report samples that prove the HTML format can explain a multi-issue workflow.",
    "task_type_hint": "workflow_batch",
    "success_criteria": [
      "The report summarizes all work items.",
      "The report highlights whether human attention is needed.",
      "The report links each conclusion to evidence."
    ]
  },
  "work_items": [
    {
      "id": "YQE-901",
      "title": "Collect workflow facts",
      "status": "completed",
      "outcome": "completed",
      "summary": "Collected root issue, work item, verification, and evidence facts into a structured context file.",
      "evidence": [
        {
          "label": "Context fixture",
          "href": "elixir/test/fixtures/report_spikes/workflow_success_context.json"
        }
      ]
    },
    {
      "id": "YQE-902",
      "title": "Render sample report",
      "status": "completed",
      "outcome": "completed",
      "summary": "Rendered a self-contained HTML report and short Markdown summary.",
      "evidence": [
        {
          "label": "Generated HTML",
          "href": ".symphony/report-spikes/workflow-success/index.html"
        }
      ]
    },
    {
      "id": "YQE-903",
      "title": "Run readability checks",
      "status": "completed",
      "outcome": "completed",
      "summary": "Verified first-screen summary, evidence index, short summary, and absence of external resources.",
      "evidence": [
        {
          "label": "Manifest",
          "href": ".symphony/report-spikes/workflow-success/manifest.json"
        }
      ]
    }
  ],
  "verification": {
    "commands": [
      {
        "command": "mix test test/symphony_elixir/workflow_report_spike_test.exs",
        "status": "pass",
        "summary": "Spike tests passed for fixture loading, rendering, and quality checks."
      }
    ],
    "test_results": [
      {
        "name": "workflow_report_spike_test",
        "status": "pass",
        "summary": "All targeted report spike tests passed."
      }
    ]
  },
  "risks": [],
  "open_questions": [],
  "raw_artifacts": [
    {
      "label": "Raw context",
      "path": "report_context.json",
      "kind": "json"
    }
  ]
}
```

- [ ] **Step 4: Add the workflow rework context**

Create `elixir/test/fixtures/report_spikes/workflow_rework_context.json` with this content:

```json
{
  "schema_version": 1,
  "subject": {
    "kind": "workflow",
    "id": "YQE-910",
    "title": "Validate failure-heavy report readability",
    "links": [
      {
        "label": "Root issue",
        "href": "https://linear.app/example/issue/YQE-910"
      }
    ]
  },
  "task": {
    "original_request": "Create a report sample that makes failed, blocked, and needs_rework work items obvious.",
    "task_type_hint": "workflow_batch",
    "success_criteria": [
      "The report puts attention items above successful items.",
      "The report explains why each attention item needs follow-up.",
      "The report does not hide missing evidence."
    ]
  },
  "work_items": [
    {
      "id": "YQE-911",
      "title": "Implement base report generator",
      "status": "completed",
      "outcome": "completed",
      "summary": "Generated an initial HTML report from structured context.",
      "evidence": [
        {
          "label": "Generator test",
          "href": "elixir/test/symphony_elixir/workflow_report_spike_test.exs"
        }
      ]
    },
    {
      "id": "YQE-912",
      "title": "Review attention handling",
      "status": "completed",
      "outcome": "needs_rework",
      "summary": "Review found that evidence for one claim was too weak and should be rewritten before formal reporting.",
      "evidence": [
        {
          "label": "Review result",
          "href": ".symphony/issue_result.json"
        }
      ]
    },
    {
      "id": "YQE-913",
      "title": "Publish report externally",
      "status": "blocked",
      "outcome": "blocked",
      "summary": "External publishing is intentionally blocked until readability samples pass human review.",
      "evidence": []
    },
    {
      "id": "YQE-914",
      "title": "Validate dashboard embedding",
      "status": "failed",
      "outcome": "failed",
      "summary": "Dashboard embedding was not attempted because the spike has not passed the readability gate.",
      "evidence": [
        {
          "label": "Gate decision",
          "href": "docs/superpowers/specs/2026-07-06-report-readability-spike-design.md"
        }
      ]
    }
  ],
  "verification": {
    "commands": [
      {
        "command": "mix test test/symphony_elixir/workflow_report_spike_test.exs",
        "status": "pass",
        "summary": "Targeted spike tests passed before sample generation."
      }
    ],
    "test_results": []
  },
  "risks": [
    "A report that hides needs_rework or blocked items would fail the spike even if all files are generated.",
    "Human review can reject a report that passes rule checks."
  ],
  "open_questions": [
    "Which visual density level is most useful for the workflow owner?"
  ],
  "raw_artifacts": [
    {
      "label": "Raw context",
      "path": "report_context.json",
      "kind": "json"
    },
    {
      "label": "Raw validation log",
      "path": "validation.log",
      "kind": "log"
    }
  ]
}
```

- [ ] **Step 5: Commit fixtures**

Run:

```powershell
git add -- elixir/test/fixtures/report_spikes/feature_success_context.json elixir/test/fixtures/report_spikes/workflow_success_context.json elixir/test/fixtures/report_spikes/workflow_rework_context.json
git commit -m "test(report): add readability spike fixtures"
```

Expected: commit only includes the three fixture files.

---

### Task 2: Load And Validate Report Contexts

**Files:**
- Create: `elixir/lib/symphony_elixir/workflow/report_spike/context.ex`
- Create: `elixir/test/symphony_elixir/workflow_report_spike_test.exs`

- [ ] **Step 1: Write failing context tests**

Create `elixir/test/symphony_elixir/workflow_report_spike_test.exs` with this initial content:

```elixir
defmodule SymphonyElixir.WorkflowReportSpikeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Workflow.ReportSpike.Context

  @fixtures Path.expand("../fixtures/report_spikes", __DIR__)

  describe "Context.load/1" do
    test "loads a valid report context fixture" do
      path = Path.join(@fixtures, "feature_success_context.json")

      assert {:ok, context} = Context.load(path)
      assert context["subject"]["id"] == "YQE-801"
      assert [%{"id" => "YQE-801"}] = context["work_items"]
    end

    test "rejects context without a subject" do
      invalid = %{
        "schema_version" => 1,
        "task" => %{"original_request" => "missing subject"},
        "work_items" => []
      }

      assert {:error, :invalid_report_context} = Context.validate(invalid)
    end

    test "rejects work items without evidence and without an attention outcome" do
      invalid = %{
        "schema_version" => 1,
        "subject" => %{"kind" => "issue", "id" => "YQE-1", "title" => "Invalid"},
        "task" => %{"original_request" => "Invalid", "task_type_hint" => "feature_implementation"},
        "work_items" => [
          %{
            "id" => "YQE-2",
            "title" => "Missing evidence",
            "status" => "completed",
            "outcome" => "completed",
            "summary" => "Completed without evidence",
            "evidence" => []
          }
        ]
      }

      assert {:error, :invalid_report_context} = Context.validate(invalid)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```powershell
cd elixir
mix test test/symphony_elixir/workflow_report_spike_test.exs
```

Expected: FAIL with an error that `SymphonyElixir.Workflow.ReportSpike.Context` is not available.

- [ ] **Step 3: Implement context loader**

Create `elixir/lib/symphony_elixir/workflow/report_spike/context.ex`:

```elixir
defmodule SymphonyElixir.Workflow.ReportSpike.Context do
  @moduledoc """
  加载并校验工程 HTML 汇报 spike 的事实包。
  """

  @attention_outcomes MapSet.new(["failed", "fail", "blocked", "needs_rework", "needs_human"])

  @spec load(Path.t()) :: {:ok, map()} | {:error, term()}
  def load(path) when is_binary(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         :ok <- validate(decoded) do
      {:ok, decoded}
    end
  end

  @spec validate(term()) :: :ok | {:error, :invalid_report_context}
  def validate(%{
        "schema_version" => 1,
        "subject" => subject,
        "task" => task,
        "work_items" => work_items
      })
      when is_map(subject) and is_map(task) and is_list(work_items) do
    cond do
      not valid_subject?(subject) ->
        {:error, :invalid_report_context}

      not valid_task?(task) ->
        {:error, :invalid_report_context}

      work_items == [] ->
        {:error, :invalid_report_context}

      not Enum.all?(work_items, &valid_work_item?/1) ->
        {:error, :invalid_report_context}

      true ->
        :ok
    end
  end

  def validate(_context), do: {:error, :invalid_report_context}

  @spec attention_item?(map()) :: boolean()
  def attention_item?(%{"outcome" => outcome}) when is_binary(outcome) do
    MapSet.member?(@attention_outcomes, String.downcase(outcome))
  end

  def attention_item?(%{"status" => status}) when is_binary(status) do
    MapSet.member?(@attention_outcomes, String.downcase(status))
  end

  def attention_item?(_item), do: false

  defp valid_subject?(%{"kind" => kind, "id" => id, "title" => title}) do
    non_blank?(kind) and non_blank?(id) and non_blank?(title)
  end

  defp valid_subject?(_subject), do: false

  defp valid_task?(%{"original_request" => request, "task_type_hint" => hint}) do
    non_blank?(request) and non_blank?(hint)
  end

  defp valid_task?(_task), do: false

  defp valid_work_item?(
         %{
           "id" => id,
           "title" => title,
           "status" => status,
           "outcome" => outcome,
           "summary" => summary,
           "evidence" => evidence
         } = item
       )
       when is_list(evidence) do
    non_blank?(id) and non_blank?(title) and non_blank?(status) and non_blank?(outcome) and
      non_blank?(summary) and (evidence != [] or attention_item?(item))
  end

  defp valid_work_item?(_item), do: false

  defp non_blank?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_blank?(_value), do: false
end
```

- [ ] **Step 4: Run tests to verify pass**

Run:

```powershell
cd elixir
mix test test/symphony_elixir/workflow_report_spike_test.exs
```

Expected: PASS for 3 tests.

- [ ] **Step 5: Commit context loader**

Run:

```powershell
git add -- elixir/lib/symphony_elixir/workflow/report_spike/context.ex elixir/test/symphony_elixir/workflow_report_spike_test.exs
git commit -m "feat(report): load readability spike contexts"
```

Expected: commit only includes context loader and test file changes.

---

### Task 3: Build The Report Brief

**Files:**
- Create: `elixir/lib/symphony_elixir/workflow/report_spike/brief.ex`
- Modify: `elixir/test/symphony_elixir/workflow_report_spike_test.exs`

- [ ] **Step 1: Add failing brief tests**

Append this `describe` block to `elixir/test/symphony_elixir/workflow_report_spike_test.exs`:

```elixir
  describe "Brief.build/1" do
    alias SymphonyElixir.Workflow.ReportSpike.Brief

    test "builds a feature implementation brief" do
      {:ok, context} = Context.load(Path.join(@fixtures, "feature_success_context.json"))

      assert {:ok, brief} = Brief.build(context)
      assert brief["report_kind"] == "feature_implementation"
      assert brief["reader_goal"] =~ "判断功能是否完成"
      assert "结论" in brief["sections"]
      assert "验证结果" in brief["sections"]
    end

    test "builds an attention-first workflow brief when work items need follow-up" do
      {:ok, context} = Context.load(Path.join(@fixtures, "workflow_rework_context.json"))

      assert {:ok, brief} = Brief.build(context)
      assert brief["report_kind"] == "workflow_with_attention"
      assert brief["attention_policy"] =~ "置顶"
      assert "需要关注" in brief["sections"]
    end
  end
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```powershell
cd elixir
mix test test/symphony_elixir/workflow_report_spike_test.exs
```

Expected: FAIL with an error that `SymphonyElixir.Workflow.ReportSpike.Brief` is not available.

- [ ] **Step 3: Implement brief builder**

Create `elixir/lib/symphony_elixir/workflow/report_spike/brief.ex`:

```elixir
defmodule SymphonyElixir.Workflow.ReportSpike.Brief do
  @moduledoc """
  根据事实包生成报告设计说明。
  """

  alias SymphonyElixir.Workflow.ReportSpike.Context

  @spec build(map()) :: {:ok, map()} | {:error, term()}
  def build(%{"task" => task, "work_items" => work_items} = context) when is_list(work_items) do
    kind = report_kind(task["task_type_hint"], work_items)

    {:ok,
     %{
       "schema_version" => 1,
       "report_kind" => kind,
       "audience" => "workflow owner",
       "reader_goal" => reader_goal(kind),
       "top_questions" => top_questions(kind),
       "sections" => sections(kind),
       "attention_policy" => attention_policy(context)
     }}
  end

  def build(_context), do: {:error, :invalid_report_context}

  defp report_kind(_hint, work_items) do
    cond do
      Enum.any?(work_items, &Context.attention_item?/1) -> "workflow_with_attention"
      length(work_items) > 1 -> "workflow_batch"
      true -> "feature_implementation"
    end
  end

  defp reader_goal("feature_implementation") do
    "快速判断功能是否完成、怎么验证、风险在哪里、证据在哪里"
  end

  defp reader_goal("workflow_batch") do
    "快速判断整批 issue 是否完成、每个节点结果如何、证据在哪里"
  end

  defp reader_goal("workflow_with_attention") do
    "快速判断哪些 issue 需要介入、为什么不能视为完成、证据在哪里"
  end

  defp top_questions("workflow_with_attention") do
    ["哪里需要我介入？", "哪些结果不可信？", "证据在哪里？", "下一步是什么？"]
  end

  defp top_questions(_kind) do
    ["完成了吗？", "做了什么？", "怎么验证？", "风险在哪里？", "证据在哪里？"]
  end

  defp sections("feature_implementation") do
    ["结论", "用户可见变化", "核心实现", "验证结果", "风险和后续", "证据索引"]
  end

  defp sections("workflow_batch") do
    ["整体状态", "Issue 结果矩阵", "验证和证据索引", "风险和后续"]
  end

  defp sections("workflow_with_attention") do
    ["整体状态", "需要关注", "Issue 结果矩阵", "验证和证据索引", "后续动作"]
  end

  defp attention_policy(%{"work_items" => work_items}) do
    if Enum.any?(work_items, &Context.attention_item?/1) do
      "failed、blocked、needs_rework、needs_human 和证据缺失必须置顶"
    else
      "无阻断项时压缩成功项，并保留证据入口"
    end
  end
end
```

- [ ] **Step 4: Run tests to verify pass**

Run:

```powershell
cd elixir
mix test test/symphony_elixir/workflow_report_spike_test.exs
```

Expected: PASS for 5 tests.

- [ ] **Step 5: Commit brief builder**

Run:

```powershell
git add -- elixir/lib/symphony_elixir/workflow/report_spike/brief.ex elixir/test/symphony_elixir/workflow_report_spike_test.exs
git commit -m "feat(report): build readability report briefs"
```

Expected: commit only includes brief builder and test changes.

---

### Task 4: Render Self-Contained HTML And Markdown

**Files:**
- Create: `elixir/lib/symphony_elixir/workflow/report_spike/renderer.ex`
- Modify: `elixir/test/symphony_elixir/workflow_report_spike_test.exs`

- [ ] **Step 1: Add failing renderer tests**

Append this `describe` block to `elixir/test/symphony_elixir/workflow_report_spike_test.exs`:

```elixir
  describe "Renderer.render/2" do
    alias SymphonyElixir.Workflow.ReportSpike.{Brief, Renderer}

    test "renders self-contained HTML with first-screen summary and evidence links" do
      {:ok, context} = Context.load(Path.join(@fixtures, "workflow_rework_context.json"))
      {:ok, brief} = Brief.build(context)

      assert {:ok, %{html: html, summary: summary}} = Renderer.render(context, brief)
      assert html =~ ~s(id="top-summary")
      assert html =~ ~s(id="attention")
      assert html =~ "YQE-912"
      assert html =~ "needs_rework"
      assert html =~ ~s(<details class="raw-artifact">)
      refute html =~ ~s(<script src=)
      refute html =~ ~s(<link href=)
      assert summary =~ "YQE-910"
      assert String.length(summary) < 2_000
    end

    test "escapes user-provided text" do
      context = %{
        "schema_version" => 1,
        "subject" => %{"kind" => "issue", "id" => "YQE-X", "title" => "<script>alert(1)</script>"},
        "task" => %{"original_request" => "Escape title", "task_type_hint" => "feature_implementation"},
        "work_items" => [
          %{
            "id" => "YQE-X",
            "title" => "<b>unsafe</b>",
            "status" => "completed",
            "outcome" => "completed",
            "summary" => "Escaped <tag>",
            "evidence" => [%{"label" => "Evidence", "href" => "safe.txt"}]
          }
        ],
        "verification" => %{"commands" => [], "test_results" => []},
        "risks" => [],
        "open_questions" => [],
        "raw_artifacts" => []
      }

      {:ok, brief} = Brief.build(context)
      assert {:ok, %{html: html}} = Renderer.render(context, brief)
      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      assert html =~ "&lt;b&gt;unsafe&lt;/b&gt;"
    end
  end
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```powershell
cd elixir
mix test test/symphony_elixir/workflow_report_spike_test.exs
```

Expected: FAIL with an error that `SymphonyElixir.Workflow.ReportSpike.Renderer` is not available.

- [ ] **Step 3: Implement renderer**

Create `elixir/lib/symphony_elixir/workflow/report_spike/renderer.ex`:

```elixir
defmodule SymphonyElixir.Workflow.ReportSpike.Renderer do
  @moduledoc """
  将报告事实包和 brief 渲染为自包含 HTML 与短 Markdown 摘要。
  """

  alias SymphonyElixir.Workflow.ReportSpike.Context

  @spec render(map(), map()) :: {:ok, %{html: String.t(), summary: String.t()}} | {:error, term()}
  def render(%{"subject" => subject, "work_items" => work_items} = context, brief)
      when is_list(work_items) and is_map(brief) do
    attention_items = Enum.filter(work_items, &Context.attention_item?/1)

    html =
      [
        "<!doctype html>",
        ~s(<html lang="zh-CN">),
        "<head>",
        ~s(<meta charset="utf-8">),
        ~s(<meta name="viewport" content="width=device-width, initial-scale=1">),
        "<title>#{h(subject["id"])} #{h(subject["title"])}</title>",
        "<style>",
        css(),
        "</style>",
        "</head>",
        "<body>",
        header(context, brief, attention_items),
        attention_section(attention_items),
        work_item_section(work_items),
        verification_section(context),
        risk_section(context),
        evidence_section(work_items),
        raw_artifacts_section(context),
        "</body>",
        "</html>"
      ]
      |> Enum.join("\n")

    {:ok, %{html: html, summary: markdown_summary(context, attention_items)}}
  end

  def render(_context, _brief), do: {:error, :invalid_report_input}

  defp header(%{"subject" => subject, "work_items" => work_items}, brief, attention_items) do
    status = if attention_items == [], do: "可继续", else: "需要关注"

    """
    <main>
      <section id="top-summary" class="hero">
        <p class="eyebrow">#{h(brief["report_kind"])} · #{h(status)}</p>
        <h1>#{h(subject["id"])} #{h(subject["title"])}</h1>
        <p class="reader-goal">#{h(brief["reader_goal"])}</p>
        <div class="stats">
          <div><strong>#{length(work_items)}</strong><span>Work items</span></div>
          <div><strong>#{completed_count(work_items)}</strong><span>Completed</span></div>
          <div><strong>#{length(attention_items)}</strong><span>Need attention</span></div>
        </div>
        <ul class="top-questions">
          #{brief["top_questions"] |> Enum.map(&"<li>#{h(&1)}</li>") |> Enum.join("\n")}
        </ul>
      </section>
    """
  end

  defp attention_section([]) do
    """
      <section id="attention" class="section ok">
        <h2>需要关注</h2>
        <p>当前样例没有阻断、返工或失败项。请继续查看验证和证据索引。</p>
      </section>
    """
  end

  defp attention_section(items) do
    rows =
      items
      |> Enum.map(fn item ->
        """
        <article class="attention-card">
          <h3>#{h(item["id"])} #{h(item["title"])}</h3>
          <p><strong>状态：</strong>#{h(item["status"])} / #{h(item["outcome"])}</p>
          <p>#{h(item["summary"])}</p>
          <p><strong>证据数量：</strong>#{length(item["evidence"] || [])}</p>
        </article>
        """
      end)
      |> Enum.join("\n")

    """
      <section id="attention" class="section attention">
        <h2>需要关注</h2>
        #{rows}
      </section>
    """
  end

  defp work_item_section(work_items) do
    rows =
      work_items
      |> Enum.map(fn item ->
        """
        <tr>
          <td>#{h(item["id"])}</td>
          <td>#{h(item["title"])}</td>
          <td><span class="pill">#{h(item["status"])}</span></td>
          <td><span class="pill">#{h(item["outcome"])}</span></td>
          <td>#{h(item["summary"])}</td>
        </tr>
        """
      end)
      |> Enum.join("\n")

    """
      <section id="work-items" class="section">
        <h2>Issue 结果矩阵</h2>
        <div class="table-wrap">
          <table>
            <thead><tr><th>ID</th><th>标题</th><th>状态</th><th>结果</th><th>摘要</th></tr></thead>
            <tbody>#{rows}</tbody>
          </table>
        </div>
      </section>
    """
  end

  defp verification_section(%{"verification" => %{"commands" => commands}}) when is_list(commands) do
    items =
      commands
      |> Enum.map(fn command ->
        "<li><code>#{h(command["command"])}</code> · #{h(command["status"])} · #{h(command["summary"])}</li>"
      end)
      |> Enum.join("\n")

    """
      <section id="verification" class="section">
        <h2>验证结果</h2>
        <ul>#{items}</ul>
      </section>
    """
  end

  defp verification_section(_context) do
    """
      <section id="verification" class="section warning">
        <h2>验证结果</h2>
        <p>未提供验证命令。该报告不能作为完成证明。</p>
      </section>
    """
  end

  defp risk_section(%{"risks" => risks, "open_questions" => questions}) do
    risk_items = Enum.map(risks || [], &"<li>#{h(&1)}</li>") |> Enum.join("\n")
    question_items = Enum.map(questions || [], &"<li>#{h(&1)}</li>") |> Enum.join("\n")

    """
      <section id="risks" class="section">
        <h2>风险和未决问题</h2>
        <h3>风险</h3>
        <ul>#{empty_message(risk_items, "无已知风险")}</ul>
        <h3>未决问题</h3>
        <ul>#{empty_message(question_items, "无未决问题")}</ul>
      </section>
    """
  end

  defp evidence_section(work_items) do
    items =
      work_items
      |> Enum.flat_map(fn item ->
        Enum.map(item["evidence"] || [], fn evidence ->
          href = evidence["href"] || "#"
          "<li><a href=\"#{h(href)}\">#{h(item["id"])} · #{h(evidence["label"])}</a></li>"
        end)
      end)
      |> Enum.join("\n")

    """
      <section id="evidence" class="section">
        <h2>证据索引</h2>
        <ul>#{empty_message(items, "没有可用证据")}</ul>
      </section>
    """
  end

  defp raw_artifacts_section(%{"raw_artifacts" => artifacts}) when is_list(artifacts) do
    details =
      artifacts
      |> Enum.map(fn artifact ->
        """
        <details class="raw-artifact">
          <summary>#{h(artifact["label"])} · #{h(artifact["kind"])}</summary>
          <p>路径：<code>#{h(artifact["path"])}</code></p>
        </details>
        """
      end)
      |> Enum.join("\n")

    """
      <section id="raw-artifacts" class="section">
        <h2>原始材料</h2>
        #{details}
      </section>
    </main>
    """
  end

  defp raw_artifacts_section(_context), do: "</main>"

  defp markdown_summary(%{"subject" => subject, "work_items" => work_items} = context, attention_items) do
    lines = [
      "# Workflow 汇报：#{subject["id"]} #{subject["title"]}",
      "",
      "状态：#{if attention_items == [], do: "可继续", else: "需要关注"}",
      "Work items：#{length(work_items)}",
      "需要关注：#{length(attention_items)}",
      "",
      "## 结论",
      "- #{context["task"]["original_request"]}",
      "",
      "## 需要关注",
      attention_markdown(attention_items),
      "",
      "## 证据",
      "- 完整 HTML 报告见 index.html。"
    ]

    Enum.join(lines, "\n")
  end

  defp attention_markdown([]), do: "- 当前没有阻断、返工或失败项。"

  defp attention_markdown(items) do
    items
    |> Enum.map(&"- #{&1["id"]} #{&1["title"]}: #{&1["outcome"]}")
    |> Enum.join("\n")
  end

  defp completed_count(work_items) do
    Enum.count(work_items, &(&1["status"] == "completed" and &1["outcome"] == "completed"))
  end

  defp empty_message("", message), do: "<li>#{h(message)}</li>"
  defp empty_message(items, _message), do: items

  defp css do
    """
    :root { color-scheme: light; font-family: Arial, sans-serif; }
    body { margin: 0; background: #f6f7f9; color: #17202a; }
    main { max-width: 1120px; margin: 0 auto; padding: 32px 20px 56px; }
    .hero, .section { background: #fff; border: 1px solid #d8dee6; border-radius: 8px; padding: 24px; margin-bottom: 18px; }
    .eyebrow { color: #52616f; font-weight: 700; text-transform: uppercase; font-size: 12px; letter-spacing: .04em; }
    h1 { font-size: 30px; line-height: 1.2; margin: 8px 0 12px; }
    h2 { font-size: 20px; margin: 0 0 16px; }
    h3 { font-size: 16px; margin: 14px 0 8px; }
    .reader-goal { font-size: 16px; max-width: 820px; }
    .stats { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 12px; margin: 18px 0; }
    .stats div { border: 1px solid #e1e6ee; border-radius: 8px; padding: 14px; background: #fbfcfe; }
    .stats strong { display: block; font-size: 28px; }
    .stats span { color: #52616f; }
    .top-questions { display: flex; flex-wrap: wrap; gap: 8px; padding: 0; list-style: none; }
    .top-questions li, .pill { border: 1px solid #cad3df; border-radius: 999px; padding: 5px 9px; background: #f8fafc; }
    .attention { border-color: #e4a11b; background: #fffaf0; }
    .warning { border-color: #e4a11b; }
    .ok { border-color: #61a36f; }
    .attention-card { border-top: 1px solid #e7c77d; padding-top: 12px; margin-top: 12px; }
    .table-wrap { overflow-x: auto; }
    table { width: 100%; border-collapse: collapse; min-width: 760px; }
    th, td { border-bottom: 1px solid #e1e6ee; padding: 10px; text-align: left; vertical-align: top; }
    code { background: #eef2f6; border-radius: 4px; padding: 2px 5px; }
    a { color: #155c9c; }
    details { border: 1px solid #d8dee6; border-radius: 8px; padding: 10px 12px; margin: 8px 0; background: #fbfcfe; }
    @media (max-width: 720px) { .stats { grid-template-columns: 1fr; } h1 { font-size: 24px; } }
    """
  end

  defp h(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
```

- [ ] **Step 4: Run tests to verify pass**

Run:

```powershell
cd elixir
mix test test/symphony_elixir/workflow_report_spike_test.exs
```

Expected: PASS for 7 tests.

- [ ] **Step 5: Commit renderer**

Run:

```powershell
git add -- elixir/lib/symphony_elixir/workflow/report_spike/renderer.ex elixir/test/symphony_elixir/workflow_report_spike_test.exs
git commit -m "feat(report): render readability spike reports"
```

Expected: commit only includes renderer and test changes.

---

### Task 5: Add Rule-Based Readability Quality Checks

**Files:**
- Create: `elixir/lib/symphony_elixir/workflow/report_spike/quality.ex`
- Modify: `elixir/test/symphony_elixir/workflow_report_spike_test.exs`

- [ ] **Step 1: Add failing quality tests**

Append this `describe` block to `elixir/test/symphony_elixir/workflow_report_spike_test.exs`:

```elixir
  describe "Quality.check/3" do
    alias SymphonyElixir.Workflow.ReportSpike.{Brief, Quality, Renderer}

    test "passes a report with summary, attention section, evidence, and collapsed raw artifacts" do
      {:ok, context} = Context.load(Path.join(@fixtures, "workflow_rework_context.json"))
      {:ok, brief} = Brief.build(context)
      {:ok, rendered} = Renderer.render(context, brief)

      assert {:ok, quality} = Quality.check(context, brief, rendered)
      assert quality["status"] == "pass"
      assert quality["checks"]["has_first_screen_summary"] == true
      assert quality["checks"]["has_exception_section"] == true
      assert quality["checks"]["has_evidence_index"] == true
    end

    test "returns draft quality when attention section is missing" do
      {:ok, context} = Context.load(Path.join(@fixtures, "workflow_rework_context.json"))
      {:ok, brief} = Brief.build(context)
      {:ok, rendered} = Renderer.render(context, brief)
      broken = %{rendered | html: String.replace(rendered.html, ~s(id="attention"), ~s(id="attention-missing"))}

      assert {:error, quality} = Quality.check(context, brief, broken)
      assert quality["status"] == "draft"
      assert "has_exception_section" in quality["failed_checks"]
    end
  end
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```powershell
cd elixir
mix test test/symphony_elixir/workflow_report_spike_test.exs
```

Expected: FAIL with an error that `SymphonyElixir.Workflow.ReportSpike.Quality` is not available.

- [ ] **Step 3: Implement quality checker**

Create `elixir/lib/symphony_elixir/workflow/report_spike/quality.ex`:

```elixir
defmodule SymphonyElixir.Workflow.ReportSpike.Quality do
  @moduledoc """
  针对 spike 报告运行规则化可读性下限检查。
  """

  alias SymphonyElixir.Workflow.ReportSpike.Context

  @spec check(map(), map(), %{html: String.t(), summary: String.t()}) :: {:ok, map()} | {:error, map()}
  def check(%{"work_items" => work_items}, brief, %{html: html, summary: summary})
      when is_list(work_items) and is_map(brief) and is_binary(html) and is_binary(summary) do
    checks = %{
      "has_first_screen_summary" => String.contains?(html, ~s(id="top-summary")),
      "has_exception_section" => exception_section_ok?(work_items, html),
      "has_evidence_index" => String.contains?(html, ~s(id="evidence")),
      "has_next_actions" => has_next_actions?(brief, html),
      "raw_logs_are_collapsed" => raw_materials_collapsed?(html),
      "linear_summary_is_short" => String.length(summary) < 2_000,
      "has_no_external_resources" => no_external_resources?(html)
    }

    failed =
      checks
      |> Enum.reject(fn {_name, passed?} -> passed? end)
      |> Enum.map(fn {name, _passed?} -> name end)

    quality = %{
      "status" => if(failed == [], do: "pass", else: "draft"),
      "score" => score(checks),
      "checks" => checks,
      "failed_checks" => failed
    }

    if failed == [], do: {:ok, quality}, else: {:error, quality}
  end

  def check(_context, _brief, _rendered) do
    {:error,
     %{
       "status" => "draft",
       "score" => 0.0,
       "checks" => %{},
       "failed_checks" => ["invalid_quality_input"]
     }}
  end

  defp exception_section_ok?(work_items, html) do
    if Enum.any?(work_items, &Context.attention_item?/1) do
      String.contains?(html, ~s(id="attention"))
    else
      true
    end
  end

  defp has_next_actions?(%{"sections" => sections}, html) when is_list(sections) do
    ("后续动作" in sections and String.contains?(html, "后续")) or
      ("风险和后续" in sections and String.contains?(html, ~s(id="risks"))) or
      "后续动作" not in sections
  end

  defp has_next_actions?(_brief, _html), do: false

  defp raw_materials_collapsed?(html) do
    not String.contains?(html, "validation.log") or String.contains?(html, "<details")
  end

  defp no_external_resources?(html) do
    not String.contains?(html, "<script src=") and not String.contains?(html, "<link href=")
  end

  defp score(checks) do
    total = map_size(checks)
    passed = checks |> Map.values() |> Enum.count(& &1)
    Float.round(passed / total, 2)
  end
end
```

- [ ] **Step 4: Run tests to verify pass**

Run:

```powershell
cd elixir
mix test test/symphony_elixir/workflow_report_spike_test.exs
```

Expected: PASS for 9 tests.

- [ ] **Step 5: Commit quality checker**

Run:

```powershell
git add -- elixir/lib/symphony_elixir/workflow/report_spike/quality.ex elixir/test/symphony_elixir/workflow_report_spike_test.exs
git commit -m "feat(report): check spike report readability"
```

Expected: commit only includes quality checker and test changes.

---

### Task 6: Write Spike Artifacts To Disk

**Files:**
- Create: `elixir/lib/symphony_elixir/workflow/report_spike/runner.ex`
- Modify: `elixir/test/symphony_elixir/workflow_report_spike_test.exs`

- [ ] **Step 1: Add failing runner test**

Append this `describe` block to `elixir/test/symphony_elixir/workflow_report_spike_test.exs`:

```elixir
  describe "Runner.run/2" do
    alias SymphonyElixir.Workflow.ReportSpike.Runner

    test "writes all reviewable spike artifacts" do
      context_path = Path.join(@fixtures, "workflow_rework_context.json")
      output_dir = Path.join(System.tmp_dir!(), "symphony-report-spike-#{System.unique_integer([:positive])}")

      try do
        assert {:ok, manifest} = Runner.run(context_path, output_dir)
        assert manifest["quality"]["status"] == "pass"
        assert File.exists?(Path.join(output_dir, "report_context.json"))
        assert File.exists?(Path.join(output_dir, "report_brief.json"))
        assert File.exists?(Path.join(output_dir, "index.html"))
        assert File.exists?(Path.join(output_dir, "summary.md"))
        assert File.exists?(Path.join(output_dir, "manifest.json"))
        assert File.exists?(Path.join(output_dir, "review.md"))
      after
        File.rm_rf!(output_dir)
      end
    end
  end
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```powershell
cd elixir
mix test test/symphony_elixir/workflow_report_spike_test.exs
```

Expected: FAIL with an error that `SymphonyElixir.Workflow.ReportSpike.Runner` is not available.

- [ ] **Step 3: Implement runner**

Create `elixir/lib/symphony_elixir/workflow/report_spike/runner.ex`:

```elixir
defmodule SymphonyElixir.Workflow.ReportSpike.Runner do
  @moduledoc """
  生成可人工审阅的本地汇报 spike artifact。
  """

  alias SymphonyElixir.Workflow.ReportSpike.{Brief, Context, Quality, Renderer}

  @spec run(Path.t(), Path.t()) :: {:ok, map()} | {:error, term()}
  def run(context_path, output_dir) when is_binary(context_path) and is_binary(output_dir) do
    with {:ok, context} <- Context.load(context_path),
         {:ok, brief} <- Brief.build(context),
         {:ok, rendered} <- Renderer.render(context, brief) do
      quality_result = Quality.check(context, brief, rendered)
      quality = quality_payload(quality_result)
      manifest = manifest(context, quality)

      File.mkdir_p!(output_dir)
      write_json!(Path.join(output_dir, "report_context.json"), context)
      write_json!(Path.join(output_dir, "report_brief.json"), brief)
      File.write!(Path.join(output_dir, "index.html"), rendered.html)
      File.write!(Path.join(output_dir, "summary.md"), rendered.summary)
      write_json!(Path.join(output_dir, "manifest.json"), manifest)
      File.write!(Path.join(output_dir, "review.md"), review_template(context))

      {:ok, manifest}
    end
  end

  defp quality_payload({:ok, quality}), do: quality
  defp quality_payload({:error, quality}), do: quality

  defp manifest(%{"subject" => subject}, quality) do
    %{
      "schema_version" => 1,
      "report_id" => subject["id"],
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "generator" => "report-readability-spike",
      "html_path" => "index.html",
      "markdown_path" => "summary.md",
      "brief_path" => "report_brief.json",
      "review_path" => "review.md",
      "quality" => quality
    }
  end

  defp write_json!(path, value) do
    File.write!(path, Jason.encode_to_iodata!(value, pretty: true))
  end

  defp review_template(%{"subject" => subject}) do
    """
    # 汇报可读性审阅

    样例：#{subject["id"]}
    审阅人：<name>
    结论：pass / fail

    ## 快速判断
    - 1 到 3 分钟内能否判断整体状态：是 / 否
    - 是否清楚知道需要关注什么：是 / 否
    - 是否清楚知道证据在哪里：是 / 否
    - 是否愿意把它作为默认汇报入口：是 / 否

    ## 评分
    - 首屏判断价值：1-5
    - 结论清晰度：1-5
    - 异常呈现：1-5
    - 证据可追踪性：1-5
    - 信息密度：1-5
    - 视觉和排版：1-5

    ## 必须修改
    - 无阻断项时填写“无”；否则逐条列出必须修改的问题。

    ## 可以后续优化
    - 无建议时填写“无”；否则逐条列出非阻断优化建议。
    """
  end
end
```

- [ ] **Step 4: Run tests to verify pass**

Run:

```powershell
cd elixir
mix test test/symphony_elixir/workflow_report_spike_test.exs
```

Expected: PASS for 10 tests.

- [ ] **Step 5: Commit runner**

Run:

```powershell
git add -- elixir/lib/symphony_elixir/workflow/report_spike/runner.ex elixir/test/symphony_elixir/workflow_report_spike_test.exs
git commit -m "feat(report): write readability spike artifacts"
```

Expected: commit only includes runner and test changes.

---

### Task 7: Add A Mix Task For Generating Local Samples

**Files:**
- Create: `elixir/lib/mix/tasks/symphony.report_spike.generate.ex`
- Modify: `elixir/test/symphony_elixir/workflow_report_spike_test.exs`

- [ ] **Step 1: Add failing Mix task test**

Append this `describe` block to `elixir/test/symphony_elixir/workflow_report_spike_test.exs`:

```elixir
  describe "Mix.Tasks.Symphony.ReportSpike.Generate" do
    test "generates a report from command arguments" do
      Mix.Task.clear()
      context_path = Path.join(@fixtures, "feature_success_context.json")
      output_dir = Path.join(System.tmp_dir!(), "symphony-report-spike-task-#{System.unique_integer([:positive])}")

      try do
        Mix.Tasks.Symphony.ReportSpike.Generate.run(["--context", context_path, "--out", output_dir])

        assert File.exists?(Path.join(output_dir, "index.html"))
        assert File.exists?(Path.join(output_dir, "review.md"))
      after
        File.rm_rf!(output_dir)
      end
    end
  end
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```powershell
cd elixir
mix test test/symphony_elixir/workflow_report_spike_test.exs
```

Expected: FAIL with an error that `Mix.Tasks.Symphony.ReportSpike.Generate` is not available.

- [ ] **Step 3: Implement Mix task**

Create `elixir/lib/mix/tasks/symphony.report_spike.generate.ex`:

```elixir
defmodule Mix.Tasks.Symphony.ReportSpike.Generate do
  @moduledoc """
  Generates a local engineering HTML report readability spike sample.
  """

  use Mix.Task

  alias SymphonyElixir.Workflow.ReportSpike.Runner

  @shortdoc "Generate a local report readability spike sample"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, invalid} =
      OptionParser.parse(args,
        strict: [context: :string, out: :string],
        aliases: [c: :context, o: :out]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    context_path = Keyword.get(opts, :context) || Mix.raise("Missing --context")
    output_dir = Keyword.get(opts, :out) || default_output_dir(context_path)

    case Runner.run(context_path, output_dir) do
      {:ok, manifest} ->
        Mix.shell().info("Generated report spike: #{Path.expand(output_dir)}")
        Mix.shell().info("Quality status: #{manifest["quality"]["status"]}")

      {:error, reason} ->
        Mix.raise("Failed to generate report spike: #{inspect(reason)}")
    end
  end

  defp default_output_dir(context_path) do
    sample_id =
      context_path
      |> Path.basename(".json")
      |> String.replace("_context", "")
      |> String.replace("_", "-")

    Path.join(["..", ".symphony", "report-spikes", sample_id])
  end
end
```

- [ ] **Step 4: Run tests to verify pass**

Run:

```powershell
cd elixir
mix test test/symphony_elixir/workflow_report_spike_test.exs
```

Expected: PASS for 11 tests.

- [ ] **Step 5: Commit Mix task**

Run:

```powershell
git add -- elixir/lib/mix/tasks/symphony.report_spike.generate.ex elixir/test/symphony_elixir/workflow_report_spike_test.exs
git commit -m "feat(report): add readability spike generator task"
```

Expected: commit only includes Mix task and test changes.

---

### Task 8: Generate Reviewable Local Samples

**Files:**
- Runtime output: `.symphony/report-spikes/feature-success/`
- Runtime output: `.symphony/report-spikes/workflow-success/`
- Runtime output: `.symphony/report-spikes/workflow-rework/`

- [ ] **Step 1: Run full targeted tests**

Run:

```powershell
cd elixir
mix test test/symphony_elixir/workflow_report_spike_test.exs
```

Expected: PASS for 11 tests.

- [ ] **Step 2: Generate the feature success sample**

Run:

```powershell
cd elixir
mix symphony.report_spike.generate --context test/fixtures/report_spikes/feature_success_context.json --out ../.symphony/report-spikes/feature-success
```

Expected output contains:

```text
Generated report spike:
Quality status: pass
```

Expected files:

```text
.symphony/report-spikes/feature-success/index.html
.symphony/report-spikes/feature-success/summary.md
.symphony/report-spikes/feature-success/review.md
.symphony/report-spikes/feature-success/manifest.json
```

- [ ] **Step 3: Generate the workflow success sample**

Run:

```powershell
cd elixir
mix symphony.report_spike.generate --context test/fixtures/report_spikes/workflow_success_context.json --out ../.symphony/report-spikes/workflow-success
```

Expected output contains:

```text
Generated report spike:
Quality status: pass
```

- [ ] **Step 4: Generate the workflow rework sample**

Run:

```powershell
cd elixir
mix symphony.report_spike.generate --context test/fixtures/report_spikes/workflow_rework_context.json --out ../.symphony/report-spikes/workflow-rework
```

Expected output contains:

```text
Generated report spike:
Quality status: pass
```

- [ ] **Step 5: Inspect the generated manifest statuses**

Run:

```powershell
Get-Content -Raw -Encoding UTF8 .symphony\report-spikes\feature-success\manifest.json
Get-Content -Raw -Encoding UTF8 .symphony\report-spikes\workflow-success\manifest.json
Get-Content -Raw -Encoding UTF8 .symphony\report-spikes\workflow-rework\manifest.json
```

Expected: every manifest contains `"status": "pass"` under `"quality"`.

- [ ] **Step 6: Report local HTML paths for human review**

In the final implementation response, include these paths:

```text
C:\Users\GQY47\coding\Symphony\.symphony\report-spikes\feature-success\index.html
C:\Users\GQY47\coding\Symphony\.symphony\report-spikes\workflow-success\index.html
C:\Users\GQY47\coding\Symphony\.symphony\report-spikes\workflow-rework\index.html
```

Do not claim the report system is validated until the user reviews these HTML files and says at least two samples are acceptable, including the rework-heavy sample.

- [ ] **Step 7: Commit generated-code state only**

If all code and fixtures are already committed from previous tasks, do not commit `.symphony/report-spikes/` outputs unless the user explicitly asks to keep sample artifacts in git. Generated local samples are review artifacts, not source code.

Run:

```powershell
git status --short --branch
```

Expected: no staged changes. Untracked `.symphony/report-spikes/` may exist for local review.

---

## Plan Self-Review

Spec coverage:

1. Real or half-real facts are covered by three fixture contexts.
2. Reviewable HTML samples are covered by Renderer and Runner.
3. Human review is covered by generated `review.md` and final handoff paths.
4. Rule-based checks are covered by `ReportSpike.Quality`.
5. Later Linear, publish, dashboard, and productization work is explicitly blocked until sample review.

Placeholder scan:

1. The plan avoids forbidden placeholder markers and unspecified implementation steps.
2. Template markers use concrete field labels such as `<name>` and `<sample-id>` only inside generated review forms.

Type consistency:

1. `Context.load/1`, `Brief.build/1`, `Renderer.render/2`, `Quality.check/3`, and `Runner.run/2` are introduced before use.
2. `quality["status"]` is consistently `pass` or `draft`.
3. Output files match the design: `report_context.json`, `report_brief.json`, `index.html`, `summary.md`, `manifest.json`, and `review.md`.
