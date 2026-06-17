defmodule SymphonyElixir.WorkflowSmokeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Workflow.Registry

  @moduletag timeout: 120_000

  test "真实 Orchestrator 通过 artifacts 跑通 planning execution review 闭环" do
    stop_default_orchestrator()

    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-smoke-workspaces-#{System.unique_integer([:positive])}")

    agent_script =
      "import json, os, sys; " <>
        "p=sys.argv[1]; os.makedirs('.symphony', exist_ok=True); " <>
        "phase='plan' if 'workflow_plan.json' in p else ('completion' if 'completion_packet.json' in p else ('review' if 'review_decision.json' in p else '')); " <>
        "payloads={" <>
        "'plan': {'kind': 'issue_graph', 'summary': 'smoke planning created one executable child issue', 'confidence': 'high', 'nodes': [{'node_key': 'implementation', 'task_type': 'implementation', 'title': 'Smoke derived implementation', 'goal': 'Prove the workflow closes through review', 'agent_id': 'codex', 'instructions': 'Write the completion packet for the smoke test.', 'evidence_expectations': ['completion packet exists']}], 'edges': []}, " <>
        "'completion': {'outcome': 'completed', 'summary': 'smoke execution completed', 'evidence': ['fake cli wrote completion_packet.json'], 'decisions': ['use artifact handoff'], 'open_questions': [], 'next_handoff': 'review the smoke completion'}, " <>
        "'review': {'decision': 'pass', 'summary': 'smoke review passed', 'confidence': 'high'}}; " <>
        "paths={'plan': '.symphony/workflow_plan.json', 'completion': '.symphony/completion_packet.json', 'review': '.symphony/review_decision.json'}; " <>
        "phase or sys.exit(2); open(paths[phase], 'w', encoding='utf-8').write(json.dumps(payloads[phase]))"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done", "Closed", "Cancelled", "Canceled", "Duplicate"],
      poll_interval_ms: 50,
      workspace_root: workspace_root,
      workspace_preserve_terminal: true,
      max_concurrent_agents: 3,
      max_turns: 1,
      agents: %{
        codex: %{
          kind: "cli_run",
          command: "/usr/bin/env",
          args: ["python3", "-c", agent_script],
          timeout_ms: 10_000
        }
      },
      routing: %{default_agent: "codex"},
      orchestration: %{
        enabled: true,
        planner_agent: "codex",
        reviewer_agent: "codex",
        artifact_dir: ".symphony",
        planning_max_turns: 1,
        review_max_turns: 1
      },
      prompt: "Smoke issue {{ issue.identifier }} {{ issue.title }}"
    )

    root_issue = %Issue{
      id: "workflow-smoke-root",
      identifier: "SMOKE-1",
      title: "Smoke root issue",
      state: "In Progress",
      url: "https://linear.app/example/issue/SMOKE-1"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [root_issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    orchestrator_name = Module.concat(__MODULE__, :SmokeOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      restart_default_orchestrator()
      File.rm_rf(workspace_root)
    end)

    unless eventually?(fn ->
             issues = Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
             root = Enum.find(issues, &(&1.id == root_issue.id))
             derived = Enum.find(issues, &(&1.id != root_issue.id))

             root && derived && root.state == "Done" && derived.state == "Done" &&
               orchestrator_idle?(orchestrator_name)
           end) do
      flunk("""
      workflow smoke did not close

      issues:
      #{inspect(Application.get_env(:symphony_elixir, :memory_tracker_issues, []), pretty: true)}

      registry:
      #{inspect(Registry.load_by_root_identifier(root_issue.identifier), pretty: true)}

      snapshot:
      #{inspect(Orchestrator.snapshot(orchestrator_name, 1_000), pretty: true)}

      artifacts:
      #{inspect(Path.wildcard(Path.join([workspace_root, "**", ".symphony", "*.json"])), pretty: true)}
      """)
    end

    assert {:ok, registry} = Registry.load_by_root_identifier(root_issue.identifier)
    assert registry["status"] == "completed"
    assert Registry.node(registry, "implementation")["status"] == "completed"

    snapshot = Orchestrator.snapshot(orchestrator_name, 1_000)
    assert snapshot.running == []
    assert snapshot.retrying == []
    assert snapshot.blocked == []
  end

  test "真实 Orchestrator 通过 needs_rework 创建返工 issue 并完成闭环" do
    stop_default_orchestrator()

    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-smoke-rework-workspaces-#{System.unique_integer([:positive])}")

    agent_script =
      "import json, os, sys; " <>
        "p=sys.argv[1]; os.makedirs('.symphony', exist_ok=True); " <>
        "phase='plan' if 'workflow_plan.json' in p else ('completion' if 'completion_packet.json' in p else ('review' if 'review_decision.json' in p else '')); " <>
        "decision='pass' if '返工' in p else 'needs_rework'; " <>
        "payloads={" <>
        "'plan': {'kind':'issue_graph','summary':'smoke planning created rework candidate','confidence':'high','nodes':[{'node_key':'implementation','task_type':'implementation','title':'Smoke rework implementation','goal':'Produce a packet that first review rejects','agent_id':'codex','instructions':'Write completion packet for rework smoke.','evidence_expectations':['completion packet exists']}],'edges':[]}, " <>
        "'completion': {'outcome':'completed','summary':'smoke execution completed for '+p[:80],'evidence':['fake cli wrote completion_packet.json'],'decisions':['use artifact handoff'],'open_questions':[],'next_handoff':'review the smoke completion'}, " <>
        "'review': {'decision':decision,'summary':'smoke rework passed' if decision=='pass' else 'smoke review requested rework','confidence':'high'}}; " <>
        "paths={'plan':'.symphony/workflow_plan.json','completion':'.symphony/completion_packet.json','review':'.symphony/review_decision.json'}; " <>
        "phase or sys.exit(2); open(paths[phase], 'w', encoding='utf-8').write(json.dumps(payloads[phase]))"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done", "Closed", "Cancelled", "Canceled", "Duplicate"],
      poll_interval_ms: 50,
      workspace_root: workspace_root,
      workspace_preserve_terminal: true,
      max_concurrent_agents: 3,
      max_turns: 1,
      agents: %{
        codex: %{
          kind: "cli_run",
          command: "/usr/bin/env",
          args: ["python3", "-c", agent_script],
          timeout_ms: 10_000
        }
      },
      routing: %{default_agent: "codex"},
      orchestration: %{
        enabled: true,
        planner_agent: "codex",
        reviewer_agent: "codex",
        artifact_dir: ".symphony",
        planning_max_turns: 1,
        review_max_turns: 1
      },
      prompt: "Smoke issue {{ issue.identifier }} {{ issue.title }}"
    )

    root_issue = %Issue{
      id: "workflow-smoke-rework-root",
      identifier: "SMOKE-REWORK-1",
      title: "Smoke rework root issue",
      state: "In Progress",
      url: "https://linear.app/example/issue/SMOKE-REWORK-1"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [root_issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    orchestrator_name = Module.concat(__MODULE__, :SmokeReworkOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      restart_default_orchestrator()
      File.rm_rf(workspace_root)
    end)

    unless eventually?(fn ->
             issues = Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
             root = Enum.find(issues, &(&1.id == root_issue.id))
             derived = Enum.reject(issues, &(&1.id == root_issue.id))

             root && root.state == "Done" && length(derived) == 2 &&
               Enum.all?(derived, &(&1.state == "Done")) &&
               orchestrator_idle?(orchestrator_name)
           end) do
      flunk("""
      workflow rework smoke did not close

      issues:
      #{inspect(Application.get_env(:symphony_elixir, :memory_tracker_issues, []), pretty: true)}

      registry:
      #{inspect(Registry.load_by_root_identifier(root_issue.identifier), pretty: true)}

      snapshot:
      #{inspect(Orchestrator.snapshot(orchestrator_name, 1_000), pretty: true)}
      """)
    end

    assert {:ok, registry} = Registry.load_by_root_identifier(root_issue.identifier)
    assert registry["status"] == "completed"
    assert Registry.node(registry, "implementation")["status"] == "superseded"
    assert Registry.node(registry, "implementation-rework-1")["status"] == "completed"
  end

  test "真实 Orchestrator 通过 needs_replan 回到 root planning 并完成新计划" do
    stop_default_orchestrator()

    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-smoke-replan-workspaces-#{System.unique_integer([:positive])}")

    agent_script =
      "import json, os, sys; " <>
        "p=sys.argv[1]; os.makedirs('.symphony', exist_ok=True); " <>
        "phase='plan' if 'workflow_plan.json' in p else ('completion' if 'completion_packet.json' in p else ('review' if 'review_decision.json' in p else '')); " <>
        "replanning='重规划原因' in p; key='implementation-v2' if replanning else 'implementation-v1'; title='Smoke replanned implementation' if replanning else 'Smoke initial implementation'; summary='smoke replanning created replacement issue' if replanning else 'smoke planning created initial issue'; " <>
        "decision='needs_replan' if 'Smoke initial implementation' in p else 'pass'; " <>
        "payloads={" <>
        "'plan': {'kind':'issue_graph','summary':summary,'confidence':'high','nodes':[{'node_key':key,'task_type':'implementation','title':title,'goal':'Prove replan closes through a replacement issue','agent_id':'codex','instructions':'Write completion packet for replan smoke.','evidence_expectations':['completion packet exists']}],'edges':[]}, " <>
        "'completion': {'outcome':'completed','summary':'smoke execution completed for '+p[:80],'evidence':['fake cli wrote completion_packet.json'],'decisions':['use artifact handoff'],'open_questions':[],'next_handoff':'review the smoke completion'}, " <>
        "'review': {'decision':decision,'summary':'smoke review requested replan' if decision=='needs_replan' else 'smoke replanned review passed','confidence':'high'}}; " <>
        "paths={'plan':'.symphony/workflow_plan.json','completion':'.symphony/completion_packet.json','review':'.symphony/review_decision.json'}; " <>
        "phase or sys.exit(2); open(paths[phase], 'w', encoding='utf-8').write(json.dumps(payloads[phase]))"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done", "Closed", "Cancelled", "Canceled", "Duplicate"],
      poll_interval_ms: 50,
      workspace_root: workspace_root,
      workspace_preserve_terminal: true,
      max_concurrent_agents: 3,
      max_turns: 1,
      agents: %{
        codex: %{
          kind: "cli_run",
          command: "/usr/bin/env",
          args: ["python3", "-c", agent_script],
          timeout_ms: 10_000
        }
      },
      routing: %{default_agent: "codex"},
      orchestration: %{
        enabled: true,
        planner_agent: "codex",
        reviewer_agent: "codex",
        artifact_dir: ".symphony",
        planning_max_turns: 1,
        review_max_turns: 1
      },
      prompt: "Smoke issue {{ issue.identifier }} {{ issue.title }}"
    )

    root_issue = %Issue{
      id: "workflow-smoke-replan-root",
      identifier: "SMOKE-REPLAN-1",
      title: "Smoke replan root issue",
      state: "In Progress",
      url: "https://linear.app/example/issue/SMOKE-REPLAN-1"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [root_issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    orchestrator_name = Module.concat(__MODULE__, :SmokeReplanOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      restart_default_orchestrator()
      File.rm_rf(workspace_root)
    end)

    unless eventually?(fn ->
             issues = Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
             root = Enum.find(issues, &(&1.id == root_issue.id))
             derived = Enum.reject(issues, &(&1.id == root_issue.id))

             root && root.state == "Done" && length(derived) == 2 &&
               Enum.all?(derived, &(&1.state == "Done")) &&
               orchestrator_idle?(orchestrator_name)
           end) do
      flunk("""
      workflow replan smoke did not close

      issues:
      #{inspect(Application.get_env(:symphony_elixir, :memory_tracker_issues, []), pretty: true)}

      registry:
      #{inspect(Registry.load_by_root_identifier(root_issue.identifier), pretty: true)}

      snapshot:
      #{inspect(Orchestrator.snapshot(orchestrator_name, 1_000), pretty: true)}
      """)
    end

    assert {:ok, registry} = Registry.load_by_root_identifier(root_issue.identifier)
    assert registry["status"] == "completed"
    assert Registry.node(registry, "implementation-v1")["status"] == "superseded"
    assert Registry.node(registry, "implementation-v2")["status"] == "completed"
  end

  defp stop_default_orchestrator do
    case Process.whereis(Orchestrator) do
      nil ->
        :ok

      pid ->
        :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, Orchestrator)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
    end
  end

  defp restart_default_orchestrator do
    case Process.whereis(Orchestrator) do
      nil ->
        case Supervisor.restart_child(SymphonyElixir.Supervisor, Orchestrator) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, :running} -> :ok
        end

      _pid ->
        :ok
    end
  end

  defp eventually?(fun, attempts \\ 80)

  defp eventually?(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(100)
      eventually?(fun, attempts - 1)
    end
  end

  defp eventually?(_fun, 0), do: false

  defp orchestrator_idle?(orchestrator_name) do
    case Orchestrator.snapshot(orchestrator_name, 1_000) do
      %{running: [], retrying: [], blocked: []} -> true
      _snapshot -> false
    end
  end
end
