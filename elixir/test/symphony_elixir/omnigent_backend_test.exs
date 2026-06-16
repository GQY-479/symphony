defmodule SymphonyElixir.OmnigentBackendTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.Backend.OmnigentHttp
  alias SymphonyElixir.Linear.Issue

  test "start_session/3 读取 resolved agent 配置并发送 session_started" do
    server =
      SymphonyElixir.FakeOmnigentServer.start!(%{
        create_body: %{"id" => "conv_fake_1", "session_id" => "conv_fake_1"}
      })

    {test_root, workspace} = unique_workspace!("start-session")
    parent = self()

    try do
      base_url = SymphonyElixir.FakeOmnigentServer.base_url(server)
      resolved_agent = omnigent_agent(base_url)

      assert {:ok, session} =
               OmnigentHttp.start_session(
                 workspace,
                 resolved_agent,
                 on_message: fn message -> send(parent, {:omnigent_backend_message, message}) end
               )

      assert session.session_id == "conv_fake_1"
      assert session.base_url == base_url
      assert session.timeout_ms == 5_000
      assert session.stream_timeout_ms == 1_000
      assert session.resolved_agent == resolved_agent

      requests = SymphonyElixir.FakeOmnigentServer.requests(server)
      create_request = Enum.find(requests, &(&1.name == "create_session"))

      assert create_request.body == %{
               "agent_id" => "ag_polly",
               "host_type" => "external",
               "host_id" => "host_local",
               "workspace" => workspace,
               "title" => "Symphony issue session",
               "labels" => %{
                 "symphony_agent_id" => "omnigent",
                 "symphony_agent_kind" => "omnigent_http"
               },
               "initial_items" => []
             }

      assert_receive {:omnigent_backend_message,
                      %{
                        event: :session_started,
                        agent_id: "omnigent",
                        agent_kind: "omnigent_http",
                        session_id: "conv_fake_1",
                        payload: %{
                          "id" => "conv_fake_1",
                          "status" => "running",
                          "runner_online" => true,
                          "host_online" => true
                        },
                        timestamp: %DateTime{}
                      }}
    after
      SymphonyElixir.FakeOmnigentServer.stop!(server)
      File.rm_rf(test_root)
    end
  end

  test "run_turn/5 发送 turn_started，转发通知，并在 completed 后返回结果" do
    server =
      SymphonyElixir.FakeOmnigentServer.start!(%{
        create_body: %{"id" => "conv_fake_2", "session_id" => "conv_fake_2"},
        stream_events: [
          {"session.status", %{"type" => "session.status", "status" => "running"}},
          {"response.output_text.delta", %{"type" => "response.output_text.delta", "delta" => "done"}},
          {"response.completed", %{"type" => "response.completed", "response" => %{"id" => "resp_1"}}},
          {nil, "[DONE]"}
        ]
      })

    {test_root, workspace} = unique_workspace!("run-turn")
    parent = self()

    try do
      base_url = SymphonyElixir.FakeOmnigentServer.base_url(server)
      resolved_agent = omnigent_agent(base_url)

      assert {:ok, session} =
               OmnigentHttp.start_session(
                 workspace,
                 resolved_agent,
                 on_message: fn message -> send(parent, {:omnigent_backend_message, message}) end
               )

      assert {:ok, result} =
               OmnigentHttp.run_turn(
                 session,
                 workspace,
                 %Issue{id: "issue-omnigent", identifier: "MT-920", title: "Omnigent backend"},
                 "hello omnigent",
                 on_message: fn message -> send(parent, {:omnigent_backend_message, message}) end
               )

      assert result.session_id == "conv_fake_2"
      assert result.output_text == "done"
      assert result.raw["type"] == "response.completed"

      assert_receive {:omnigent_backend_message,
                      %{
                        event: :turn_started,
                        agent_id: "omnigent",
                        agent_kind: "omnigent_http",
                        session_id: "conv_fake_2",
                        payload: %{},
                        timestamp: %DateTime{}
                      }}

      assert_receive {:omnigent_backend_message,
                      %{
                        event: :notification,
                        agent_id: "omnigent",
                        agent_kind: "omnigent_http",
                        session_id: "conv_fake_2",
                        payload: %{"type" => "session.status", "status" => "running"},
                        timestamp: %DateTime{}
                      }}

      assert_receive {:omnigent_backend_message,
                      %{
                        event: :notification,
                        payload: %{"type" => "response.output_text.delta", "delta" => "done"}
                      }}

      assert_receive {:omnigent_backend_message,
                      %{
                        event: :turn_completed,
                        agent_id: "omnigent",
                        agent_kind: "omnigent_http",
                        session_id: "conv_fake_2",
                        payload: %{
                          session_id: "conv_fake_2",
                          output_text: "done",
                          raw: %{"type" => "response.completed", "response" => %{"id" => "resp_1"}}
                        },
                        timestamp: %DateTime{}
                      }}

      refute_receive {:omnigent_backend_message,
                      %{
                        event: :notification,
                        payload: %{"type" => "response.completed"}
                      }},
                     50
    after
      SymphonyElixir.FakeOmnigentServer.stop!(server)
      File.rm_rf(test_root)
    end
  end

  test "stop_session/1 正常 cleanup 只发送 stop_session control event" do
    server = SymphonyElixir.FakeOmnigentServer.start!()
    {test_root, workspace} = unique_workspace!("stop-session")

    try do
      base_url = SymphonyElixir.FakeOmnigentServer.base_url(server)
      resolved_agent = omnigent_agent(base_url)

      assert {:ok, session} = OmnigentHttp.start_session(workspace, resolved_agent, on_message: fn _message -> :ok end)
      assert :ok = OmnigentHttp.stop_session(session)

      requests =
        SymphonyElixir.FakeOmnigentServer.requests(server)
        |> Enum.filter(&(&1.name == "post_event"))

      assert Enum.map(requests, & &1.body) == [%{"type" => "stop_session", "data" => %{}}]
    after
      SymphonyElixir.FakeOmnigentServer.stop!(server)
      File.rm_rf(test_root)
    end
  end

  test "run_turn/5 对 child session 和 failed 结果发送事件并返回错误" do
    server =
      SymphonyElixir.FakeOmnigentServer.start!(%{
        create_body: %{"id" => "conv_fake_3", "session_id" => "conv_fake_3"},
        stream_events: [
          {"session.created", %{"type" => "session.created", "session_id" => "child-1"}},
          {"response.failed", %{"type" => "response.failed", "error" => %{"message" => "boom"}}},
          {nil, "[DONE]"}
        ]
      })

    {test_root, workspace} = unique_workspace!("failed-turn")
    parent = self()

    try do
      base_url = SymphonyElixir.FakeOmnigentServer.base_url(server)
      resolved_agent = omnigent_agent(base_url)

      assert {:ok, session} =
               OmnigentHttp.start_session(
                 workspace,
                 resolved_agent,
                 on_message: fn message -> send(parent, {:omnigent_backend_message, message}) end
               )

      assert {:error, {:omnigent_failed, %{"message" => "boom"}}} =
               OmnigentHttp.run_turn(
                 session,
                 workspace,
                 %Issue{id: "issue-omnigent-failed", identifier: "MT-921"},
                 "hello omnigent",
                 on_message: fn message -> send(parent, {:omnigent_backend_message, message}) end
               )

      assert_receive {:omnigent_backend_message,
                      %{
                        event: :child_session_observed,
                        agent_id: "omnigent",
                        agent_kind: "omnigent_http",
                        session_id: "conv_fake_3",
                        payload: %{"type" => "session.created", "session_id" => "child-1"},
                        timestamp: %DateTime{}
                      }}

      assert_receive {:omnigent_backend_message,
                      %{
                        event: :turn_failed,
                        agent_id: "omnigent",
                        agent_kind: "omnigent_http",
                        session_id: "conv_fake_3",
                        payload: %{reason: {:omnigent_failed, %{"message" => "boom"}}},
                        timestamp: %DateTime{}
                      }}

      refute_receive {:omnigent_backend_message,
                      %{
                        event: :notification,
                        payload: %{"type" => "response.failed"}
                      }},
                     50
    after
      SymphonyElixir.FakeOmnigentServer.stop!(server)
      File.rm_rf(test_root)
    end
  end

  test "run_turn/5 对 user_interrupt incomplete 发送 turn_cancelled 并返回原错误" do
    server =
      SymphonyElixir.FakeOmnigentServer.start!(%{
        create_body: %{"id" => "conv_fake_4", "session_id" => "conv_fake_4"},
        stream_events: [
          {"response.incomplete", %{"type" => "response.incomplete", "reason" => "user_interrupt"}},
          {nil, "[DONE]"}
        ]
      })

    {test_root, workspace} = unique_workspace!("cancelled-turn")
    parent = self()

    try do
      base_url = SymphonyElixir.FakeOmnigentServer.base_url(server)
      resolved_agent = omnigent_agent(base_url)

      assert {:ok, session} =
               OmnigentHttp.start_session(
                 workspace,
                 resolved_agent,
                 on_message: fn message -> send(parent, {:omnigent_backend_message, message}) end
               )

      assert {:error, {:omnigent_incomplete, "user_interrupt"}} =
               OmnigentHttp.run_turn(
                 session,
                 workspace,
                 %Issue{id: "issue-omnigent-cancelled", identifier: "MT-922"},
                 "hello omnigent",
                 on_message: fn message -> send(parent, {:omnigent_backend_message, message}) end
               )

      assert_receive {:omnigent_backend_message,
                      %{
                        event: :turn_cancelled,
                        agent_id: "omnigent",
                        agent_kind: "omnigent_http",
                        session_id: "conv_fake_4",
                        payload: %{reason: {:omnigent_incomplete, "user_interrupt"}},
                        timestamp: %DateTime{}
                      }}

      refute_receive {:omnigent_backend_message,
                      %{
                        event: :notification,
                        payload: %{"type" => "response.incomplete"}
                      }},
                     50
    after
      SymphonyElixir.FakeOmnigentServer.stop!(server)
      File.rm_rf(test_root)
    end
  end

  defp omnigent_agent(base_url, overrides \\ %{}) do
    default = %{
      id: "omnigent",
      kind: "omnigent_http",
      config: %{
        "kind" => "omnigent_http",
        "base_url" => base_url,
        "host" => %{
          "mode" => "external",
          "host_id" => "host_local",
          "workspace" => "{{workspace}}"
        },
        "agent" => %{"type" => "agent_id", "id" => "ag_polly"},
        "timeout_ms" => 5_000,
        "stream_timeout_ms" => 1_000
      }
    }

    Map.merge(default, overrides, fn
      :config, left, right when is_map(left) and is_map(right) -> Map.merge(left, right)
      _key, _left, right -> right
    end)
  end

  defp unique_workspace!(name) do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-omnigent-backend-#{name}-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(test_root, "workspace")
    File.mkdir_p!(workspace)
    {test_root, workspace}
  end
end
