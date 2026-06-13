defmodule SymphonyElixir.AcpAgentRunnerTest do
  use SymphonyElixir.TestSupport

  test "AgentRunner runs acp_stdio agents as session backends" do
    test_root = Path.join(System.tmp_dir!(), "symphony-acp-runner-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)
      {executable, _env} = SymphonyElixir.FakeAcpServer.write!(test_root, %{"sessionId" => "fake-acp-session"})

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        agents: %{
          mimocode: %{
            kind: "acp_stdio",
            command: executable,
            args: [],
            permission_policy: "reject",
            timeout_ms: 5_000,
            read_timeout_ms: 5_000
          }
        },
        routing: %{default_agent: "mimocode"}
      )

      issue = %Issue{
        id: "issue-acp-runner",
        identifier: "MT-911",
        title: "ACP runner",
        description: "Run through ACP",
        state: "In Progress",
        labels: []
      }

      assert :ok =
               AgentRunner.run(
                 issue,
                 self(),
                 agent_id: "mimocode",
                 max_turns: 1,
                 issue_state_fetcher: fn ["issue-acp-runner"] -> {:ok, [%{issue | state: "Done"}]} end
               )

      assert_receive {:codex_worker_update, "issue-acp-runner",
                      %{
                        event: :turn_completed,
                        agent_id: "mimocode",
                        agent_kind: "acp_stdio",
                        session_id: "fake-acp-session"
                      }}
    after
      File.rm_rf(test_root)
    end
  end
end
