defmodule SymphonyElixir.WorkflowArtifactsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Workflow.Artifacts
  alias SymphonyElixir.Workflow.Registry

  test "workflow artifact path uses orchestration artifact_dir" do
    workspace = Path.join(System.tmp_dir!(), "workspace-a")

    assert Artifacts.workflow_plan_path(workspace) == Path.join(workspace, ".symphony/workflow_plan.json")
    assert Artifacts.completion_packet_path(workspace) == Path.join(workspace, ".symphony/completion_packet.json")
    assert Artifacts.review_decision_path(workspace) == Path.join(workspace, ".symphony/review_decision.json")
  end

  test "validate_plan accepts direct execution and issue graph" do
    assert :ok == Artifacts.validate_plan(%{"mode" => "direct_execution"})

    assert :ok ==
             Artifacts.validate_plan(%{
               "mode" => "issue_graph",
               "summary" => "s",
               "confidence" => 1,
               "nodes" => [
                 %{
                   "node_key" => "n1",
                   "task_type" => "task",
                   "title" => "t",
                   "goal" => "g",
                   "agent_id" => "codex"
                 }
               ],
               "edges" => []
             })
  end

  test "validate_completion_packet requires outcome summary and evidence" do
    assert :ok ==
             Artifacts.validate_completion_packet(%{
               "outcome" => "done",
               "summary" => "完成",
               "evidence" => []
             })

    assert {:error, _reason} = Artifacts.validate_completion_packet(%{})
  end

  test "load artifacts returns error for missing file and invalid json" do
    workspace = Path.join(System.tmp_dir!(), "workflow-artifacts-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    assert {:error, _reason} = Artifacts.load_plan(workspace)

    File.write!(Artifacts.completion_packet_path(workspace), "{invalid")
    assert {:error, _reason} = Artifacts.load_completion_packet(workspace)

    File.rm_rf!(workspace)
  end

  test "validate_review_decision requires decision summary and confidence" do
    assert :ok ==
             Artifacts.validate_review_decision(%{
               "decision" => "pass",
               "summary" => "通过",
               "confidence" => "high"
             })

    assert {:error, _reason} = Artifacts.validate_review_decision(%{"decision" => "pass"})
  end

  test "registry persists nodes by issue id" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", title: "根问题", state: "Todo"}
    registry = Registry.new_root(issue)
    registry = Registry.put_node(registry, "child-1", %{issue_id: "issue-2", title: "子任务"})
    registry = Registry.add_edge(registry, {"root", "child-1"})

    assert Registry.node(registry, "child-1")
    assert Registry.node_by_issue_id(registry, "issue-2")

    assert {:ok, path} = Registry.save!(registry)
    assert String.ends_with?(path, ".symphony/workflows/MT-1.json")

    assert {:ok, loaded} = Registry.load_by_root_identifier("MT-1")
    assert Registry.node(loaded, "child-1")
    assert Registry.node_by_issue_id(loaded, "issue-2")
  end
end
