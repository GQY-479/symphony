defmodule SymphonyElixir.AgentBackendTest.FakeAppServer do
  @moduledoc false

  def run(workspace, prompt, issue, opts) do
    on_message = Keyword.fetch!(opts, :on_message)
    on_message.(%{event: :session_started, workspace: workspace, prompt: prompt})

    {:ok,
     %{
       session_id: "fake-session",
       workspace: workspace,
       prompt: prompt,
       issue_id: issue.id,
       agent_config: Keyword.get(opts, :agent_config)
     }}
  end

  def start_session(_workspace, _opts), do: {:error, :fake_start_failed}
end

defmodule SymphonyElixir.AgentBackendTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.Backend

  test "module_for resolves supported backend kinds and rejects unknown kinds" do
    assert Backend.module_for("codex_app_server") == SymphonyElixir.Agent.Backend.CodexAppServer
    assert Backend.module_for("cli_run") == SymphonyElixir.Agent.Backend.CliRun
    assert Backend.module_for("omnigent_http") == SymphonyElixir.Agent.Backend.OmnigentHttp

    assert_raise ArgumentError, ~r/unknown agent backend kind/, fn ->
      Backend.module_for("not-real")
    end
  end

  test "codex app-server backend annotates messages with resolved agent identity" do
    issue = %Issue{id: "issue-codex-backend", identifier: "MT-901", title: "Codex wrapper"}

    resolved_agent = %{
      id: "named-codex",
      kind: "codex_app_server",
      config: %{
        "command" => "custom-codex app-server",
        "approval_policy" => "never",
        "thread_sandbox" => "workspace-write",
        "timeout_ms" => 123_000,
        "read_timeout_ms" => 1_000
      }
    }

    parent = self()

    assert {:ok, result} =
             Backend.CodexAppServer.run_issue(
               "/tmp/workspace",
               issue,
               "prompt body",
               resolved_agent,
               app_server_module: SymphonyElixir.AgentBackendTest.FakeAppServer,
               on_message: fn message -> send(parent, {:backend_message, message}) end
             )

    assert result.session_id == "fake-session"
    assert result.agent_config == resolved_agent.config

    assert_receive {:backend_message,
                    %{
                      event: :session_started,
                      agent_id: "named-codex",
                      agent_kind: "codex_app_server",
                      timestamp: %DateTime{}
                    }}
  end

  test "codex app-server backend uses a default no-op handler when none is provided" do
    issue = %Issue{id: "issue-codex-default", identifier: "MT-907", title: "No handler"}

    resolved_agent = %{
      id: "codex",
      kind: "codex_app_server",
      config: %{"command" => "codex app-server"}
    }

    assert {:ok, %{session_id: "fake-session"}} =
             Backend.CodexAppServer.run_issue(
               "/tmp/workspace",
               issue,
               "prompt body",
               resolved_agent,
               app_server_module: SymphonyElixir.AgentBackendTest.FakeAppServer
             )
  end

  test "codex app-server backend propagates start_session errors" do
    resolved_agent = %{id: "codex", kind: "codex_app_server", config: %{"command" => "codex app-server"}}

    assert {:error, :fake_start_failed} =
             Backend.CodexAppServer.start_session(
               "/tmp/workspace",
               resolved_agent,
               app_server_module: SymphonyElixir.AgentBackendTest.FakeAppServer
             )
  end

  test "cli backend runs configured executable, emits decoded line events, and returns output" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-cli-backend-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      executable = Path.join(test_root, "fake-cli")
      trace_file = Path.join(test_root, "cli.trace")
      File.mkdir_p!(workspace)

      File.write!(executable, """
      #!/bin/sh
      trace_file="#{trace_file}"
      printf 'CWD:%s\\n' "$PWD" >> "$trace_file"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"
      printf '%s\\n' '{"kind":"progress","step":1}'
      printf '%s\\n' 'plain output'
      """)

      File.chmod!(executable, 0o755)

      issue = %Issue{id: "issue-cli-backend", identifier: "MT-902", title: "CLI backend"}

      resolved_agent = %{
        id: "mimocode",
        kind: "cli_run",
        config: %{
          "command" => executable,
          "args" => ["run", "--workspace", "{{workspace}}"],
          "timeout_ms" => 5_000,
          "max_output_bytes" => 200_000
        }
      }

      parent = self()

      assert {:ok, result} =
               Backend.CliRun.run_issue(
                 workspace,
                 issue,
                 "perform cli task",
                 resolved_agent,
                 on_message: fn message -> send(parent, {:cli_message, message}) end
               )

      assert result.exit_status == 0
      assert result.output =~ ~s({"kind":"progress","step":1})
      assert result.output =~ "plain output"
      assert result.session_id =~ "mimocode-"

      trace = File.read!(trace_file)
      assert trace =~ "CWD:#{workspace}"
      assert trace =~ "ARGV:run --workspace #{workspace} perform cli task"

      assert_receive {:cli_message,
                      %{
                        event: :cli_output,
                        agent_id: "mimocode",
                        agent_kind: "cli_run",
                        payload: %{"kind" => "progress", "step" => 1},
                        timestamp: %DateTime{}
                      }}

      assert_receive {:cli_message,
                      %{
                        event: :cli_output,
                        payload: %{text: "plain output"}
                      }}

      assert_receive {:cli_message,
                      %{
                        event: :turn_completed,
                        agent_id: "mimocode",
                        agent_kind: "cli_run"
                      }}
    after
      File.rm_rf(test_root)
    end
  end

  test "cli backend emits session metadata and normalized MiMo token usage" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-cli-backend-mimo-usage-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      executable = Path.join(test_root, "fake-mimo-cli")
      File.mkdir_p!(workspace)

      File.write!(executable, """
      #!/bin/sh
      printf '%s\\n' '{"type":"step_start","sessionID":"ses_mimo_123","part":{"type":"step-start"}}'
      printf '%s\\n' '{"type":"step_finish","sessionID":"ses_mimo_123","part":{"type":"step-finish","tokens":{"input":12,"output":4,"total":16}}}'
      """)

      File.chmod!(executable, 0o755)

      resolved_agent = %{
        id: "mimocode",
        kind: "cli_run",
        config: %{"command" => executable, "timeout_ms" => 5_000}
      }

      parent = self()

      assert {:ok, _result} =
               Backend.CliRun.run_issue(
                 workspace,
                 %Issue{id: "issue-cli-mimo-usage", identifier: "MT-908"},
                 "prompt",
                 resolved_agent,
                 on_message: fn message -> send(parent, {:cli_message, message}) end
               )

      assert_receive {:cli_message,
                      %{
                        event: :session_started,
                        session_id: session_id,
                        agent_id: "mimocode",
                        agent_kind: "cli_run"
                      }}

      assert session_id =~ "mimocode-"

      assert_receive {:cli_message,
                      %{
                        event: :cli_output,
                        session_id: "ses_mimo_123",
                        usage: %{"input_tokens" => 12, "output_tokens" => 4, "total_tokens" => 16}
                      }}
    after
      File.rm_rf(test_root)
    end
  end

  test "cli backend returns an error for non-zero exits" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-cli-backend-exit-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      executable = Path.join(test_root, "fake-cli")
      File.mkdir_p!(workspace)

      File.write!(executable, """
      #!/bin/sh
      printf '%s\\n' 'failed hard'
      exit 7
      """)

      File.chmod!(executable, 0o755)

      resolved_agent = %{
        id: "bad-cli",
        kind: "cli_run",
        config: %{"command" => executable, "timeout_ms" => 5_000}
      }

      assert {:error, {:cli_exit, 7, output}} =
               Backend.CliRun.run_issue(
                 workspace,
                 %Issue{id: "issue-cli-exit", identifier: "MT-903"},
                 "prompt",
                 resolved_agent,
                 []
               )

      assert output =~ "failed hard"
    after
      File.rm_rf(test_root)
    end
  end

  test "cli backend returns an error when the command cannot be started" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-cli-backend-missing-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      missing_executable = Path.join(test_root, "missing-cli")
      File.mkdir_p!(workspace)

      resolved_agent = %{
        id: "missing-cli",
        kind: "cli_run",
        config: %{"command" => missing_executable, "timeout_ms" => 5_000}
      }

      assert {:error, {:cli_command_not_found, ^missing_executable}} =
               Backend.CliRun.run_issue(
                 workspace,
                 %Issue{id: "issue-cli-missing", identifier: "MT-904"},
                 "prompt",
                 resolved_agent,
                 []
               )
    after
      File.rm_rf(test_root)
    end
  end

  test "cli backend times out and caps output without newline" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-cli-backend-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      timeout_executable = Path.join(test_root, "timeout-cli")
      output_executable = Path.join(test_root, "output-cli")
      File.mkdir_p!(workspace)

      File.write!(timeout_executable, """
      #!/bin/sh
      sleep 1
      """)

      File.write!(output_executable, """
      #!/bin/sh
      printf 'abcdefghijklmnopqrstuvwxyz'
      """)

      File.chmod!(timeout_executable, 0o755)
      File.chmod!(output_executable, 0o755)

      timeout_agent = %{
        id: "slow-cli",
        kind: "cli_run",
        config: %{"command" => timeout_executable, "timeout_ms" => 25}
      }

      assert {:error, :cli_timeout} =
               Backend.CliRun.run_issue(
                 workspace,
                 %Issue{id: "issue-cli-timeout", identifier: "MT-905"},
                 "prompt",
                 timeout_agent,
                 []
               )

      output_agent = %{
        id: "output-cli",
        kind: "cli_run",
        config: %{"command" => output_executable, "timeout_ms" => 5_000, "max_output_bytes" => 10}
      }

      assert {:ok, %{output: output}} =
               Backend.CliRun.run_issue(
                 workspace,
                 %Issue{id: "issue-cli-output", identifier: "MT-906"},
                 "prompt",
                 output_agent,
                 []
               )

      assert output == "abcdefghij"
    after
      File.rm_rf(test_root)
    end
  end

  test "cli backend cleans up child processes on timeout" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-cli-backend-timeout-cleanup-#{System.unique_integer([:positive])}"
      )

    child_pid_file = Path.join(test_root, "child.pid")

    try do
      workspace = Path.join(test_root, "workspace")
      executable = Path.join(test_root, "parent-cli")
      child_executable = Path.join(test_root, "child-cli")
      File.mkdir_p!(workspace)

      File.write!(child_executable, """
      #!/bin/sh
      sleep 60
      """)

      File.write!(executable, """
      #!/bin/sh
      "#{child_executable}" &
      printf '%s\\n' "$!" > "#{child_pid_file}"
      wait
      """)

      File.chmod!(child_executable, 0o755)
      File.chmod!(executable, 0o755)

      timeout_agent = %{
        id: "slow-cli",
        kind: "cli_run",
        config: %{"command" => executable, "timeout_ms" => 50}
      }

      assert {:error, :cli_timeout} =
               Backend.CliRun.run_issue(
                 workspace,
                 %Issue{id: "issue-cli-timeout-cleanup", identifier: "MT-909"},
                 "prompt",
                 timeout_agent,
                 []
               )

      child_pid = child_pid_file |> File.read!() |> String.trim() |> String.to_integer()

      refute eventually_process_alive?(child_pid, 1_000)
    after
      if File.exists?(child_pid_file) do
        child_pid = child_pid_file |> File.read!() |> String.trim()
        System.cmd("kill", ["-KILL", child_pid], stderr_to_stdout: true)
      end

      File.rm_rf(test_root)
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
