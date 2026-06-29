defmodule SymphonyElixir.Agent.Omnigent.Client do
  @moduledoc false

  alias SymphonyElixir.Agent.Omnigent.Sse

  @default_timeout_ms 30_000
  @stream_ready_timeout_ms 1_000
  @default_runner_ready_poll_ms 500

  @spec create_session(map()) :: {:ok, map()} | {:error, term()}
  def create_session(params) when is_map(params) do
    base_url = normalize_base_url(fetch!(params, :base_url))
    timeout_ms = Map.get(params, :timeout_ms, @default_timeout_ms)
    stream_timeout_ms = Map.get(params, :stream_timeout_ms, @default_timeout_ms)

    runner_ready_timeout_ms = Map.get(params, :runner_ready_timeout_ms, 0)
    runner_ready_poll_ms = Map.get(params, :runner_ready_poll_ms, @default_runner_ready_poll_ms)

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

      session = %{
        session_id: session_id,
        base_url: base_url,
        timeout_ms: timeout_ms,
        stream_timeout_ms: stream_timeout_ms,
        raw: payload
      }

      maybe_wait_runner_ready(session, runner_ready_timeout_ms, runner_ready_poll_ms)
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

    stream_task = start_stream_consumer(stream_url, stream_timeout_ms, session_id, on_event)

    with :ok <- wait_stream_ready(stream_task) do
      case post(events_url, message_event_body(input_text), timeout_ms) do
        {:ok, response} ->
          case decode_2xx(response) do
            {:ok, _payload} ->
              await_stream_consumer(stream_task, stream_timeout_ms)

            {:error, _reason} = error ->
              stop_stream_consumer(stream_task)
              error
          end

        {:error, _reason} = error ->
          stop_stream_consumer(stream_task)
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
    with {:ok, bundle_archive} <- pack_bundle(path) do
      try do
        metadata = create_session_metadata(agent, host, params)
        fields = bundle_multipart_fields(metadata, bundle_archive.tar_path)
        post_multipart(url, fields, timeout_ms)
      after
        File.rm_rf(bundle_archive.temp_dir)
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
        "host_type" => "external"
      }
      |> maybe_put("title", Map.get(params, :title))
      |> maybe_put("labels", Map.get(params, :labels))
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
      "host_type" => "external"
    }
    |> maybe_put("title", Map.get(params, :title))
    |> maybe_put("labels", Map.get(params, :labels))
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
    with {:ok, temp_dir} <- make_bundle_temp_dir() do
      write_bundle_archive(temp_dir, path)
    end
  end

  defp write_bundle_archive(temp_dir, path) do
    tar_path = Path.join(temp_dir, "bundle.tar.gz")
    expanded_path = Path.expand(path)

    case System.cmd("tar", ["-czf", tar_path, "-C", expanded_path, "."], stderr_to_stdout: true) do
      {_output, 0} ->
        {:ok, %{tar_path: tar_path, temp_dir: temp_dir}}

      {output, status} ->
        File.rm_rf(temp_dir)
        {:error, {:bundle_pack_failed, status, output}}
    end
  rescue
    error ->
      File.rm_rf(temp_dir)
      {:error, {:bundle_pack_failed, :exception, Exception.message(error)}}
  end

  defp make_bundle_temp_dir(attempts \\ 5)

  defp make_bundle_temp_dir(0) do
    {:error, {:bundle_pack_failed, :temp_dir_unavailable, "could not create temporary bundle directory"}}
  end

  defp make_bundle_temp_dir(attempts) do
    suffix =
      16
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    temp_dir = Path.join(System.tmp_dir!(), "symphony_omnigent_bundle_#{suffix}")

    case File.mkdir(temp_dir) do
      :ok -> {:ok, temp_dir}
      {:error, :eexist} -> make_bundle_temp_dir(attempts - 1)
      {:error, reason} -> {:error, {:bundle_pack_failed, :temp_dir_unavailable, inspect(reason)}}
    end
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

  defp maybe_wait_runner_ready(session, timeout_ms, _poll_ms) when not is_integer(timeout_ms) or timeout_ms <= 0 do
    {:ok, session}
  end

  defp maybe_wait_runner_ready(session, timeout_ms, poll_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_ms = if is_integer(poll_ms) and poll_ms > 0, do: poll_ms, else: @default_runner_ready_poll_ms
    wait_runner_ready(session, deadline, timeout_ms, poll_ms, session.raw)
  end

  defp wait_runner_ready(session, deadline, timeout_ms, poll_ms, last_snapshot) do
    case get_session(session) do
      {:ok, %{"runner_online" => true} = snapshot} ->
        {:ok, %{session | raw: snapshot}}

      {:ok, %{"status" => "failed"} = snapshot} ->
        {:error, {:omnigent_failed, Map.get(snapshot, "last_task_error") || Map.get(snapshot, "error")}}

      {:ok, snapshot} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, {:omnigent_runner_not_ready, timeout_ms, snapshot}}
        else
          Process.sleep(poll_ms)
          wait_runner_ready(session, deadline, timeout_ms, poll_ms, snapshot)
        end

      {:error, _reason} = error ->
        if System.monotonic_time(:millisecond) >= deadline do
          case last_snapshot do
            snapshot when is_map(snapshot) ->
              {:error, {:omnigent_runner_not_ready, timeout_ms, snapshot}}

            _ ->
              error
          end
        else
          Process.sleep(poll_ms)
          wait_runner_ready(session, deadline, timeout_ms, poll_ms, last_snapshot)
        end
    end
  end

  defp get_session(session) do
    base_url = normalize_base_url(fetch!(session, :base_url))
    session_id = fetch!(session, :session_id)
    timeout_ms = Map.get(session, :timeout_ms, @default_timeout_ms)
    url = base_url <> "/v1/sessions/" <> session_id <> "?include_items=false"

    with {:ok, response} <- get(url, timeout_ms) do
      decode_2xx(response)
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

  defp consume_stream(response, session_id, on_event, ready_signal) do
    result =
      Enum.reduce_while(response.body, {:cont, {Sse.new(), "", false}}, fn chunk, {:cont, {sse, output_text, ready?}} ->
        {events, next_sse} = Sse.feed(sse, chunk)
        ready? = maybe_notify_stream_ready(ready_signal, ready?, events)

        case handle_stream_events(events, next_sse, output_text, session_id, on_event) do
          {:cont, {sse, output_text}} -> {:cont, {:cont, {sse, output_text, ready?}}}
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

  defp start_stream_consumer(url, timeout_ms, session_id, on_event) do
    parent = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        case open_stream(url, timeout_ms) do
          {:ok, response} ->
            consume_stream(response, session_id, on_event, {parent, ref})

          {:error, reason} = error ->
            send(parent, {:omnigent_stream_open_failed, ref, reason})
            error
        end
      end)

    %{task: task, ref: ref}
  end

  defp wait_stream_ready(%{task: task, ref: ref}) do
    receive do
      {:omnigent_stream_ready, ^ref} ->
        :ok

      {:omnigent_stream_open_failed, ^ref, reason} ->
        Task.shutdown(task, :brutal_kill)
        {:error, reason}

      {task_ref, {:error, reason}} when task_ref == task.ref ->
        Process.demonitor(task.ref, [:flush])
        {:error, reason}
    after
      @stream_ready_timeout_ms ->
        :ok
    end
  end

  defp await_stream_consumer(%{task: task}, timeout_ms) do
    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, {:omnigent_transport_error, :timeout}}
    end
  end

  defp stop_stream_consumer(%{task: task}) do
    Task.shutdown(task, :brutal_kill)
    :ok
  end

  defp maybe_notify_stream_ready(_ready_signal, true, _events), do: true
  defp maybe_notify_stream_ready(_ready_signal, false, []), do: false

  defp maybe_notify_stream_ready({parent, ref}, false, _events) do
    send(parent, {:omnigent_stream_ready, ref})
    true
  end

  defp maybe_notify_stream_ready(nil, false, _events), do: true

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

      "session.status" ->
        handle_session_status_event(data, output_text)

      "response.incomplete" ->
        {:halt, {:error, {:omnigent_incomplete, Map.get(data, "reason")}}}

      _other ->
        {:cont, output_text}
    end
  end

  defp handle_stream_event(_event, output_text, _session_id, _on_event) do
    {:cont, output_text}
  end

  defp handle_session_status_event(%{"status" => "failed"} = data, _output_text) do
    {:halt, {:error, {:omnigent_failed, Map.get(data, "error")}}}
  end

  defp handle_session_status_event(_data, output_text) do
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

  defp get(url, timeout_ms) do
    case Req.get(url, connect_options: [timeout: timeout_ms], receive_timeout: timeout_ms) do
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
