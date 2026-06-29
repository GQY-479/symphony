defmodule SymphonyElixir.OrchestratorReasonCategoryTest do
  use SymphonyElixir.TestSupport

  defp make_running_entry(issue, overrides \\ []) do
    defaults = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      agent_id: "mimocode",
      agent_kind: "cli_run",
      session_id: "test-session",
      turn_count: 0,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now()
    }

    Map.merge(defaults, Map.new(overrides))
  end

  defp start_test_orchestrator(name) do
    {:ok, pid} = Orchestrator.start_link(name: name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    pid
  end

  defp build_state_with_running(pid, issue, running_entry) do
    initial_state = :sys.get_state(pid)

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue.id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue.id))
    end)

    :sys.get_state(pid)
  end

  describe "categorize_error" do
    test "categorizes agent failure errors" do
      assert {:agent_failure, _reason} =
               Orchestrator.categorize_error_for_test("agent exited: {:badarg, []}")
    end

    test "categorizes agent stall errors" do
      assert {:agent_failure, _reason} =
               Orchestrator.categorize_error_for_test("stalled for 300000ms without codex activity")
    end

    test "categorizes missing credentials errors" do
      assert {:missing_credentials, _reason} =
               Orchestrator.categorize_error_for_test("missing tracker api key")
    end

    test "categorizes missing linear api token" do
      assert {:missing_credentials, _reason} =
               Orchestrator.categorize_error_for_test("missing linear api token")
    end

    test "categorizes missing linear project slug" do
      assert {:missing_credentials, _reason} =
               Orchestrator.categorize_error_for_test("missing linear project slug")
    end

    test "categorizes artifact validation errors for enoent" do
      assert {:artifact_validation, _reason} =
               Orchestrator.categorize_error_for_test("planning phase completed without required artifact: expected plan.json; reason=:enoent")
    end

    test "categorizes artifact validation errors for invalid" do
      assert {:artifact_validation, _reason} =
               Orchestrator.categorize_error_for_test("execution artifact invalid: expected packet.json; reason=:invalid")
    end

    test "categorizes workflow artifact repair failure" do
      assert {:artifact_validation, _reason} =
               Orchestrator.categorize_error_for_test("workflow artifact repair failed: phase=review expected review.json; reason=:enoent")
    end

    test "categorizes operator input needed for codex turn" do
      assert {:operator_input_needed, _reason} =
               Orchestrator.categorize_error_for_test("codex turn requires operator input")
    end

    test "categorizes operator input needed for approval" do
      assert {:operator_input_needed, _reason} =
               Orchestrator.categorize_error_for_test("codex turn requires approval")
    end

    test "categorizes operator input needed for MCP elicitation" do
      assert {:operator_input_needed, _reason} =
               Orchestrator.categorize_error_for_test("codex MCP elicitation requires operator input")
    end

    test "categorizes operator input needed for workflow human input" do
      assert {:operator_input_needed, _reason} =
               Orchestrator.categorize_error_for_test("workflow needs human input: provide criteria")
    end

    test "categorizes operator input needed for review needs human" do
      assert {:operator_input_needed, _reason} =
               Orchestrator.categorize_error_for_test("review needs human: missing approval")
    end

    test "categorizes workflow failure" do
      assert {:workflow_failure, _reason} =
               Orchestrator.categorize_error_for_test("review failed: incomplete changes")
    end

    test "categorizes workflow waiting" do
      assert {:workflow_waiting, _reason} =
               Orchestrator.categorize_error_for_test("workflow waiting on dependencies")
    end

    test "categorizes workflow blocked" do
      assert {:workflow_waiting, _reason} =
               Orchestrator.categorize_error_for_test("workflow blocked: dependency issue")
    end

    test "categorizes workflow failed" do
      assert {:workflow_waiting, _reason} =
               Orchestrator.categorize_error_for_test("workflow failed: planner error")
    end

    test "categorizes configuration errors" do
      assert {:configuration, _reason} =
               Orchestrator.categorize_error_for_test("orchestration is disabled; set orchestration.mode: legacy only for compatibility")
    end

    test "categorizes unknown errors as unknown" do
      assert {:unknown, "some random error"} =
               Orchestrator.categorize_error_for_test("some random error")
    end

    test "extracts short reason without agent diagnostics" do
      {_category, reason} =
        Orchestrator.categorize_error_for_test("planning phase completed without required artifact: expected plan.json; agent_id=mimocode agent_kind=cli_run session_id=test reason=:enoent")

      assert is_binary(reason)
      assert reason =~ "planning phase completed without required artifact"
      refute reason =~ "agent_id="
    end
  end

  describe "blocked entries from orchestrator" do
    test "blocked entry for input-required agent includes reason_category :operator_input_needed" do
      issue = %Issue{
        id: "issue-input-required",
        identifier: "MT-INPUT",
        title: "Input required test",
        state: "In Progress",
        url: "https://linear.app/yqeeqy/issue/MT-INPUT"
      }

      orchestrator_name = Module.concat(__MODULE__, :InputRequiredCategory)
      pid = start_test_orchestrator(orchestrator_name)

      running_entry =
        make_running_entry(issue, %{
          last_codex_event: :turn_input_required,
          last_codex_message: %{message: %{"method" => "mcpServer/elicitation/request"}}
        })

      state = build_state_with_running(pid, issue, running_entry)

      result_state =
        Orchestrator.handle_agent_down_for_test(
          {:shutdown, :input_required},
          state,
          issue.id,
          running_entry
        )

      entry = Map.get(result_state.blocked, issue.id)

      assert entry != nil
      assert entry.reason_category == :operator_input_needed
      assert is_binary(entry.reason)
      assert entry.error =~ "codex turn requires operator input"
    end

    test "blocked entry for artifact repair failure includes reason_category :artifact_validation" do
      issue = %Issue{
        id: "issue-artifact-repair",
        identifier: "MT-ART",
        title: "Artifact repair test",
        state: "In Progress",
        url: "https://linear.app/yqeeqy/issue/MT-ART"
      }

      orchestrator_name = Module.concat(__MODULE__, :ArtifactValidationCategory)
      pid = start_test_orchestrator(orchestrator_name)

      running_entry = make_running_entry(issue)
      state = build_state_with_running(pid, issue, running_entry)

      error =
        AgentRunner.Error.exception(reason: {:workflow_artifact_repair_failed, :planning, "/workspace/.symphony/workflow_plan.json", :enoent})

      result_state =
        Orchestrator.handle_agent_down_for_test({error, []}, state, issue.id, running_entry)

      entry = Map.get(result_state.blocked, issue.id)

      assert entry != nil
      assert entry.reason_category == :artifact_validation
      assert is_binary(entry.reason)
      assert entry.error =~ "workflow artifact repair failed"
    end

    test "blocked entry for MCP elicitation stall includes reason_category :operator_input_needed" do
      issue = %Issue{
        id: "issue-mcp-elicitation",
        identifier: "MT-MCP",
        title: "MCP elicitation test",
        state: "In Progress",
        url: "https://linear.app/yqeeqy/issue/MT-MCP"
      }

      orchestrator_name = Module.concat(__MODULE__, :McpElicitationCategory)
      pid = start_test_orchestrator(orchestrator_name)

      stale_time = DateTime.add(DateTime.utc_now(), -5, :second)

      running_entry =
        make_running_entry(issue, %{
          agent_stall_timeout_ms: 1_000,
          worker_host: "dm-dev2",
          workspace_path: "/workspaces/MT-MCP",
          last_codex_message: %{
            event: :notification,
            message: %{"method" => "mcpServer/elicitation/request"},
            timestamp: stale_time
          },
          last_codex_timestamp: stale_time,
          last_codex_event: :notification
        })

      state = build_state_with_running(pid, issue, running_entry)

      result_state =
        Orchestrator.handle_agent_down_for_test({:shutdown, :stall}, state, issue.id, running_entry)

      entry = Map.get(result_state.blocked, issue.id)

      assert entry != nil
      assert entry.reason_category == :operator_input_needed
      assert is_binary(entry.reason)
    end

    test "orchestrator snapshot includes reason_category and reason for blocked entries" do
      orchestrator_name = Module.concat(__MODULE__, :SnapshotReasonCategory)
      pid = start_test_orchestrator(orchestrator_name)

      initial_state = :sys.get_state(pid)

      blocked_entry = %{
        identifier: "MT-CAT",
        issue: %Issue{id: "issue-cat", identifier: "MT-CAT", state: "In Progress"},
        error: "codex turn requires operator input",
        reason_category: :operator_input_needed,
        reason: "codex turn requires operator input",
        agent_id: "mimocode",
        agent_kind: "cli_run",
        workflow_phase: :issue,
        blocked_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:blocked, %{"issue-cat" => blocked_entry})
      end)

      snapshot = Orchestrator.snapshot(orchestrator_name, 1_000)
      assert %{blocked: [blocked]} = snapshot
      assert blocked.reason_category == :operator_input_needed
      assert blocked.reason == "codex turn requires operator input"
      assert blocked.error == "codex turn requires operator input"
    end

    test "status dashboard renders reason category for blocked entries" do
      snapshot_data =
        {:ok,
         %{
           running: [],
           retrying: [],
           blocked: [
             %{
               identifier: "MT-CAT",
               workflow_phase: :issue,
               reason_category: :operator_input_needed,
               workflow_blocked_reason: "codex turn requires operator input",
               error: "codex turn requires operator input"
             }
           ],
           codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
           rate_limits: nil
         }}

      rendered = StatusDashboard.format_snapshot_content_for_test(snapshot_data, 0.0)
      plain = Regex.replace(~r/\e\[[0-9;]*m/, rendered, "")

      assert plain =~ "Blocked"
      assert plain =~ "MT-CAT"
      assert plain =~ "category=operator_input_needed"
      assert plain =~ "codex turn requires operator input"
    end
  end
end
