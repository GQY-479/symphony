defmodule SymphonyElixir.Agent.Omnigent.Client do
  @moduledoc false

  alias SymphonyElixir.Agent.Omnigent.Sse

  @default_timeout_ms 30_000

  @spec create_session(map()) :: {:ok, map()} | {:error, term()}
  def create_session(params) when is_map(params) do
    base_url = normalize_base_url(fetch!(params, :base_url))
    timeout_ms = Map.get(params, :timeout_ms, @default_timeout_ms)
    stream_timeout_ms = Map.get(params, :stream_timeout_ms, @default_timeout_ms)

    with {:ok, response} <-
           post_create_session(
             base_url <> "/v1/sessions",
             fetch!(params, :agent),
             Map.get(params, :host, %{}),
             params,
             timeout_ms
           ),
         {:ok, payload} <- decode_2xx(response) do
      session_id = payload["session_id"] || payload["id"]

      {:ok,
       %{
         session_id: session_id,
         base_url: base_url,
         timeout_ms: timeout_ms,
         stream_timeout_ms: stream_timeout_ms,
         raw: payload
       }}
    end
  end

  @spec run_turn(map(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, input_text, opts \\ []) when is_map(session) and is_binary(input_text) do
    base_url = normalize_base_url(fetch!(session, :base_url))
    session_id = fetch!(session, :session_id)
    timeout_ms = Keyword.get(opts, :timeout_ms, Map.get(session, :timeout_ms, @default_timeout_ms))
    stream_timeout_ms = Map.get(session, :stream_timeout_ms, timeout_ms)
    on_event = Keyword.get(opts, :on_event, fn _event -> :ok end)

    stream_url = base_url <> "/v1/sessions/" <> session_id <> "/stream"
    events_url = base_url <> "/v1/sessions/" <> session_id <> "/events"

    with {:ok, stream_response} <- open_stream(stream_url, stream_timeout_ms) do
      case post(events_url, message_event_body(input_text), timeout_ms) do
        {:ok, response} ->
          case decode_2xx(response) do
            {:ok, _payload} ->
              consume_stream(stream_response, session_id, on_event)

            {:error, _reason} = error ->
              cancel_stream(stream_response)
              error
          end

        {:error, _reason} = error ->
          cancel_stream(stream_response)
          error
      end
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

  defp post_create_session(url, %{"type" => "agent_id"} = agent, host, params, timeout_ms) do
    with {:ok, body} <- create_session_body(agent, host, params) do
      post(url, body, timeout_ms)
    end
  end

  defp post_create_session(url, %{"type" => "bundle_path", "path" => path} = agent, host, params, timeout_ms) do
    with {:ok, tar_path} <- pack_bundle(path) do
      try do
        metadata = create_session_metadata(agent, host, params)
        fields = bundle_multipart_fields(metadata, tar_path)
        post_multipart(url, fields, timeout_ms)
      after
        File.rm(tar_path)
      end
    end
  end

  defp post_create_session(_url, agent, _host, _params, _timeout_ms) do
    {:error, {:omnigent_invalid_agent, agent}}
  end

  defp create_session_body(%{"type" => "agent_id", "id" => agent_id}, host, params) do
    metadata =
      %{
        "agent_id" => agent_id,
        "initial_items" => [],
        "title" => Map.get(params, :title),
        "labels" => Map.get(params, :labels),
        "host_type" => "external"
      }
      |> maybe_put("host_id", Map.get(host, "host_id"))
      |> maybe_put("workspace", Map.get(host, "workspace"))

    {:ok, metadata}
  end

  defp create_session_body(agent, _host, _params) do
    {:error, {:omnigent_invalid_agent, agent}}
  end

  defp create_session_metadata(%{"type" => "bundle_path", "path" => path}, host, params) do
    %{
      "agent" => %{"type" => "bundle_path", "path" => path},
      "agent_type" => "bundle_path",
      "bundle_path" => path,
      "initial_items" => [],
      "title" => Map.get(params, :title),
      "labels" => Map.get(params, :labels),
      "host_type" => "external"
    }
    |> maybe_put("host_id", Map.get(host, "host_id"))
    |> maybe_put("workspace", Map.get(host, "workspace"))
  end

  defp bundle_multipart_fields(metadata, tar_path) do
    [
      metadata: {Jason.encode!(metadata), content_type: "application/json"},
      bundle: {File.stream!(tar_path, [], 2048), filename: "bundle.tar.gz", content_type: "application/gzip", size: File.stat!(tar_path).size}
    ]
  end

  defp pack_bundle(path) when is_binary(path) do
    tar_path = Path.join(System.tmp_dir!(), "omnigent_bundle_#{System.unique_integer([:positive])}.tar.gz")
    expanded_path = Path.expand(path)

    case System.cmd("tar", ["-czf", tar_path, "-C", expanded_path, "."], stderr_to_stdout: true) do
      {_output, 0} ->
        {:ok, tar_path}

      {output, status} ->
        File.rm(tar_path)
        {:error, {:bundle_pack_failed, status, output}}
    end
  rescue
    error ->
      {:error, {:bundle_pack_failed, :exception, Exception.message(error)}}
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
    base_url = normalize_base_url(fetch!(session, :base_url))
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
    try do
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
    rescue
      error ->
        {:error, {:omnigent_transport_error, error}}
    catch
      kind, reason ->
        {:error, {:omnigent_transport_error, {kind, reason}}}
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

  defp post_multipart(url, fields, timeout_ms) do
    case Req.post(url,
           form_multipart: fields,
           connect_options: [timeout: timeout_ms],
           receive_timeout: timeout_ms
         ) do
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

  defp cancel_stream(response) do
    try do
      Req.cancel_async_response(response)
    rescue
      _error -> :ok
    end
  end

  defp normalize_base_url(base_url) when is_binary(base_url) do
    String.trim_trailing(base_url, "/")
  end

  defp fetch!(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> raise KeyError, key: key, term: map
    end
  end
end
