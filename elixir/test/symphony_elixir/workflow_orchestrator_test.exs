defmodule SymphonyElixir.WorkflowOrchestratorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Workflow.Artifacts
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

  test "planning phase 正常结束后物化 workflow plan 并释放 root claim" do
    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-orchestrator-planning-down-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      agents: %{codex: %{kind: "cli_run", command: "missing-codex-test-binary"}},
      routing: %{default_agent: "codex"},
      orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
    )

    root_issue = %Issue{
      id: "root-planning-down",
      identifier: "YQE-710",
      title: "需要规划",
      state: "In Progress"
    }

    workspace = Path.join(workspace_root, root_issue.identifier)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    File.write!(
      Artifacts.workflow_plan_path(workspace),
      Jason.encode!(%{
        "kind" => "direct_execution",
        "summary" => "任务可直接执行",
        "confidence" => "high"
      })
    )

    state = %{workflow_state() | claimed: MapSet.new([root_issue.id])}

    running_entry = running_entry(root_issue, workspace, :planning)

    updated_state =
      Orchestrator.handle_agent_down_for_test(:normal, state, root_issue.id, running_entry)

    assert MapSet.member?(updated_state.completed, root_issue.id)
    refute MapSet.member?(updated_state.claimed, root_issue.id)
    assert {:ok, registry} = Registry.load_by_root_identifier(root_issue.identifier)
    assert Registry.node(registry, "root")["status"] == "ready"
  end

  test "execution phase 正常结束后读取 completion packet 并排队 review" do
    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-orchestrator-execution-down-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      agents: %{codex: %{kind: "cli_run", command: "missing-codex-test-binary"}},
      routing: %{default_agent: "codex"},
      orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
    )

    issue = %Issue{
      id: "derived-execution-down",
      identifier: "YQE-711",
      title: "执行任务",
      state: "In Progress",
      url: "https://linear.app/yqeeqy/issue/YQE-711"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    workspace = Path.join(workspace_root, issue.identifier)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    File.write!(
      Artifacts.completion_packet_path(workspace),
      Jason.encode!(%{
        "outcome" => "completed",
        "summary" => "执行完成，等待 review",
        "evidence" => ["mix test workflow_orchestrator_test.exs"]
      })
    )

    state = %{workflow_state() | claimed: MapSet.new([issue.id])}
    running_entry = running_entry(issue, workspace, :execution)

    updated_state =
      Orchestrator.handle_agent_down_for_test(:normal, state, issue.id, running_entry)

    review_entry = updated_state.running[issue.id]

    on_exit(fn ->
      if is_map(review_entry) do
        pid = Map.get(review_entry, :pid)
        if is_pid(pid) and Process.alive?(pid), do: Process.exit(pid, :shutdown)
      end
    end)

    assert MapSet.member?(updated_state.completed, issue.id)
    assert %{workflow_phase: :review, agent_id: "codex"} = review_entry
    assert_receive {:memory_tracker_comment, "derived-execution-down", body}
    assert body =~ "Completion Packet"
  end

  test "review phase pass 后释放 claim 并推进下游 readiness" do
    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-orchestrator-review-down-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      agents: %{codex: %{kind: "cli_run", command: "missing-codex-test-binary"}},
      routing: %{default_agent: "codex"},
      orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
    )

    root_issue = %Issue{id: "root-review-down", identifier: "YQE-712", title: "root", state: "In Progress"}
    reviewed_issue = %Issue{id: "derived-review-down", identifier: "YQE-713", title: "调研", state: "In Progress"}
    waiting_issue = %Issue{id: "derived-after-review", identifier: "YQE-714", title: "实现", state: "Todo"}

    root_issue
    |> Registry.new_root()
    |> Registry.put_node("research", %{
      "node_key" => "research",
      "issue_id" => reviewed_issue.id,
      "issue_identifier" => reviewed_issue.identifier,
      "agent_id" => "codex",
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

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    workspace = Path.join(workspace_root, reviewed_issue.identifier)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    File.write!(
      Artifacts.review_decision_path(workspace),
      Jason.encode!(%{
        "decision" => "pass",
        "summary" => "可以进入实现",
        "confidence" => "high"
      })
    )

    state = %{workflow_state() | claimed: MapSet.new([reviewed_issue.id])}
    running_entry = running_entry(reviewed_issue, workspace, :review)

    updated_state =
      Orchestrator.handle_agent_down_for_test(:normal, state, reviewed_issue.id, running_entry)

    assert MapSet.member?(updated_state.completed, reviewed_issue.id)
    refute MapSet.member?(updated_state.claimed, reviewed_issue.id)
    refute Map.has_key?(updated_state.running, reviewed_issue.id)
    refute Map.has_key?(updated_state.blocked, reviewed_issue.id)
    assert Controller.issue_ready?(waiting_issue.id)
    assert_receive {:memory_tracker_comment, "derived-review-down", body}
    assert body =~ "Review Decision"
  end

  test "review phase needs_rework 后创建返工 issue 并释放当前 claim" do
    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-orchestrator-review-rework-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_terminal_states: ["Done"],
      workspace_root: workspace_root,
      agents: %{
        codex: %{kind: "cli_run", command: "missing-codex-test-binary"},
        mimocode: %{kind: "cli_run", command: "missing-mimo-test-binary"}
      },
      routing: %{default_agent: "codex"},
      orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
    )

    root_issue = %Issue{id: "root-review-rework", identifier: "YQE-716", title: "root", state: "In Progress"}

    reviewed_issue = %Issue{
      id: "derived-review-rework",
      identifier: "YQE-717",
      title: "实现",
      state: "In Progress",
      assignee_id: "worker-1",
      url: "https://linear.app/yqeeqy/issue/YQE-717"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [root_issue, reviewed_issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    root_issue
    |> Registry.new_root()
    |> Registry.put_node("implementation", %{
      "node_key" => "implementation",
      "issue_id" => reviewed_issue.id,
      "issue_identifier" => reviewed_issue.identifier,
      "agent_id" => "mimocode",
      "task_type" => "implementation",
      "workflow_semantics" => "executable",
      "status" => "ready",
      "dependencies" => [],
      "completion_packet" => %{
        "outcome" => "completed",
        "summary" => "实现了主体逻辑但缺少回归测试",
        "evidence" => ["mix test"]
      }
    })
    |> Map.put("status", "planning_complete")
    |> Registry.save!()

    workspace = Path.join(workspace_root, reviewed_issue.identifier)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    File.write!(
      Artifacts.review_decision_path(workspace),
      Jason.encode!(%{
        "decision" => "needs_rework",
        "summary" => "补齐失败路径测试后再验收",
        "confidence" => "high"
      })
    )

    state = %{workflow_state() | claimed: MapSet.new([reviewed_issue.id])}
    running_entry = running_entry(reviewed_issue, workspace, :review)

    updated_state =
      Orchestrator.handle_agent_down_for_test(:normal, state, reviewed_issue.id, running_entry)

    assert_receive {:memory_tracker_issue_created, %Issue{} = rework_issue}

    assert MapSet.member?(updated_state.completed, reviewed_issue.id)
    refute MapSet.member?(updated_state.claimed, reviewed_issue.id)
    refute Map.has_key?(updated_state.blocked, reviewed_issue.id)

    assert {:dispatch, metadata} = Orchestrator.workflow_dispatch_decision_for_test(rework_issue, updated_state)
    assert metadata.workflow_phase == :execution
    assert metadata.agent_id == "mimocode"
    assert metadata.workflow_context["rework_of"] == "implementation"
    assert metadata.workflow_context["review_summary"] == "补齐失败路径测试后再验收"

    issues = Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
    assert Enum.find(issues, &(&1.id == reviewed_issue.id)).state == "Done"
  end

  test "review phase needs_replan 后调度 root issue 重新 planning" do
    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-orchestrator-review-replan-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      agents: %{codex: %{kind: "cli_run", command: "missing-codex-test-binary"}},
      routing: %{default_agent: "codex"},
      orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
    )

    root_issue = %Issue{
      id: "root-review-replan",
      identifier: "YQE-720",
      title: "root",
      state: "In Progress",
      url: "https://linear.app/yqeeqy/issue/YQE-720"
    }

    reviewed_issue = %Issue{
      id: "derived-review-replan",
      identifier: "YQE-721",
      title: "实现",
      state: "In Progress",
      url: "https://linear.app/yqeeqy/issue/YQE-721"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [root_issue, reviewed_issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    root_issue
    |> Registry.new_root()
    |> Registry.put_node("implementation", %{
      "node_key" => "implementation",
      "issue_id" => reviewed_issue.id,
      "issue_identifier" => reviewed_issue.identifier,
      "agent_id" => "codex",
      "task_type" => "implementation",
      "workflow_semantics" => "executable",
      "status" => "ready",
      "dependencies" => [],
      "completion_packet" => %{
        "outcome" => "completed",
        "summary" => "实现路径被审查判定需要改计划",
        "evidence" => ["mix test"]
      }
    })
    |> Map.put("status", "planning_complete")
    |> Registry.save!()

    workspace = Path.join(workspace_root, reviewed_issue.identifier)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    File.write!(
      Artifacts.review_decision_path(workspace),
      Jason.encode!(%{
        "decision" => "needs_replan",
        "summary" => "需要重新拆分 root issue 的后续任务",
        "confidence" => "high"
      })
    )

    state =
      %{
        workflow_state()
        | claimed: MapSet.new([reviewed_issue.id, root_issue.id]),
          blocked: %{
            root_issue.id => %{
              issue_id: root_issue.id,
              identifier: root_issue.identifier,
              issue: root_issue,
              error: "workflow root issue is waiting on derived issues"
            }
          }
      }

    running_entry = running_entry(reviewed_issue, workspace, :review)

    updated_state =
      Orchestrator.handle_agent_down_for_test(:normal, state, reviewed_issue.id, running_entry)

    assert MapSet.member?(updated_state.completed, reviewed_issue.id)
    refute MapSet.member?(updated_state.claimed, reviewed_issue.id)
    refute MapSet.member?(updated_state.claimed, root_issue.id)
    refute Map.has_key?(updated_state.blocked, root_issue.id)

    refute Map.has_key?(updated_state.retry_attempts, reviewed_issue.id)
    assert retry = Map.fetch!(updated_state.retry_attempts, root_issue.id)
    assert retry.workflow_phase == :planning
    assert retry.workflow_root_issue_id == root_issue.identifier
    assert retry.agent_id == "codex"
    assert retry.error =~ "需要重新拆分 root issue 的后续任务"
    assert retry.workflow_context["replan_reason"] == "需要重新拆分 root issue 的后续任务"
    assert retry.workflow_context["reviewed_issue_id"] == reviewed_issue.id

    assert {:dispatch, metadata} = Orchestrator.workflow_dispatch_decision_for_test(root_issue, updated_state)
    assert metadata.workflow_phase == :planning
    assert metadata.workflow_context["replan_reason"] == "需要重新拆分 root issue 的后续任务"
  end

  test "planning phase 产出 needs_human_input 后阻塞 root issue 并保留明确原因" do
    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-orchestrator-human-input-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      agents: %{codex: %{kind: "cli_run", command: "missing-codex-test-binary"}},
      routing: %{default_agent: "codex"},
      orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
    )

    root_issue = %Issue{
      id: "root-human-input-down",
      identifier: "YQE-713",
      title: "信息不足",
      state: "In Progress"
    }

    workspace = Path.join(workspace_root, root_issue.identifier)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    File.write!(
      Artifacts.workflow_plan_path(workspace),
      Jason.encode!(%{
        "kind" => "needs_human_input",
        "summary" => "缺少验收标准",
        "confidence" => "low",
        "request" => "请补充验收标准"
      })
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    state = %{workflow_state() | claimed: MapSet.new([root_issue.id])}
    running_entry = running_entry(root_issue, workspace, :planning)

    updated_state =
      Orchestrator.handle_agent_down_for_test(:normal, state, root_issue.id, running_entry)

    assert MapSet.member?(updated_state.claimed, root_issue.id)
    assert blocked = Map.fetch!(updated_state.blocked, root_issue.id)
    assert blocked.workflow_phase == :planning
    assert blocked.workflow_root_issue_id == "YQE-713"
    assert blocked.error =~ "workflow needs human input"
    assert blocked.error =~ "请补充验收标准"
    assert_receive {:memory_tracker_comment, "root-human-input-down", body}
    assert body =~ "Needs Human Input"
  end

  test "direct execution root issue 使用普通路由进入 execution dispatch" do
    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-orchestrator-direct-#{System.unique_integer([:positive])}")

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
      id: "root-direct",
      identifier: "YQE-705",
      title: "可以直接执行的 root issue",
      state: "In Progress",
      url: "https://linear.app/yqeeqy/issue/YQE-705"
    }

    issue
    |> Registry.new_root()
    |> Registry.put_node("root", %{
      "node_key" => "root",
      "issue_id" => issue.id,
      "issue_identifier" => issue.identifier,
      "task_type" => "direct_execution",
      "workflow_semantics" => "executable",
      "status" => "ready",
      "dependencies" => []
    })
    |> Map.put("status", "planning_complete")
    |> Registry.save!()

    assert {:dispatch, metadata} = Orchestrator.workflow_dispatch_decision_for_test(issue, workflow_state())
    assert metadata.workflow_phase == :execution
    assert metadata.workflow_root_issue_id == "YQE-705"
    assert metadata.agent_id == nil
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

  defp running_entry(issue, workspace, workflow_phase) do
    %{
      identifier: issue.identifier,
      issue: issue,
      agent_id: "codex",
      agent_kind: "cli_run",
      worker_host: nil,
      workspace_path: workspace,
      workflow_phase: workflow_phase,
      workflow_context: %{},
      workflow_root_issue_id: issue.identifier,
      session_id: "session-for-test",
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0
    }
  end
end
