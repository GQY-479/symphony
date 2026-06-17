defmodule SymphonyElixir.WorkflowOrchestratorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Workflow.Controller
  alias SymphonyElixir.Workflow.Registry

  test "root issue 在编排开启且没有 registry 时进入 planning dispatch" do
    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-orchestrator-root-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      agents: %{
        codex: %{kind: "codex_app_server", command: "codex app-server"},
        mimocode: %{kind: "cli_run", command: "mimo"}
      },
      routing: %{default_agent: "mimocode"},
      orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
    )

    issue = %Issue{
      id: "root-1",
      identifier: "YQE-700",
      title: "需要规划的 root issue",
      state: "In Progress",
      url: "https://linear.app/yqeeqy/issue/YQE-700"
    }

    state = workflow_state()

    assert {:dispatch, metadata} = Orchestrator.workflow_dispatch_decision_for_test(issue, state)
    assert metadata.workflow_phase == :planning
    assert metadata.agent_id == "codex"
    assert metadata.workflow_root_issue_id == "YQE-700"
    assert metadata.max_turns == 1
  end

  test "derived issue 只有 ready 时才进入 execution dispatch" do
    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-orchestrator-derived-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      agents: %{
        codex: %{kind: "codex_app_server", command: "codex app-server"},
        mimocode: %{kind: "cli_run", command: "mimo"}
      },
      routing: %{default_agent: "codex"},
      orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
    )

    root_issue = %Issue{
      id: "root-2",
      identifier: "YQE-701",
      title: "已规划 root issue",
      state: "In Progress"
    }

    ready_issue = %Issue{
      id: "derived-ready",
      identifier: "YQE-702",
      title: "调研任务",
      state: "Todo",
      url: "https://linear.app/yqeeqy/issue/YQE-702"
    }

    waiting_issue = %Issue{
      id: "derived-waiting",
      identifier: "YQE-703",
      title: "实现任务",
      state: "Todo",
      url: "https://linear.app/yqeeqy/issue/YQE-703"
    }

    root_issue
    |> Registry.new_root()
    |> Registry.put_node("research", %{
      "node_key" => "research",
      "issue_id" => ready_issue.id,
      "issue_identifier" => ready_issue.identifier,
      "agent_id" => "mimocode",
      "task_type" => "research",
      "status" => "ready",
      "dependencies" => []
    })
    |> Registry.put_node("implementation", %{
      "node_key" => "implementation",
      "issue_id" => waiting_issue.id,
      "issue_identifier" => waiting_issue.identifier,
      "agent_id" => "codex",
      "task_type" => "implementation",
      "status" => "waiting",
      "dependencies" => ["research"]
    })
    |> Registry.add_edge(%{"from" => "research", "to" => "implementation"})
    |> Map.put("status", "planning_complete")
    |> Registry.save!()

    state = workflow_state()

    assert Controller.issue_ready?(ready_issue.id)
    refute Controller.issue_ready?(waiting_issue.id)

    assert {:dispatch, ready_metadata} = Orchestrator.workflow_dispatch_decision_for_test(ready_issue, state)
    assert ready_metadata.workflow_phase == :execution
    assert ready_metadata.agent_id == "mimocode"
    assert ready_metadata.workflow_root_issue_id == "YQE-701"
    assert ready_metadata.workflow_context["node_key"] == "research"

    assert {:block, waiting_metadata} = Orchestrator.workflow_dispatch_decision_for_test(waiting_issue, state)
    assert waiting_metadata.workflow_phase == :execution
    assert waiting_metadata.workflow_root_issue_id == "YQE-701"
    assert waiting_metadata.error =~ "workflow waiting on dependencies"
  end

  defp workflow_state do
    %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      blocked: %{},
      retry_attempts: %{},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }
  end
end
