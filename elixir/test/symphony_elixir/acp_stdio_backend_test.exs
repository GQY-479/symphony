defmodule SymphonyElixir.AcpStdioBackendTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.Backend.AcpStdio

  test "starts session, annotates events, and runs a prompt" do
    test_root = Path.join(System.tmp_dir!(), "symphony-acp-backend-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)
      {executable, env} = SymphonyElixir.FakeAcpServer.write!(test_root, %{"sessionId" => "fake-acp-session"})

      resolved_agent = %{
        id: "mimocode",
        kind: "acp_stdio",
        config: %{
          "command" => executable,
          "args" => [],
          "permission_policy" => "reject",
          "timeout_ms" => 5_000,
          "env" => env
        }
      }

      parent = self()

      assert {:ok, session} =
               AcpStdio.start_session(
                 workspace,
                 resolved_agent,
                 on_message: fn message -> send(parent, {:acp_backend_message, message}) end
               )

      assert {:ok, result} =
               AcpStdio.run_turn(
                 session,
                 workspace,
                 %Issue{id: "issue-acp-backend", identifier: "MT-910"},
                 "perform acp task",
                 on_message: fn message -> send(parent, {:acp_backend_message, message}) end
               )

      assert result.session_id == "fake-acp-session"

      assert_receive {:acp_backend_message,
                      %{
                        event: :session_started,
                        agent_id: "mimocode",
                        agent_kind: "acp_stdio",
                        session_id: "fake-acp-session"
                      }}

      assert_receive {:acp_backend_message,
                      %{
                        event: :turn_completed,
                        agent_id: "mimocode",
                        agent_kind: "acp_stdio",
                        session_id: "fake-acp-session"
                      }}

      assert :ok = AcpStdio.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end
end
