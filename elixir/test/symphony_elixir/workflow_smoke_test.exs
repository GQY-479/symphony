defmodule SymphonyElixir.WorkflowSmokeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Workflow.Registry

  @moduletag timeout: 120_000

  test "真实 Orchestrator 通过 implementation 跑通 root execution review 闭环" do
    stop_default_orchestrator()

    test_root =
      Path.join(System.tmp_dir!(), "workflow-smoke-direct-execution-#{System.unique_integer([:positive])}")

    workspace_root = Path.join(test_root, "workspaces")
    log_path = Path.join(test_root, "agent_runs.jsonl")

    agent_script =
      single_issue_graph_agent_script(
        log_path,
        %{
          "schema_version" => 1,
          "node_key" => "implementation",
          "task_type" => "implementation",
          "outcome" => "completed",
          "summary" => "implementation completed",
          "evidence" => ["fake cli wrote issue_result.json"],
          "decisions" => ["execute root issue directly"],
          "open_questions" => []
        },
        %{
          "schema_version" => 1,
          "node_key" => "final_review",
          "task_type" => "review",
          "outcome" => "pass",
          "reviews" => ["__root_candidate__"],
          "summary" => "implementation review passed",
          "evidence" => ["fake cli reviewed issue_result.json"],
          "decisions" => [],
          "open_questions" => []
        }
      )

    write_issue_graph_workflow!(workspace_root, agent_script)

    root_issue = %Issue{
      id: "workflow-smoke-direct-root",
      identifier: "SMOKE-DIRECT-1",
      title: "Smoke implementation root issue",
      state: "In Progress",
      url: "https://linear.app/example/issue/SMOKE-DIRECT-1"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [root_issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    orchestrator_name = Module.concat(__MODULE__, :SmokeSingleIssueGraphOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    Orchestrator.request_refresh(orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      restart_default_orchestrator()
      File.rm_rf(test_root)
    end)

    unless eventually?(fn ->
             issues = Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
             root = Enum.find(issues, &(&1.id == root_issue.id))

             root && root.state == "Done" && orchestrator_idle?(orchestrator_name)
           end) do
      flunk("""
      workflow implementation smoke did not close

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
    assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(registry["updated_at"])

    implementation_node = Registry.node(registry, "implementation")
    assert implementation_node["task_type"] == "implementation"
    assert implementation_node["status"] == "completed"
    assert Registry.node(registry, "final_review")["status"] == "completed"

    issues = Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
    assert length(issues) == 3

    runs = read_agent_runs(log_path)
    assert %{"phase" => "planning", "issue_identifier" => root_issue.identifier, "workspace" => root_issue.identifier} in runs
    assert Enum.any?(runs, &(&1["phase"] == "issue" and &1["task_type"] == "implementation"))
    assert Enum.any?(runs, &(&1["phase"] == "issue" and &1["task_type"] == "review"))
  end

  test "真实 Orchestrator 拒绝缺少 evidence 的 implementation issue result" do
    stop_default_orchestrator()

    test_root =
      Path.join(System.tmp_dir!(), "workflow-smoke-direct-missing-evidence-#{System.unique_integer([:positive])}")

    workspace_root = Path.join(test_root, "workspaces")
    log_path = Path.join(test_root, "agent_runs.jsonl")

    agent_script =
      single_issue_graph_agent_script(
        log_path,
        %{
          "schema_version" => 1,
          "node_key" => "root",
          "task_type" => "implementation",
          "outcome" => "completed",
          "summary" => "implementation completed without evidence",
          "evidence" => [],
          "decisions" => ["execute root issue directly"],
          "open_questions" => []
        },
        %{
          "schema_version" => 1,
          "node_key" => "final_review",
          "task_type" => "review",
          "outcome" => "pass",
          "reviews" => ["__root_candidate__"],
          "summary" => "review should not run for invalid issue result",
          "evidence" => ["fake cli reviewed issue_result.json"],
          "decisions" => [],
          "open_questions" => []
        }
      )

    write_issue_graph_workflow!(workspace_root, agent_script)

    root_issue = %Issue{
      id: "workflow-smoke-direct-missing-evidence-root",
      identifier: "SMOKE-DIRECT-EVIDENCE-1",
      title: "Smoke implementation missing evidence",
      state: "In Progress",
      url: "https://linear.app/example/issue/SMOKE-DIRECT-EVIDENCE-1"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [root_issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    orchestrator_name = Module.concat(__MODULE__, :SmokeDirectMissingEvidenceOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    Orchestrator.request_refresh(orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      restart_default_orchestrator()
      File.rm_rf(test_root)
    end)

    unless eventually?(fn ->
             snapshot = Orchestrator.snapshot(orchestrator_name, 1_000)

             Enum.any?(snapshot.blocked, fn blocked ->
               blocked.issue_id == root_issue.id and blocked.workflow_phase == :issue and
                 String.contains?(blocked.error, "invalid_issue_result")
             end)
           end) do
      flunk("""
      workflow implementation missing evidence did not block in execution

      registry:
      #{inspect(Registry.load_by_root_identifier(root_issue.identifier), pretty: true)}

      snapshot:
      #{inspect(Orchestrator.snapshot(orchestrator_name, 1_000), pretty: true)}

      agent runs:
      #{inspect(read_agent_runs(log_path), pretty: true)}
      """)
    end

    assert {:ok, registry} = Registry.load_by_root_identifier(root_issue.identifier)
    refute registry["status"] == "completed"
    refute Registry.node(registry, "root")["status"] == "completed"

    runs = read_agent_runs(log_path)
    assert Enum.any?(runs, &(&1["phase"] == "planning" and &1["issue_identifier"] == root_issue.identifier))
    assert Enum.any?(runs, &(&1["phase"] == "issue" and &1["task_type"] == "implementation"))
    refute Enum.any?(runs, &(&1["phase"] == "issue" and &1["task_type"] == "review"))
  end

  test "真实 Orchestrator 在 implementation review needs_human 时阻塞 registry 并保存人工输入请求" do
    stop_default_orchestrator()

    test_root =
      Path.join(System.tmp_dir!(), "workflow-smoke-direct-needs-human-#{System.unique_integer([:positive])}")

    workspace_root = Path.join(test_root, "workspaces")
    log_path = Path.join(test_root, "agent_runs.jsonl")

    agent_script =
      single_issue_graph_agent_script(
        log_path,
        %{
          "schema_version" => 1,
          "node_key" => "root",
          "task_type" => "implementation",
          "outcome" => "completed",
          "summary" => "implementation completed but needs product input",
          "evidence" => ["fake cli wrote issue_result.json"],
          "decisions" => ["execute root issue directly"],
          "open_questions" => []
        },
        %{
          "schema_version" => 1,
          "node_key" => "final_review",
          "task_type" => "review",
          "outcome" => "needs_human",
          "reviews" => ["__root_candidate__"],
          "summary" => "product decision required before closing",
          "evidence" => ["fake cli reviewed issue_result.json"],
          "decisions" => [],
          "open_questions" => [],
          "reason" => "acceptance criteria require human confirmation",
          "requested_input" => "Please confirm whether this implementation is acceptable."
        }
      )

    write_issue_graph_workflow!(workspace_root, agent_script)

    root_issue = %Issue{
      id: "workflow-smoke-direct-needs-human-root",
      identifier: "SMOKE-DIRECT-HUMAN-1",
      title: "Smoke implementation needs human",
      state: "In Progress",
      url: "https://linear.app/example/issue/SMOKE-DIRECT-HUMAN-1"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [root_issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    orchestrator_name = Module.concat(__MODULE__, :SmokeDirectNeedsHumanOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    Orchestrator.request_refresh(orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      restart_default_orchestrator()
      File.rm_rf(test_root)
    end)

    unless eventually?(fn ->
             snapshot = Orchestrator.snapshot(orchestrator_name, 1_000)

             case Registry.load_by_root_identifier(root_issue.identifier) do
               {:ok, %{"status" => "blocked", "human_input_request" => request}} when is_binary(request) ->
                 snapshot.running == [] and snapshot.retrying == [] and
                   Enum.any?(snapshot.blocked, fn blocked ->
                     blocked.workflow_phase == :issue and
                       String.contains?(blocked.error, "review needs human")
                   end)

               _ ->
                 false
             end
           end) do
      flunk("""
      workflow implementation needs_human did not block registry

      registry:
      #{inspect(Registry.load_by_root_identifier(root_issue.identifier), pretty: true)}

      snapshot:
      #{inspect(Orchestrator.snapshot(orchestrator_name, 1_000), pretty: true)}

      agent runs:
      #{inspect(read_agent_runs(log_path), pretty: true)}
      """)
    end

    assert {:ok, registry} = Registry.load_by_root_identifier(root_issue.identifier)
    assert registry["status"] == "blocked"
    assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(registry["updated_at"])
    assert registry["blocked_reason"] == "product decision required before closing"
    assert registry["human_input_request"] == "Please confirm whether this implementation is acceptable."
    assert Registry.node(registry, "root")["status"] == "completed"
    assert Registry.node(registry, "final_review")["status"] == "blocked"
    assert Registry.node(registry, "final_review")["review_summary"] == "product decision required before closing"
  end

  test "真实 Orchestrator 在 implementation review fail 时标记 registry failed 并保存失败原因" do
    stop_default_orchestrator()

    test_root =
      Path.join(System.tmp_dir!(), "workflow-smoke-direct-fail-#{System.unique_integer([:positive])}")

    workspace_root = Path.join(test_root, "workspaces")
    log_path = Path.join(test_root, "agent_runs.jsonl")

    agent_script =
      single_issue_graph_agent_script(
        log_path,
        %{
          "schema_version" => 1,
          "node_key" => "root",
          "task_type" => "implementation",
          "outcome" => "completed",
          "summary" => "implementation completed with unacceptable result",
          "evidence" => ["fake cli wrote issue_result.json"],
          "decisions" => ["execute root issue directly"],
          "open_questions" => []
        },
        %{
          "schema_version" => 1,
          "node_key" => "final_review",
          "task_type" => "review",
          "outcome" => "fail",
          "reviews" => ["__root_candidate__"],
          "summary" => "implementation failed review",
          "evidence" => ["fake cli reviewed issue_result.json"],
          "decisions" => [],
          "open_questions" => [],
          "reason" => "completion evidence proves the wrong behavior"
        }
      )

    write_issue_graph_workflow!(workspace_root, agent_script)

    root_issue = %Issue{
      id: "workflow-smoke-direct-fail-root",
      identifier: "SMOKE-DIRECT-FAIL-1",
      title: "Smoke implementation fail",
      state: "In Progress",
      url: "https://linear.app/example/issue/SMOKE-DIRECT-FAIL-1"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [root_issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    orchestrator_name = Module.concat(__MODULE__, :SmokeDirectFailOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
    Orchestrator.request_refresh(orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
      restart_default_orchestrator()
      File.rm_rf(test_root)
    end)

    unless eventually?(fn ->
             snapshot = Orchestrator.snapshot(orchestrator_name, 1_000)

             case Registry.load_by_root_identifier(root_issue.identifier) do
               {:ok, %{"status" => "failed", "failure_reason" => reason}} when is_binary(reason) ->
                 snapshot.running == [] and snapshot.retrying == [] and
                   Enum.any?(snapshot.blocked, fn blocked ->
                     blocked.workflow_phase == :issue and
                       String.contains?(blocked.error, "review failed")
                   end)

               _ ->
                 false
             end
           end) do
      flunk("""
      workflow implementation fail did not fail registry

      registry:
      #{inspect(Registry.load_by_root_identifier(root_issue.identifier), pretty: true)}

      snapshot:
      #{inspect(Orchestrator.snapshot(orchestrator_name, 1_000), pretty: true)}

      agent runs:
      #{inspect(read_agent_runs(log_path), pretty: true)}
      """)
    end

    assert {:ok, registry} = Registry.load_by_root_identifier(root_issue.identifier)
    assert registry["status"] == "failed"
    assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(registry["updated_at"])
    assert registry["failure_reason"] == "implementation failed review"
    refute registry["failure_reason"] == "completion evidence proves the wrong behavior"
    assert Registry.node(registry, "root")["status"] == "completed"
    assert Registry.node(registry, "final_review")["status"] == "failed"
    assert Registry.node(registry, "final_review")["review_summary"] == "implementation failed review"
  end

  test "真实 Orchestrator 通过 artifacts 跑通 planning execution review 闭环" do
    stop_default_orchestrator()

    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-smoke-workspaces-#{System.unique_integer([:positive])}")

    agent_script =
      "import json, os, sys; " <>
        "p=sys.argv[1]; os.makedirs('.symphony', exist_ok=True); " <>
        "phase='plan' if 'workflow_plan.json' in p else ('issue' if 'issue_result.json' in p else ''); " <>
        "is_review='\"task_type\": \"review\"' in p or 'Review issue' in p; " <>
        "payloads={" <>
        "'plan': {'kind': 'issue_graph', 'summary': 'smoke planning created one executable child issue', 'confidence': 'high', 'nodes': [{'node_key': 'implementation', 'task_type': 'implementation', 'title': 'Smoke derived implementation', 'goal': 'Prove the workflow closes through review', 'agent_id': 'codex', 'instructions': 'Write the issue result for the smoke test.', 'evidence_expectations': ['issue result exists']},{'node_key':'final_review','task_type':'review','title':'Final review','goal':'Review the root candidate result','agent_id':'codex','reviews':['__root_candidate__'],'subject_selector':{'type':'final_candidate_range'}}], 'edges': [{'from':'implementation','to':'final_review'}]}, " <>
        "'implementation': {'schema_version': 1, 'node_key': 'implementation', 'task_type': 'implementation', 'outcome': 'completed', 'summary': 'smoke execution completed', 'evidence': ['fake cli wrote issue_result.json'], 'decisions': ['use artifact handoff'], 'open_questions': []}, " <>
        "'review': {'schema_version': 1, 'node_key': 'final_review', 'task_type': 'review', 'outcome': 'pass', 'reviews': ['__root_candidate__'], 'summary': 'smoke review passed', 'evidence': ['fake cli reviewed issue_result.json'], 'decisions': [], 'open_questions': []}}; " <>
        "payloads['issue']=payloads['review'] if is_review else payloads['implementation']; " <>
        "paths={'plan': '.symphony/workflow_plan.json', 'issue': '.symphony/issue_result.json'}; " <>
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

  test "新的 Orchestrator 从 planning_complete registry 恢复并完成派生 issue 闭环" do
    stop_default_orchestrator()

    test_root =
      Path.join(System.tmp_dir!(), "workflow-smoke-recovery-workspaces-#{System.unique_integer([:positive])}")

    workspace_root = Path.join(test_root, "workspaces")
    log_path = Path.join(test_root, "agent-runs.jsonl")

    agent_script =
      "import json, os, sys; " <>
        "p=sys.argv[1]; log=#{Jason.encode!(log_path)}; os.makedirs('.symphony', exist_ok=True); os.makedirs(os.path.dirname(log), exist_ok=True); " <>
        "phase='planning' if 'workflow_plan.json' in p else ('issue' if 'issue_result.json' in p else ''); " <>
        "is_review='\"task_type\": \"review\"' in p or 'Review issue' in p; " <>
        "payloads={" <>
        "'planning': {'kind': 'issue_graph', 'summary': 'recovery planning created one executable child issue', 'confidence': 'high', 'nodes': [{'node_key': 'implementation', 'task_type': 'implementation', 'title': 'Recovery derived implementation', 'goal': 'Finish after orchestrator restart', 'agent_id': 'codex', 'instructions': 'Write the issue result for recovery smoke.', 'evidence_expectations': ['issue result exists']},{'node_key':'final_review','task_type':'review','title':'Final review','goal':'Review the root candidate result','agent_id':'codex','reviews':['__root_candidate__'],'subject_selector':{'type':'final_candidate_range'}}], 'edges': [{'from':'implementation','to':'final_review'}]}, " <>
        "'implementation': {'schema_version': 1, 'node_key': 'implementation', 'task_type': 'implementation', 'outcome': 'completed', 'summary': 'recovery execution completed', 'evidence': ['fake cli wrote issue_result.json'], 'decisions': ['continue from persisted registry'], 'open_questions': []}, " <>
        "'review': {'schema_version': 1, 'node_key': 'final_review', 'task_type': 'review', 'outcome': 'pass', 'reviews': ['__root_candidate__'], 'summary': 'recovery review passed', 'evidence': ['fake cli reviewed issue_result.json'], 'decisions': [], 'open_questions': []}}; " <>
        "payloads['issue']=payloads['review'] if is_review else payloads['implementation']; " <>
        "paths={'planning': '.symphony/workflow_plan.json', 'issue': '.symphony/issue_result.json'}; " <>
        "phase or sys.exit(2); open(log, 'a', encoding='utf-8').write(json.dumps({'phase': phase, 'task_type': payloads[phase].get('task_type'), 'node_key': payloads[phase].get('node_key'), 'issue_identifier': os.path.basename(os.getcwd())}, ensure_ascii=False)+chr(10)); " <>
        "open(paths[phase], 'w', encoding='utf-8').write(json.dumps(payloads[phase], ensure_ascii=False))"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done", "Closed", "Cancelled", "Canceled", "Duplicate"],
      poll_interval_ms: 30_000,
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
      id: "workflow-smoke-recovery-root",
      identifier: "SMOKE-RECOVERY-1",
      title: "Smoke recovery root issue",
      state: "In Progress",
      url: "https://linear.app/example/issue/SMOKE-RECOVERY-1"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [root_issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    first_name = Module.concat(__MODULE__, :SmokeRecoveryFirstOrchestrator)
    second_name = Module.concat(__MODULE__, :SmokeRecoverySecondOrchestrator)
    {:ok, first_pid} = Orchestrator.start_link(name: first_name)
    Orchestrator.request_refresh(first_name)

    on_exit(fn ->
      if Process.alive?(first_pid), do: Process.exit(first_pid, :normal)

      case Process.whereis(second_name) do
        pid when is_pid(pid) -> Process.exit(pid, :normal)
        nil -> :ok
      end

      restart_default_orchestrator()
      File.rm_rf(test_root)
    end)

    unless eventually?(fn ->
             with {:ok, registry} <- Registry.load_by_root_identifier(root_issue.identifier),
                  %{"status" => "ready"} <- Registry.node(registry, "implementation") do
               registry["status"] == "planning_complete" and
                 Enum.any?(read_agent_runs(log_path), &(&1["phase"] == "planning")) and
                 not Enum.any?(read_agent_runs(log_path), &(&1["phase"] == "issue"))
             else
               _ -> false
             end
           end) do
      flunk("""
      workflow recovery smoke did not persist planning_complete before restart

      issues:
      #{inspect(Application.get_env(:symphony_elixir, :memory_tracker_issues, []), pretty: true)}

      registry:
      #{inspect(Registry.load_by_root_identifier(root_issue.identifier), pretty: true)}

      snapshot:
      #{inspect(Orchestrator.snapshot(first_name, 1_000), pretty: true)}

      agent runs:
      #{inspect(read_agent_runs(log_path), pretty: true)}
      """)
    end

    planning_runs_before_restart =
      log_path
      |> read_agent_runs()
      |> Enum.count(&(&1["phase"] == "planning"))

    assert planning_runs_before_restart == 1

    GenServer.stop(first_pid, :normal)
    refute Process.alive?(first_pid)

    {:ok, second_pid} = Orchestrator.start_link(name: second_name)
    Orchestrator.request_refresh(second_name)

    unless eventually?(fn ->
             issues = Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
             root = Enum.find(issues, &(&1.id == root_issue.id))
             derived = Enum.find(issues, &(&1.id != root_issue.id))

             if root && derived && root.state == "Done" && derived.state == "Done" do
               Orchestrator.request_refresh(second_name)
             end

             root && derived && root.state == "Done" && derived.state == "Done" &&
               orchestrator_idle?(second_name)
           end) do
      flunk("""
      workflow recovery smoke did not close after restart

      issues:
      #{inspect(Application.get_env(:symphony_elixir, :memory_tracker_issues, []), pretty: true)}

      registry:
      #{inspect(Registry.load_by_root_identifier(root_issue.identifier), pretty: true)}

      first snapshot:
      #{inspect(if(Process.alive?(first_pid), do: Orchestrator.snapshot(first_name, 1_000), else: :stopped), pretty: true)}

      second snapshot:
      #{inspect(Orchestrator.snapshot(second_name, 1_000), pretty: true)}

      agent runs:
      #{inspect(read_agent_runs(log_path), pretty: true)}
      """)
    end

    assert Process.alive?(second_pid)
    assert {:ok, registry} = Registry.load_by_root_identifier(root_issue.identifier)
    assert registry["status"] == "completed"
    assert Registry.node(registry, "implementation")["status"] == "completed"

    runs = read_agent_runs(log_path)
    assert Enum.count(runs, &(&1["phase"] == "planning")) == planning_runs_before_restart
    assert Enum.any?(runs, &(&1["phase"] == "planning" and &1["issue_identifier"] == root_issue.identifier))
    assert Enum.any?(runs, &(&1["phase"] == "issue" and &1["task_type"] == "implementation"))
    assert Enum.any?(runs, &(&1["phase"] == "issue" and &1["task_type"] == "review"))
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
          "path" => ".symphony/issue_result.json",
          "contents" =>
            Jason.encode!(%{
              "schema_version" => 1,
              "node_key" => "implementation",
              "task_type" => "implementation",
              "outcome" => "completed",
              "summary" => "mimocode execution completed",
              "evidence" => ["fake acp_stdio mimocode wrote issue_result.json"],
              "decisions" => ["use mimocode for implementation"],
              "open_questions" => []
            })
        },
        "appendJsonlOnPrompt" => %{
          "path" => log_path,
          "entry" => %{
            "agent" => "mimocode",
            "agent_kind" => "acp_stdio",
            "phase" => "issue",
            "task_type" => "implementation"
          }
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

    assert %{
             "agent" => "mimocode",
             "agent_kind" => "acp_stdio",
             "phase" => "issue",
             "task_type" => "implementation"
           } in runs

    assert %{
             "agent" => "codex",
             "agent_kind" => "codex_app_server",
             "phase" => "issue",
             "task_type" => "review"
           } in runs

    refute Enum.any?(runs, &(&1["agent"] == "codex" and &1["task_type"] == "implementation"))
    refute %{"agent" => "mimocode", "agent_kind" => "acp_stdio", "phase" => "planning"} in runs
    refute Enum.any?(runs, &(&1["agent"] == "mimocode" and &1["task_type"] == "review"))

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
        "phase='plan' if 'workflow_plan.json' in p else ('issue' if 'issue_result.json' in p else ''); " <>
        "is_review='\"task_type\": \"review\"' in p or 'Review issue' in p; is_final='final_review' in p or '__root_candidate__' in p; is_rework='返工：' in p or 'implementation-rework-1' in p; " <>
        "decision='pass' if is_final else 'needs_rework'; " <>
        "payloads={" <>
        "'plan': {'kind':'issue_graph','summary':'smoke planning created rework candidate','confidence':'high','nodes':[{'node_key':'implementation','task_type':'implementation','title':'Smoke rework implementation','goal':'Produce a result that first review rejects','agent_id':'codex','instructions':'Write issue result for rework smoke.','evidence_expectations':['issue result exists']},{'node_key':'implementation_review','task_type':'review','title':'Review smoke implementation','goal':'Review the implementation result','agent_id':'codex','reviews':['implementation'],'subject_selector':{'type':'candidate_range'}},{'node_key':'final_review','task_type':'review','title':'Final review','goal':'Review the root candidate result','agent_id':'codex','reviews':['__root_candidate__'],'subject_selector':{'type':'final_candidate_range'}}],'edges':[{'from':'implementation','to':'implementation_review'},{'from':'implementation_review','to':'final_review'}]}, " <>
        "'implementation': {'schema_version':1,'node_key':'implementation-rework-1' if is_rework else 'implementation','task_type':'implementation','outcome':'completed','summary':'smoke execution completed for '+p[:80],'evidence':['fake cli wrote issue_result.json'],'decisions':['use artifact handoff'],'open_questions':[]}, " <>
        "'review': {'schema_version':1,'node_key':'final_review' if is_final else 'implementation_review','task_type':'review','outcome':decision,'reviews':['__root_candidate__'] if is_final else ['implementation'],'summary':'smoke review passed' if decision=='pass' else 'smoke review requested rework','reason':'smoke requested rework' if decision!='pass' else '', 'evidence':['fake cli reviewed issue_result.json'],'decisions':[],'open_questions':[]}}; " <>
        "payloads['issue']=payloads['review'] if is_review else payloads['implementation']; " <>
        "paths={'plan':'.symphony/workflow_plan.json','issue':'.symphony/issue_result.json'}; " <>
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

             root && root.state == "Done" && length(derived) >= 3 &&
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
    assert Registry.node(registry, "final_review")["status"] == "completed"
  end

  test "真实 Orchestrator 通过 needs_replan 回到 root planning 并完成新计划" do
    stop_default_orchestrator()

    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-smoke-replan-workspaces-#{System.unique_integer([:positive])}")

    agent_script =
      "import json, os, sys; " <>
        "p=sys.argv[1]; os.makedirs('.symphony', exist_ok=True); " <>
        "phase='plan' if 'workflow_plan.json' in p else ('issue' if 'issue_result.json' in p else ''); " <>
        "is_review='\"task_type\": \"review\"' in p or 'Review issue' in p; is_final='final_review' in p or '__root_candidate__' in p; " <>
        "replanning='重规划原因' in p; key='implementation-v2' if replanning else 'implementation-v1'; title='Smoke replanned implementation' if replanning else 'Smoke initial implementation'; summary='smoke replanning created replacement issue' if replanning else 'smoke planning created initial issue'; " <>
        "decision='pass' if is_final else 'needs_replan'; " <>
        "payloads={" <>
        "'plan': {'kind':'issue_graph','summary':summary,'confidence':'high','nodes':([{'node_key':key,'task_type':'implementation','title':title,'goal':'Prove replan closes through a replacement issue','agent_id':'codex','instructions':'Write issue result for replan smoke.','evidence_expectations':['issue result exists']},{'node_key':'final_review','task_type':'review','title':'Final review','goal':'Review the root candidate result','agent_id':'codex','reviews':['__root_candidate__'],'subject_selector':{'type':'final_candidate_range'}}] if replanning else [{'node_key':key,'task_type':'implementation','title':title,'goal':'Prove replan closes through a replacement issue','agent_id':'codex','instructions':'Write issue result for replan smoke.','evidence_expectations':['issue result exists']},{'node_key':'implementation_review','task_type':'review','title':'Review initial implementation','goal':'Request replanning for the initial result','agent_id':'codex','reviews':['implementation-v1'],'subject_selector':{'type':'candidate_range'}},{'node_key':'final_review','task_type':'review','title':'Final review','goal':'Review the root candidate result','agent_id':'codex','reviews':['__root_candidate__'],'subject_selector':{'type':'final_candidate_range'}}]),'edges':([{'from':key,'to':'final_review'}] if replanning else [{'from':'implementation-v1','to':'implementation_review'},{'from':'implementation_review','to':'final_review'}])}, " <>
        "'implementation': {'schema_version':1,'node_key':key,'task_type':'implementation','outcome':'completed','summary':'smoke execution completed for '+p[:80],'evidence':['fake cli wrote issue_result.json'],'decisions':['use artifact handoff'],'open_questions':[]}, " <>
        "'review': {'schema_version':1,'node_key':'final_review' if is_final else 'implementation_review','task_type':'review','outcome':decision,'reviews':['__root_candidate__'] if is_final else ['implementation-v1'],'summary':'smoke review requested replan' if decision=='needs_replan' else 'smoke replanned review passed','reason':'smoke requested replan' if decision!='pass' else '', 'evidence':['fake cli reviewed issue_result.json'],'decisions':[],'open_questions':[]}}; " <>
        "payloads['issue']=payloads['review'] if is_review else payloads['implementation']; " <>
        "paths={'plan':'.symphony/workflow_plan.json','issue':'.symphony/issue_result.json'}; " <>
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

             root && root.state == "Done" && length(derived) >= 2 &&
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
    assert Registry.node(registry, "implementation-v1")["status"] == "completed"
    assert Registry.node(registry, "implementation-v2")["status"] == "completed"
    assert Registry.node(registry, "final_review")["status"] == "completed"
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

    assert Enum.any?(
             runs,
             &(&1["phase"] == "issue" and &1["task_type"] == "implementation" and
                 &1["prompt_contains_root_workspace"] == true)
           )

    assert Enum.any?(
             runs,
             &(&1["phase"] == "issue" and &1["task_type"] == "review" and
                 &1["prompt_contains_root_workspace"] == true)
           )

    assert Enum.any?(runs, fn run ->
             run["phase"] == "issue" and run["task_type"] == "implementation" and is_list(run["writable_roots"]) and
               root_workspace in run["writable_roots"]
           end)

    assert Enum.any?(runs, fn run ->
             run["phase"] == "issue" and run["task_type"] == "review" and is_list(run["writable_roots"]) and
               root_workspace in run["writable_roots"]
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

  defp write_issue_graph_workflow!(workspace_root, agent_script) do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Done", "Closed", "Cancelled", "Canceled", "Duplicate"],
      poll_interval_ms: 50,
      workspace_root: workspace_root,
      workspace_preserve_terminal: true,
      max_concurrent_agents: 1,
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
  end

  defp single_issue_graph_agent_script(log_path, issue_result, review_result) do
    plan_json =
      Jason.encode!(%{
        "kind" => "issue_graph",
        "summary" => "smoke planning created a single implementation node",
        "confidence" => "high",
        "nodes" => [
          %{
            "node_key" => "implementation",
            "task_type" => "implementation",
            "title" => "Smoke implementation",
            "goal" => "Prove the workflow closes through review",
            "agent_id" => "codex"
          },
          %{
            "node_key" => "final_review",
            "task_type" => "review",
            "title" => "Final review",
            "goal" => "Review the root candidate result",
            "agent_id" => "codex",
            "reviews" => ["__root_candidate__"],
            "subject_selector" => %{"type" => "final_candidate_range"}
          }
        ],
        "edges" => [%{"from" => "implementation", "to" => "final_review"}]
      })

    issue_json = Jason.encode!(issue_result)
    review_json = Jason.encode!(review_result)

    plan_b64 = Base.encode64(plan_json)
    issue_b64 = Base.encode64(issue_json)
    review_b64 = Base.encode64(review_json)

    "import base64, json, os, sys; " <>
      "p=sys.argv[1]; log=#{Jason.encode!(log_path)}; os.makedirs('.symphony', exist_ok=True); os.makedirs(os.path.dirname(log), exist_ok=True); " <>
      "phase='planning' if 'workflow_plan.json' in p else ('issue' if 'issue_result.json' in p else ''); " <>
      "task_type='review' if '\"task_type\": \"review\"' in p or 'Review issue' in p else ('implementation' if '\"task_type\": \"implementation\"' in p else ''); " <>
      "loads=lambda v: json.loads(base64.b64decode(v).decode('utf-8')); " <>
      "payloads={'planning': loads('#{plan_b64}'), 'issue': (loads('#{review_b64}') if task_type=='review' else loads('#{issue_b64}'))}; " <>
      "paths={'planning': '.symphony/workflow_plan.json', 'issue': '.symphony/issue_result.json'}; " <>
      "phase or sys.exit(2); open(log, 'a', encoding='utf-8').write(json.dumps({'phase': phase, 'issue_identifier': os.path.basename(os.getcwd()), 'workspace': os.path.basename(os.getcwd())}, ensure_ascii=False)+chr(10)); " <>
      "open(log, 'a', encoding='utf-8').write(json.dumps({'phase': phase, 'task_type': task_type, 'node_key': payloads[phase].get('node_key'), 'issue_identifier': os.path.basename(os.getcwd()), 'workspace': os.path.basename(os.getcwd())}, ensure_ascii=False)+chr(10)) if phase == 'issue' else None; " <>
      "open(paths[phase], 'w', encoding='utf-8').write(json.dumps(payloads[phase], ensure_ascii=False))"
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
        "schema_version" => 1,
        "node_key" => "final_review",
        "task_type" => "review",
        "outcome" => "pass",
        "reviews" => ["__root_candidate__"],
        "summary" => "codex review passed routed execution",
        "evidence" => ["fake codex reviewed routed execution"],
        "decisions" => [],
        "open_questions" => []
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

    def append_run(phase, task_type=None):
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        payload = {"agent": "codex", "agent_kind": "codex_app_server", "phase": phase}
        if task_type is not None:
            payload["task_type"] = task_type
        with open(LOG_PATH, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(payload, ensure_ascii=False) + "\\n")

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
            elif "issue_result.json" in text:
                phase = "issue"
                write_json(".symphony/issue_result.json", REVIEW)
            else:
                sys.exit(7)

            append_run(phase, REVIEW.get("task_type") if phase == "issue" else None)
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
            "goal" => "Verify implementation/review issue nodes receive root workspace context",
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
            elif "issue_result.json" in text and not ("\\\"task_type\\\": \\\"review\\\"" in text or "Review issue" in text):
                phase = "issue"
                prompt_contains_root_workspace = ROOT_WORKSPACE in text
                target = os.path.join(ROOT_WORKSPACE, "ROOT_WORKSPACE_PROBE.md")
                os.makedirs(ROOT_WORKSPACE, exist_ok=True)
                with open(target, "w", encoding="utf-8") as handle:
                    handle.write("probe ok\\n")
                write_json(".symphony/issue_result.json", {
                    "schema_version": 1,
                    "node_key": "implementation",
                    "task_type": "implementation",
                    "outcome": "completed",
                    "summary": "execution saw root workspace context",
                    "evidence": [target],
                    "decisions": ["root workspace handoff available"],
                    "open_questions": []
                })
                append_run({
                    "phase": phase,
                    "task_type": "implementation",
                    "prompt_contains_root_workspace": prompt_contains_root_workspace,
                    "writable_roots": writable_roots,
                    "target": target
                })
            elif "issue_result.json" in text:
                phase = "issue"
                prompt_contains_root_workspace = ROOT_WORKSPACE in text
                target = os.path.join(ROOT_WORKSPACE, "ROOT_WORKSPACE_PROBE.md")
                exists = os.path.exists(target)
                write_json(".symphony/issue_result.json", {
                    "schema_version": 1,
                    "node_key": "final_review",
                    "task_type": "review",
                    "outcome": "pass" if prompt_contains_root_workspace and exists else "fail",
                    "reviews": ["__root_candidate__"],
                    "summary": "review saw root workspace context" if prompt_contains_root_workspace and exists else "review missing root workspace context",
                    "reason": "root workspace probe missing" if not (prompt_contains_root_workspace and exists) else "",
                    "evidence": [target],
                    "decisions": [],
                    "open_questions": []
                })
                append_run({
                    "phase": phase,
                    "task_type": "review",
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
