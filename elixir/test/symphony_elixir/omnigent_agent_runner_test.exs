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
        labels: [" Agent:Omnigent "]
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

      assert_receive {:codex_worker_update, "issue-omnigent-runner-route",
                      %{
                        agent_id: "omnigent",
                        agent_kind: "omnigent_http",
                        event: :turn_completed,
                        session_id: "conv_fake_1"
                      }}

      requests = SymphonyElixir.FakeOmnigentServer.requests(server)
      create_requests = Enum.filter(requests, &(&1.name == "create_session"))

      post_events = Enum.filter(requests, &(&1.name == "post_event"))

      message_events =
        Enum.filter(post_events, &(&1.body["type"] == "message"))

      stop_events =
        Enum.filter(post_events, &(&1.body == %{"type" => "stop_session", "data" => %{}}))

      interrupt_events = Enum.filter(post_events, &(&1.body["type"] == "interrupt"))

      assert length(create_requests) == 1
      assert length(post_events) == 2
      assert length(message_events) == 1
      assert length(stop_events) == 1
      assert length(interrupt_events) == 0
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

      post_events = Enum.filter(requests, &(&1.name == "post_event"))

      message_events =
        Enum.filter(post_events, &(&1.body["type"] == "message"))

      stop_events =
        Enum.filter(post_events, &(&1.body == %{"type" => "stop_session", "data" => %{}}))

      interrupt_events = Enum.filter(post_events, &(&1.body["type"] == "interrupt"))

      first_message_text = request_message_text(Enum.at(message_events, 0))
      second_message_text = request_message_text(Enum.at(message_events, 1))

      assert length(create_requests) == 1
      assert length(post_events) == 3
      assert length(message_events) == 2
      assert length(stop_events) == 1
      assert length(interrupt_events) == 0
      assert Enum.map(message_events, & &1.session_id) == ["conv_fake_1", "conv_fake_1"]
      refute first_message_text =~ "Continuation guidance:"
      assert second_message_text =~ "Continuation guidance:"
      assert second_message_text =~ "continuation turn #2 of 2"
    after
      SymphonyElixir.FakeOmnigentServer.stop!(server)
      File.rm_rf(test_root)
    end
  end

  test "continuation 在 issue 改派到其他 agent 后停止当前 omnigent session" do
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
        "symphony-omnigent-runner-reroute-#{System.unique_integer([:positive])}"
      )

    parent = self()

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
        routing: %{default_agent: "codex", by_label: %{"agent:omnigent" => "omnigent"}},
        max_turns: 3
      )

      issue = %Issue{
        id: "issue-omnigent-runner-reroute",
        identifier: "MT-932",
        title: "Omnigent runner reroute",
        description: "Stop when the issue no longer routes to Omnigent",
        state: "In Progress",
        labels: ["agent:omnigent"]
      }

      issue_state_fetcher = fn ["issue-omnigent-runner-reroute"] ->
        count = Process.get(:omnigent_reroute_fetch_count, 0) + 1
        Process.put(:omnigent_reroute_fetch_count, count)
        send(parent, {:omnigent_reroute_fetch, count})

        {:ok, [%{issue | state: "In Progress", labels: []}]}
      end

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: issue_state_fetcher)

      assert_receive {:omnigent_reroute_fetch, 1}
      refute_receive {:omnigent_reroute_fetch, 2}, 100

      requests = SymphonyElixir.FakeOmnigentServer.requests(server)
      create_requests = Enum.filter(requests, &(&1.name == "create_session"))
      post_events = Enum.filter(requests, &(&1.name == "post_event"))
      message_events = Enum.filter(post_events, &(&1.body["type"] == "message"))
      stop_events = Enum.filter(post_events, &(&1.body == %{"type" => "stop_session", "data" => %{}}))

      assert length(create_requests) == 1
      assert length(message_events) == 1
      assert length(stop_events) == 1
    after
      SymphonyElixir.FakeOmnigentServer.stop!(server)
      File.rm_rf(test_root)
    end
  end

  defp request_message_text(request) do
    get_in(request.body, ["data", "content"])
    |> List.first()
    |> Map.get("text")
  end
end
