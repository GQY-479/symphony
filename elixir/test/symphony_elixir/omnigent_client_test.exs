defmodule SymphonyElixir.OmnigentClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.Omnigent.Client

  test "create_session/1 创建 session 并发送正确请求" do
    server =
      SymphonyElixir.FakeOmnigentServer.start!(%{
        create_body: %{"id" => "conv_fake_1", "session_id" => "conv_fake_1"}
      })

    try do
      base_url = SymphonyElixir.FakeOmnigentServer.base_url(server)

      assert {:ok, session} =
               Client.create_session(%{
                 base_url: base_url,
                 agent: %{"type" => "agent_id", "id" => "ag_polly"},
                 host: %{
                   "mode" => "external",
                   "host_id" => "host_local",
                   "workspace" => "/tmp/work"
                 },
                 title: "YQE-1: test",
                 labels: %{"symphony_issue_id" => "issue-1"},
                 timeout_ms: 5_000
               })

      assert session.session_id == "conv_fake_1"
      assert session.base_url == base_url

      requests = SymphonyElixir.FakeOmnigentServer.requests(server)
      create_request = Enum.find(requests, &(&1.name == "create_session"))

      assert create_request.body["agent_id"] == "ag_polly"
      assert create_request.body["host_type"] == "external"
      assert create_request.body["host_id"] == "host_local"
      assert create_request.body["workspace"] == "/tmp/work"
      assert create_request.body["title"] == "YQE-1: test"
      assert create_request.body["labels"] == %{"symphony_issue_id" => "issue-1"}
      assert create_request.body["initial_items"] == []
    after
      SymphonyElixir.FakeOmnigentServer.stop!(server)
    end
  end

  test "run_turn/3 发送 message 并消费 stream 到 completed" do
    parent = self()

    server =
      SymphonyElixir.FakeOmnigentServer.start!(%{
        create_body: %{"id" => "conv_fake_1", "session_id" => "conv_fake_1"},
        stream_events: [
          {"session.status", %{"type" => "session.status", "status" => "running"}},
          {"response.output_text.delta", %{"type" => "response.output_text.delta", "delta" => "done"}},
          {"response.completed", %{"type" => "response.completed", "response" => %{"id" => "resp_1"}}},
          {nil, "[DONE]"}
        ]
      })

    try do
      base_url = SymphonyElixir.FakeOmnigentServer.base_url(server)

      session = %{base_url: base_url, session_id: "conv_fake_1", stream_timeout_ms: 1_000}

      assert {:ok, result} =
               Client.run_turn(
                 session,
                 "hello omnigent",
                 timeout_ms: 5_000,
                 on_event: fn event -> send(parent, {:omnigent_event, event}) end
               )

      assert result.session_id == "conv_fake_1"
      assert result.output_text == "done"
      assert result.raw["type"] == "response.completed"

      assert_receive {:omnigent_event, %{"type" => "session.status", "status" => "running"}}

      assert_receive {:omnigent_event,
                      %{"type" => "response.output_text.delta", "delta" => "done"}}

      assert_receive {:omnigent_event,
                      %{"type" => "response.completed", "response" => %{"id" => "resp_1"}}}

      requests = SymphonyElixir.FakeOmnigentServer.requests(server)
      post_event_request = Enum.find(requests, &(&1.name == "post_event"))

      assert post_event_request.body == %{
               "type" => "message",
               "data" => %{
                 "role" => "user",
                 "content" => [%{"type" => "input_text", "text" => "hello omnigent"}]
               }
             }
    after
      SymphonyElixir.FakeOmnigentServer.stop!(server)
    end
  end

  test "run_turn/3 遇到 response.failed 返回错误" do
    server =
      SymphonyElixir.FakeOmnigentServer.start!(%{
        stream_events: [
          {"response.failed",
           %{"type" => "response.failed", "error" => %{"message" => "boom"}}},
          {nil, "[DONE]"}
        ]
      })

    try do
      session = %{
        base_url: SymphonyElixir.FakeOmnigentServer.base_url(server),
        session_id: "conv_fake_1",
        stream_timeout_ms: 1_000
      }

      assert {:error, {:omnigent_failed, %{"message" => "boom"}}} =
               Client.run_turn(session, "hello omnigent", timeout_ms: 5_000)
    after
      SymphonyElixir.FakeOmnigentServer.stop!(server)
    end
  end

  test "run_turn/3 遇到 response.incomplete 返回原因" do
    server =
      SymphonyElixir.FakeOmnigentServer.start!(%{
        stream_events: [
          {"response.incomplete",
           %{
             "type" => "response.incomplete",
             "reason" => "user_interrupt"
           }},
          {nil, "[DONE]"}
        ]
      })

    try do
      session = %{
        base_url: SymphonyElixir.FakeOmnigentServer.base_url(server),
        session_id: "conv_fake_1",
        stream_timeout_ms: 1_000
      }

      assert {:error, {:omnigent_incomplete, "user_interrupt"}} =
               Client.run_turn(session, "hello omnigent", timeout_ms: 5_000)
    after
      SymphonyElixir.FakeOmnigentServer.stop!(server)
    end
  end

  test "interrupt/1 发送 interrupt control event" do
    server = SymphonyElixir.FakeOmnigentServer.start!()

    try do
      session = %{
        base_url: SymphonyElixir.FakeOmnigentServer.base_url(server),
        session_id: "conv_fake_1"
      }

      assert :ok = Client.interrupt(session)

      requests = SymphonyElixir.FakeOmnigentServer.requests(server)
      post_event_request = Enum.find(requests, &(&1.name == "post_event"))

      assert post_event_request.body == %{"type" => "interrupt", "data" => %{}}
    after
      SymphonyElixir.FakeOmnigentServer.stop!(server)
    end
  end

  test "stop_session/1 发送 stop_session control event" do
    server = SymphonyElixir.FakeOmnigentServer.start!()

    try do
      session = %{
        base_url: SymphonyElixir.FakeOmnigentServer.base_url(server),
        session_id: "conv_fake_1"
      }

      assert :ok = Client.stop_session(session)

      requests = SymphonyElixir.FakeOmnigentServer.requests(server)
      post_event_request = Enum.find(requests, &(&1.name == "post_event"))

      assert post_event_request.body == %{"type" => "stop_session", "data" => %{}}
    after
      SymphonyElixir.FakeOmnigentServer.stop!(server)
    end
  end
end
