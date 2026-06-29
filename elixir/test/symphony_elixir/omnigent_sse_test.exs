defmodule SymphonyElixir.OmnigentSseTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.Omnigent.Sse

  test "公共测试入口可见 fake Omnigent server 支持模块" do
    assert Code.ensure_loaded?(SymphonyElixir.FakeOmnigentServer)
    assert function_exported?(SymphonyElixir.FakeOmnigentServer, :start!, 1)
  end

  test "解析命名 SSE 事件并保留未完成帧" do
    state = Sse.new()

    assert {[], state} = Sse.feed(state, "event: response.output_text.delta\n")

    assert {events, state} =
             Sse.feed(
               state,
               "data: {\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}\n\n"
             )

    assert [
             %{
               event: "response.output_text.delta",
               data: %{"type" => "response.output_text.delta", "delta" => "hi"}
             }
           ] = events

    assert state.buffer == ""
  end

  test "解析 data-only 事件、注释和 done 标记" do
    {events, _state} =
      Sse.new()
      |> Sse.feed("""
      : heartbeat

      data: {"type":"session.status","status":"running"}

      data: [DONE]

      """)

    assert [
             %{event: nil, data: %{"type" => "session.status", "status" => "running"}},
             %{event: nil, data: "[DONE]"}
           ] = events
  end

  test "坏 JSON 不崩溃并标记为原始内容" do
    {events, _state} = Sse.feed(Sse.new(), "event: response.error\ndata: {not-json}\n\n")

    assert [
             %{event: "response.error", data: %{"raw" => "{not-json}", "malformed" => true}}
           ] = events
  end

  test "忽略没有 data 的 SSE frame" do
    assert {[], state} = Sse.feed(Sse.new(), "event: heartbeat\n\n")
    assert state.buffer == ""
  end

  test "保留显式空 data 事件" do
    assert {[%{event: nil, data: ""}], state} = Sse.feed(Sse.new(), "data:\n\n")
    assert state.buffer == ""
  end

  test "保留带事件名的显式空 data 事件" do
    assert {[%{event: "heartbeat", data: ""}], state} =
             Sse.feed(Sse.new(), "event: heartbeat\ndata:\n\n")

    assert state.buffer == ""
  end

  test "解析 CRLF frame" do
    assert {[%{event: "response.completed", data: %{"type" => "response.completed"}}], state} =
             Sse.feed(
               Sse.new(),
               "event: response.completed\r\ndata: {\"type\":\"response.completed\"}\r\n\r\n"
             )

    assert state.buffer == ""
  end

  test "解析多行 data" do
    assert {[%{event: nil, data: %{"a" => 1, "b" => 2}}], state} =
             Sse.feed(Sse.new(), "data: {\"a\":1,\ndata: \"b\":2}\n\n")

    assert state.buffer == ""
  end

  test "fake Omnigent server HTTP smoke" do
    server =
      SymphonyElixir.FakeOmnigentServer.start!(%{
        create_body: %{"id" => "conv_fake_1", "session_id" => "conv_fake_1"}
      })

    try do
      base_url = SymphonyElixir.FakeOmnigentServer.base_url(server)

      create = Req.post!(base_url <> "/v1/sessions")

      assert create.status == 201
      assert create.body["id"] == "conv_fake_1"
      assert create.body["session_id"] == "conv_fake_1"

      post_event =
        Req.post!(
          base_url <> "/v1/sessions/conv_fake_1/events",
          json: %{"type" => "message", "text" => "hi"}
        )

      assert post_event.status == 204

      stream = Req.get!(base_url <> "/v1/sessions/conv_fake_1/stream")

      assert stream.status == 200

      assert Enum.any?(stream.headers, fn {name, value} ->
               String.downcase(to_string(name)) == "content-type" and
                 String.contains?(IO.iodata_to_binary(value), "text/event-stream")
             end)

      assert String.contains?(stream.body, "response.completed")

      requests = SymphonyElixir.FakeOmnigentServer.requests(server)

      assert Enum.any?(requests, fn request -> request.name == "create_session" end)
      assert Enum.any?(requests, fn request -> request.name == "post_event" end)
      assert Enum.any?(requests, fn request -> request.name == "stream" end)

      post_event_request = Enum.find(requests, fn request -> request.name == "post_event" end)
      assert post_event_request.body["type"] == "message"
    after
      SymphonyElixir.FakeOmnigentServer.stop!(server)
    end
  end
end
