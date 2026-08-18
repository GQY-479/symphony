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
end
