defmodule SymphonyElixir.OmnigentClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.Omnigent.Client

  test "create_session/1 支持 bundle_path 并上传 multipart bundle" do
    server =
      SymphonyElixir.FakeOmnigentServer.start!(%{
        create_body: %{"id" => "conv_bundle_1", "session_id" => "conv_bundle_1"}
      })

    bundle_dir = Path.join(System.tmp_dir!(), "omnigent_bundle_#{System.unique_integer([:positive])}")

    try do
      File.mkdir_p!(bundle_dir)
      File.write!(Path.join(bundle_dir, "agent.yaml"), "name: bundle-agent\n")

      base_url = SymphonyElixir.FakeOmnigentServer.base_url(server)

      assert {:ok, session} =
               Client.create_session(%{
                 base_url: base_url,
                 agent: %{"type" => "bundle_path", "path" => bundle_dir},
                 host: %{
                   "mode" => "external",
                   "host_id" => "host_local",
                   "workspace" => "/tmp/work"
                 },
                 title: "YQE-1: bundle",
                 labels: %{"symphony_issue_id" => "issue-bundle"},
                 timeout_ms: 5_000,
                 stream_timeout_ms: 1_234
               })

      assert session.session_id == "conv_bundle_1"
      assert session.base_url == base_url
      assert session.timeout_ms == 5_000
      assert session.stream_timeout_ms == 1_234
      assert session.raw == %{"id" => "conv_bundle_1", "session_id" => "conv_bundle_1"}

      requests = SymphonyElixir.FakeOmnigentServer.requests(server)
      create_request = Enum.find(requests, &(&1.name == "create_session"))

      assert {"content-type", content_type} =
               Enum.find(create_request.headers, fn {key, _value} -> key == "content-type" end)

      assert String.starts_with?(content_type, "multipart/form-data")
      assert create_request.body["metadata"]["host_type"] == "external"
      assert create_request.body["metadata"]["host_id"] == "host_local"
      assert create_request.body["metadata"]["workspace"] == "/tmp/work"
      assert create_request.body["metadata"]["title"] == "YQE-1: bundle"
      assert create_request.body["metadata"]["labels"] == %{"symphony_issue_id" => "issue-bundle"}
      assert create_request.body["metadata"]["agent"] == %{"type" => "bundle_path", "path" => bundle_dir}
      assert create_request.body["metadata"]["initial_items"] == []
      assert create_request.body["bundle"]["filename"] == "bundle.tar.gz"
      assert create_request.body["bundle"]["size"] > 0
    after
      File.rm_rf!(bundle_dir)
      SymphonyElixir.FakeOmnigentServer.stop!(server)
    end
  end

  test "create_session/1 在 bundle_path 打包失败时返回结构化错误" do
    missing_bundle_dir =
      Path.join(System.tmp_dir!(), "missing_omnigent_bundle_#{System.unique_integer([:positive])}")

    assert {:error, {:bundle_pack_failed, status, output}} =
             Client.create_session(%{
               base_url: "http://127.0.0.1:1",
               agent: %{"type" => "bundle_path", "path" => missing_bundle_dir},
               host: %{},
               timeout_ms: 5_000
             })

    assert is_integer(status) or status == :exception
    assert is_binary(output)
    assert output != ""
  end

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
      assert session.timeout_ms == 5_000
      assert session.stream_timeout_ms == 30_000

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

  test "create_session/1 忽略传入 host.mode 并固定发送 external host_type" do
    server =
      SymphonyElixir.FakeOmnigentServer.start!(%{
        create_body: %{"id" => "conv_fake_1", "session_id" => "conv_fake_1"}
      })

    try do
      base_url = SymphonyElixir.FakeOmnigentServer.base_url(server)

      assert {:ok, _session} =
               Client.create_session(%{
                 base_url: base_url,
                 agent: %{"type" => "agent_id", "id" => "ag_polly"},
                 host: %{
                   "mode" => "local_override",
                   "host_id" => "host_local",
                   "workspace" => "/tmp/work"
                 },
                 timeout_ms: 5_000
               })

      requests = SymphonyElixir.FakeOmnigentServer.requests(server)
      create_request = Enum.find(requests, &(&1.name == "create_session"))

      assert create_request.body["host_type"] == "external"
    after
      SymphonyElixir.FakeOmnigentServer.stop!(server)
    end
  end

  test "create_session/1 返回的 session 可直接喂给 run_turn/3 并保留 stream_timeout_ms" do
    server =
      SymphonyElixir.FakeOmnigentServer.start!(%{
        create_body: %{"id" => "conv_fake_1", "session_id" => "conv_fake_1"},
        stream_events: [
          {"response.output_text.delta", %{"type" => "response.output_text.delta", "delta" => "done"}},
          {"response.completed", %{"type" => "response.completed", "response" => %{"id" => "resp_1"}}},
          {nil, "[DONE]"}
        ]
      })

    try do
      base_url = SymphonyElixir.FakeOmnigentServer.base_url(server)

      assert {:ok, session} =
               Client.create_session(%{
                 base_url: base_url,
                 agent: %{"type" => "agent_id", "id" => "ag_polly"},
                 host: %{"host_id" => "host_local", "workspace" => "/tmp/work"},
                 timeout_ms: 5_000,
                 stream_timeout_ms: 1_234
               })

      assert session.timeout_ms == 5_000
      assert session.stream_timeout_ms == 1_234

      assert {:ok, result} = Client.run_turn(session, "hello omnigent")
      assert result.session_id == "conv_fake_1"
      assert result.output_text == "done"
    after
      SymphonyElixir.FakeOmnigentServer.stop!(server)
    end
  end

  test "create_session/1 规整 base_url 尾斜杠" do
    server =
      SymphonyElixir.FakeOmnigentServer.start!(%{
        create_body: %{"id" => "conv_fake_1", "session_id" => "conv_fake_1"}
      })

    try do
      base_url = SymphonyElixir.FakeOmnigentServer.base_url(server)

      assert {:ok, session} =
               Client.create_session(%{
                 base_url: base_url <> "/",
                 agent: %{"type" => "agent_id", "id" => "ag_polly"},
                 host: %{"host_id" => "host_local", "workspace" => "/tmp/work"},
                 timeout_ms: 5_000
               })

      assert session.base_url == base_url

      requests = SymphonyElixir.FakeOmnigentServer.requests(server)
      create_request = Enum.find(requests, &(&1.name == "create_session"))
      assert create_request.path == "/v1/sessions"
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

      assert_receive {:omnigent_event, %{"type" => "response.output_text.delta", "delta" => "done"}}

      assert_receive {:omnigent_event, %{"type" => "response.completed", "response" => %{"id" => "resp_1"}}}

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

  test "run_turn/3 在 POST /events 非 2xx 时立刻返回 HTTP 错误" do
    server =
      SymphonyElixir.FakeOmnigentServer.start!(%{
        events_status: 500,
        events_body: %{"error" => "events failed"},
        stream_events: [
          {"response.output_text.delta", %{"type" => "response.output_text.delta", "delta" => "late"}},
          {"response.completed", %{"type" => "response.completed", "response" => %{"id" => "resp_1"}}},
          {nil, "[DONE]"}
        ]
      })

    try do
      session = %{
        base_url: SymphonyElixir.FakeOmnigentServer.base_url(server),
        session_id: "conv_fake_1",
        stream_timeout_ms: 1_000
      }

      assert {:error, {:omnigent_http_error, 500, %{"error" => "events failed"}}} =
               Client.run_turn(session, "hello omnigent", timeout_ms: 5_000)
    after
      SymphonyElixir.FakeOmnigentServer.stop!(server)
    end
  end

  test "run_turn/3 在 message event 被拒绝时立即返回" do
    server =
      SymphonyElixir.FakeOmnigentServer.start!(%{
        events_status: 500,
        events_body: %{"error" => "nope"},
        stream_delay_ms: 500,
        stream_events: [
          {"response.output_text.delta", %{"type" => "response.output_text.delta", "delta" => "late"}},
          {"response.completed", %{"type" => "response.completed", "response" => %{"id" => "resp_1"}}},
          {nil, "[DONE]"}
        ]
      })

    try do
      session = %{
        base_url: SymphonyElixir.FakeOmnigentServer.base_url(server),
        session_id: "conv_fake_1",
        stream_timeout_ms: 2_000
      }

      started_at = System.monotonic_time(:millisecond)

      assert {:error, {:omnigent_http_error, 500, %{"error" => "nope"}}} =
               Client.run_turn(session, "hello omnigent", timeout_ms: 5_000)

      elapsed_ms = System.monotonic_time(:millisecond) - started_at
      assert elapsed_ms < 300
    after
      SymphonyElixir.FakeOmnigentServer.stop!(server)
    end
  end

  test "run_turn/3 在 stream async 超时后返回 transport 错误而不是抛异常" do
    server =
      SymphonyElixir.FakeOmnigentServer.start!(%{
        stream_delay_ms: 100,
        stream_events: [
          {"response.output_text.delta", %{"type" => "response.output_text.delta", "delta" => "late"}},
          {"response.completed", %{"type" => "response.completed", "response" => %{"id" => "resp_1"}}},
          {nil, "[DONE]"}
        ]
      })

    try do
      session = %{
        base_url: SymphonyElixir.FakeOmnigentServer.base_url(server),
        session_id: "conv_fake_1",
        stream_timeout_ms: 10
      }

      assert {:error, {:omnigent_transport_error, _reason}} =
               Client.run_turn(session, "hello omnigent", timeout_ms: 5_000)
    after
      SymphonyElixir.FakeOmnigentServer.stop!(server)
    end
  end

  test "run_turn/3 遇到 response.failed 返回错误" do
    server =
      SymphonyElixir.FakeOmnigentServer.start!(%{
        stream_events: [
          {"response.failed", %{"type" => "response.failed", "error" => %{"message" => "boom"}}},
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
