defmodule SymphonyElixir.AcpStdioClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.AcpStdio.Client

  test "starts a session and completes a prompt through an ACP stdio process" do
    test_root = Path.join(System.tmp_dir!(), "symphony-acp-client-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)
      {executable, env} = SymphonyElixir.FakeAcpServer.write!(test_root, %{"sessionId" => "fake-acp-session"})

      parent = self()

      assert {:ok, session} =
               Client.start_session(
                 workspace,
                 %{command: executable, args: [], env: env, permission_policy: "reject", timeout_ms: 5_000},
                 fn event -> send(parent, {:acp_event, event}) end
               )

      assert session.session_id == "fake-acp-session"

      assert {:ok, result} = Client.prompt(session, "hello", timeout_ms: 5_000)
      assert Map.get(result, "stop_reason") == "end_turn"

      assert_receive {:acp_event, %{event: :session_started, session_id: "fake-acp-session"}}
      assert_receive {:acp_event, %{event: :notification, payload: %{"method" => "session/update"}}}

      assert :ok = Client.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end
end
