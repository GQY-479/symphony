defmodule SymphonyElixirWeb.PresenterWorkflowTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixirWeb.Presenter

  test "state_payload/2 按 workflow root 聚合 running/retrying/blocked 并收集 attention items" do
    payload = Presenter.state_payload({:snapshot, workflow_snapshot()}, 1_000)

    assert payload.counts == %{running: 1, retrying: 1, blocked: 1}
    assert length(payload.workflows) == 1
    assert [workflow] = payload.workflows

    assert workflow.root_issue_identifier == "MT-ROOT"
    assert workflow.root_issue_id == nil
    assert workflow.title == "MT-ROOT"
    assert workflow.issue_url == "https://example.org/issues/MT-RUN"
    assert workflow.status == "blocked"
    assert workflow.phase_summary == "execution"
    assert workflow.counts.running == 1
    assert workflow.counts.retrying == 1
    assert workflow.counts.blocked == 1
    assert workflow.counts.completed == nil
    assert workflow.counts.total_nodes == nil
    assert workflow.registry_available? == false
    assert workflow.tokens == %{input_tokens: 4, output_tokens: 8, total_tokens: 12}
    assert workflow.runtime_seconds == 42

    assert Enum.map(workflow.active_entries, & &1.issue_identifier) == [
             "MT-RUN",
             "MT-RETRY",
             "MT-BLOCKED"
           ]

    assert workflow.recent_event == %{
             issue_identifier: "MT-BLOCKED",
             event: :turn_input_required,
             message: "turn blocked: waiting for user input",
             at: "2026-01-01T00:03:00Z"
           }

    assert %{
             kind: "blocked",
             root_issue_identifier: "MT-ROOT",
             issue_identifier: "MT-BLOCKED",
             reason: "codex turn requires operator input",
             phase: :execution
           } in workflow.attention_items

    assert %{
             kind: "retrying",
             root_issue_identifier: "MT-ROOT",
             issue_identifier: "MT-RETRY",
             attempt: 2,
             reason: "boom",
             phase: :planning
           } in workflow.attention_items

    assert payload.attention_items == workflow.attention_items
  end

  test "state_payload/2 为没有 workflow root 的旧式 running entry 生成 direct_execution workflow" do
    payload =
      Presenter.state_payload(
        {:snapshot,
         %{
           running: [running_entry(%{identifier: "MT-LEGACY", issue_id: "legacy-id", workflow_root_issue_id: nil})],
           retrying: [],
           blocked: [],
           codex_totals: %{input_tokens: 1, output_tokens: 2, total_tokens: 3, seconds_running: 5},
           rate_limits: nil
         }},
        1_000
      )

    assert [
             %{
               root_issue_identifier: "MT-LEGACY",
               root_issue_id: "legacy-id",
               title: "MT-LEGACY",
               status: "direct_execution",
               phase_summary: "direct_execution",
               counts: %{running: 1, retrying: 0, blocked: 0, completed: nil, total_nodes: nil},
               attention_items: [],
               registry_available?: false
             }
           ] = payload.workflows

    assert payload.attention_items == []
  end

  test "workflow_payload/3 读取 registry 并投影详情节点和边" do
    root_identifier = "MT-ROOT"
    workspace_root = configure_temporary_workspace_root("presenter-workflow-registry")
    on_exit(fn -> File.rm_rf(workspace_root) end)

    registry =
      %{
        "root_issue_id" => "root-id",
        "root_issue_identifier" => root_identifier,
        "root_title" => "Root workflow title",
        "status" => "running",
        "nodes" => %{
          "build" => %{
            "node_key" => "build",
            "issue_id" => "issue-build",
            "issue_identifier" => "MT-102",
            "title" => "Build dashboard",
            "task_type" => "implementation",
            "status" => "running",
            "workflow_semantics" => "executable",
            "completion_summary" => "UI ready",
            "evidence" => ["mix test"],
            "review_summary" => "reviewed",
            "blocked_reason" => nil,
            "hidden_field" => "不要暴露"
          },
          "plan" => %{
            "node_key" => "plan",
            "issue_id" => "issue-plan",
            "issue_identifier" => "MT-101",
            "title" => "Plan dashboard",
            "task_type" => "planning",
            "status" => "completed",
            "workflow_semantics" => "coordination",
            "completion_summary" => "Plan accepted",
            "evidence" => ["plan.json"],
            "review_summary" => nil,
            "blocked_reason" => nil
          }
        },
        "edges" => [
          %{"from" => "plan", "to" => "build", "type" => "depends_on"}
        ]
      }

    registry_path = Path.join([workspace_root, ".symphony", "workflows", "#{root_identifier}.json"])
    File.mkdir_p!(Path.dirname(registry_path))
    File.write!(registry_path, Jason.encode!(registry))

    assert {:ok, payload} = Presenter.workflow_payload(root_identifier, {:snapshot, workflow_snapshot()}, 1_000)

    assert payload.root_issue_identifier == root_identifier
    assert payload.root_issue_id == "root-id"
    assert payload.registry_available? == true
    assert payload.root_title == "Root workflow title"
    assert payload.status == "running"
    assert Enum.map(payload.nodes, & &1.node_key) == ["build", "plan"]

    assert List.first(payload.nodes) == %{
             node_key: "build",
             issue_id: "issue-build",
             issue_identifier: "MT-102",
             title: "Build dashboard",
             task_type: "implementation",
             status: "running",
             workflow_semantics: "executable",
             completion_summary: "UI ready",
             evidence_count: 1,
             review_summary: "reviewed",
             blocked_reason: nil
           }

    assert payload.edges == [%{from: "plan", to: "build", type: "depends_on"}]
    assert Enum.map(payload.runtime_entries, & &1.issue_identifier) == ["MT-RUN", "MT-RETRY", "MT-BLOCKED"]
    assert Enum.any?(payload.attention_items, &(&1.kind == "blocked"))
  end

  test "workflow_payload/3 在 registry 缺失但 snapshot 有 workflow 时返回 fallback payload" do
    workspace_root = configure_temporary_workspace_root("presenter-workflow-fallback")
    on_exit(fn -> File.rm_rf(workspace_root) end)

    assert {:ok, payload} = Presenter.workflow_payload("MT-ROOT", {:snapshot, workflow_snapshot()}, 1_000)

    assert payload.root_issue_identifier == "MT-ROOT"
    assert payload.registry_available? == false
    assert payload.nodes == []
    assert Enum.map(payload.runtime_entries, & &1.issue_identifier) == ["MT-RUN", "MT-RETRY", "MT-BLOCKED"]
  end

  test "workflow_payload/3 在 registry 和 runtime 都缺失时返回 workflow_not_found" do
    workspace_root = configure_temporary_workspace_root("presenter-workflow-missing")
    on_exit(fn -> File.rm_rf(workspace_root) end)

    assert {:error, :workflow_not_found} =
             Presenter.workflow_payload("MT-MISSING", {:snapshot, workflow_snapshot()}, 1_000)
  end

  defp workflow_snapshot do
    %{
      running: [
        running_entry(%{
          identifier: "MT-RUN",
          issue_id: "issue-run",
          issue_url: "https://example.org/issues/MT-RUN",
          workflow_phase: :review,
          workflow_root_issue_id: "MT-ROOT",
          last_codex_event: :notification,
          last_codex_message: "rendered",
          last_codex_timestamp: ~U[2026-01-01 00:01:00Z],
          runtime_seconds: 42
        })
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          issue_url: "https://example.org/issues/MT-RETRY",
          attempt: 2,
          due_in_ms: 2_000,
          error: "boom",
          agent_id: "mimocode",
          agent_kind: "cli_run",
          workflow_phase: :planning,
          workflow_root_issue_id: "MT-ROOT"
        }
      ],
      blocked: [
        %{
          issue_id: "issue-blocked",
          identifier: "MT-BLOCKED",
          issue_url: "https://example.org/issues/MT-BLOCKED",
          state: "In Progress",
          error: "codex turn requires operator input",
          agent_id: "mimocode",
          agent_kind: "cli_run",
          worker_host: "dm-dev2",
          workspace_path: "/workspaces/MT-BLOCKED",
          session_id: "thread-blocked",
          workflow_phase: :execution,
          workflow_root_issue_id: "MT-ROOT",
          blocked_at: ~U[2026-01-01 00:02:00Z],
          last_codex_event: :turn_input_required,
          last_codex_message: %{
            event: :turn_input_required,
            message: %{"method" => "turn/input_required"},
            timestamp: ~U[2026-01-01 00:03:00Z]
          },
          last_codex_timestamp: ~U[2026-01-01 00:03:00Z]
        }
      ],
      codex_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42},
      rate_limits: %{"primary" => %{"remaining" => 11}}
    }
  end

  defp running_entry(overrides) do
    Map.merge(
      %{
        issue_id: "issue-run",
        identifier: "MT-RUN",
        issue_url: "https://example.org/issues/MT-RUN",
        state: "In Progress",
        agent_id: "mimocode",
        agent_kind: "cli_run",
        worker_host: "dm-dev1",
        workspace_path: "/workspaces/MT-RUN",
        session_id: "thread-run",
        turn_count: 7,
        codex_app_server_pid: nil,
        last_codex_message: nil,
        last_codex_timestamp: ~U[2026-01-01 00:00:00Z],
        last_codex_event: nil,
        codex_input_tokens: 4,
        codex_output_tokens: 8,
        codex_total_tokens: 12,
        workflow_phase: nil,
        workflow_root_issue_id: nil,
        started_at: ~U[2026-01-01 00:00:00Z],
        runtime_seconds: 5
      },
      overrides
    )
  end

  defp configure_temporary_workspace_root(prefix) do
    workspace_root = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive, :monotonic])}")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      orchestration: %{enabled: true, artifact_dir: ".symphony"}
    )

    workspace_root
  end
end
