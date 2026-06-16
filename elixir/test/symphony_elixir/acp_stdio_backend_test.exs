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
                        event: :turn_started,
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

  test "emits ACP prompt usage on turn completion" do
    test_root = Path.join(System.tmp_dir!(), "symphony-acp-backend-usage-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)

      {executable, env} =
        SymphonyElixir.FakeAcpServer.write!(test_root, %{
          "sessionId" => "fake-acp-session",
          "usage" => %{"inputTokens" => 12, "outputTokens" => 4, "totalTokens" => 16}
        })

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
                 %Issue{id: "issue-acp-backend-usage", identifier: "MT-912"},
                 "perform acp task",
                 on_message: fn message -> send(parent, {:acp_backend_message, message}) end
               )

      assert result.usage == %{"inputTokens" => 12, "outputTokens" => 4, "totalTokens" => 16}

      assert_receive {:acp_backend_message,
                      %{
                        event: :turn_completed,
                        agent_id: "mimocode",
                        agent_kind: "acp_stdio",
                        usage: %{"inputTokens" => 12, "outputTokens" => 4, "totalTokens" => 16}
                      }}

      assert :ok = AcpStdio.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end

  test "passes configured ACP session options from resolved agent config" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-acp-backend-config-options-#{System.unique_integer([:positive])}")

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

      resolved_agent = %{
        id: "mimocode",
        kind: "acp_stdio",
        config: %{
          "command" => executable,
          "args" => [],
          "permission_policy" => "reject",
          "read_timeout_ms" => 5_000,
          "env" => env,
          "config_options" => %{"model" => "mimo/mimo-auto"}
        }
      }

      assert {:ok, session} =
               AcpStdio.start_session(
                 workspace,
                 resolved_agent,
                 on_message: fn _message -> :ok end
               )

      trace = File.read!(trace_file)
      assert trace =~ "session/set_config_option"
      assert :ok = AcpStdio.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end

  test "builds default linear MCP server config for ACP sessions" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-acp-backend-default-mcp-#{System.unique_integer([:positive])}")

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

      resolved_agent = %{
        id: "mimocode",
        kind: "acp_stdio",
        config: %{
          "command" => executable,
          "args" => [],
          "permission_policy" => "reject",
          "read_timeout_ms" => 5_000,
          "env" => env,
          "mcp" => %{"linear_tools" => true}
        }
      }

      assert {:ok, session} =
               AcpStdio.start_session(
                 workspace,
                 resolved_agent,
                 on_message: fn _message -> :ok end
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

      assert :ok = AcpStdio.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end

  test "logs low-sensitive ACP tool update summaries without tool arguments" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-acp-backend-tool-log-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)

      {executable, env} =
        SymphonyElixir.FakeAcpServer.write!(test_root, %{
          "sessionId" => "fake-acp-session",
          "promptUpdate" => %{
            "kind" => "tool_call",
            "title" => "Invalid Tool",
            "status" => "failed",
            "toolCall" => %{
              "name" => "symphony-linear_linear_graphql",
              "arguments" => %{
                "query" => "mutation SecretPayload { commentCreate(input: {body: s3cr3t}) { success } }"
              }
            }
          }
        })

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

      log =
        capture_log(fn ->
          assert {:ok, session} =
                   AcpStdio.start_session(
                     workspace,
                     resolved_agent,
                     on_message: fn _message -> :ok end
                   )

          assert {:ok, _result} =
                   AcpStdio.run_turn(
                     session,
                     workspace,
                     %Issue{id: "issue-acp-backend-tool-log", identifier: "MT-916"},
                     "perform acp task",
                     on_message: fn _message -> :ok end
                   )

          assert :ok = AcpStdio.stop_session(session)
        end)

      assert log =~ "ACP session/update"
      assert log =~ "agent_id=mimocode"
      assert log =~ "agent_kind=acp_stdio"
      assert log =~ "session_id=fake-acp-session"
      assert log =~ "update_kind=tool_call"
      assert log =~ "tool_name=\"symphony-linear_linear_graphql\""
      assert log =~ "tool_status=failed"
      assert log =~ "error_category=tool_error"
      refute log =~ "SecretPayload"
      refute log =~ "s3cr3t"
      refute log =~ "commentCreate"
    after
      File.rm_rf(test_root)
    end
  end

  test "copies configured close timeout into ACP session" do
    test_root = Path.join(System.tmp_dir!(), "symphony-acp-backend-close-timeout-#{System.unique_integer([:positive])}")

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
          "close_timeout_ms" => 75,
          "env" => env
        }
      }

      assert {:ok, session} = AcpStdio.start_session(workspace, resolved_agent, on_message: fn _message -> :ok end)
      assert session.close_timeout_ms == 75

      assert :ok = AcpStdio.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end

  test "emits turn_failed when ACP prompt fails" do
    test_root = Path.join(System.tmp_dir!(), "symphony-acp-backend-failed-turn-#{System.unique_integer([:positive])}")

    try do
      workspace = Path.join(test_root, "workspace")
      File.mkdir_p!(workspace)

      {executable, env} =
        SymphonyElixir.FakeAcpServer.write!(test_root, %{
          "sessionId" => "fake-acp-session",
          "permission" => true
        })

      resolved_agent = %{
        id: "mimocode",
        kind: "acp_stdio",
        config: %{
          "command" => executable,
          "args" => [],
          "permission_policy" => "fail",
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

      assert {:error, {:permission_required, %{"toolCall" => %{"title" => "write"}}}} =
               AcpStdio.run_turn(
                 session,
                 workspace,
                 %Issue{id: "issue-acp-backend-failure", identifier: "MT-913"},
                 "perform acp task",
                 on_message: fn message -> send(parent, {:acp_backend_message, message}) end
               )

      assert_receive {:acp_backend_message,
                      %{
                        event: :approval_required,
                        agent_id: "mimocode",
                        agent_kind: "acp_stdio",
                        session_id: "fake-acp-session",
                        payload: %{"toolCall" => %{"title" => "write"}}
                      }}

      assert_receive {:acp_backend_message,
                      %{
                        event: :turn_failed,
                        agent_id: "mimocode",
                        agent_kind: "acp_stdio",
                        session_id: "fake-acp-session",
                        payload: %{reason: {:permission_required, %{"toolCall" => %{"title" => "write"}}}}
                      }}

      assert :ok = AcpStdio.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end

  test "emits turn_cancelled and sends one cancel when ACP prompt times out" do
    test_root = Path.join(System.tmp_dir!(), "symphony-acp-backend-timeout-#{System.unique_integer([:positive])}")

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

      resolved_agent = %{
        id: "mimocode",
        kind: "acp_stdio",
        config: %{
          "command" => executable,
          "args" => [],
          "permission_policy" => "reject",
          "timeout_ms" => 25,
          "read_timeout_ms" => 5_000,
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

      assert {:error, :acp_timeout} =
               AcpStdio.run_turn(
                 session,
                 workspace,
                 %Issue{id: "issue-acp-backend-timeout", identifier: "MT-915"},
                 "perform acp task",
                 on_message: fn message -> send(parent, {:acp_backend_message, message}) end
               )

      assert_receive {:acp_backend_message,
                      %{
                        event: :turn_cancelled,
                        agent_id: "mimocode",
                        agent_kind: "acp_stdio",
                        session_id: "fake-acp-session",
                        payload: %{reason: :acp_timeout}
                      }}

      assert eventually_trace_count(trace_file, "session/cancel", 1, 1_500)

      assert :ok = AcpStdio.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end

  defp eventually_trace_count(path, expected, count, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    eventually_trace_count(path, expected, count, deadline, false)
  end

  defp eventually_trace_count(path, expected, count, deadline, last_result) do
    actual_count =
      if File.exists?(path) do
        path
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.count(&(&1 == expected))
      else
        0
      end

    cond do
      actual_count == count ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        last_result

      true ->
        Process.sleep(25)
        eventually_trace_count(path, expected, count, deadline, actual_count == count)
    end
  end
end
