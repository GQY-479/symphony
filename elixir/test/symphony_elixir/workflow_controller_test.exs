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

  defp write_issue_result!(workspace, result) do
    File.write!(Artifacts.issue_result_path(workspace), Jason.encode!(result))
  end

  defp issue_result(node_key, task_type, summary, overrides) do
    Map.merge(
      %{
        "schema_version" => 1,
        "node_key" => node_key,
        "task_type" => task_type,
        "outcome" => "completed",
        "summary" => summary,
        "evidence" => ["mix test"],
        "decisions" => [],
        "open_questions" => []
      },
      overrides
    )
  end

  defp review_result(node_key, reviews, outcome, summary, overrides \\ %{}) do
    issue_result(node_key, "review", summary, Map.merge(%{"outcome" => outcome, "reviews" => reviews}, overrides))
  end

  test "mode direct_execution materializes root node and final review" do
    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-controller-direct-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

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
    assert map_size(registry["nodes"]) == 2

    root_node = Registry.node(registry, "root")
    assert root_node["issue_id"] == "root-1"
    assert root_node["issue_identifier"] == "YQE-100"
    assert root_node["status"] == "ready"
    assert root_node["agent_id"] == nil
    assert root_node["task_type"] == "direct_execution"

    assert_receive {:memory_tracker_issue_created, %Issue{} = final_review_issue}

    final_review = Registry.node(registry, "final_review")
    assert final_review["issue_id"] == final_review_issue.id
    assert final_review["task_type"] == "review"
    assert final_review["status"] == "waiting"
    assert final_review["dependencies"] == ["root"]
    assert final_review["reviews"] == ["__root_candidate__"]
    assert final_review["subject_selector"] == %{"type" => "final_candidate_range"}

    assert Enum.any?(registry["edges"], fn edge ->
             edge["from"] == "root" and edge["to"] == "final_review"
           end)

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

  test "issue_graph materialization auto creates final review when missing" do
    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-controller-final-review-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    root_issue = %Issue{id: "root-final-review", identifier: "YQE-FINAL", title: "root", state: "In Progress"}
    workspace = Path.join(workspace_root, root_issue.identifier)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    File.write!(
      Artifacts.workflow_plan_path(workspace),
      Jason.encode!(%{
        "kind" => "issue_graph",
        "summary" => "只有实现节点",
        "confidence" => "high",
        "nodes" => [
          %{
            "node_key" => "implementation",
            "task_type" => "implementation",
            "title" => "实现",
            "goal" => "实现功能",
            "agent_id" => "codex"
          }
        ],
        "edges" => []
      })
    )

    assert {:ok, registry} = Controller.handle_planning_completion(root_issue, workspace)

    assert Registry.node(registry, "final_review")["task_type"] == "review"
    assert Registry.node(registry, "final_review")["reviews"] == ["__root_candidate__"]
    assert Registry.node(registry, "final_review")["subject_selector"] == %{"type" => "final_candidate_range"}

    assert Enum.any?(registry["edges"], fn edge ->
             edge["from"] == "implementation" and edge["to"] == "final_review"
           end)
  end

  test "auto final review depends on existing review leaves" do
    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-controller-final-after-review-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    root_issue = %Issue{id: "root-final-after-review", identifier: "YQE-FINAL-AFTER", title: "root", state: "In Progress"}
    workspace = Path.join(workspace_root, root_issue.identifier)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    File.write!(
      Artifacts.workflow_plan_path(workspace),
      Jason.encode!(%{
        "kind" => "issue_graph",
        "summary" => "实现后审查",
        "confidence" => "high",
        "nodes" => [
          %{
            "node_key" => "implementation",
            "task_type" => "implementation",
            "title" => "实现",
            "goal" => "实现功能",
            "agent_id" => "codex"
          },
          %{
            "node_key" => "implementation_review",
            "task_type" => "review",
            "title" => "审查实现",
            "goal" => "审查实现结果",
            "agent_id" => "codex",
            "reviews" => ["implementation"],
            "subject_selector" => %{"type" => "candidate_range"}
          }
        ],
        "edges" => [%{"from" => "implementation", "to" => "implementation_review"}]
      })
    )

    assert {:ok, registry} = Controller.handle_planning_completion(root_issue, workspace)

    assert Enum.any?(registry["edges"], fn edge ->
             edge["from"] == "implementation_review" and edge["to"] == "final_review"
           end)

    refute Enum.any?(registry["edges"], fn edge ->
             edge["from"] == "implementation" and edge["to"] == "final_review"
           end)
  end

  test "issue_graph plan comment shows dependency relationships and completion conditions" do
    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-controller-deps-comment-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    root_issue = %Issue{
      id: "root-deps-comment",
      identifier: "YQE-DEPS-COMMENT",
      title: "依赖关系测试 root issue",
      state: "In Progress",
      assignee_id: "worker-deps"
    }

    workspace = Path.join(workspace_root, root_issue.identifier)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    File.write!(
      Artifacts.workflow_plan_path(workspace),
      Jason.encode!(%{
        "kind" => "issue_graph",
        "summary" => "验证依赖关系和完成条件在注释中显示",
        "confidence" => "high",
        "nodes" => [
          %{
            "node_key" => "research",
            "task_type" => "research",
            "title" => "调研",
            "goal" => "收集设计证据",
            "agent_id" => "codex",
            "completion_conditions" => ["调研文档已创建", "风险已识别"]
          },
          %{
            "node_key" => "implementation",
            "task_type" => "implementation",
            "title" => "实现",
            "goal" => "根据调研结果实现",
            "agent_id" => "codex",
            "completion_conditions" => ["测试通过", "文档更新"]
          }
        ],
        "edges" => [%{"from" => "research", "to" => "implementation"}]
      })
    )

    assert {:ok, _registry} = Controller.handle_planning_completion(root_issue, workspace)

    assert_receive {:memory_tracker_comment, "root-deps-comment", comment_body}
    assert comment_body =~ "Dependencies (edges):"
    assert comment_body =~ "research -> implementation"
    assert comment_body =~ "(depends on: research)"
    assert comment_body =~ "(completion: 测试通过; 文档更新)"
  end

  test "issue_graph 派生 issue 会继承 root labels 以满足 required_labels 调度" do
    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-controller-labels-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_required_labels: ["symphony-local-test"],
      workspace_root: workspace_root,
      orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    root_issue = %Issue{
      id: "root-labels",
      identifier: "YQE-LABELS",
      title: "带标签的 root issue",
      state: "In Progress",
      labels: ["symphony-local-test", "agent:mimo"]
    }

    workspace = Path.join(workspace_root, root_issue.identifier)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    File.write!(
      Artifacts.workflow_plan_path(workspace),
      Jason.encode!(%{
        "kind" => "issue_graph",
        "summary" => "验证派生 issue 可继续被 required_labels 选中",
        "confidence" => "high",
        "nodes" => [
          %{
            "node_key" => "implementation",
            "task_type" => "implementation",
            "title" => "继承标签的派生任务",
            "goal" => "证明派生任务可调度",
            "agent_id" => "codex"
          }
        ],
        "edges" => []
      })
    )

    assert {:ok, _registry} = Controller.handle_planning_completion(root_issue, workspace)

    assert_receive {:memory_tracker_issue_created, %Issue{} = derived_issue}

    assert "symphony-local-test" in derived_issue.labels
    assert "agent:mimo" in derived_issue.labels
    assert Issue.routable?(derived_issue, Config.settings!().tracker.required_labels)

    assert_receive {:memory_tracker_comment, "root-labels", _comment}
  end

  test "issue_graph 派生 issue 会继承 root 的 Linear project/team 上下文" do
    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-controller-context-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    root_issue = %Issue{
      id: "root-context",
      identifier: "YQE-CONTEXT",
      title: "带 Linear 上下文的 root issue",
      state: "In Progress",
      assignee_id: "worker-1",
      project_id: "project-root",
      team_id: "team-root",
      labels: ["symphony-local-test"]
    }

    workspace = Path.join(workspace_root, root_issue.identifier)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    File.write!(
      Artifacts.workflow_plan_path(workspace),
      Jason.encode!(%{
        "kind" => "issue_graph",
        "summary" => "验证派生 issue 使用 root Linear 上下文",
        "confidence" => "high",
        "nodes" => [
          %{
            "node_key" => "implementation",
            "task_type" => "implementation",
            "title" => "继承 Linear 上下文的派生任务",
            "goal" => "证明派生任务创建时使用同一 project/team",
            "agent_id" => "codex"
          }
        ],
        "edges" => []
      })
    )

    assert {:ok, _registry} = Controller.handle_planning_completion(root_issue, workspace)
    assert_receive {:memory_tracker_issue_created, %Issue{} = derived_issue}

    assert derived_issue.project_id == "project-root"
    assert derived_issue.team_id == "team-root"
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

    assert {:error, :invalid_workflow_plan} =
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
    assert_receive {:memory_tracker_issue_created, %Issue{} = final_review_issue}
    refute_receive {:memory_tracker_issue_created, _}
    assert_receive {:memory_tracker_comment, "root-6", _comment_body}

    assert Registry.node(registry, "research-1")["issue_id"] == first_issue.id
    assert Registry.node(registry, "implementation-1")["issue_id"] == second_issue.id
    assert Registry.node(registry, "final_review")["issue_id"] == final_review_issue.id
    assert Registry.node(registry, "final_review")["dependencies"] == ["implementation-1"]

    assert Enum.count(Application.get_env(:symphony_elixir, :memory_tracker_issues, [])) == 3
  end

  test "dispatch metadata uses root workspace path without running workspace hooks" do
    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-controller-root-workspace-#{System.unique_integer([:positive])}")

    hook_marker = Path.join(workspace_root, "after-create-hook-ran")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      hook_after_create: "touch #{hook_marker}",
      orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
    )

    root_issue = %Issue{id: "root-workspace", identifier: "YQE-ROOT-WS", title: "Root workspace", state: "In Progress"}
    derived_issue = %Issue{id: "derived-workspace", identifier: "YQE-DERIVED-WS", title: "Derived workspace", state: "Todo"}

    root_issue
    |> Registry.new_root()
    |> Registry.put_node("implementation", %{
      "node_key" => "implementation",
      "issue_id" => derived_issue.id,
      "issue_identifier" => derived_issue.identifier,
      "agent_id" => "codex",
      "task_type" => "implementation",
      "workflow_semantics" => "executable",
      "status" => "ready",
      "dependencies" => []
    })
    |> Map.put("status", "planning_complete")
    |> Registry.save!()

    assert {:ok, metadata} = Controller.issue_dispatch_metadata(derived_issue.id)

    assert metadata.workflow_context["root_workspace"] == Path.join(workspace_root, root_issue.identifier)
    refute File.exists?(hook_marker)
  end

  test "dispatch metadata normalizes root workspace identifier without creating workspace" do
    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-controller-root-workspace-safe-#{System.unique_integer([:positive])}")

    hook_marker = Path.join(workspace_root, "after-create-hook-ran")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      hook_after_create: "touch #{hook_marker}",
      orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
    )

    root_issue = %Issue{id: "root-workspace-safe", identifier: "YQE-ROOT-SAFE", title: "Root workspace", state: "In Progress"}
    derived_issue = %Issue{id: "derived-workspace-safe", identifier: "YQE-DERIVED-SAFE", title: "Derived workspace", state: "Todo"}

    registry =
      root_issue
      |> Registry.new_root()
      |> Map.put("root_issue_identifier", "../ROOT/1")
      |> Registry.put_node("implementation", %{
        "node_key" => "implementation",
        "issue_id" => derived_issue.id,
        "issue_identifier" => derived_issue.identifier,
        "agent_id" => "codex",
        "task_type" => "implementation",
        "workflow_semantics" => "executable",
        "status" => "ready",
        "dependencies" => []
      })
      |> Map.put("status", "planning_complete")

    registry_path = Registry.registry_path(root_issue.identifier)
    File.mkdir_p!(Path.dirname(registry_path))
    File.write!(registry_path, Jason.encode!(registry))

    assert {:ok, metadata} = Controller.issue_dispatch_metadata(derived_issue.id)

    expected_workspace = Path.join(workspace_root, ".._ROOT_1")
    assert metadata.workflow_context["root_workspace"] == expected_workspace
    assert String.starts_with?(metadata.workflow_context["root_workspace"], Path.expand(workspace_root) <> "/")
    refute File.exists?(expected_workspace)
    refute File.exists?(hook_marker)
  end

  test "issue completion stores issue result and unlocks downstream nodes" do
    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-controller-issue-result-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    root_issue = %Issue{id: "root-result", identifier: "YQE-RESULT", title: "root", state: "In Progress"}
    issue = %Issue{id: "derived-result", identifier: "YQE-RESULT-1", title: "调研", state: "In Progress"}
    downstream = %Issue{id: "derived-result-2", identifier: "YQE-RESULT-2", title: "实现", state: "Todo"}

    root_issue
    |> Registry.new_root()
    |> Registry.put_node("research", %{
      "node_key" => "research",
      "issue_id" => issue.id,
      "issue_identifier" => issue.identifier,
      "agent_id" => "codex",
      "task_type" => "research",
      "workflow_semantics" => "executable",
      "status" => "ready",
      "dependencies" => []
    })
    |> Registry.put_node("implementation", %{
      "node_key" => "implementation",
      "issue_id" => downstream.id,
      "issue_identifier" => downstream.identifier,
      "agent_id" => "codex",
      "task_type" => "implementation",
      "workflow_semantics" => "executable",
      "status" => "waiting",
      "dependencies" => ["research"]
    })
    |> Map.put("status", "planning_complete")
    |> Registry.save!()

    workspace = Path.join(workspace_root, issue.identifier)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    File.write!(
      Artifacts.issue_result_path(workspace),
      Jason.encode!(%{
        "schema_version" => 1,
        "node_key" => "research",
        "task_type" => "research",
        "outcome" => "completed",
        "summary" => "调研完成",
        "evidence" => ["research.md"],
        "decisions" => [],
        "open_questions" => []
      })
    )

    assert {:ok, {:completed, "derived-result"}} = Controller.handle_issue_completion(issue, workspace)
    assert {:ok, registry} = Registry.load_by_root_identifier(root_issue.identifier)
    assert Registry.node(registry, "research")["status"] == "completed"
    assert Registry.node(registry, "research")["issue_result"]["summary"] == "调研完成"
    assert Registry.node(registry, "implementation")["status"] == "ready"
  end

  test "review issue result pass accepts subject and unlocks downstream nodes" do
    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-controller-review-result-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_terminal_states: ["Closed"],
      workspace_root: workspace_root,
      orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    root_issue = %Issue{id: "root-review-result", identifier: "YQE-REVIEW-ROOT", title: "root", state: "In Progress"}

    implementation_issue = %Issue{
      id: "impl-review-result",
      identifier: "YQE-REVIEW-1",
      title: "实现",
      state: "Closed"
    }

    review_issue = %Issue{
      id: "review-result",
      identifier: "YQE-REVIEW-2",
      title: "审查实现",
      state: "In Progress"
    }

    downstream_issue = %Issue{
      id: "downstream-review-result",
      identifier: "YQE-REVIEW-3",
      title: "下游",
      state: "Todo"
    }

    root_issue
    |> Registry.new_root()
    |> Registry.put_node("implementation", %{
      "node_key" => "implementation",
      "issue_id" => implementation_issue.id,
      "issue_identifier" => implementation_issue.identifier,
      "agent_id" => "codex",
      "task_type" => "implementation",
      "workflow_semantics" => "executable",
      "status" => "completed",
      "dependencies" => [],
      "issue_result" => %{"summary" => "实现完成"}
    })
    |> Registry.put_node("implementation_review", %{
      "node_key" => "implementation_review",
      "issue_id" => review_issue.id,
      "issue_identifier" => review_issue.identifier,
      "agent_id" => "codex",
      "task_type" => "review",
      "workflow_semantics" => "executable",
      "status" => "ready",
      "dependencies" => ["implementation"],
      "reviews" => ["implementation"],
      "subject_selector" => %{
        "type" => "candidate_range",
        "from" => "implementation.candidate_before_sha",
        "to" => "implementation.candidate_after_sha"
      }
    })
    |> Registry.put_node("downstream", %{
      "node_key" => "downstream",
      "issue_id" => downstream_issue.id,
      "issue_identifier" => downstream_issue.identifier,
      "agent_id" => "codex",
      "task_type" => "implementation",
      "workflow_semantics" => "executable",
      "status" => "waiting",
      "dependencies" => ["implementation_review"]
    })
    |> Registry.put_subject("subject-implementation", %{
      "type" => "candidate_range",
      "base_sha" => "base",
      "head_sha" => "head",
      "paths" => [],
      "status" => "pending"
    })
    |> Map.put("status", "planning_complete")
    |> Registry.save!()

    workspace = Path.join(workspace_root, review_issue.identifier)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    File.write!(
      Artifacts.issue_result_path(workspace),
      Jason.encode!(%{
        "schema_version" => 1,
        "node_key" => "implementation_review",
        "task_type" => "review",
        "outcome" => "pass",
        "reviews" => ["implementation"],
        "summary" => "审查通过",
        "evidence" => ["mix test"],
        "decisions" => [],
        "open_questions" => []
      })
    )

    assert {:ok, {:completed, "review-result"}} = Controller.handle_issue_completion(review_issue, workspace)

    assert {:ok, registry} = Registry.load_by_root_identifier(root_issue.identifier)
    assert Registry.node(registry, "implementation_review")["status"] == "completed"
    assert Registry.node(registry, "downstream")["status"] == "ready"
    assert registry["reviews"]["implementation_review"]["status"] == "accepted"
  end

  test "review issue result needs_rework targets the reviewed node" do
    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-controller-review-result-rework-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    root_issue = %Issue{id: "root-review-result-rework", identifier: "YQE-REVIEW-REWORK", title: "root", state: "In Progress"}
    implementation_issue = %Issue{id: "impl-review-result-rework", identifier: "YQE-REVIEW-REWORK-1", title: "实现", state: "Closed"}
    review_issue = %Issue{id: "review-result-rework", identifier: "YQE-REVIEW-REWORK-2", title: "审查实现", state: "In Progress"}
    downstream_issue = %Issue{id: "downstream-review-result-rework", identifier: "YQE-REVIEW-REWORK-3", title: "下游", state: "Todo"}

    root_issue
    |> Registry.new_root()
    |> Registry.put_node("implementation", %{
      "node_key" => "implementation",
      "issue_id" => implementation_issue.id,
      "issue_identifier" => implementation_issue.identifier,
      "agent_id" => "codex",
      "task_type" => "implementation",
      "workflow_semantics" => "executable",
      "status" => "completed",
      "dependencies" => [],
      "issue_result" => %{
        "summary" => "实现完成",
        "evidence" => ["mix test"]
      }
    })
    |> Registry.put_node("implementation_review", %{
      "node_key" => "implementation_review",
      "issue_id" => review_issue.id,
      "issue_identifier" => review_issue.identifier,
      "agent_id" => "codex",
      "task_type" => "review",
      "workflow_semantics" => "executable",
      "status" => "ready",
      "dependencies" => ["implementation"],
      "reviews" => ["implementation"],
      "subject_selector" => %{"type" => "candidate_range"}
    })
    |> Registry.put_node("downstream", %{
      "node_key" => "downstream",
      "issue_id" => downstream_issue.id,
      "issue_identifier" => downstream_issue.identifier,
      "agent_id" => "codex",
      "task_type" => "verification",
      "workflow_semantics" => "executable",
      "status" => "waiting",
      "dependencies" => ["implementation_review"]
    })
    |> Registry.add_edge(%{"from" => "implementation_review", "to" => "downstream", "kind" => "handoff"})
    |> Map.put("status", "planning_complete")
    |> Registry.save!()

    workspace = Path.join(workspace_root, review_issue.identifier)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    File.write!(
      Artifacts.issue_result_path(workspace),
      Jason.encode!(%{
        "schema_version" => 1,
        "node_key" => "implementation_review",
        "task_type" => "review",
        "outcome" => "needs_rework",
        "reviews" => ["implementation"],
        "summary" => "需要补齐失败场景",
        "reason" => "缺少失败场景测试",
        "evidence" => ["mix test"],
        "decisions" => [],
        "open_questions" => []
      })
    )

    assert {:ok, {:needs_rework, "review-result-rework", "需要补齐失败场景"}} =
             Controller.handle_issue_completion(review_issue, workspace)

    assert_receive {:memory_tracker_issue_created, %Issue{} = rework_issue}

    assert {:ok, registry} = Registry.load_by_root_identifier(root_issue.identifier)
    original_node = Registry.node(registry, "implementation")
    review_node = Registry.node(registry, "implementation_review")
    rework_node = Registry.node(registry, "implementation-rework-1")

    assert original_node["status"] == "superseded"
    assert original_node["superseded_by"] == "implementation-rework-1"
    assert review_node["status"] == "superseded"
    assert review_node["review_summary"] == "需要补齐失败场景"
    assert rework_node["issue_id"] == rework_issue.id
    assert rework_node["task_type"] == "implementation"
    assert rework_node["rework_of"] == "implementation"
    assert Registry.node(registry, "implementation_review-rework-1") == nil
  end

  test "review issue completion 读取 issue result、回写评论并完成 issue" do
    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-controller-review-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    issue = %Issue{
      id: "derived-review",
      identifier: "YQE-801",
      title: "审查任务",
      state: "In Progress"
    }

    workspace = Path.join(workspace_root, issue.identifier)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    write_issue_result!(
      workspace,
      review_result("implementation_review", ["implementation"], "pass", "实现满足当前 Task 7 的最小验收要求")
    )

    assert {:ok, {:completed, "derived-review"}} =
             Controller.handle_issue_completion(issue, workspace)

    assert_receive {:memory_tracker_comment, "derived-review", body}
    assert body =~ "Issue Result"
    assert body =~ "pass"
    assert body =~ "实现满足当前 Task 7"
  end

  test "review issue needs_rework 会创建返工 issue 并让下游等待返工节点" do
    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-controller-review-rework-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    root_issue = %Issue{id: "root-rework", identifier: "YQE-813", title: "root", state: "In Progress"}
    reviewed_issue = %Issue{id: "derived-rework-reviewed", identifier: "YQE-814", title: "实现任务", state: "Closed"}
    review_issue = %Issue{id: "derived-rework-review", identifier: "YQE-814-R", title: "审查实现任务", state: "In Progress"}
    waiting_issue = %Issue{id: "derived-rework-waiting", identifier: "YQE-815", title: "审查后续任务", state: "Todo"}

    root_issue
    |> Registry.new_root()
    |> Registry.put_node("implementation", %{
      "node_key" => "implementation",
      "issue_id" => reviewed_issue.id,
      "issue_identifier" => reviewed_issue.identifier,
      "agent_id" => "mimocode",
      "task_type" => "implementation",
      "workflow_semantics" => "executable",
      "status" => "completed",
      "dependencies" => [],
      "issue_result" => %{
        "schema_version" => 1,
        "node_key" => "implementation",
        "task_type" => "implementation",
        "outcome" => "completed",
        "summary" => "实现了接口，但缺少错误处理",
        "evidence" => ["mix test"],
        "decisions" => ["提交接口实现供审查"],
        "open_questions" => []
      }
    })
    |> Registry.put_node("implementation_review", %{
      "node_key" => "implementation_review",
      "issue_id" => review_issue.id,
      "issue_identifier" => review_issue.identifier,
      "agent_id" => "codex",
      "task_type" => "review",
      "workflow_semantics" => "executable",
      "status" => "ready",
      "dependencies" => ["implementation"],
      "reviews" => ["implementation"],
      "subject_selector" => %{"type" => "candidate_range"}
    })
    |> Registry.put_node("verification", %{
      "node_key" => "verification",
      "issue_id" => waiting_issue.id,
      "issue_identifier" => waiting_issue.identifier,
      "agent_id" => "codex",
      "task_type" => "verification",
      "workflow_semantics" => "executable",
      "status" => "waiting",
      "dependencies" => ["implementation_review"]
    })
    |> Registry.add_edge(%{"from" => "implementation_review", "to" => "verification", "kind" => "handoff"})
    |> Map.put("status", "planning_complete")
    |> Registry.save!()

    workspace = Path.join(workspace_root, review_issue.identifier)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    write_issue_result!(
      workspace,
      review_result(
        "implementation_review",
        ["implementation"],
        "needs_rework",
        "缺少失败场景处理，需要补齐测试和实现",
        %{"confidence" => "high", "reason" => "缺少失败场景处理"}
      )
    )

    assert {:ok, {:needs_rework, "derived-rework-review", "缺少失败场景处理，需要补齐测试和实现"}} =
             Controller.handle_issue_completion(review_issue, workspace)

    assert_receive {:memory_tracker_issue_created, %Issue{} = rework_issue}

    assert {:ok, registry} = Registry.load_by_root_identifier(root_issue.identifier)
    original_node = Registry.node(registry, "implementation")
    review_node = Registry.node(registry, "implementation_review")
    rework_node = Registry.node(registry, "implementation-rework-1")
    downstream_node = Registry.node(registry, "verification")

    assert original_node["status"] == "superseded"
    assert original_node["workflow_semantics"] == "superseded"
    assert original_node["superseded_by"] == "implementation-rework-1"
    assert review_node["status"] == "superseded"

    assert rework_node["issue_id"] == rework_issue.id
    assert rework_node["issue_identifier"] == rework_issue.identifier
    assert rework_node["agent_id"] == "mimocode"
    assert rework_node["task_type"] == "implementation"
    assert rework_node["status"] == "ready"
    assert rework_node["rework_of"] == "implementation"
    assert rework_node["review_summary"] == "缺少失败场景处理，需要补齐测试和实现"
    assert rework_node["previous_issue_result"]["summary"] == "实现了接口，但缺少错误处理"

    assert downstream_node["dependencies"] == ["implementation-rework-1"]
    assert Controller.issue_ready?(rework_issue.id)
    refute Controller.issue_ready?(waiting_issue.id)
    assert rework_issue.description =~ "缺少失败场景处理"
    assert rework_issue.description =~ review_issue.identifier
  end

  test "review issue needs_rework 创建的返工 issue 会继承 review issue labels" do
    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-controller-rework-labels-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_required_labels: ["symphony-local-test"],
      workspace_root: workspace_root,
      orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    root_issue = %Issue{id: "root-rework-labels", identifier: "YQE-REWORK-LABELS", title: "root", state: "In Progress"}

    reviewed_issue = %Issue{
      id: "derived-rework-labels-reviewed",
      identifier: "YQE-REWORK-LABELS-1",
      title: "实现任务",
      state: "Closed"
    }

    review_issue = %Issue{
      id: "derived-rework-labels-review",
      identifier: "YQE-REWORK-LABELS-2",
      title: "审查实现任务",
      state: "In Progress",
      labels: ["symphony-local-test", "agent:mimo"]
    }

    root_issue
    |> Registry.new_root()
    |> Registry.put_node("implementation", %{
      "node_key" => "implementation",
      "issue_id" => reviewed_issue.id,
      "issue_identifier" => reviewed_issue.identifier,
      "agent_id" => "mimocode",
      "task_type" => "implementation",
      "workflow_semantics" => "executable",
      "status" => "completed",
      "dependencies" => [],
      "issue_result" => %{
        "schema_version" => 1,
        "node_key" => "implementation",
        "task_type" => "implementation",
        "outcome" => "completed",
        "summary" => "缺陷实现",
        "evidence" => ["mix test"],
        "decisions" => ["提交缺陷实现供返工审查"],
        "open_questions" => []
      }
    })
    |> Registry.put_node("implementation_review", %{
      "node_key" => "implementation_review",
      "issue_id" => review_issue.id,
      "issue_identifier" => review_issue.identifier,
      "agent_id" => "codex",
      "task_type" => "review",
      "workflow_semantics" => "executable",
      "status" => "ready",
      "dependencies" => ["implementation"],
      "reviews" => ["implementation"],
      "subject_selector" => %{"type" => "candidate_range"}
    })
    |> Map.put("status", "planning_complete")
    |> Registry.save!()

    workspace = Path.join(workspace_root, review_issue.identifier)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    write_issue_result!(
      workspace,
      review_result("implementation_review", ["implementation"], "needs_rework", "需要返工", %{
        "confidence" => "high",
        "reason" => "需要返工"
      })
    )

    review_issue_id = review_issue.id

    assert {:ok, {:needs_rework, ^review_issue_id, "需要返工"}} =
             Controller.handle_issue_completion(review_issue, workspace)

    assert_receive {:memory_tracker_issue_created, %Issue{} = rework_issue}
    assert "symphony-local-test" in rework_issue.labels
    assert "agent:mimo" in rework_issue.labels
    assert Issue.routable?(rework_issue, Config.settings!().tracker.required_labels)
  end

  test "review issue needs_replan 会标记 root 进入重规划并废弃未完成节点" do
    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-controller-review-replan-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    root_issue = %Issue{id: "root-replan", identifier: "YQE-816", title: "root", state: "In Progress"}
    research_issue = %Issue{id: "derived-replan-research", identifier: "YQE-817", title: "调研任务", state: "Done"}
    reviewed_issue = %Issue{id: "derived-replan-reviewed", identifier: "YQE-818", title: "实现任务", state: "Closed"}
    review_issue = %Issue{id: "derived-replan-review", identifier: "YQE-818-R", title: "审查实现任务", state: "In Progress"}
    waiting_issue = %Issue{id: "derived-replan-waiting", identifier: "YQE-819", title: "后续任务", state: "Todo"}

    root_issue
    |> Registry.new_root()
    |> Registry.put_node("research", %{
      "node_key" => "research",
      "issue_id" => research_issue.id,
      "issue_identifier" => research_issue.identifier,
      "agent_id" => "codex",
      "task_type" => "research",
      "workflow_semantics" => "executable",
      "status" => "completed",
      "dependencies" => [],
      "issue_result" => %{
        "schema_version" => 1,
        "node_key" => "research",
        "task_type" => "research",
        "outcome" => "completed",
        "summary" => "已有调研结论",
        "evidence" => ["research.md"],
        "decisions" => ["沿用调研结论"],
        "open_questions" => []
      }
    })
    |> Registry.put_node("implementation", %{
      "node_key" => "implementation",
      "issue_id" => reviewed_issue.id,
      "issue_identifier" => reviewed_issue.identifier,
      "agent_id" => "mimocode",
      "task_type" => "implementation",
      "workflow_semantics" => "executable",
      "status" => "completed",
      "dependencies" => ["research"],
      "issue_result" => %{
        "schema_version" => 1,
        "node_key" => "implementation",
        "task_type" => "implementation",
        "outcome" => "completed",
        "summary" => "实现方向被证明不适用",
        "evidence" => ["mix test"],
        "decisions" => ["请求回到 root 重规划"],
        "open_questions" => []
      }
    })
    |> Registry.put_node("implementation_review", %{
      "node_key" => "implementation_review",
      "issue_id" => review_issue.id,
      "issue_identifier" => review_issue.identifier,
      "agent_id" => "codex",
      "task_type" => "review",
      "workflow_semantics" => "executable",
      "status" => "ready",
      "dependencies" => ["implementation"],
      "reviews" => ["implementation"],
      "subject_selector" => %{"type" => "candidate_range"}
    })
    |> Registry.put_node("verification", %{
      "node_key" => "verification",
      "issue_id" => waiting_issue.id,
      "issue_identifier" => waiting_issue.identifier,
      "agent_id" => "codex",
      "task_type" => "verification",
      "workflow_semantics" => "executable",
      "status" => "waiting",
      "dependencies" => ["implementation_review"]
    })
    |> Map.put("status", "planning_complete")
    |> Registry.save!()

    workspace = Path.join(workspace_root, review_issue.identifier)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    write_issue_result!(
      workspace,
      review_result(
        "implementation_review",
        ["implementation"],
        "needs_replan",
        "当前方案不适用，需要回到 root 重新规划",
        %{"confidence" => "high", "reason" => "当前方案不适用"}
      )
    )

    assert {:ok, {:needs_replan, "derived-replan-review", "当前方案不适用，需要回到 root 重新规划"}} =
             Controller.handle_issue_completion(review_issue, workspace)

    assert {:ok, registry} = Registry.load_by_root_identifier(root_issue.identifier)
    assert registry["status"] == "replanning"
    assert registry["replan_request"] == "当前方案不适用，需要回到 root 重新规划"
    assert registry["replan_source_issue_id"] == review_issue.id
    assert Registry.node(registry, "research")["status"] == "completed"
    assert Registry.node(registry, "implementation")["status"] == "completed"
    assert Registry.node(registry, "implementation_review")["status"] == "superseded"
    assert Registry.node(registry, "verification")["status"] == "superseded"
  end

  test "review issue needs_human 会阻塞 registry 并保存人工输入请求" do
    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-controller-review-human-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    root_issue = %Issue{id: "root-review-human", identifier: "YQE-820", title: "root", state: "In Progress"}
    reviewed_issue = %Issue{id: "derived-review-human", identifier: "YQE-821", title: "实现任务", state: "Closed"}
    review_issue = %Issue{id: "derived-review-human-review", identifier: "YQE-821-R", title: "审查实现任务", state: "In Progress"}

    root_issue
    |> Registry.new_root()
    |> Registry.put_node("implementation", %{
      "node_key" => "implementation",
      "issue_id" => reviewed_issue.id,
      "issue_identifier" => reviewed_issue.identifier,
      "agent_id" => "codex",
      "task_type" => "implementation",
      "workflow_semantics" => "executable",
      "status" => "completed",
      "dependencies" => []
    })
    |> Registry.put_node("implementation_review", %{
      "node_key" => "implementation_review",
      "issue_id" => review_issue.id,
      "issue_identifier" => review_issue.identifier,
      "agent_id" => "codex",
      "task_type" => "review",
      "workflow_semantics" => "executable",
      "status" => "ready",
      "dependencies" => ["implementation"],
      "reviews" => ["implementation"],
      "subject_selector" => %{"type" => "candidate_range"}
    })
    |> Map.put("status", "planning_complete")
    |> Registry.save!()

    workspace = Path.join(workspace_root, review_issue.identifier)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    write_issue_result!(
      workspace,
      review_result(
        "implementation_review",
        ["implementation"],
        "needs_human",
        "需要产品确认是否允许破坏兼容性",
        %{
          "confidence" => "medium",
          "reason" => "兼容性策略不明确",
          "requested_input" => "请确认是否允许移除旧字段"
        }
      )
    )

    assert {:ok, {:needs_human, "derived-review-human-review", "需要产品确认是否允许破坏兼容性"}} =
             Controller.handle_issue_completion(review_issue, workspace)

    assert {:ok, registry} = Registry.load_by_root_identifier(root_issue.identifier)
    assert registry["status"] == "blocked"
    assert registry["blocked_reason"] == "需要产品确认是否允许破坏兼容性"
    assert registry["human_input_request"] == "请确认是否允许移除旧字段"
    assert Registry.node(registry, "implementation")["status"] == "completed"
    assert Registry.node(registry, "implementation_review")["status"] == "blocked"
    assert Registry.node(registry, "implementation_review")["review_summary"] == "需要产品确认是否允许破坏兼容性"
  end

  test "review issue fail 会标记 registry 失败并保存审查摘要" do
    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-controller-review-fail-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    root_issue = %Issue{id: "root-review-fail", identifier: "YQE-822", title: "root", state: "In Progress"}
    reviewed_issue = %Issue{id: "derived-review-fail", identifier: "YQE-823", title: "实现任务", state: "Closed"}
    review_issue = %Issue{id: "derived-review-fail-review", identifier: "YQE-823-R", title: "审查实现任务", state: "In Progress"}

    root_issue
    |> Registry.new_root()
    |> Registry.put_node("implementation", %{
      "node_key" => "implementation",
      "issue_id" => reviewed_issue.id,
      "issue_identifier" => reviewed_issue.identifier,
      "agent_id" => "codex",
      "task_type" => "implementation",
      "workflow_semantics" => "executable",
      "status" => "completed",
      "dependencies" => []
    })
    |> Registry.put_node("implementation_review", %{
      "node_key" => "implementation_review",
      "issue_id" => review_issue.id,
      "issue_identifier" => review_issue.identifier,
      "agent_id" => "codex",
      "task_type" => "review",
      "workflow_semantics" => "executable",
      "status" => "ready",
      "dependencies" => ["implementation"],
      "reviews" => ["implementation"],
      "subject_selector" => %{"type" => "candidate_range"}
    })
    |> Map.put("status", "planning_complete")
    |> Registry.save!()

    workspace = Path.join(workspace_root, review_issue.identifier)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    write_issue_result!(
      workspace,
      review_result(
        "implementation_review",
        ["implementation"],
        "fail",
        "实现删除了用户数据，不能继续",
        %{"confidence" => "high", "reason" => "发现不可接受的数据丢失"}
      )
    )

    assert {:ok, {:fail, "derived-review-fail-review", "实现删除了用户数据，不能继续"}} =
             Controller.handle_issue_completion(review_issue, workspace)

    assert {:ok, registry} = Registry.load_by_root_identifier(root_issue.identifier)
    assert registry["status"] == "failed"
    assert registry["failure_reason"] == "实现删除了用户数据，不能继续"
    assert Registry.node(registry, "implementation")["status"] == "completed"
    assert Registry.node(registry, "implementation_review")["status"] == "failed"
    assert Registry.node(registry, "implementation_review")["review_summary"] == "实现删除了用户数据，不能继续"
  end

  test "needs_human_input plan 会保存明确的人工输入请求并写回 root 评论" do
    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-controller-human-input-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    root_issue = %Issue{
      id: "root-human-input",
      identifier: "YQE-812",
      title: "信息不足的 root issue",
      state: "In Progress"
    }

    workspace = Path.join(workspace_root, root_issue.identifier)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    File.write!(
      Artifacts.workflow_plan_path(workspace),
      Jason.encode!(%{
        "kind" => "needs_human_input",
        "summary" => "任务信息不足，无法可靠规划",
        "confidence" => "low",
        "request" => "请补充目标仓库、目标行为和验收标准"
      })
    )

    assert {:ok, registry} = Controller.handle_planning_completion(root_issue, workspace)

    assert registry["status"] == "needs_human_input"
    assert registry["human_input_request"] == "请补充目标仓库、目标行为和验收标准"
    assert registry["human_input_summary"] == "任务信息不足，无法可靠规划"

    assert_receive {:memory_tracker_comment, "root-human-input", body}
    assert body =~ "Needs Human Input"
    assert body =~ "请补充目标仓库、目标行为和验收标准"
  end

  test "dispatch metadata 会把依赖节点的 issue result 交给下游 issue" do
    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-controller-upstream-packets-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: workspace_root,
      orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
    )

    root_issue = %Issue{id: "root-upstream", identifier: "YQE-809", title: "root", state: "In Progress"}
    research_issue = %Issue{id: "derived-upstream-research", identifier: "YQE-810", title: "调研", state: "Done"}
    implementation_issue = %Issue{id: "derived-upstream-implementation", identifier: "YQE-811", title: "实现", state: "Todo"}

    root_issue
    |> Registry.new_root()
    |> Registry.put_node("research", %{
      "node_key" => "research",
      "issue_id" => research_issue.id,
      "issue_identifier" => research_issue.identifier,
      "agent_id" => "codex",
      "task_type" => "research",
      "workflow_semantics" => "executable",
      "status" => "completed",
      "dependencies" => [],
      "issue_result" => %{
        "schema_version" => 1,
        "node_key" => "research",
        "task_type" => "research",
        "outcome" => "completed",
        "summary" => "上游调研完成",
        "evidence" => ["research.md"],
        "decisions" => ["使用调研结论推进实现"],
        "open_questions" => []
      }
    })
    |> Registry.put_node("implementation", %{
      "node_key" => "implementation",
      "issue_id" => implementation_issue.id,
      "issue_identifier" => implementation_issue.identifier,
      "agent_id" => "codex",
      "task_type" => "implementation",
      "workflow_semantics" => "executable",
      "status" => "ready",
      "dependencies" => ["research"]
    })
    |> Map.put("status", "planning_complete")
    |> Registry.save!()

    assert {:ok, metadata} = Controller.issue_dispatch_metadata(implementation_issue.id)
    assert [%{"summary" => "上游调研完成", "evidence" => ["research.md"]}] = metadata.workflow_context["upstream_results"]

    assert [
             %{
               "node_key" => "research",
               "issue_identifier" => "YQE-810",
               "workspace" => upstream_workspace
             }
           ] = metadata.workflow_context["upstream_workspaces"]

    assert upstream_workspace == Path.join(workspace_root, research_issue.identifier)
  end

  test "review issue pass 会关闭当前 issue，并在所有可执行节点完成后关闭 root issue" do
    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-controller-review-close-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_terminal_states: ["Closed"],
      workspace_root: workspace_root,
      orchestration: %{enabled: true, planner_agent: "codex", reviewer_agent: "codex", artifact_dir: ".symphony"}
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    root_issue = %Issue{
      id: "root-close",
      identifier: "YQE-805",
      title: "root",
      state: "In Progress"
    }

    reviewed_issue = %Issue{
      id: "derived-close",
      identifier: "YQE-806",
      title: "实现任务",
      state: "Closed"
    }

    review_issue = %Issue{
      id: "derived-close-review",
      identifier: "YQE-807",
      title: "审查实现任务",
      state: "In Progress"
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [root_issue, reviewed_issue, review_issue])

    root_issue
    |> Registry.new_root()
    |> Registry.put_node("implementation", %{
      "node_key" => "implementation",
      "issue_id" => reviewed_issue.id,
      "issue_identifier" => reviewed_issue.identifier,
      "agent_id" => "codex",
      "task_type" => "implementation",
      "workflow_semantics" => "executable",
      "status" => "completed",
      "dependencies" => []
    })
    |> Registry.put_node("implementation_review", %{
      "node_key" => "implementation_review",
      "issue_id" => review_issue.id,
      "issue_identifier" => review_issue.identifier,
      "agent_id" => "codex",
      "task_type" => "review",
      "workflow_semantics" => "executable",
      "status" => "ready",
      "dependencies" => ["implementation"],
      "reviews" => ["implementation"],
      "subject_selector" => %{"type" => "candidate_range"}
    })
    |> Map.put("status", "planning_complete")
    |> Registry.save!()

    workspace = Path.join(workspace_root, review_issue.identifier)
    File.mkdir_p!(Path.join(workspace, ".symphony"))

    write_issue_result!(
      workspace,
      review_result("implementation_review", ["implementation"], "pass", "实现结果满足验收要求", %{
        "confidence" => "high"
      })
    )

    assert {:ok, {:completed, "derived-close-review"}} =
             Controller.handle_issue_completion(review_issue, workspace)

    assert {:ok, registry} = Registry.load_by_root_identifier(root_issue.identifier)
    assert registry["status"] == "completed"
    assert Registry.node(registry, "implementation")["status"] == "completed"
    assert Registry.node(registry, "implementation_review")["status"] == "completed"

    issues = Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
    assert Enum.find(issues, &(&1.id == root_issue.id)).state == "Closed"
    assert Enum.find(issues, &(&1.id == review_issue.id)).state == "Closed"

    assert_receive {:memory_tracker_state_update, "derived-close-review", "Closed"}
    assert_receive {:memory_tracker_state_update, "root-close", "Closed"}
  end
end
