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
          "Completion Packet",
          "Review Decision",
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

  test "phase prompts document orchestration artifact contracts" do
    write_workflow_file!(Workflow.workflow_file_path(),
      orchestration: %{enabled: true, artifact_dir: ".symphony"}
    )

    workspace = "/tmp/symphony-contract-workspace"

    planning = Prompts.append("Base prompt", :planning, %{}, workspace)
    execution = Prompts.append("Base prompt", :execution, %{}, workspace)
    review = Prompts.append("Base prompt", :review, %{}, workspace)

    for text <- [
          "workflow_plan.json",
          "direct_execution",
          "issue_graph",
          "needs_human_input",
          "控制层"
        ] do
      assert planning =~ text
    end

    for text <- [
          "completion_packet.json",
          "必须包含所有字段",
          "outcome",
          "failed",
          "summary",
          "evidence",
          "非空",
          "decisions",
          "open_questions",
          "next_handoff"
        ] do
      assert execution =~ text
    end

    for text <- [
          "review_decision.json",
          "pass",
          "needs_rework",
          "needs_replan",
          "needs_human",
          "fail",
          "evidence",
          "reason",
          "requested_input"
        ] do
      assert review =~ text
    end
  end
end
