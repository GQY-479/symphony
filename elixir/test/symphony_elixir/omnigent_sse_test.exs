Code.require_file("../support/fake_omnigent_server.exs", __DIR__)

defmodule SymphonyElixir.OmnigentSseTest do

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.Omnigent.Sse

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
      |> Sse.feed(": heartbeat\n\ndata: {\"type\":\"session.status\",\"status\":\"running\"}\n\ndata: [DONE]\n\n")

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
end
