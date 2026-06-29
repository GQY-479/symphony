defmodule SymphonyElixir.WorkflowArtifactsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Workflow.Artifacts
  alias SymphonyElixir.Workflow.ExecutionSummary
  alias SymphonyElixir.Workflow.Registry

  defp final_review_node do
    %{
      "node_key" => "final_review",
      "task_type" => "review",
      "title" => "最终审查",
      "goal" => "审查 root candidate 是否满足用户目标",
      "agent_id" => "codex",
      "reviews" => ["__root_candidate__"],
      "subject_selector" => %{"type" => "final_candidate_range"}
    }
  end

  test "artifact helpers build planning and issue result paths" do
    write_workflow_file!(Workflow.workflow_file_path(),
      orchestration: %{enabled: true, artifact_dir: ".symphony"}
    )

    workspace = Path.join(System.tmp_dir!(), "workflow-artifacts-paths")

    assert Artifacts.workflow_plan_path(workspace) ==
             Path.join([workspace, ".symphony", "workflow_plan.json"])

    assert Artifacts.issue_result_path(workspace) ==
             Path.join([workspace, ".symphony", "issue_result.json"])
  end

  test "execution summary path uses the configured artifact directory" do
    write_workflow_file!(Workflow.workflow_file_path(),
      orchestration: %{enabled: true, artifact_dir: ".symphony"}
    )

    workspace = Path.join(System.tmp_dir!(), "workflow-execution-summary-path")

    assert ExecutionSummary.summary_path(workspace) ==
             Path.join([workspace, ".symphony", "execution_summary.json"])
  end

  test "validate_plan accepts issue_graph" do
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
                 },
                 %{
                   "node_key" => "final_review",
                   "task_type" => "review",
                   "title" => "最终审查",
                   "goal" => "审查 root candidate 是否满足用户目标",
                   "agent_id" => "codex",
                   "reviews" => ["__root_candidate__"],
                   "subject_selector" => %{"type" => "final_candidate_range"}
                 }
               ],
               "edges" => [%{"from" => "research-1", "to" => "final_review"}]
             })
  end

  test "validate_plan accepts issue_graph with dependencies" do
    assert :ok ==
             Artifacts.validate_plan(%{
               "kind" => "issue_graph",
               "summary" => "需要调研后实现",
               "confidence" => "high",
               "nodes" => [
                 %{
                   "node_key" => "research-1",
                   "task_type" => "research",
                   "title" => "调研依赖方案",
                   "goal" => "收集设计证据",
                   "agent_id" => "codex"
                 },
                 %{
                   "node_key" => "implement-1",
                   "task_type" => "implementation",
                   "title" => "实现功能",
                   "goal" => "根据调研结果实现",
                   "agent_id" => "codex"
                 },
                 final_review_node()
               ],
               "edges" => [
                 %{"from" => "research-1", "to" => "implement-1"},
                 %{"from" => "implement-1", "to" => "final_review"}
               ]
             })
  end

  test "validate_plan accepts issue_graph with multiple dependencies" do
    assert :ok ==
             Artifacts.validate_plan(%{
               "kind" => "issue_graph",
               "summary" => "多步依赖工作流",
               "confidence" => "high",
               "nodes" => [
                 %{
                   "node_key" => "design",
                   "task_type" => "research",
                   "title" => "设计",
                   "goal" => "设计方案",
                   "agent_id" => "codex"
                 },
                 %{
                   "node_key" => "impl-a",
                   "task_type" => "implementation",
                   "title" => "实现 A",
                   "goal" => "实现组件 A",
                   "agent_id" => "codex"
                 },
                 %{
                   "node_key" => "impl-b",
                   "task_type" => "implementation",
                   "title" => "实现 B",
                   "goal" => "实现组件 B",
                   "agent_id" => "codex"
                 },
                 %{
                   "node_key" => "integration",
                   "task_type" => "implementation",
                   "title" => "集成测试",
                   "goal" => "集成 A 和 B",
                   "agent_id" => "codex"
                 },
                 final_review_node()
               ],
               "edges" => [
                 %{"from" => "design", "to" => "impl-a"},
                 %{"from" => "design", "to" => "impl-b"},
                 %{"from" => "impl-a", "to" => "integration"},
                 %{"from" => "impl-b", "to" => "integration"},
                 %{"from" => "integration", "to" => "final_review"}
               ]
             })
  end

  test "validate_plan accepts review nodes with subject selector" do
    assert :ok ==
             Artifacts.validate_plan(%{
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
                   "subject_selector" => %{
                     "type" => "candidate_range",
                     "from" => "implementation.candidate_before_sha",
                     "to" => "implementation.candidate_after_sha"
                   }
                 },
                 final_review_node()
               ],
               "edges" => [
                 %{"from" => "implementation", "to" => "implementation_review"},
                 %{"from" => "implementation_review", "to" => "final_review"}
               ]
             })
  end

  test "validate_plan rejects review nodes without review subjects" do
    base_review_node = %{
      "node_key" => "implementation_review",
      "task_type" => "review",
      "title" => "审查实现",
      "goal" => "审查实现结果",
      "agent_id" => "codex",
      "reviews" => ["implementation"],
      "subject_selector" => %{"type" => "candidate_range"}
    }

    assert {:error, :invalid_workflow_plan} ==
             Artifacts.validate_plan(%{
               "kind" => "issue_graph",
               "summary" => "无 reviews",
               "confidence" => "medium",
               "nodes" => [Map.delete(base_review_node, "reviews")],
               "edges" => []
             })

    assert {:error, :invalid_workflow_plan} ==
             Artifacts.validate_plan(%{
               "kind" => "issue_graph",
               "summary" => "无 subject selector",
               "confidence" => "medium",
               "nodes" => [Map.delete(base_review_node, "subject_selector")],
               "edges" => []
             })

    assert {:error, :invalid_workflow_plan} ==
             Artifacts.validate_plan(%{
               "kind" => "issue_graph",
               "summary" => "空 reviews",
               "confidence" => "medium",
               "nodes" => [%{base_review_node | "reviews" => []}],
               "edges" => []
             })
  end

  test "validate_plan rejects issue_graph with unknown edge references" do
    assert {:error, :invalid_workflow_plan} ==
             Artifacts.validate_plan(%{
               "kind" => "issue_graph",
               "summary" => "依赖图",
               "confidence" => "medium",
               "nodes" => [
                 %{
                   "node_key" => "a",
                   "task_type" => "research",
                   "title" => "A",
                   "goal" => "目标 A",
                   "agent_id" => "codex"
                 },
                 %{
                   "node_key" => "b",
                   "task_type" => "implementation",
                   "title" => "B",
                   "goal" => "目标 B",
                   "agent_id" => "codex"
                 }
               ],
               "edges" => [%{"from" => "a", "to" => "b"}, %{"from" => "b", "to" => "c"}]
             })
  end

  test "validate_plan accepts nodes with completion_conditions" do
    assert :ok ==
             Artifacts.validate_plan(%{
               "kind" => "issue_graph",
               "summary" => "带完成条件的工作流",
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
                 },
                 final_review_node()
               ],
               "edges" => [
                 %{"from" => "research", "to" => "implementation"},
                 %{"from" => "implementation", "to" => "final_review"}
               ]
             })
  end

  test "validate_plan rejects nodes with invalid completion_conditions" do
    assert {:error, :invalid_workflow_plan} ==
             Artifacts.validate_plan(%{
               "kind" => "issue_graph",
               "summary" => "无效完成条件",
               "confidence" => "medium",
               "nodes" => [
                 %{
                   "node_key" => "a",
                   "task_type" => "research",
                   "title" => "A",
                   "goal" => "目标 A",
                   "agent_id" => "codex",
                   "completion_conditions" => [123, "valid condition"]
                 }
               ],
               "edges" => []
             })
  end

  test "validate_plan accepts issue_graph without completion_conditions" do
    assert :ok ==
             Artifacts.validate_plan(%{
               "kind" => "issue_graph",
               "summary" => "无完成条件的工作流",
               "confidence" => "high",
               "nodes" => [
                 %{
                   "node_key" => "a",
                   "task_type" => "research",
                   "title" => "A",
                   "goal" => "目标 A",
                   "agent_id" => "codex"
                 },
                 final_review_node()
               ],
               "edges" => [%{"from" => "a", "to" => "final_review"}]
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

  test "validate_issue_result accepts normal issue result" do
    assert :ok ==
             Artifacts.validate_issue_result(%{
               "schema_version" => 1,
               "node_key" => "implementation",
               "task_type" => "implementation",
               "outcome" => "completed",
               "summary" => "实现完成",
               "evidence" => ["mix test"],
               "decisions" => [],
               "open_questions" => []
             })
  end

  test "validate_issue_result accepts review outcomes" do
    assert :ok ==
             Artifacts.validate_issue_result(%{
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

    assert :ok ==
             Artifacts.validate_issue_result(%{
               "schema_version" => 1,
               "node_key" => "implementation_review",
               "task_type" => "review",
               "outcome" => "needs_rework",
               "reviews" => ["implementation"],
               "summary" => "需要返工",
               "reason" => "缺少测试",
               "evidence" => ["mix test failed"],
               "decisions" => [],
               "open_questions" => []
             })
  end

  test "validate_issue_result rejects normal issue results with missing required fields" do
    valid_result = %{
      "schema_version" => 1,
      "node_key" => "implementation",
      "task_type" => "implementation",
      "outcome" => "completed",
      "summary" => "实现完成",
      "evidence" => ["mix test"],
      "decisions" => [],
      "open_questions" => []
    }

    for invalid_result <- [
          Map.delete(valid_result, "decisions"),
          Map.delete(valid_result, "open_questions"),
          %{valid_result | "evidence" => []},
          %{valid_result | "summary" => ""}
        ] do
      assert {:error, :invalid_issue_result} ==
               Artifacts.validate_issue_result(invalid_result)
    end
  end

  test "validate_issue_result rejects invalid review outcomes and missing review fields" do
    valid_result = %{
      "schema_version" => 1,
      "node_key" => "implementation_review",
      "task_type" => "review",
      "outcome" => "needs_human",
      "reviews" => ["implementation"],
      "summary" => "需要人工确认上线窗口",
      "reason" => "缺少上线窗口约束",
      "requested_input" => "请确认是否可以今天发布",
      "evidence" => ["mix test"],
      "decisions" => [],
      "open_questions" => []
    }

    for invalid_result <- [
          %{valid_result | "outcome" => "unknown"},
          Map.delete(valid_result, "reviews"),
          %{valid_result | "reviews" => []},
          Map.delete(valid_result, "reason"),
          Map.delete(valid_result, "requested_input")
        ] do
      assert {:error, :invalid_issue_result} ==
               Artifacts.validate_issue_result(invalid_result)
    end
  end

  test "load helpers return file and json errors without raising" do
    write_workflow_file!(Workflow.workflow_file_path(),
      orchestration: %{enabled: true, artifact_dir: ".symphony"}
    )

    workspace =
      Path.join(System.tmp_dir!(), "workflow-artifacts-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, ".symphony"))

    assert {:error, :enoent} = Artifacts.load_plan(workspace)

    File.write!(Artifacts.issue_result_path(workspace), "{invalid")
    assert match?({:error, %Jason.DecodeError{}}, Artifacts.load_issue_result(workspace))

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

  test "registry stores checkpoints subjects and review states" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(System.tmp_dir!(), "workflow-registry-subjects"),
      orchestration: %{enabled: true, artifact_dir: ".symphony"}
    )

    root_issue = %Issue{id: "root-subject", identifier: "YQE-SUBJECT", title: "root", state: "In Progress"}

    registry =
      root_issue
      |> Registry.new_root()
      |> Registry.put_workflow_git(%{
        "target_branch" => "main",
        "target_base_sha" => "base",
        "candidate_branch" => "symphony/YQE-SUBJECT/candidate",
        "candidate_head_sha" => "base",
        "final_review_node" => "final_review"
      })
      |> Registry.add_checkpoint(%{
        "id" => "checkpoint-001",
        "node_key" => "implementation",
        "issue_branch" => "symphony/YQE-SUBJECT/YQE-2",
        "issue_base_sha" => "base",
        "issue_head_sha" => "head",
        "candidate_before_sha" => "base",
        "candidate_after_sha" => "after",
        "merge_commit_sha" => "merge"
      })
      |> Registry.put_subject("subject-001", %{
        "type" => "candidate_range",
        "base_sha" => "base",
        "head_sha" => "after",
        "paths" => [],
        "artifact_ref" => nil,
        "status" => "pending"
      })
      |> Registry.put_review_state("implementation_review", %{
        "subject_id" => "subject-001",
        "decision" => "pass",
        "status" => "accepted",
        "decided_at" => "2026-06-27T00:00:00Z"
      })

    assert registry["candidate_branch"] == "symphony/YQE-SUBJECT/candidate"
    assert [checkpoint] = registry["checkpoints"]
    assert checkpoint["candidate_after_sha"] == "after"
    assert registry["subjects"]["subject-001"]["status"] == "pending"
    assert registry["reviews"]["implementation_review"]["status"] == "accepted"
  end

  test "registry paths expand tilde workspace roots before joining workflow directory" do
    workspace_root = "~/workflow-registry-expanded-#{System.unique_integer([:positive])}"

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      orchestration: %{enabled: true, artifact_dir: ".symphony"}
    )

    path = Registry.registry_path("YQE-TILDE")

    assert path ==
             Path.join([
               Path.expand(workspace_root),
               ".symphony",
               "workflows",
               "YQE-TILDE.json"
             ])

    assert Path.type(path) == :absolute
    refute String.contains?(path, "/~/")
  end

  test "registry save writes atomically and does not leave temp files" do
    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-registry-atomic-#{System.unique_integer([:positive])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      orchestration: %{enabled: true, artifact_dir: ".symphony"}
    )

    root_issue = %Issue{id: "root-atomic", identifier: "YQE-ATOMIC", title: "Atomic root", state: "In Progress"}
    registry = Registry.new_root(root_issue)

    :ok = Registry.save!(registry)

    registry_path = Registry.registry_path(root_issue.identifier)
    registry_dir = Path.dirname(registry_path)

    assert File.exists?(registry_path)
    assert {:ok, loaded} = Registry.load_by_root_identifier(root_issue.identifier)
    assert loaded["root_issue_identifier"] == root_issue.identifier

    assert {:ok, files} = File.ls(registry_dir)
    refute Enum.any?(files, &String.contains?(&1, ".tmp"))
  end

  test "load helpers return :enoent for missing plan artifact" do
    write_workflow_file!(Workflow.workflow_file_path(),
      orchestration: %{enabled: true, artifact_dir: ".symphony"}
    )

    workspace =
      Path.join(System.tmp_dir!(), "workflow-artifacts-missing-plan-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, ".symphony"))

    assert {:error, :enoent} = Artifacts.load_plan(workspace)

    File.rm_rf!(workspace)
  end

  test "load helpers return :enoent for missing issue result" do
    write_workflow_file!(Workflow.workflow_file_path(),
      orchestration: %{enabled: true, artifact_dir: ".symphony"}
    )

    workspace =
      Path.join(System.tmp_dir!(), "workflow-artifacts-missing-result-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, ".symphony"))

    assert {:error, :enoent} = Artifacts.load_issue_result(workspace)

    File.rm_rf!(workspace)
  end

  test "load helpers return decode error for invalid JSON in plan" do
    write_workflow_file!(Workflow.workflow_file_path(),
      orchestration: %{enabled: true, artifact_dir: ".symphony"}
    )

    workspace =
      Path.join(System.tmp_dir!(), "workflow-artifacts-invalid-json-plan-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, ".symphony"))
    File.write!(Artifacts.workflow_plan_path(workspace), "{invalid json")

    assert match?({:error, %Jason.DecodeError{}}, Artifacts.load_plan(workspace))

    File.rm_rf!(workspace)
  end

  test "load helpers return decode error for invalid JSON in issue result" do
    write_workflow_file!(Workflow.workflow_file_path(),
      orchestration: %{enabled: true, artifact_dir: ".symphony"}
    )

    workspace =
      Path.join(System.tmp_dir!(), "workflow-artifacts-invalid-json-result-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, ".symphony"))
    File.write!(Artifacts.issue_result_path(workspace), "{invalid json")

    assert match?({:error, %Jason.DecodeError{}}, Artifacts.load_issue_result(workspace))

    File.rm_rf!(workspace)
  end

  test "validate_plan rejects plan with missing required fields" do
    retired_kind = "direct" <> "_execution"

    assert {:error, :invalid_workflow_plan} = Artifacts.validate_plan(%{})
    assert {:error, :invalid_workflow_plan} = Artifacts.validate_plan(%{"kind" => retired_kind})
    assert {:error, :invalid_workflow_plan} = Artifacts.validate_plan(%{"kind" => retired_kind, "summary" => "test", "confidence" => "high"})
    assert {:error, :invalid_workflow_plan} = Artifacts.validate_plan(%{"summary" => "test"})
  end

  test "load helpers return validation error for structurally invalid plan" do
    write_workflow_file!(Workflow.workflow_file_path(),
      orchestration: %{enabled: true, artifact_dir: ".symphony"}
    )

    workspace =
      Path.join(System.tmp_dir!(), "workflow-artifacts-invalid-struct-plan-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, ".symphony"))

    File.write!(
      Artifacts.workflow_plan_path(workspace),
      Jason.encode!(%{"kind" => "unknown_kind", "summary" => "test", "confidence" => "high"})
    )

    assert {:error, :invalid_workflow_plan} = Artifacts.load_plan(workspace)

    File.rm_rf!(workspace)
  end

  test "load helpers return validation error for structurally invalid issue result" do
    write_workflow_file!(Workflow.workflow_file_path(),
      orchestration: %{enabled: true, artifact_dir: ".symphony"}
    )

    workspace =
      Path.join(System.tmp_dir!(), "workflow-artifacts-invalid-struct-result-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(workspace, ".symphony"))

    File.write!(
      Artifacts.issue_result_path(workspace),
      Jason.encode!(%{"outcome" => "completed", "summary" => "test"})
    )

    assert {:error, :invalid_issue_result} = Artifacts.load_issue_result(workspace)

    File.rm_rf!(workspace)
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
