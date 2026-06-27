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

  test "in-repo workflow and local overlay example keep agent overrides under agents" do
    workflow = File.read!(Path.expand("../../WORKFLOW.md", __DIR__))
    local_overlay = File.read!(Path.expand("../../WORKFLOW.local.example.yml", __DIR__))

    refute workflow =~ "\ncodex:"
    refute local_overlay =~ "\ncodex:"

    assert local_overlay =~ "\nagents:"
    assert local_overlay =~ "  codex:"
    assert local_overlay =~ "  mimocode:"
  end

  test "in-repo WORKFLOW.md starts MiMo ACP with the supported command shape" do
    workflow = File.read!(Path.expand("../../WORKFLOW.md", __DIR__))
    front_matter = workflow_front_matter(workflow)
    args = get_in(front_matter, ["agents", "mimocode", "args"])

    assert args == ["acp", "--cwd", "{{workspace}}", "--pure"]
    refute "--agent" in args
    refute Enum.chunk_every(args, 2, 1, :discard) |> Enum.any?(&(&1 == ["--agent", "compose"]))
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
          "issue_graph",
          "needs_human_input",
          "业务编排策略",
          "管理不确定性、依赖、风险、证据和验证闭环",
          "所有可执行工作都使用 `issue_graph`",
          "原因、现状、影响范围不清楚",
          "存在方案选择、接口契约、数据模型",
          "多个子任务目标独立",
          "高风险实现、核心行为、数据、权限、调度或安全相关改动",
          "大型或低置信度任务",
          "下游需要已认可结果时必须依赖 review node",
          "每个 node 和每条 edge 都必须有明确编排理由",
          "框架合规要求",
          "review 是普通 issue node，不是隐藏 phase",
          "planner 不要填写 Git branch、sha、checkpoint 或 diff range",
          "每个 node 必须有明确交付物、证据预期和完成条件",
          "控制层",
          "只允许创建或更新 planning artifact",
          "不要修改源码、测试、文档或其他业务文件",
          "不要修改当前 Linear issue 状态",
          "写入并读回 `workflow_plan.json` 后立即结束"
        ] do
      assert planning =~ text
    end

    retired_kind = "direct" <> "_execution"
    refute planning =~ retired_kind

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
