defmodule SymphonyElixir.WorkflowControllerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Workflow.Artifacts
  alias SymphonyElixir.Workflow.Controller
  alias SymphonyElixir.Workflow.Registry

  defmodule FailingTracker do
    def create_comment(_issue_id, _body), do: {:error, :comment_create_failed}
    def create_issue(attrs), do: SymphonyElixir.Tracker.Memory.create_issue(attrs)
  end

  defmodule FlakyCreateTracker do
    def create_comment(issue_id, body), do: SymphonyElixir.Tracker.Memory.create_comment(issue_id, body)

    def create_issue(attrs) do
      count = Process.get({__MODULE__, :create_count}, 0) + 1
      Process.put({__MODULE__, :create_count}, count)

      if count == Process.get({__MODULE__, :fail_at}) do
        {:error, :planned_create_failure}
      else
        SymphonyElixir.Tracker.Memory.create_issue(attrs)
      end
    end
  end

  test "mode direct_execution 仅落 root registry 且不创建派生 issue" do
    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-controller-direct-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    root_issue = %Issue{
      id: "root-1",
      identifier: "YQE-100",
      title: "直接执行的 root issue",
      description: "一次性处理即可",
      state: "In Progress",
      assignee_id: "worker-1"
    }

    workspace = Path.join(workspace_root, root_issue.identifier)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    File.write!(
      Artifacts.workflow_plan_path(workspace),
      Jason.encode!(%{
        "mode" => "direct_execution",
        "summary" => "任务足够简单，可直接执行",
        "confidence" => "high"
      })
    )

    assert {:ok, registry} = Controller.handle_planning_completion(root_issue, workspace)

    assert registry["root_issue_id"] == "root-1"
    assert registry["root_issue_identifier"] == "YQE-100"
    assert map_size(registry["nodes"]) == 1

    root_node =
      registry["nodes"]
      |> Map.values()
      |> List.first()

    assert root_node["issue_id"] == "root-1"
    assert root_node["issue_identifier"] == "YQE-100"
    assert root_node["status"] == "ready"

    refute_receive {:memory_tracker_issue_created, _}

    assert {:ok, persisted} = Registry.load_by_root_identifier("YQE-100")
    assert persisted["root_issue_identifier"] == "YQE-100"
  end

  test "issue_graph 会创建派生 issue、保存 registry readiness，并给 root 留规划摘要 comment" do
    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-controller-graph-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    root_issue = %Issue{
      id: "root-2",
      identifier: "YQE-200",
      title: "复杂 root issue",
      description: "需要先调研再实现",
      state: "In Progress",
      assignee_id: "worker-2"
    }

    workspace = Path.join(workspace_root, root_issue.identifier)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    File.write!(
      Artifacts.workflow_plan_path(workspace),
      Jason.encode!(%{
        "mode" => "issue_graph",
        "summary" => "先调研现有实现，再完成接入",
        "confidence" => "medium",
        "nodes" => [
          %{
            "node_key" => "research-1",
            "task_type" => "research",
            "title" => "调研 HTTP backend 现状",
            "goal" => "梳理可复用的接口和风险",
            "agent_id" => "codex",
            "instructions" => "检查 workflow、tracker、runner 的既有接缝",
            "evidence_expectations" => ["列出涉及文件", "给出约束与风险"]
          },
          %{
            "node_key" => "implementation-1",
            "task_type" => "implementation",
            "title" => "实现 planning materialization",
            "goal" => "按调研结果完成控制器物化逻辑",
            "agent_id" => "codex",
            "instructions" => "复用 registry 与 tracker",
            "evidence_expectations" => ["补齐测试", "记录验证命令"]
          }
        ],
        "edges" => [
          %{
            "from" => "research-1",
            "to" => "implementation-1",
            "kind" => "handoff",
            "handoff_summary" => "调研结论供实现任务消费"
          }
        ]
      })
    )

    assert {:ok, registry} = Controller.handle_planning_completion(root_issue, workspace)

    assert_receive {:memory_tracker_issue_created, %Issue{} = research_issue}
    assert_receive {:memory_tracker_issue_created, %Issue{} = implementation_issue}

    research_node = Registry.node(registry, "research-1")
    implementation_node = Registry.node(registry, "implementation-1")

    assert research_node["issue_id"] == research_issue.id
    assert research_node["issue_identifier"] == research_issue.identifier
    assert research_node["agent_id"] == "codex"
    assert research_node["status"] == "ready"

    assert implementation_node["issue_id"] == implementation_issue.id
    assert implementation_node["issue_identifier"] == implementation_issue.identifier
    assert implementation_node["agent_id"] == "codex"
    assert implementation_node["status"] == "waiting"

    assert Enum.any?(registry["edges"], fn edge ->
             edge["from"] == "research-1" and edge["to"] == "implementation-1"
           end)

    assert {:ok, persisted} = Registry.load_by_root_identifier("YQE-200")
    assert Registry.node(persisted, "research-1")["issue_id"] == research_issue.id
    assert Registry.node(persisted, "implementation-1")["issue_id"] == implementation_issue.id
    assert Registry.node(persisted, "implementation-1")["status"] == "waiting"

    assert_receive {:memory_tracker_comment, "root-2", comment_body}
    assert comment_body =~ "YQE-200"
    assert comment_body =~ "issue_graph"
    assert comment_body =~ research_issue.identifier
    assert comment_body =~ implementation_issue.identifier

    assert research_issue.description =~ "YQE-200"
    assert research_issue.description =~ "research-1"
    assert research_issue.description =~ "research"
    assert research_issue.description =~ "检查 workflow、tracker、runner 的既有接缝"

    assert implementation_issue.description =~ "YQE-200"
    assert implementation_issue.description =~ "implementation-1"
    assert implementation_issue.description =~ "implementation"
    assert implementation_issue.description =~ "调研结论供实现任务消费"
  end

  test "issue_graph 规划注释失败会向上返回错误" do
    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-controller-comment-fail-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
    )

    Application.put_env(:symphony_elixir, :tracker_adapter_override, FailingTracker)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :tracker_adapter_override) end)

    root_issue = %Issue{
      id: "root-3",
      identifier: "YQE-300",
      title: "注释失败 root issue",
      description: "验证错误传播",
      state: "In Progress",
      assignee_id: "worker-3"
    }

    workspace = Path.join(workspace_root, root_issue.identifier)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    File.write!(
      Artifacts.workflow_plan_path(workspace),
      Jason.encode!(%{
        "kind" => "issue_graph",
        "summary" => "需要派生任务",
        "confidence" => "medium",
        "nodes" => [
          %{
            "node_key" => "research-1",
            "task_type" => "research",
            "title" => "调研",
            "goal" => "收集证据",
            "agent_id" => "codex"
          }
        ],
        "edges" => []
      })
    )

    assert {:error, :comment_create_failed} =
             Controller.handle_planning_completion(root_issue, workspace)
  end

  test "issue_graph 会保留所有入边 handoff summary" do
    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-controller-handoff-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
    )

    root_issue = %Issue{
      id: "root-4",
      identifier: "YQE-400",
      title: "多入边 root issue",
      description: "验证多个 handoff",
      state: "In Progress",
      assignee_id: "worker-4"
    }

    workspace = Path.join(workspace_root, root_issue.identifier)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    File.write!(
      Artifacts.workflow_plan_path(workspace),
      Jason.encode!(%{
        "kind" => "issue_graph",
        "summary" => "需要汇总多个交接",
        "confidence" => "medium",
        "nodes" => [
          %{"node_key" => "research-1", "task_type" => "research", "title" => "调研 A", "goal" => "A", "agent_id" => "codex"},
          %{"node_key" => "research-2", "task_type" => "research", "title" => "调研 B", "goal" => "B", "agent_id" => "codex"},
          %{"node_key" => "implementation-1", "task_type" => "implementation", "title" => "实现", "goal" => "C", "agent_id" => "codex"}
        ],
        "edges" => [
          %{"from" => "research-1", "to" => "implementation-1", "kind" => "handoff", "handoff_summary" => "第一条交接"},
          %{"from" => "research-2", "to" => "implementation-1", "kind" => "handoff", "handoff_summary" => "第二条交接"}
        ]
      })
    )

    assert {:ok, registry} = Controller.handle_planning_completion(root_issue, workspace)

    node = Registry.node(registry, "implementation-1")

    assert List.wrap(node["handoff"]) |> Enum.join("\n") =~ "第一条交接"
    assert List.wrap(node["handoff"]) |> Enum.join("\n") =~ "第二条交接"
    assert node["status"] == "waiting"
  end

  test "issue_graph 规划引用不存在的 node 时应失败且不创建派生 issue" do
    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-controller-bad-edge-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
    )

    root_issue = %Issue{
      id: "root-5",
      identifier: "YQE-500",
      title: "坏边 root issue",
      description: "验证前置校验",
      state: "In Progress",
      assignee_id: "worker-5"
    }

    workspace = Path.join(workspace_root, root_issue.identifier)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    File.write!(
      Artifacts.workflow_plan_path(workspace),
      Jason.encode!(%{
        "kind" => "issue_graph",
        "summary" => "边引用错误",
        "confidence" => "medium",
        "nodes" => [
          %{"node_key" => "research-1", "task_type" => "research", "title" => "调研", "goal" => "A", "agent_id" => "codex"},
          %{"node_key" => "implementation-1", "task_type" => "implementation", "title" => "实现", "goal" => "B", "agent_id" => "codex"}
        ],
        "edges" => [
          %{"from" => "ghost-1", "to" => "implementation-1", "kind" => "handoff", "handoff_summary" => "不存在的上游"}
        ]
      })
    )

    assert {:error, {:invalid_workflow_plan_edge_reference, _details}} =
             Controller.handle_planning_completion(root_issue, workspace)

    refute_receive {:memory_tracker_issue_created, _}
    refute_receive {:memory_tracker_comment, _, _}
  end

  test "issue_graph 创建中途失败后重试会复用已保存的 node 映射" do
    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-controller-retry-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :tracker_adapter_override, FlakyCreateTracker)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :tracker_adapter_override)
      Process.delete({FlakyCreateTracker, :create_count})
      Process.delete({FlakyCreateTracker, :fail_at})
    end)

    root_issue = %Issue{
      id: "root-6",
      identifier: "YQE-600",
      title: "可恢复规划 root issue",
      description: "验证派生 issue 幂等创建",
      state: "In Progress",
      assignee_id: "worker-6"
    }

    workspace = Path.join(workspace_root, root_issue.identifier)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    File.write!(
      Artifacts.workflow_plan_path(workspace),
      Jason.encode!(%{
        "kind" => "issue_graph",
        "summary" => "创建第二个节点时失败，重试应复用第一个节点",
        "confidence" => "medium",
        "nodes" => [
          %{"node_key" => "research-1", "task_type" => "research", "title" => "调研", "goal" => "A", "agent_id" => "codex"},
          %{"node_key" => "implementation-1", "task_type" => "implementation", "title" => "实现", "goal" => "B", "agent_id" => "codex"}
        ],
        "edges" => [
          %{"from" => "research-1", "to" => "implementation-1", "kind" => "handoff", "handoff_summary" => "调研后实现"}
        ]
      })
    )

    Process.put({FlakyCreateTracker, :create_count}, 0)
    Process.put({FlakyCreateTracker, :fail_at}, 2)

    assert {:error, :planned_create_failure} =
             Controller.handle_planning_completion(root_issue, workspace)

    assert_receive {:memory_tracker_issue_created, %Issue{} = first_issue}
    refute_receive {:memory_tracker_issue_created, _}

    assert {:ok, partial_registry} = Registry.load_by_root_identifier("YQE-600")
    assert Registry.node(partial_registry, "research-1")["issue_id"] == first_issue.id
    refute Registry.node(partial_registry, "implementation-1")

    Process.put({FlakyCreateTracker, :fail_at}, nil)

    assert {:ok, registry} = Controller.handle_planning_completion(root_issue, workspace)

    assert_receive {:memory_tracker_issue_created, %Issue{} = second_issue}
    refute_receive {:memory_tracker_issue_created, _}
    assert_receive {:memory_tracker_comment, "root-6", _comment_body}

    assert Registry.node(registry, "research-1")["issue_id"] == first_issue.id
    assert Registry.node(registry, "implementation-1")["issue_id"] == second_issue.id

    assert Enum.count(Application.get_env(:symphony_elixir, :memory_tracker_issues, [])) == 2
  end
end
