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

  test "rejects ACP permission requests by default" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-acp-client-permission-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)
      {executable, env} = SymphonyElixir.FakeAcpServer.write!(test_root, %{"sessionId" => "fake-acp-session", "permission" => true})

      parent = self()

      assert {:ok, session} =
               Client.start_session(
                 workspace,
                 %{command: executable, args: [], env: env, permission_policy: "reject", timeout_ms: 5_000},
                 fn event -> send(parent, {:acp_event, event}) end
               )

      assert {:ok, _result} = Client.prompt(session, "hello", timeout_ms: 5_000)

      assert_receive {:acp_event, %{event: :permission_rejected, payload: %{"toolCall" => %{"title" => "write"}}}}

      assert :ok = Client.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end

  test "allows ACP permission requests when policy is allow" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-acp-client-permission-allow-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)
      {executable, env} = SymphonyElixir.FakeAcpServer.write!(test_root, %{"sessionId" => "fake-acp-session", "permission" => true})

      parent = self()

      assert {:ok, session} =
               Client.start_session(
                 workspace,
                 %{command: executable, args: [], env: env, permission_policy: "allow", timeout_ms: 5_000},
                 fn event -> send(parent, {:acp_event, event}) end
               )

      assert {:ok, _result} = Client.prompt(session, "hello", timeout_ms: 5_000)

      assert_receive {:acp_event, %{event: :approval_auto_approved, payload: %{"toolCall" => %{"title" => "write"}}}}

      assert :ok = Client.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end

  test "fails the prompt when permission policy is fail" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-acp-client-permission-fail-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)
      {executable, env} = SymphonyElixir.FakeAcpServer.write!(test_root, %{"sessionId" => "fake-acp-session", "permission" => true})

      parent = self()

      assert {:ok, session} =
               Client.start_session(
                 workspace,
                 %{command: executable, args: [], env: env, permission_policy: "fail", timeout_ms: 5_000},
                 fn event -> send(parent, {:acp_event, event}) end
               )

      assert {:error, {:permission_required, %{"toolCall" => %{"title" => "write"}}}} =
               Client.prompt(session, "hello", timeout_ms: 5_000)

      assert_receive {:acp_event, %{event: :approval_required, payload: %{"toolCall" => %{"title" => "write"}}}}

      assert :ok = Client.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end

  test "emits malformed events and continues reading valid ACP messages" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-acp-client-malformed-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)
      {executable, env} = SymphonyElixir.FakeAcpServer.write!(test_root, %{"sessionId" => "fake-acp-session", "malformed" => true})

      parent = self()

      assert {:ok, session} =
               Client.start_session(
                 workspace,
                 %{command: executable, args: [], env: env, permission_policy: "reject", timeout_ms: 5_000},
                 fn event -> send(parent, {:acp_event, event}) end
               )

      assert {:ok, result} = Client.prompt(session, "hello", timeout_ms: 5_000)
      assert Map.get(result, "stop_reason") == "end_turn"

      assert_receive {:acp_event, %{event: :malformed, payload: %{"line" => "not-json"}}}
      assert_receive {:acp_event, %{event: :notification, payload: %{"method" => "session/update"}}}

      assert :ok = Client.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end

  test "sends session cancel when prompt times out" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-acp-client-timeout-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(test_root, "workspace")
      trace_file = Path.join(test_root, "acp.trace")
      File.mkdir_p!(workspace)

      {executable, env} =
        SymphonyElixir.FakeAcpServer.write!(test_root, %{
          "sessionId" => "fake-acp-session",
          "delayPromptMs" => 500,
          "traceFile" => trace_file
        })

      assert {:ok, session} =
               Client.start_session(
                 workspace,
                 %{command: executable, args: [], env: env, permission_policy: "reject", timeout_ms: 5_000},
                 fn _event -> :ok end
               )

      assert {:error, :acp_timeout} = Client.prompt(session, "hello", timeout_ms: 25)

      assert eventually_file_contains?(trace_file, "session/cancel", 1_000)

      assert :ok = Client.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end

  defp eventually_file_contains?(path, expected, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    eventually_file_contains?(path, expected, deadline, false)
  end

  defp eventually_file_contains?(path, expected, deadline, last_result) do
    found? = File.exists?(path) and String.contains?(File.read!(path), expected)

    cond do
      found? ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        last_result

      true ->
        Process.sleep(25)
        eventually_file_contains?(path, expected, deadline, found?)
    end
  end
end
