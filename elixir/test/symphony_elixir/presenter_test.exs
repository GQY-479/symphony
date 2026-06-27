defmodule SymphonyElixirWeb.PresenterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixirWeb.Presenter

  @snapshot_timeout_ms 5_000

  defp build_orchestrator!(name) do
    {:ok, pid} = Orchestrator.start_link(name: name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    name
  end

  defp replace_state!(orchestrator, state_fun) do
    pid = GenServer.whereis(orchestrator)
    :sys.replace_state(pid, state_fun)
  end

  defp base_issue(identifier, overrides \\ []) do
    defaults = [
      id: "issue-#{identifier}",
      identifier: identifier,
      title: "Test issue",
      state: "In Progress",
      url: "https://linear.app/yqeeqy/issue/#{identifier}"
    ]

    struct!(Issue, Keyword.merge(defaults, overrides))
  end

  defp base_running_entry(issue, overrides) do
    defaults = [
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      agent_id: "mimocode",
      agent_kind: "cli_run",
      session_id: "thread-1-turn-1",
      turn_count: 3,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_app_server_pid: "4242",
      codex_input_tokens: 100,
      codex_output_tokens: 50,
      codex_total_tokens: 150,
      started_at: DateTime.utc_now()
    ]

    Map.merge(Map.new(defaults), Map.new(overrides))
  end

  defp base_retry_entry(issue, overrides) do
    defaults = [
      issue_id: issue.id,
      attempt: 2,
      due_at_ms: System.monotonic_time(:millisecond) + 5_000,
      timer_ref: nil,
      identifier: issue.identifier,
      issue_url: issue.url,
      error: "worker exited: :normal"
    ]

    Map.merge(Map.new(defaults), Map.new(overrides))
  end

  defp base_blocked_entry(issue, overrides) do
    defaults = [
      issue_id: issue.id,
      identifier: issue.identifier,
      issue: issue,
      agent_id: "mimocode",
      agent_kind: "cli_run",
      session_id: "thread-blocked-turn-blocked",
      error: "workflow waiting on dependencies",
      blocked_at: DateTime.utc_now(),
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil
    ]

    Map.merge(Map.new(defaults), Map.new(overrides))
  end

  describe "state_payload/2" do
    test "includes workflow_phase in running entries" do
      orchestrator = build_orchestrator!(PresenterTest.RunningPhaseOrch)
      issue = base_issue("MT-RP")
      entry = base_running_entry(issue, workflow_phase: :planning)

      replace_state!(orchestrator, fn state ->
        state
        |> Map.put(:running, %{issue.id => entry})
        |> Map.put(:claimed, MapSet.put(state.claimed, issue.id))
      end)

      payload = Presenter.state_payload(orchestrator, @snapshot_timeout_ms)

      assert [running] = payload.running
      assert running.workflow_phase == :planning
      assert running.issue_identifier == "MT-RP"
      assert running.agent_id == "mimocode"
    end

    test "includes nil workflow_phase for entries without it" do
      orchestrator = build_orchestrator!(PresenterTest.NoPhaseOrch)
      issue = base_issue("MT-NP")
      entry = base_running_entry(issue, workflow_phase: nil)

      replace_state!(orchestrator, fn state ->
        state
        |> Map.put(:running, %{issue.id => entry})
        |> Map.put(:claimed, MapSet.put(state.claimed, issue.id))
      end)

      payload = Presenter.state_payload(orchestrator, @snapshot_timeout_ms)

      assert [running] = payload.running
      assert running.workflow_phase == nil
    end

    test "includes workflow_phase in retry entries" do
      orchestrator = build_orchestrator!(PresenterTest.RetryPhaseOrch)
      issue = base_issue("MT-RTRP")
      entry = base_retry_entry(issue, workflow_phase: :issue)

      replace_state!(orchestrator, fn state ->
        %{state | retry_attempts: %{issue.id => entry}}
      end)

      payload = Presenter.state_payload(orchestrator, @snapshot_timeout_ms)

      assert [retrying] = payload.retrying
      assert retrying.workflow_phase == :issue
      assert retrying.issue_identifier == "MT-RTRP"
    end

    test "includes workflow_phase in blocked entries" do
      orchestrator = build_orchestrator!(PresenterTest.BlockedPhaseOrch)
      issue = base_issue("MT-BP")
      entry = base_blocked_entry(issue, workflow_phase: :issue)

      replace_state!(orchestrator, fn state ->
        state
        |> Map.put(:running, %{})
        |> Map.put(:retry_attempts, %{})
        |> Map.put(:blocked, %{issue.id => entry})
      end)

      payload = Presenter.state_payload(orchestrator, @snapshot_timeout_ms)

      assert [blocked] = payload.blocked
      assert blocked.workflow_phase == :issue
      assert blocked.issue_identifier == "MT-BP"
    end

    test "resolves workflow_artifact_path for planning phase" do
      orchestrator = build_orchestrator!(PresenterTest.ArtifactPathOrch)
      issue = base_issue("MT-AP")
      workspace = "/tmp/symphony_workspaces/MT-AP"

      entry = base_running_entry(issue, workflow_phase: :planning, workspace_path: workspace)

      replace_state!(orchestrator, fn state ->
        state
        |> Map.put(:running, %{issue.id => entry})
        |> Map.put(:claimed, MapSet.put(state.claimed, issue.id))
      end)

      payload = Presenter.state_payload(orchestrator, @snapshot_timeout_ms)

      assert [running] = payload.running
      assert running.workflow_phase == :planning
      assert running.workflow_artifact_path =~ "workflow_plan.json"
    end

    test "resolves workflow_artifact_path for issue phase" do
      orchestrator = build_orchestrator!(PresenterTest.ExecutionArtifactOrch)
      issue = base_issue("MT-EAP")
      workspace = "/tmp/symphony_workspaces/MT-EAP"

      entry = base_running_entry(issue, workflow_phase: :issue, workspace_path: workspace)

      replace_state!(orchestrator, fn state ->
        state
        |> Map.put(:running, %{issue.id => entry})
        |> Map.put(:claimed, MapSet.put(state.claimed, issue.id))
      end)

      payload = Presenter.state_payload(orchestrator, @snapshot_timeout_ms)

      assert [running] = payload.running
      assert running.workflow_phase == :issue
      assert running.workflow_artifact_path =~ "issue_result.json"
    end

    test "retired workflow phases do not expose artifact paths" do
      orchestrator = build_orchestrator!(PresenterTest.ReviewArtifactOrch)
      issue = base_issue("MT-RVAP")
      workspace = "/tmp/symphony_workspaces/MT-RVAP"

      entry = base_running_entry(issue, workflow_phase: :review, workspace_path: workspace)

      replace_state!(orchestrator, fn state ->
        state
        |> Map.put(:running, %{issue.id => entry})
        |> Map.put(:claimed, MapSet.put(state.claimed, issue.id))
      end)

      payload = Presenter.state_payload(orchestrator, @snapshot_timeout_ms)

      assert [running] = payload.running
      assert running.workflow_phase == :review
      assert running.workflow_artifact_path == nil
    end

    test "returns nil workflow_artifact_path when phase is nil" do
      orchestrator = build_orchestrator!(PresenterTest.NilArtifactOrch)
      issue = base_issue("MT-NAP")
      workspace = "/tmp/symphony_workspaces/MT-NAP"

      entry = base_running_entry(issue, workflow_phase: nil, workspace_path: workspace)

      replace_state!(orchestrator, fn state ->
        state
        |> Map.put(:running, %{issue.id => entry})
        |> Map.put(:claimed, MapSet.put(state.claimed, issue.id))
      end)

      payload = Presenter.state_payload(orchestrator, @snapshot_timeout_ms)

      assert [running] = payload.running
      assert running.workflow_phase == nil
      assert running.workflow_artifact_path == nil
    end

    test "workflow phase does not assume a fixed sequence" do
      orchestrator = build_orchestrator!(PresenterTest.DynamicPhaseOrch)

      issue_a = base_issue("MT-DYN-A")
      entry_a = base_running_entry(issue_a, workflow_phase: :issue)

      issue_b = base_issue("MT-DYN-B")
      entry_b = base_running_entry(issue_b, workflow_phase: :issue)

      issue_c = base_issue("MT-DYN-C")
      entry_c = base_running_entry(issue_c, workflow_phase: :planning)

      replace_state!(orchestrator, fn state ->
        state
        |> Map.put(:running, %{
          issue_a.id => entry_a,
          issue_b.id => entry_b,
          issue_c.id => entry_c
        })
        |> Map.put(:claimed, MapSet.new([issue_a.id, issue_b.id, issue_c.id]))
      end)

      payload = Presenter.state_payload(orchestrator, @snapshot_timeout_ms)
      phases = Enum.map(payload.running, & &1.workflow_phase) |> Enum.sort()

      assert :planning in phases
      assert Enum.count(phases, &(&1 == :issue)) == 2
    end
  end

  describe "issue_payload/3" do
    test "includes workflow_phase in running issue detail" do
      orchestrator = build_orchestrator!(PresenterTest.IssueDetailOrch)
      issue = base_issue("MT-ID")
      entry = base_running_entry(issue, workflow_phase: :planning, workspace_path: "/tmp/ws/MT-ID")

      replace_state!(orchestrator, fn state ->
        state
        |> Map.put(:running, %{issue.id => entry})
        |> Map.put(:claimed, MapSet.put(state.claimed, issue.id))
      end)

      assert {:ok, detail} = Presenter.issue_payload("MT-ID", orchestrator, @snapshot_timeout_ms)
      assert detail.running.workflow_phase == :planning
      assert detail.status == "running"
    end

    test "surfaces retry attempt while an issue is running from a retry dispatch" do
      orchestrator = build_orchestrator!(PresenterTest.IssueRunningRetryAttemptOrch)
      issue = base_issue("MT-RRA")
      entry = base_running_entry(issue, workflow_phase: :issue, retry_attempt: 2)

      replace_state!(orchestrator, fn state ->
        state
        |> Map.put(:running, %{issue.id => entry})
        |> Map.put(:claimed, MapSet.put(state.claimed, issue.id))
        |> Map.put(:retry_attempts, %{})
      end)

      assert {:ok, detail} = Presenter.issue_payload("MT-RRA", orchestrator, @snapshot_timeout_ms)
      assert detail.status == "running"
      assert detail.attempts.current_retry_attempt == 2
      assert detail.attempts.restart_count == 1
    end

    test "includes workflow_phase in retry issue detail" do
      orchestrator = build_orchestrator!(PresenterTest.IssueRetryDetailOrch)
      issue = base_issue("MT-IRD")
      entry = base_retry_entry(issue, workflow_phase: :issue)

      replace_state!(orchestrator, fn state ->
        %{state | retry_attempts: %{issue.id => entry}}
      end)

      assert {:ok, detail} = Presenter.issue_payload("MT-IRD", orchestrator, @snapshot_timeout_ms)
      assert detail.retry.workflow_phase == :issue
      assert detail.status == "retrying"
    end

    test "includes workflow_phase in blocked issue detail" do
      orchestrator = build_orchestrator!(PresenterTest.IssueBlockedDetailOrch)
      issue = base_issue("MT-IBD")
      entry = base_blocked_entry(issue, workflow_phase: :issue)

      replace_state!(orchestrator, fn state ->
        state
        |> Map.put(:running, %{})
        |> Map.put(:retry_attempts, %{})
        |> Map.put(:blocked, %{issue.id => entry})
      end)

      assert {:ok, detail} = Presenter.issue_payload("MT-IBD", orchestrator, @snapshot_timeout_ms)
      assert detail.blocked.workflow_phase == :issue
      assert detail.status == "blocked"
    end

    test "returns issue_not_found for unknown identifier" do
      orchestrator = build_orchestrator!(PresenterTest.NotFoundOrch)

      assert {:error, :issue_not_found} =
               Presenter.issue_payload("MT-UNKNOWN", orchestrator, @snapshot_timeout_ms)
    end
  end
end
