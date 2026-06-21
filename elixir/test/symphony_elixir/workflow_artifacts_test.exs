defmodule SymphonyElixir.WorkflowArtifactsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Workflow.Artifacts
  alias SymphonyElixir.Workflow.Registry

  test "artifact helpers build planning, completion, and review paths" do
    write_workflow_file!(Workflow.workflow_file_path(),
      orchestration: %{enabled: true, artifact_dir: ".symphony"}
    )

    workspace = Path.join(System.tmp_dir!(), "workflow-artifacts-paths")

    assert Artifacts.workflow_plan_path(workspace) ==
             Path.join([workspace, ".symphony", "workflow_plan.json"])

    assert Artifacts.completion_packet_path(workspace) ==
             Path.join([workspace, ".symphony", "completion_packet.json"])

    assert Artifacts.review_decision_path(workspace) ==
             Path.join([workspace, ".symphony", "review_decision.json"])
  end

  test "validate_plan accepts direct_execution and issue_graph" do
    assert :ok ==
             Artifacts.validate_plan(%{
               "kind" => "direct_execution",
               "summary" => "任务足够简单，可直接执行",
               "confidence" => "high"
             })

    assert :ok ==
             Artifacts.validate_plan(%{
               "kind" => "issue_graph",
               "summary" => "需要拆出调研与实现任务",
               "confidence" => "medium",
               "nodes" => [
                 %{
                   "node_key" => "research-1",
                   "task_type" => "research",
                   "title" => "调研 ACP 支持",
                   "goal" => "收集适配器设计证据",
                   "agent_id" => "codex"
                 }
               ],
               "edges" => []
             })
  end

  test "validate_plan accepts needs_human_input" do
    assert :ok ==
             Artifacts.validate_plan(%{
               "kind" => "needs_human_input",
               "summary" => "需求信息不足",
               "confidence" => "low",
               "request" => "请补充目标仓库和验收标准"
             })

    assert :ok ==
             Artifacts.validate_plan(%{
               "mode" => "needs_human_input",
               "summary" => "需求信息不足",
               "confidence" => "low",
               "request" => "请补充目标仓库和验收标准"
             })
  end

  test "validate_plan rejects invalid issue graph edges" do
    assert {:error, :invalid_workflow_plan} ==
             Artifacts.validate_plan(%{
               "kind" => "issue_graph",
               "summary" => "需要拆出调研与实现任务",
               "confidence" => "medium",
               "nodes" => [
                 %{
                   "node_key" => "research-1",
                   "task_type" => "research",
                   "title" => "调研 ACP 支持",
                   "goal" => "收集适配器设计证据",
                   "agent_id" => "codex"
                 }
               ],
               "edges" => [123]
             })
  end

  test "validate_plan rejects duplicate node keys and unknown edge references" do
    base_node = %{
      "node_key" => "research-1",
      "task_type" => "research",
      "title" => "调研 ACP 支持",
      "goal" => "收集适配器设计证据",
      "agent_id" => "codex"
    }

    assert {:error, :invalid_workflow_plan} ==
             Artifacts.validate_plan(%{
               "kind" => "issue_graph",
               "summary" => "需要拆出调研与实现任务",
               "confidence" => "medium",
               "nodes" => [
                 base_node,
                 %{base_node | "title" => "重复节点"}
               ],
               "edges" => []
             })

    assert {:error, :invalid_workflow_plan} ==
             Artifacts.validate_plan(%{
               "mode" => "issue_graph",
               "summary" => "需要拆出调研与实现任务",
               "confidence" => "medium",
               "nodes" => [base_node],
               "edges" => [%{"from" => "research-1", "to" => "missing-node"}]
             })

    assert {:error, :invalid_workflow_plan} ==
             Artifacts.validate_plan(%{
               "kind" => "issue_graph",
               "summary" => "需要拆出调研与实现任务",
               "confidence" => "medium",
               "nodes" => [base_node],
               "edges" => [%{from: "missing-node", to: "research-1"}]
             })
  end

  test "validate_plan 对 mode issue_graph 同样校验 edges" do
    assert {:error, :invalid_workflow_plan} ==
             Artifacts.validate_plan(%{
               "mode" => "issue_graph",
               "summary" => "需要拆出调研与实现任务",
               "confidence" => "medium",
               "nodes" => [
                 %{
                   "node_key" => "research-1",
                   "task_type" => "research",
                   "title" => "调研 ACP 支持",
                   "goal" => "收集适配器设计证据",
                   "agent_id" => "codex"
                 }
               ],
               "edges" => [123]
             })
  end

  test "validate_completion_packet requires outcome summary and evidence" do
    assert :ok ==
             Artifacts.validate_completion_packet(%{
               "outcome" => "completed",
               "summary" => "实现了适配器",
               "evidence" => ["mix test test/symphony_elixir/workflow_controller_test.exs"],
               "decisions" => ["保留现有适配器边界"],
               "open_questions" => [],
               "next_handoff" => "交给 review 阶段检查实现"
             })

    assert {:error, :invalid_completion_packet} ==
             Artifacts.validate_completion_packet(%{
               "outcome" => "completed",
               "summary" => "实现了适配器"
             })
  end

  test "validate_completion_packet requires all handoff fields and non-empty evidence" do
    valid_packet = %{
      "outcome" => "completed",
      "summary" => "实现了适配器",
      "evidence" => ["mix test test/symphony_elixir/workflow_controller_test.exs"],
      "decisions" => ["保留现有适配器边界"],
      "open_questions" => [],
      "next_handoff" => "交给 review 阶段检查实现"
    }

    assert :ok == Artifacts.validate_completion_packet(valid_packet)

    for invalid_packet <- [
          Map.delete(valid_packet, "decisions"),
          Map.delete(valid_packet, "open_questions"),
          Map.delete(valid_packet, "next_handoff"),
          %{valid_packet | "evidence" => []},
          %{valid_packet | "next_handoff" => ""}
        ] do
      assert {:error, :invalid_completion_packet} ==
               Artifacts.validate_completion_packet(invalid_packet)
    end
  end

  test "validate_review_decision requires allowed decision summary and confidence" do
    assert :ok ==
             Artifacts.validate_review_decision(%{
               "decision" => "pass",
               "summary" => "满足当前阶段要求",
               "confidence" => "high"
             })

    assert {:error, :invalid_review_decision} ==
             Artifacts.validate_review_decision(%{
               "decision" => "unknown",
               "summary" => "不合法",
               "confidence" => "low"
             })
  end

  test "validate_review_decision requires reason fields for non-pass decisions" do
    assert :ok ==
             Artifacts.validate_review_decision(%{
               "decision" => "needs_human",
               "summary" => "需要人工确认上线窗口",
               "confidence" => "medium",
               "reason" => "缺少上线窗口约束",
               "requested_input" => "请确认是否可以今天发布"
             })

    assert :ok ==
             Artifacts.validate_review_decision(%{
               "decision" => "fail",
               "summary" => "实现没有产出必要文件",
               "confidence" => "high",
               "reason" => "缺少 completion_packet.json"
             })

    assert {:error, :invalid_review_decision} ==
             Artifacts.validate_review_decision(%{
               "decision" => "needs_human",
               "summary" => "需要人工确认上线窗口",
               "confidence" => "medium",
               "requested_input" => "请确认是否可以今天发布"
             })

    assert {:error, :invalid_review_decision} ==
             Artifacts.validate_review_decision(%{
               "decision" => "needs_human",
               "summary" => "需要人工确认上线窗口",
               "confidence" => "medium",
               "reason" => "缺少上线窗口约束"
             })
  end

  test "load helpers return file and json errors without raising" do
    write_workflow_file!(Workflow.workflow_file_path(),
      orchestration: %{enabled: true, artifact_dir: ".symphony"}
    )

    workspace =
      Path.join(System.tmp_dir!(), "workflow-artifacts-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, ".symphony"))

    assert {:error, :enoent} = Artifacts.load_plan(workspace)

    File.write!(Artifacts.completion_packet_path(workspace), "{invalid")
    assert match?({:error, %Jason.DecodeError{}}, Artifacts.load_completion_packet(workspace))

    File.rm_rf!(workspace)
  end

  test "registry persists root workflow and finds node by issue id" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(System.tmp_dir!(), "workflow-registry-root"),
      orchestration: %{enabled: true, artifact_dir: ".symphony"}
    )

    root_issue = %Issue{id: "root-1", identifier: "YQE-100", title: "Workflow root", state: "In Progress"}

    registry =
      Registry.new_root(root_issue)
      |> Registry.put_node("research-1", %{
        issue_id: "issue-1",
        issue_identifier: "YQE-101",
        task_type: "research",
        workflow_semantics: "executable",
        status: "ready"
      })
      |> Registry.add_edge({"root", "research-1"})

    assert registry["status"] == "planning"
    assert Registry.node(registry, "research-1")["task_type"] == "research"

    :ok = Registry.save!(registry)

    assert {:ok, loaded} = Registry.load_by_root_identifier("YQE-100")
    assert Registry.node_by_issue_id(loaded, "issue-1")["task_type"] == "research"
    assert Registry.node(loaded, "research-1")["status"] == "ready"
  end

  test "registry load_by_root_identifier rejects invalid registry structure" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(System.tmp_dir!(), "workflow-registry-root"),
      orchestration: %{enabled: true, artifact_dir: ".symphony"}
    )

    path = Registry.registry_path("YQE-999")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(%{"nodes" => [], "status" => "planned", "edges" => []}))

    assert {:error, {:invalid_registry_structure, ^path}} = Registry.load_by_root_identifier("YQE-999")
    assert nil == Registry.node_by_issue_id(%{"nodes" => []}, "issue-1")
  end
end
