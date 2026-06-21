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

      assert_receive {:worker_runtime_info, "issue-acp-runner", %{issue: %Issue{state: "Done", identifier: "MT-911"}}}
    after
      File.rm_rf(test_root)
    end
  end

  test "AgentRunner routes agent:mimo labeled issues to the acp_stdio backend" do
    test_root = Path.join(System.tmp_dir!(), "symphony-acp-runner-label-route-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)
      {executable, _env} = SymphonyElixir.FakeAcpServer.write!(test_root, %{"sessionId" => "fake-acp-session"})

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        agents: %{
          codex: %{kind: "codex_app_server", command: "codex app-server"},
          mimocode: %{
            kind: "acp_stdio",
            command: executable,
            args: [],
            permission_policy: "reject",
            timeout_ms: 5_000,
            read_timeout_ms: 5_000
          }
        },
        routing: %{default_agent: "codex", by_label: %{"agent:mimo" => "mimocode"}}
      )

      issue = %Issue{
        id: "issue-acp-runner-label-route",
        identifier: "MT-914",
        title: "ACP runner label route",
        description: "Run through ACP by label",
        state: "In Progress",
        labels: ["Agent:MiMo"]
      }

      assert :ok =
               AgentRunner.run(
                 issue,
                 self(),
                 max_turns: 1,
                 issue_state_fetcher: fn ["issue-acp-runner-label-route"] -> {:ok, [%{issue | state: "Done"}]} end
               )

      assert_receive {:codex_worker_update, "issue-acp-runner-label-route",
                      %{
                        event: :turn_started,
                        agent_id: "mimocode",
                        agent_kind: "acp_stdio",
                        session_id: "fake-acp-session"
                      }}

      assert_receive {:codex_worker_update, "issue-acp-runner-label-route",
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

  test "AgentRunner adds Linear MCP guidance for acp_stdio agents with linear tools enabled" do
    test_root = Path.join(System.tmp_dir!(), "symphony-acp-runner-mcp-guidance-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      trace_file = Path.join(test_root, "acp.trace")
      File.mkdir_p!(workspace_root)

      {executable, _env} =
        SymphonyElixir.FakeAcpServer.write!(test_root, %{
          "sessionId" => "fake-acp-session",
          "traceFile" => trace_file,
          "tracePromptText" => true
        })

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        prompt: "Handle {{ issue.identifier }}.",
        agents: %{
          mimocode: %{
            kind: "acp_stdio",
            command: executable,
            args: [],
            permission_policy: "reject",
            timeout_ms: 5_000,
            read_timeout_ms: 5_000,
            mcp: %{"linear_tools" => true}
          }
        },
        routing: %{default_agent: "mimocode"}
      )

      issue = %Issue{
        id: "issue-acp-runner-mcp-guidance",
        identifier: "MT-917",
        title: "ACP runner MCP guidance",
        description: "Use Linear tools cleanly",
        state: "In Progress",
        labels: []
      }

      assert :ok =
               AgentRunner.run(
                 issue,
                 self(),
                 max_turns: 1,
                 issue_state_fetcher: fn ["issue-acp-runner-mcp-guidance"] -> {:ok, [%{issue | state: "Done"}]} end
               )

      trace_lines = trace_file |> File.read!() |> String.split("\n", trim: true)
      prompt_line = Enum.find(trace_lines, &String.starts_with?(&1, "PROMPT:"))

      assert prompt_line =~ "Handle MT-917."
      assert prompt_line =~ "Runtime tools available through Symphony:"
      assert prompt_line =~ "`linear_issue_read`"
      assert prompt_line =~ "`linear_comment_create`"
      assert prompt_line =~ "`linear_issue_update_state`"
      assert prompt_line =~ "`linear_graphql` as a lower-level fallback"
      assert prompt_line =~ "`symphony-linear_linear_graphql`"
      assert prompt_line =~ "If your tool list shows the namespaced form"
      assert prompt_line =~ "Do not use shell, git, push, skill, or unsupported tools for Linear updates"
      assert prompt_line =~ "Do not load local Symphony skills such as `linear` or `push` for Linear work"
      assert prompt_line =~ "Use normal workspace file-editing capabilities only for repository or file changes"
      assert prompt_line =~ "Do not use Linear state changes to finish, hand off, review, or close the current workflow issue"
      assert prompt_line =~ "Treat target file names and exact file contents in the issue description as literal task data"
      assert prompt_line =~ "do not treat strings such as `$fileName` or `$phrase` as variables to resolve"
      assert prompt_line =~ "Do not substitute an existing repository file for a requested target file"
      assert prompt_line =~ "Before creating a success comment, read back the exact target file"
      assert prompt_line =~ "If the target file name or exact content is missing or ambiguous, report blocked"
    after
      File.rm_rf(test_root)
    end
  end

  test "AgentRunner continues ACP turns in the same session with backend-neutral guidance" do
    test_root = Path.join(System.tmp_dir!(), "symphony-acp-runner-continuation-#{System.unique_integer([:positive])}")

    try do
      workspace_root = Path.join(test_root, "workspaces")
      trace_file = Path.join(test_root, "acp.trace")
      File.mkdir_p!(workspace_root)

      {executable, _env} =
        SymphonyElixir.FakeAcpServer.write!(test_root, %{
          "sessionId" => "fake-acp-session",
          "traceFile" => trace_file,
          "tracePromptText" => true
        })

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
        routing: %{default_agent: "mimocode"},
        max_turns: 3
      )

      issue = %Issue{
        id: "issue-acp-runner-continuation",
        identifier: "MT-916",
        title: "ACP runner continuation",
        description: "Run two ACP turns in one session",
        state: "In Progress",
        labels: []
      }

      parent = self()

      issue_state_fetcher = fn ["issue-acp-runner-continuation"] ->
        attempt = Process.get(:acp_continuation_fetch_count, 0) + 1
        Process.put(:acp_continuation_fetch_count, attempt)
        send(parent, {:issue_state_fetch, attempt})

        state =
          if attempt == 1 do
            "In Progress"
          else
            "Done"
          end

        {:ok, [%{issue | state: state}]}
      end

      assert :ok =
               AgentRunner.run(
                 issue,
                 self(),
                 max_turns: 3,
                 issue_state_fetcher: issue_state_fetcher
               )

      assert_receive {:issue_state_fetch, 1}
      assert_receive {:issue_state_fetch, 2}

      trace_lines = trace_file |> File.read!() |> String.split("\n", trim: true)

      assert Enum.count(trace_lines, &(&1 == "session/new")) == 1
      assert Enum.count(trace_lines, &(&1 == "session/prompt")) == 2

      prompt_lines = Enum.filter(trace_lines, &String.starts_with?(&1, "PROMPT:"))
      assert length(prompt_lines) == 2

      continuation_prompt = Enum.at(prompt_lines, 1)
      assert continuation_prompt =~ "previous agent turn completed normally"
      assert continuation_prompt =~ "continuation turn #2 of 3"
      refute continuation_prompt =~ "previous Codex turn"

      assert_receive {:codex_worker_update, "issue-acp-runner-continuation",
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
