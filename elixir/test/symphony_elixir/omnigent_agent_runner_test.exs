defmodule SymphonyElixir.OmnigentAgentRunnerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Workflow

  test "Linear issue 带 agent:omnigent label 时路由到 omnigent_http backend" do
    server =
      SymphonyElixir.FakeOmnigentServer.start!(%{
        create_body: %{"id" => "conv_fake_1", "session_id" => "conv_fake_1"},
        stream_events: [
          {"response.completed", %{"type" => "response.completed", "response" => %{"id" => "resp_1"}}},
          {nil, "[DONE]"}
        ]
      })

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-omnigent-runner-route-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        agents: %{
          codex: %{kind: "codex_app_server", command: "codex app-server"},
          omnigent: %{
            kind: "omnigent_http",
            base_url: SymphonyElixir.FakeOmnigentServer.base_url(server),
            host: %{
              mode: "external",
              host_id: "host_local",
              workspace: "{{workspace}}"
            },
            agent: %{type: "agent_id", id: "ag_polly"},
            timeout_ms: 5_000,
            stream_timeout_ms: 1_000
          }
        },
        routing: %{default_agent: "codex", by_label: %{"agent:omnigent" => "omnigent"}}
      )

      issue = %Issue{
        id: "issue-omnigent-runner-route",
        identifier: "MT-930",
        title: "Omnigent runner route",
        description: "Route to omnigent by label",
        state: "Done",
        labels: ["agent:omnigent"]
      }

      assert :ok =
               AgentRunner.run(
                 issue,
                 self(),
                 issue_state_fetcher: fn ["issue-omnigent-runner-route"] ->
                   {:ok, [%{issue | state: "Done"}]}
                 end
               )

      assert_receive {:codex_worker_update, "issue-omnigent-runner-route",
                      %{
                        agent_id: "omnigent",
                        agent_kind: "omnigent_http",
                        event: :turn_started,
                        session_id: "conv_fake_1"
                      }}

      requests = SymphonyElixir.FakeOmnigentServer.requests(server)
      create_requests = Enum.filter(requests, &(&1.name == "create_session"))

      message_events =
        requests
        |> Enum.filter(&(&1.name == "post_event"))
        |> Enum.filter(&(&1.body["type"] == "message"))

      assert length(create_requests) == 1
      assert length(message_events) == 1
      assert Enum.at(message_events, 0).body["type"] == "message"
    after
      SymphonyElixir.FakeOmnigentServer.stop!(server)
      File.rm_rf(test_root)
    end
  end

  test "continuation 在同一 AgentRunner attempt 内复用同一个 omnigent session" do
    server =
      SymphonyElixir.FakeOmnigentServer.start!(%{
        create_body: %{"id" => "conv_fake_1", "session_id" => "conv_fake_1"},
        stream_events: [
          {"response.completed", %{"type" => "response.completed", "response" => %{"id" => "resp_1"}}},
          {nil, "[DONE]"}
        ]
      })

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-omnigent-runner-continuation-#{System.unique_integer([:positive])}"
      )

    parent = self()

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        agents: %{
          omnigent: %{
            kind: "omnigent_http",
            base_url: SymphonyElixir.FakeOmnigentServer.base_url(server),
            host: %{
              mode: "external",
              host_id: "host_local",
              workspace: "{{workspace}}"
            },
            agent: %{type: "agent_id", id: "ag_polly"},
            timeout_ms: 5_000,
            stream_timeout_ms: 1_000
          }
        },
        routing: %{default_agent: "omnigent"},
        max_turns: 2
      )

      issue = %Issue{
        id: "issue-omnigent-runner-continuation",
        identifier: "MT-931",
        title: "Omnigent runner continuation",
        description: "Run two turns in one Omnigent session",
        state: "In Progress",
        labels: []
      }

      issue_state_fetcher = fn ["issue-omnigent-runner-continuation"] ->
        count = Process.get(:omnigent_issue_fetch_count, 0) + 1
        Process.put(:omnigent_issue_fetch_count, count)
        send(parent, {:omnigent_issue_fetch, count})

        state =
          if count == 1 do
            "In Progress"
          else
            "Done"
          end

        {:ok, [%{issue | state: state}]}
      end

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: issue_state_fetcher)

      assert_receive {:omnigent_issue_fetch, 1}
      assert_receive {:omnigent_issue_fetch, 2}

      requests = SymphonyElixir.FakeOmnigentServer.requests(server)
      create_requests = Enum.filter(requests, &(&1.name == "create_session"))

      message_events =
        requests
        |> Enum.filter(&(&1.name == "post_event"))
        |> Enum.filter(&(&1.body["type"] == "message"))

      assert length(create_requests) == 1
      assert length(message_events) == 2
      assert Enum.map(message_events, & &1.session_id) == ["conv_fake_1", "conv_fake_1"]
    after
      SymphonyElixir.FakeOmnigentServer.stop!(server)
      File.rm_rf(test_root)
    end
  end
end
