defmodule SymphonyElixir.WorkflowPromptContractTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Workflow.Prompts

  test "in-repo WORKFLOW.md documents orchestration artifact source of truth contract" do
    workflow = File.read!(Path.expand("../../WORKFLOW.md", __DIR__))

    for text <- [
          "orchestration:",
          "enabled: true",
          "routing:",
          "default_agent: mimocode",
          "agents:",
          "agents.<id>",
          "Workflow registry",
          "issue_result.json",
          "review issues",
          "artifact",
          "source of truth"
        ] do
      assert workflow =~ text
    end

    for old_text <- [
          "Treat a single persistent Linear comment as the source of truth",
          "single persistent scratchpad comment",
          "Use exactly one persistent workpad comment",
          "\ncodex:"
        ] do
      refute workflow =~ old_text
    end
  end

  test "in-repo workflow files keep agent overrides under agents" do
    workflow = File.read!(Path.expand("../../WORKFLOW.md", __DIR__))
    local_workflow = File.read!(Path.expand("../../WORKFLOW.local.md", __DIR__))

    refute workflow =~ "\ncodex:"
    refute local_workflow =~ "\ncodex:"

    assert local_workflow =~ "\nagents:"
    assert local_workflow =~ "  codex:"
    assert local_workflow =~ "  mimocode:"
  end

  test "in-repo workflow files start MiMo ACP with the supported command shape" do
    for path <- ["../../WORKFLOW.md", "../../WORKFLOW.local.md"] do
      workflow = File.read!(Path.expand(path, __DIR__))
      front_matter = workflow_front_matter(workflow)
      args = get_in(front_matter, ["agents", "mimocode", "args"])

      assert args == ["acp", "--cwd", "{{workspace}}", "--pure"]
      refute "--agent" in args
      refute Enum.chunk_every(args, 2, 1, :discard) |> Enum.any?(&(&1 == ["--agent", "compose"]))
    end
  end

  test "phase prompts document orchestration artifact contracts" do
    write_workflow_file!(Workflow.workflow_file_path(),
      orchestration: %{enabled: true, artifact_dir: ".symphony"}
    )

    workspace = "/tmp/symphony-contract-workspace"

    planning = Prompts.append("Base prompt", :planning, %{}, workspace)

    issue =
      Prompts.append(
        "Base prompt",
        :issue,
        %{"node_key" => "implementation", "task_type" => "implementation"},
        workspace
      )

    review_issue =
      Prompts.append(
        "Base prompt",
        :issue,
        %{
          "node_key" => "implementation_review",
          "task_type" => "review",
          "reviews" => ["implementation"],
          "subject_selector" => %{"type" => "candidate_range"}
        },
        workspace
      )

    for text <- [
          "workflow_plan.json",
          "direct_execution",
          "issue_graph",
          "needs_human_input",
          "业务编排策略",
          "先判断任务形态，再选择最小可靠 workflow",
          "单点、低风险、验收清楚",
          "原因、现状、影响范围不清楚",
          "存在方案选择或跨模块设计",
          "多个子任务可独立完成且文件或模块边界清楚",
          "高风险实现、核心行为、数据、权限、调度或安全相关改动",
          "大型或低置信度任务",
          "下游需要已认可结果时必须依赖 review node",
          "优先少拆 issue，但不能跨越风险边界",
          "框架合规要求",
          "review 是普通 issue node，不是隐藏 phase",
          "planner 不要填写 Git branch、sha、checkpoint 或 diff range",
          "每个 node 必须有明确交付物、证据预期和完成条件",
          "控制层",
          "只允许创建或更新 planning artifact",
          "不要修改源码、测试、文档或其他业务文件",
          "不要执行 direct_execution 的实现内容",
          "不要修改当前 Linear issue 状态",
          "写入并读回 `workflow_plan.json` 后立即结束"
        ] do
      assert planning =~ text
    end

    for text <- [
          "issue_result.json",
          "必须包含所有字段",
          "schema_version",
          "node_key",
          "task_type",
          "outcome",
          "completed",
          "summary",
          "evidence",
          "非空",
          "decisions",
          "open_questions",
          "不要通过移动当前 Linear issue 状态",
          "写入并读回 `issue_result.json` 后立即结束"
        ] do
      assert issue =~ text
    end

    for text <- [
          "issue_result.json",
          "pass",
          "needs_rework",
          "needs_replan",
          "needs_human",
          "fail",
          "evidence",
          "summary",
          "reason",
          "requested_input",
          "不要通过移动当前 Linear issue 状态",
          "不要执行 `git add`",
          "不要 stage",
          "不要 commit",
          "不要 push",
          "不要创建 PR",
          "写入并读回 `issue_result.json` 后立即结束"
        ] do
      assert review_issue =~ text
    end
  end

  test "active workflow code no longer exposes retired workflow phase artifact repair paths" do
    root = Path.expand("../..", __DIR__)

    active_sources =
      [
        "lib/symphony_elixir/agent_runner.ex",
        "lib/symphony_elixir/orchestrator.ex"
      ]
      |> Enum.map(&File.read!(Path.join(root, &1)))
      |> Enum.join("\n")

    retired_execution = "exec" <> "ution"
    retired_review = "rev" <> "iew"

    for forbidden <- [
          "workflow_artifact_repair_prompt(:" <> retired_execution,
          "workflow_artifact_repair_prompt(:" <> retired_review,
          "phase_label(:" <> retired_execution,
          "phase_label(:" <> retired_review,
          "phase in [:" <> retired_execution <> ", :issue]"
        ] do
      refute active_sources =~ forbidden
    end
  end

  defp workflow_front_matter(contents) do
    case String.split(contents, "---", parts: 3) do
      [_prefix, front_matter, _body] -> YamlElixir.read_from_string!(front_matter)
      _other -> flunk("workflow file must contain YAML front matter")
    end
  end
end
