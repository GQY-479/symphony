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

  test "starts a session against ACP servers that require mcpServers" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-acp-client-session-new-mcp-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)

      {executable, env} =
        SymphonyElixir.FakeAcpServer.write!(test_root, %{
          "sessionId" => "fake-acp-session",
          "sessionNewRequiresMcpServers" => true
        })

      assert {:ok, session} =
               Client.start_session(
                 workspace,
                 %{command: executable, args: [], env: env, permission_policy: "reject", timeout_ms: 5_000},
                 fn _event -> :ok end
               )

      assert session.session_id == "fake-acp-session"
      assert :ok = Client.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end

  test "injects configured MCP servers into session/new params" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-acp-client-mcp-injection-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(test_root, "workspace")
      trace_file = Path.join(test_root, "acp.trace")
      File.mkdir_p!(workspace)

      {executable, env} =
        SymphonyElixir.FakeAcpServer.write!(test_root, %{
          "sessionId" => "fake-acp-session",
          "traceFile" => trace_file,
          "traceMessages" => true
        })

      assert {:ok, session} =
               Client.start_session(
                 workspace,
                 %{
                   command: executable,
                   args: [],
                   env: env,
                   permission_policy: "reject",
                   timeout_ms: 5_000,
                   mcp: %{
                     "linear_tools" => true,
                     "url" => "http://127.0.0.1:4000/mcp/linear-tools"
                   }
                 },
                 fn _event -> :ok end
               )

      session_new =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.find_value(fn line ->
          if String.starts_with?(line, "JSON:") do
            payload = line |> String.trim_leading("JSON:") |> Jason.decode!()
            if payload["method"] == "session/new", do: payload
          end
        end)

      assert get_in(session_new, ["params", "mcpServers"]) == [
               %{
                 "name" => "symphony-linear",
                 "type" => "http",
                 "url" => "http://127.0.0.1:4000/mcp/linear-tools",
                 "headers" => [],
                 "env" => []
               }
             ]

      assert :ok = Client.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end

  test "applies configured ACP session config options after creating a session" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-acp-client-config-options-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(test_root, "workspace")
      trace_file = Path.join(test_root, "acp.trace")
      File.mkdir_p!(workspace)

      {executable, env} =
        SymphonyElixir.FakeAcpServer.write!(test_root, %{
          "sessionId" => "fake-acp-session",
          "traceFile" => trace_file,
          "traceMessages" => true,
          "expectedConfigOptions" => %{"model" => "mimo/mimo-auto"}
        })

      assert {:ok, session} =
               Client.start_session(
                 workspace,
                 %{
                   command: executable,
                   args: [],
                   env: env,
                   permission_policy: "reject",
                   timeout_ms: 5_000,
                   config_options: %{"model" => "mimo/mimo-auto"}
                 },
                 fn _event -> :ok end
               )

      trace = File.read!(trace_file)
      assert trace =~ "session/set_config_option"

      assert trace
             |> String.split("\n", trim: true)
             |> Enum.any?(fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload = line |> String.trim_leading("JSON:") |> Jason.decode!()

                 payload["method"] == "session/set_config_option" &&
                   get_in(payload, ["params", "sessionId"]) == "fake-acp-session" &&
                   get_in(payload, ["params", "configId"]) == "model" &&
                   get_in(payload, ["params", "value"]) == "mimo/mimo-auto"
               else
                 false
               end
             end)

      assert :ok = Client.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end

  test "does not send session close when ACP server does not advertise close capability" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-acp-client-no-close-capability-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(test_root, "workspace")
      trace_file = Path.join(test_root, "acp.trace")
      File.mkdir_p!(workspace)

      {executable, env} =
        SymphonyElixir.FakeAcpServer.write!(test_root, %{
          "sessionId" => "fake-acp-session",
          "traceFile" => trace_file
        })

      assert {:ok, session} =
               Client.start_session(
                 workspace,
                 %{command: executable, args: [], env: env, permission_policy: "reject", timeout_ms: 5_000},
                 fn _event -> :ok end
               )

      assert :ok = Client.stop_session(session)

      assert eventually_file_contains?(trace_file, "session/new", 1_000)
      refute eventually_file_contains?(trace_file, "session/close", 500)
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

  test "allow policy selects MiMo-Code compatible permission option id" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-acp-client-permission-option-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)

      {executable, env} =
        SymphonyElixir.FakeAcpServer.write!(test_root, %{
          "sessionId" => "fake-acp-session",
          "permission" => true,
          "expectedPermissionOptionId" => "once"
        })

      assert {:ok, session} =
               Client.start_session(
                 workspace,
                 %{command: executable, args: [], env: env, permission_policy: "allow", timeout_ms: 5_000},
                 fn _event -> :ok end
               )

      assert {:ok, _result} = Client.prompt(session, "hello", timeout_ms: 5_000)

      assert :ok = Client.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end

  test "allow policy selects the offered allow_once permission option" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-acp-client-permission-offered-option-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)

      {executable, env} =
        SymphonyElixir.FakeAcpServer.write!(test_root, %{
          "sessionId" => "fake-acp-session",
          "permission" => true,
          "permissionOptions" => [
            %{"optionId" => "custom-allow", "kind" => "allow_once", "name" => "Allow once"},
            %{"optionId" => "custom-reject", "kind" => "reject_once", "name" => "Reject"}
          ],
          "expectedPermissionOptionId" => "custom-allow"
        })

      assert {:ok, session} =
               Client.start_session(
                 workspace,
                 %{command: executable, args: [], env: env, permission_policy: "allow", timeout_ms: 5_000},
                 fn _event -> :ok end
               )

      assert {:ok, _result} = Client.prompt(session, "hello", timeout_ms: 5_000)

      assert :ok = Client.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end

  test "responds to unsupported agent requests instead of stalling the prompt" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-acp-client-unsupported-request-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)

      {executable, env} =
        SymphonyElixir.FakeAcpServer.write!(test_root, %{
          "sessionId" => "fake-acp-session",
          "permission" => true,
          "clientRequestAfterPermission" => %{
            "id" => 9002,
            "method" => "fs/writeTextFile",
            "params" => %{"path" => "file.txt", "content" => "content"}
          }
        })

      parent = self()

      assert {:ok, session} =
               Client.start_session(
                 workspace,
                 %{command: executable, args: [], env: env, permission_policy: "allow", timeout_ms: 5_000},
                 fn event -> send(parent, {:acp_event, event}) end
               )

      assert {:ok, _result} = Client.prompt(session, "hello", timeout_ms: 5_000)

      assert_receive {:acp_event,
                      %{
                        event: :unsupported_request,
                        payload: %{"method" => "fs/writeTextFile"}
                      }}

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

  test "drains prompt response after permission policy fail before later requests" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-acp-client-permission-fail-drain-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)

      {executable, env} =
        SymphonyElixir.FakeAcpServer.write!(test_root, %{
          "sessionId" => "fake-acp-session",
          "permission" => true
        })

      parent = self()

      assert {:ok, session} =
               Client.start_session(
                 workspace,
                 %{command: executable, args: [], env: env, permission_policy: "fail", timeout_ms: 5_000},
                 fn event -> send(parent, {:acp_event, event}) end
               )

      assert {:error, {:permission_required, %{"toolCall" => %{"title" => "write"}}}} =
               Client.prompt(session, "hello", timeout_ms: 5_000)

      assert_receive {:acp_event, %{event: :notification, payload: %{"method" => "session/update"}}}
      refute_receive {_port, {:data, _data}}, 100

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

  test "handles ACP JSON lines split across stdio chunks" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-acp-client-split-line-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)

      {executable, env} =
        SymphonyElixir.FakeAcpServer.write!(test_root, %{
          "sessionId" => "fake-acp-session",
          "splitPromptResponse" => true
        })

      parent = self()

      assert {:ok, session} =
               Client.start_session(
                 workspace,
                 %{command: executable, args: [], env: env, permission_policy: "reject", timeout_ms: 5_000},
                 fn event -> send(parent, {:acp_event, event}) end
               )

      assert {:ok, result} = Client.prompt(session, "hello", timeout_ms: 5_000)
      assert Map.get(result, "stop_reason") == "end_turn"

      refute_receive {:acp_event, %{event: :malformed}}, 100

      assert :ok = Client.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end

  test "handles complete notifications that share a stdio chunk with the response" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-acp-client-response-trailing-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)

      {executable, env} =
        SymphonyElixir.FakeAcpServer.write!(test_root, %{
          "sessionId" => "fake-acp-session",
          "trailingNotificationAfterPromptResponse" => true
        })

      parent = self()

      assert {:ok, session} =
               Client.start_session(
                 workspace,
                 %{command: executable, args: [], env: env, permission_policy: "reject", timeout_ms: 5_000},
                 fn event -> send(parent, {:acp_event, event}) end
               )

      assert {:ok, result} = Client.prompt(session, "hello", timeout_ms: 5_000)
      assert Map.get(result, "stop_reason") == "end_turn"

      assert_receive {:acp_event,
                      %{
                        event: :notification,
                        payload: %{
                          "method" => "session/update",
                          "params" => %{"update" => %{"text" => "post-response"}}
                        }
                      }}

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

  test "prompt timeout is not extended by streaming updates" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-acp-client-stream-timeout-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(test_root, "workspace")
      trace_file = Path.join(test_root, "acp.trace")
      File.mkdir_p!(workspace)

      {executable, env} =
        SymphonyElixir.FakeAcpServer.write!(test_root, %{
          "sessionId" => "fake-acp-session",
          "traceFile" => trace_file,
          "streamUpdatesBeforePromptResponseMs" => 250,
          "streamUpdateIntervalMs" => 10
        })

      assert {:ok, session} =
               Client.start_session(
                 workspace,
                 %{command: executable, args: [], env: env, permission_policy: "reject", timeout_ms: 5_000},
                 fn _event -> :ok end
               )

      started_at = System.monotonic_time(:millisecond)
      assert {:error, :acp_timeout} = Client.prompt(session, "hello", timeout_ms: 50)
      elapsed_ms = System.monotonic_time(:millisecond) - started_at

      assert elapsed_ms < 200
      assert eventually_file_contains?(trace_file, "session/cancel", 1_000)

      assert :ok = Client.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end

  test "closes the ACP process when session startup fails after the port starts" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-acp-client-startup-cleanup-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(test_root, "workspace")
      pid_file = Path.join(test_root, "acp.pid")
      File.mkdir_p!(workspace)

      {executable, env} =
        SymphonyElixir.FakeAcpServer.write!(test_root, %{
          "pidFile" => pid_file,
          "sessionNewError" => true
        })

      assert {:error, {:acp_error, %{"code" => -32000, "message" => "session new failed"}}} =
               Client.start_session(
                 workspace,
                 %{command: executable, args: [], env: env, permission_policy: "reject", timeout_ms: 5_000},
                 fn _event -> :ok end
               )

      pid = pid_file |> File.read!() |> String.trim() |> String.to_integer()
      refute eventually_process_alive?(pid, 1_000)
    after
      File.rm_rf(test_root)
    end
  end

  test "does not send session cancel when session startup request times out" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-acp-client-startup-timeout-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(test_root, "workspace")
      trace_file = Path.join(test_root, "acp.trace")
      File.mkdir_p!(workspace)

      {executable, env} =
        SymphonyElixir.FakeAcpServer.write!(test_root, %{
          "traceFile" => trace_file,
          "sessionNewHangAndTraceNext" => true
        })

      assert {:error, :acp_timeout} =
               Client.start_session(
                 workspace,
                 %{command: executable, args: [], env: env, permission_policy: "reject", timeout_ms: 200},
                 fn _event -> :ok end
               )

      assert eventually_file_contains?(trace_file, "session/new", 1_000)
      refute eventually_file_contains?(trace_file, "session/cancel", 500)
    after
      File.rm_rf(test_root)
    end
  end

  test "uses configured close timeout when stopping an ACP session" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-acp-client-close-timeout-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(test_root, "workspace")
      pid_file = Path.join(test_root, "acp.pid")
      File.mkdir_p!(workspace)

      {executable, env} =
        SymphonyElixir.FakeAcpServer.write!(test_root, %{
          "pidFile" => pid_file,
          "sessionId" => "fake-acp-session",
          "closeCapability" => true,
          "delayCloseMs" => 1_000
        })

      assert {:ok, session} =
               Client.start_session(
                 workspace,
                 %{command: executable, args: [], env: env, permission_policy: "reject", timeout_ms: 5_000},
                 fn _event -> :ok end
               )

      started_at = System.monotonic_time(:millisecond)
      assert :ok = Client.stop_session(Map.put(session, :close_timeout_ms, 50))
      elapsed_ms = System.monotonic_time(:millisecond) - started_at

      assert elapsed_ms < 500

      pid = pid_file |> File.read!() |> String.trim() |> String.to_integer()
      refute eventually_process_alive?(pid, 1_000)
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

  defp eventually_process_alive?(pid, timeout_ms) when is_integer(pid) and timeout_ms >= 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    eventually_process_alive?(pid, deadline, true)
  end

  defp eventually_process_alive?(pid, deadline, last_seen_alive?) do
    alive? = process_alive?(pid)

    cond do
      not alive? ->
        false

      System.monotonic_time(:millisecond) >= deadline ->
        last_seen_alive?

      true ->
        Process.sleep(25)
        eventually_process_alive?(pid, deadline, alive?)
    end
  end

  defp process_alive?(pid) when is_integer(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end
end
