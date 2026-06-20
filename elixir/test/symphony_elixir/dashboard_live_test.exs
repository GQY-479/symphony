defmodule SymphonyElixirWeb.DashboardLiveTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end
  end

  test "首页渲染 root workflow 卡片和 attention inbox" do
    orchestrator_name = Module.concat(__MODULE__, :WorkflowHomeOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: workflow_snapshot()
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "Root Workflows"
    assert html =~ "SYM-500"
    assert html =~ "execution"
    assert html =~ "Attention Inbox"
    assert html =~ "review needs human"
    assert html =~ "/workflows/SYM-500"
  end

  test "workflow 详情页在 registry 不可用时展示 runtime entries" do
    orchestrator_name = Module.concat(__MODULE__, :WorkflowDetailOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: workflow_snapshot()
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/workflows/SYM-500")

    assert html =~ "SYM-500"
    assert html =~ "Registry unavailable"
    assert html =~ "SYM-501"
    assert html =~ "execution"
  end

  test "首页在没有活动 workflow 时展示安静空态" do
    orchestrator_name = Module.concat(__MODULE__, :EmptyWorkflowHomeOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: empty_snapshot()
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "No active root workflows"
    assert html =~ "No operator action needed"
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp workflow_snapshot do
    %{
      running: [
        %{
          issue_id: "issue-run",
          identifier: "SYM-501",
          issue_url: "https://example.org/issues/SYM-501",
          state: "In Progress",
          agent_id: "codex",
          agent_kind: "cli_run",
          session_id: "thread-run",
          turn_count: 3,
          codex_app_server_pid: nil,
          last_codex_message: "rendered",
          last_codex_timestamp: ~U[2026-01-01 00:01:00Z],
          last_codex_event: :notification,
          codex_input_tokens: 10,
          codex_output_tokens: 20,
          codex_total_tokens: 30,
          workflow_phase: :execution,
          workflow_root_issue_id: "SYM-500",
          started_at: ~U[2026-01-01 00:00:00Z],
          runtime_seconds: 60
        }
      ],
      retrying: [],
      blocked: [
        %{
          issue_id: "issue-review",
          identifier: "SYM-502",
          issue_url: "https://example.org/issues/SYM-502",
          state: "In Progress",
          error: "review needs human",
          agent_id: "codex",
          agent_kind: "cli_run",
          worker_host: "local",
          workspace_path: "/workspaces/SYM-502",
          session_id: "thread-review",
          workflow_phase: :execution,
          workflow_root_issue_id: "SYM-500",
          blocked_at: ~U[2026-01-01 00:02:00Z],
          last_codex_event: :turn_input_required,
          last_codex_message: "review needs human",
          last_codex_timestamp: ~U[2026-01-01 00:03:00Z]
        }
      ],
      codex_totals: %{input_tokens: 10, output_tokens: 20, total_tokens: 30, seconds_running: 60},
      rate_limits: nil
    }
  end

  defp empty_snapshot do
    %{
      running: [],
      retrying: [],
      blocked: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil
    }
  end
end
