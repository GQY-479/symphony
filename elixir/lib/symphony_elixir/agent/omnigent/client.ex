defmodule SymphonyElixir.Agent.Omnigent.Client do
  @moduledoc false

  alias SymphonyElixir.Agent.Omnigent.Sse

  @default_timeout_ms 30_000

  @spec create_session(map()) :: {:ok, map()} | {:error, term()}
  def create_session(params) when is_map(params) do
    base_url = fetch!(params, :base_url)
    timeout_ms = Map.get(params, :timeout_ms, @default_timeout_ms)

    with {:ok, body} <- create_session_body(fetch!(params, :agent), Map.get(params, :host, %{}), params),
         {:ok, response} <- post(base_url <> "/v1/sessions", body, timeout_ms),
         {:ok, payload} <- decode_2xx(response) do
      session_id = payload["session_id"] || payload["id"]

      {:ok,
       %{
         session_id: session_id,
         base_url: base_url,
         raw: payload
       }}
    end
  end

  @spec run_turn(map(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, input_text, opts \\ []) when is_map(session) and is_binary(input_text) do
    base_url = fetch!(session, :base_url)
    session_id = fetch!(session, :session_id)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    stream_timeout_ms = Map.get(session, :stream_timeout_ms, timeout_ms)
    on_event = Keyword.get(opts, :on_event, fn _event -> :ok end)

    stream_url = base_url <> "/v1/sessions/" <> session_id <> "/stream"
    events_url = base_url <> "/v1/sessions/" <> session_id <> "/events"

    with {:ok, stream_response} <- open_stream(stream_url, stream_timeout_ms),
         {:ok, _response} <- post(events_url, message_event_body(input_text), timeout_ms) do
      consume_stream(stream_response, session_id, on_event)
    end
  end

  @spec interrupt(map()) :: :ok | {:error, term()}
  def interrupt(session) when is_map(session) do
    post_control_event(session, %{"type" => "interrupt", "data" => %{}})
  end

  @spec stop_session(map()) :: :ok | {:error, term()}
  def stop_session(session) when is_map(session) do
    post_control_event(session, %{"type" => "stop_session", "data" => %{}})
  end

  defp create_session_body(%{"type" => "agent_id", "id" => agent_id}, host, params) do
    body =
      %{
        "agent_id" => agent_id,
        "initial_items" => [],
        "title" => Map.get(params, :title),
        "labels" => Map.get(params, :labels),
        "host_type" => "external"
      }
      |> maybe_put("host_id", Map.get(host, "host_id"))
      |> maybe_put("workspace", Map.get(host, "workspace"))

    {:ok, body}
  end

  defp create_session_body(%{"type" => "bundle_path", "path" => path}, _host, _params) do
    {:error, {:omnigent_bundle_upload_not_supported_yet, path}}
  end

  defp create_session_body(agent, _host, _params) do
    {:error, {:omnigent_invalid_agent, agent}}
  end

  defp message_event_body(input_text) do
    %{
      "type" => "message",
      "data" => %{
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => input_text}]
      }
    }
  end

  defp post_control_event(session, body) do
    base_url = fetch!(session, :base_url)
    session_id = fetch!(session, :session_id)
    timeout_ms = Map.get(session, :timeout_ms, @default_timeout_ms)
    url = base_url <> "/v1/sessions/" <> session_id <> "/events"

    with {:ok, response} <- post(url, body, timeout_ms),
         {:ok, _payload} <- decode_2xx(response) do
      :ok
    end
  end

  defp open_stream(url, timeout_ms) do
    case Req.get(url, into: :self, connect_options: [timeout: timeout_ms], receive_timeout: timeout_ms) do
      {:ok, %Req.Response{status: status} = response} when status >= 200 and status < 300 ->
        {:ok, response}

      {:ok, %Req.Response{} = response} ->
        {:error, {:omnigent_http_error, response.status, response.body}}

      {:error, reason} ->
        {:error, {:omnigent_transport_error, reason}}
    end
  end

  defp consume_stream(response, session_id, on_event) do
    result =
      Enum.reduce_while(response.body, {:cont, {Sse.new(), ""}}, fn chunk, {:cont, {sse, output_text}} ->
        {events, next_sse} = Sse.feed(sse, chunk)

        case handle_stream_events(events, next_sse, output_text, session_id, on_event) do
          {:cont, next_state} -> {:cont, {:cont, next_state}}
          {:halt, outcome} -> {:halt, outcome}
        end
      end)

    case result do
      {:cont, _state} -> {:error, :omnigent_stream_ended}
      other -> other
    end
  end

  defp handle_stream_events([], sse, output_text, _session_id, _on_event) do
    {:cont, {sse, output_text}}
  end

  defp handle_stream_events([event | rest], sse, output_text, session_id, on_event) do
    case handle_stream_event(event, output_text, session_id, on_event) do
      {:cont, next_output_text} ->
        handle_stream_events(rest, sse, next_output_text, session_id, on_event)

      {:halt, outcome} ->
        {:halt, outcome}
    end
  end

  defp handle_stream_event(%{data: "[DONE]"}, output_text, _session_id, _on_event) do
    {:cont, output_text}
  end

  defp handle_stream_event(%{data: data}, output_text, session_id, on_event) when is_map(data) do
    on_event.(data)

    case data["type"] do
      "response.output_text.delta" ->
        {:cont, output_text <> to_string(Map.get(data, "delta", ""))}

      "response.completed" ->
        {:halt,
         {:ok,
          %{
            session_id: session_id,
            output_text: output_text,
            raw: data
          }}}

      "response.failed" ->
        {:halt, {:error, {:omnigent_failed, Map.get(data, "error")}}}

      "response.incomplete" ->
        {:halt, {:error, {:omnigent_incomplete, Map.get(data, "reason")}}}

      _other ->
        {:cont, output_text}
    end
  end

  defp handle_stream_event(_event, output_text, _session_id, _on_event) do
    {:cont, output_text}
  end

  defp post(url, body, timeout_ms) do
    case Req.post(url, json: body, connect_options: [timeout: timeout_ms], receive_timeout: timeout_ms) do
      {:ok, %Req.Response{} = response} ->
        {:ok, response}

      {:error, reason} ->
        {:error, {:omnigent_transport_error, reason}}
    end
  end

  defp decode_2xx(%Req.Response{status: status, body: body}) when status >= 200 and status < 300 do
    {:ok, body}
  end

  defp decode_2xx(%Req.Response{status: status, body: body}) do
    {:error, {:omnigent_http_error, status, body}}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp fetch!(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> raise KeyError, key: key, term: map
    end
  end
end
