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

  test "真实 Orchestrator 按规划结果把派生 issue 分派给指定 agent 并完成审查闭环" do
    stop_default_orchestrator()

    test_root =
      Path.join(System.tmp_dir!(), "workflow-smoke-agent-routing-#{System.unique_integer([:positive])}")

    workspace_root =
      Path.join(test_root, "workspaces")

    log_path = Path.join(test_root, "agent_runs.jsonl")
    File.mkdir_p!(workspace_root)

    codex_binary = write_fake_codex_app_server!(test_root, log_path)

    {mimo_executable, _env} =
      SymphonyElixir.FakeAcpServer.write!(test_root, %{
        "sessionId" => "fake-mimo-session",
        "writeFileOnPrompt" => %{
          "path" => ".symphony/completion_packet.json",
          "contents" =>
            Jason.encode!(%{
              "outcome" => "completed",
              "summary" => "mimocode execution completed",
              "evidence" => ["fake acp_stdio mimocode wrote completion_packet.json"],
              "decisions" => ["use mimocode for implementation"],
              "open_questions" => [],
              "next_handoff" => "codex review"
            })
        },
        "appendJsonlOnPrompt" => %{
          "path" => log_path,
          "entry" => %{"agent" => "mimocode", "agent_kind" => "acp_stdio", "phase" => "execution"}
        }
      })

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
          kind: "codex_app_server",
          command: "#{codex_binary} app-server",
          approval_policy: "never",
          timeout_ms: 10_000,
          read_timeout_ms: 5_000
        },
        mimocode: %{
          kind: "acp_stdio",
          command: mimo_executable,
          args: [],
          permission_policy: "reject",
          timeout_ms: 10_000,
          read_timeout_ms: 5_000
        }
      },
      routing: %{default_agent: "mimocode"},
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
      id: "workflow-smoke-routing-root",
      identifier: "SMOKE-ROUTING-1",
      title: "Smoke routed root issue",
      state: "In Progress",
      url: "https://linear.app/example/issue/SMOKE-ROUTING-1"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [root_issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    orchestrator_name = Module.concat(__MODULE__, :SmokeAgentRoutingOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      restart_default_orchestrator()
      File.rm_rf(test_root)
    end)

    unless eventually?(fn ->
             issues = Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
             root = Enum.find(issues, &(&1.id == root_issue.id))
             derived = Enum.find(issues, &(&1.id != root_issue.id))

             root && derived && root.state == "Done" && derived.state == "Done" &&
               orchestrator_idle?(orchestrator_name)
           end) do
      flunk("""
      workflow agent routing smoke did not close

      issues:
      #{inspect(Application.get_env(:symphony_elixir, :memory_tracker_issues, []), pretty: true)}

      registry:
      #{inspect(Registry.load_by_root_identifier(root_issue.identifier), pretty: true)}

      snapshot:
      #{inspect(Orchestrator.snapshot(orchestrator_name, 1_000), pretty: true)}

      agent runs:
      #{inspect(read_agent_runs(log_path), pretty: true)}
      """)
    end

    assert {:ok, registry} = Registry.load_by_root_identifier(root_issue.identifier)
    assert registry["status"] == "completed"
    assert Registry.node(registry, "implementation")["agent_id"] == "mimocode"
    assert Registry.node(registry, "implementation")["status"] == "completed"

    runs = read_agent_runs(log_path)

    assert %{"agent" => "codex", "agent_kind" => "codex_app_server", "phase" => "planning"} in runs
    assert %{"agent" => "mimocode", "agent_kind" => "acp_stdio", "phase" => "execution"} in runs
    assert %{"agent" => "codex", "agent_kind" => "codex_app_server", "phase" => "review"} in runs
    refute %{"agent" => "codex", "agent_kind" => "codex_app_server", "phase" => "execution"} in runs
    refute %{"agent" => "mimocode", "agent_kind" => "acp_stdio", "phase" => "planning"} in runs
    refute %{"agent" => "mimocode", "agent_kind" => "acp_stdio", "phase" => "review"} in runs

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
        "'review': {'decision':decision,'summary':'smoke rework passed' if decision=='pass' else 'smoke review requested rework','confidence':'high','reason':'smoke requested rework' if decision!='pass' else ''}}; " <>
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
        "'review': {'decision':decision,'summary':'smoke review requested replan' if decision=='needs_replan' else 'smoke replanned review passed','confidence':'high','reason':'smoke requested replan' if decision!='pass' else ''}}; " <>
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

  test "真实 Codex app-server smoke 会把 root workspace 与可写目录传给 execution 和 review" do
    stop_default_orchestrator()

    test_root =
      Path.join(
        System.tmp_dir!(),
        "workflow-smoke-root-workspace-probe-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    log_path = Path.join(test_root, "agent-runs.jsonl")

    root_issue = %Issue{
      id: "workflow-smoke-root-workspace-probe-root",
      identifier: "SMOKE-ROOT-PROBE-1",
      title: "Smoke root workspace probe",
      state: "In Progress",
      url: "https://linear.app/example/issue/SMOKE-ROOT-PROBE-1"
    }

    root_workspace = Path.join(workspace_root, root_issue.identifier)
    codex_binary = write_fake_codex_app_server_with_root_workspace_probe!(test_root, log_path, root_workspace)

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
          kind: "codex_app_server",
          command: "#{codex_binary} app-server",
          approval_policy: "never",
          timeout_ms: 10_000,
          read_timeout_ms: 5_000
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

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [root_issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    orchestrator_name = Module.concat(__MODULE__, :SmokeRootWorkspaceProbeOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      restart_default_orchestrator()
      File.rm_rf(test_root)
    end)

    unless eventually?(fn ->
             issues = Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
             root = Enum.find(issues, &(&1.id == root_issue.id))
             derived = Enum.find(issues, &(&1.id != root_issue.id))

             root && derived && root.state == "Done" && derived.state == "Done" &&
               File.exists?(Path.join(root_workspace, "ROOT_WORKSPACE_PROBE.md")) &&
               orchestrator_idle?(orchestrator_name)
           end) do
      flunk("""
      workflow root workspace probe did not close

      issues:
      #{inspect(Application.get_env(:symphony_elixir, :memory_tracker_issues, []), pretty: true)}

      registry:
      #{inspect(Registry.load_by_root_identifier(root_issue.identifier), pretty: true)}

      snapshot:
      #{inspect(Orchestrator.snapshot(orchestrator_name, 1_000), pretty: true)}

      agent runs:
      #{inspect(read_agent_runs(log_path), pretty: true)}
      """)
    end

    runs = read_agent_runs(log_path)

    assert Enum.any?(runs, &(&1["phase"] == "execution" and &1["prompt_contains_root_workspace"] == true))
    assert Enum.any?(runs, &(&1["phase"] == "review" and &1["prompt_contains_root_workspace"] == true))

    assert Enum.any?(runs, fn run ->
             run["phase"] == "execution" and is_list(run["writable_roots"]) and root_workspace in run["writable_roots"]
           end)

    assert Enum.any?(runs, fn run ->
             run["phase"] == "review" and is_list(run["writable_roots"]) and root_workspace in run["writable_roots"]
           end)
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

  defp write_fake_codex_app_server!(test_root, log_path) do
    executable = Path.join(test_root, "fake-codex")
    script = Path.join(test_root, "fake_codex_app_server.py")

    plan_json =
      Jason.encode!(%{
        "kind" => "issue_graph",
        "summary" => "planner selected mimocode for implementation",
        "confidence" => "high",
        "nodes" => [
          %{
            "node_key" => "implementation",
            "task_type" => "implementation",
            "title" => "Smoke routed implementation",
            "goal" => "Prove derived issue dispatches to mimocode",
            "agent_id" => "mimocode",
            "instructions" => "Write the completion packet for the routed smoke test.",
            "evidence_expectations" => ["mimocode execution log exists"]
          }
        ],
        "edges" => []
      })

    review_json =
      Jason.encode!(%{
        "decision" => "pass",
        "summary" => "codex review passed routed execution",
        "confidence" => "high"
      })

    File.write!(script, """
    import json
    import os
    import sys

    LOG_PATH = #{Jason.encode!(log_path)}
    PLAN = json.loads('''#{python_triple_quoted(plan_json)}''')
    REVIEW = json.loads('''#{python_triple_quoted(review_json)}''')
    planning_turns = 0

    def send(message):
        print(json.dumps(message), flush=True)

    def prompt_text(message):
        inputs = message.get("params", {}).get("input", [])
        return "\\n".join(part.get("text", "") for part in inputs if isinstance(part, dict))

    def write_json(path, payload):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(json.dumps(payload, ensure_ascii=False))

    def append_run(phase):
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        with open(LOG_PATH, "a", encoding="utf-8") as handle:
            handle.write(json.dumps({"agent": "codex", "agent_kind": "codex_app_server", "phase": phase}, ensure_ascii=False) + "\\n")

    for line in sys.stdin:
        message = json.loads(line)
        method = message.get("method")
        request_id = message.get("id")

        if method == "initialize":
            send({"id": request_id, "result": {}})
        elif method == "initialized":
            pass
        elif method == "thread/start":
            send({"id": request_id, "result": {"thread": {"id": "fake-codex-thread"}}})
        elif method == "turn/start":
            text = prompt_text(message)
            if "workflow_plan.json" in text:
                planning_turns += 1
                phase = "planning"
                if planning_turns > 1 or "上一轮 planning 已正常结束" in text:
                    write_json(".symphony/workflow_plan.json", PLAN)
            elif "review_decision.json" in text:
                phase = "review"
                write_json(".symphony/review_decision.json", REVIEW)
            else:
                sys.exit(7)

            append_run(phase)
            send({"id": request_id, "result": {"turn": {"id": "fake-codex-" + phase}}})
            send({"method": "turn/completed"})
        elif request_id is not None:
            send({"id": request_id, "result": {}})
    """)

    File.write!(executable, """
    #!/bin/sh
    exec python3 -u "#{script}"
    """)

    File.chmod!(executable, 0o755)
    executable
  end

  defp write_fake_codex_app_server_with_root_workspace_probe!(test_root, log_path, root_workspace) do
    executable = Path.join(test_root, "fake-codex-root-probe")
    script = Path.join(test_root, "fake_codex_root_probe.py")

    File.mkdir_p!(test_root)

    plan_json =
      Jason.encode!(%{
        "kind" => "issue_graph",
        "summary" => "planner selected codex implementation that needs root workspace handoff",
        "confidence" => "high",
        "nodes" => [
          %{
            "node_key" => "implementation",
            "task_type" => "implementation",
            "title" => "Probe root workspace implementation",
            "goal" => "Verify execution/review receive root workspace context",
            "agent_id" => "codex",
            "instructions" => "在 root workflow workspace 中读取或写入目标文件，并在当前 issue workspace 写 artifact。",
            "evidence_expectations" => ["root workflow workspace path is present in prompt"]
          }
        ],
        "edges" => []
      })

    File.write!(script, """
    import json
    import os
    import sys

    LOG_PATH = #{Jason.encode!(log_path)}
    ROOT_WORKSPACE = #{Jason.encode!(root_workspace)}
    PLAN = json.loads('''#{python_triple_quoted(plan_json)}''')

    def send(message):
        print(json.dumps(message), flush=True)

    def prompt_text(message):
        inputs = message.get("params", {}).get("input", [])
        return "\\n".join(part.get("text", "") for part in inputs if isinstance(part, dict))

    def append_run(payload):
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        with open(LOG_PATH, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(payload, ensure_ascii=False) + "\\n")

    def write_json(path, payload):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(json.dumps(payload, ensure_ascii=False))

    for line in sys.stdin:
        message = json.loads(line)
        method = message.get("method")
        request_id = message.get("id")

        if method == "initialize":
            send({"id": request_id, "result": {}})
        elif method == "initialized":
            pass
        elif method == "thread/start":
            send({"id": request_id, "result": {"thread": {"id": "fake-root-probe-thread"}}})
        elif method == "turn/start":
            text = prompt_text(message)
            sandbox = message.get("params", {}).get("sandboxPolicy", {})
            writable_roots = sandbox.get("writableRoots", [])

            if "workflow_plan.json" in text:
                phase = "planning"
                write_json(".symphony/workflow_plan.json", PLAN)
                append_run({
                    "phase": phase,
                    "prompt_contains_root_workspace": ROOT_WORKSPACE in text,
                    "writable_roots": writable_roots
                })
            elif "completion_packet.json" in text:
                phase = "execution"
                prompt_contains_root_workspace = ROOT_WORKSPACE in text
                target = os.path.join(ROOT_WORKSPACE, "ROOT_WORKSPACE_PROBE.md")
                os.makedirs(ROOT_WORKSPACE, exist_ok=True)
                with open(target, "w", encoding="utf-8") as handle:
                    handle.write("probe ok\\n")
                write_json(".symphony/completion_packet.json", {
                    "outcome": "completed",
                    "summary": "execution saw root workspace context",
                    "evidence": [target],
                    "decisions": ["root workspace handoff available"],
                    "open_questions": [],
                    "next_handoff": "review the root workspace probe"
                })
                append_run({
                    "phase": phase,
                    "prompt_contains_root_workspace": prompt_contains_root_workspace,
                    "writable_roots": writable_roots,
                    "target": target
                })
            elif "review_decision.json" in text:
                phase = "review"
                prompt_contains_root_workspace = ROOT_WORKSPACE in text
                target = os.path.join(ROOT_WORKSPACE, "ROOT_WORKSPACE_PROBE.md")
                exists = os.path.exists(target)
                write_json(".symphony/review_decision.json", {
                    "decision": "pass" if prompt_contains_root_workspace and exists else "fail",
                    "summary": "review saw root workspace context" if prompt_contains_root_workspace and exists else "review missing root workspace context",
                    "confidence": "high",
                    "reason": "" if prompt_contains_root_workspace and exists else "root workspace probe missing"
                })
                append_run({
                    "phase": phase,
                    "prompt_contains_root_workspace": prompt_contains_root_workspace,
                    "writable_roots": writable_roots,
                    "target_exists": exists
                })
            else:
                sys.exit(7)

            send({"id": request_id, "result": {"turn": {"id": "fake-root-probe-" + phase}}})
            send({"method": "turn/completed"})
        elif request_id is not None:
            send({"id": request_id, "result": {}})
    """)

    File.write!(executable, """
    #!/bin/sh
    exec python3 -u "#{script}"
    """)

    File.chmod!(executable, 0o755)
    executable
  end

  defp python_triple_quoted(value) when is_binary(value) do
    String.replace(value, "'''", "\\'\\'\\'")
  end

  defp read_agent_runs(log_path) do
    if File.exists?(log_path) do
      log_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
    else
      []
    end
  end
end
