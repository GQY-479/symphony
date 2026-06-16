defmodule SymphonyElixir.Agent.Backend.OmnigentHttp do
  @moduledoc false

  @behaviour SymphonyElixir.Agent.Backend

  alias SymphonyElixir.Agent.Omnigent.Client

  @default_timeout_ms 3_600_000
  @default_stream_timeout_ms 600_000

  @impl true
  def run_issue(_workspace, _issue, _prompt, _resolved_agent, _opts),
    do: {:error, :omnigent_http_session_backend_only}

  @spec start_session(Path.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_session(workspace, resolved_agent, opts) do
    config = agent_config(resolved_agent)
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    timeout_ms = Map.get(config, "timeout_ms", @default_timeout_ms)
    stream_timeout_ms = Map.get(config, "stream_timeout_ms", @default_stream_timeout_ms)

    client_config = %{
      base_url: Map.get(config, "base_url"),
      agent: Map.get(config, "agent"),
      host: expand_host_workspace(Map.get(config, "host", %{}), workspace),
      title: "Symphony issue session",
      labels: %{
        "symphony_agent_id" => agent_id(resolved_agent),
        "symphony_agent_kind" => agent_kind(resolved_agent)
      },
      timeout_ms: timeout_ms,
      stream_timeout_ms: stream_timeout_ms
    }

    case Client.create_session(client_config) do
      {:ok, session} ->
        session =
          session
          |> Map.put(:resolved_agent, resolved_agent)
          |> Map.put(:timeout_ms, timeout_ms)
          |> Map.put(:stream_timeout_ms, stream_timeout_ms)

        emit(on_message, resolved_agent, session.session_id, :session_started, session.raw)
        {:ok, session}

      other ->
        other
    end
  end

  @spec run_turn(map(), Path.t(), map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, _workspace, _issue, prompt, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, Map.get(session, :timeout_ms, @default_timeout_ms))
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    resolved_agent = Map.fetch!(session, :resolved_agent)

    emit(on_message, resolved_agent, session.session_id, :turn_started, %{})

    case Client.run_turn(session, prompt, timeout_ms: timeout_ms, on_event: backend_on_event(on_message, session)) do
      {:ok, result} ->
        emit(on_message, resolved_agent, session.session_id, :turn_completed, result)
        {:ok, result}

      {:error, {:omnigent_incomplete, "user_interrupt"} = reason} = error ->
        emit(on_message, resolved_agent, session.session_id, :turn_cancelled, %{reason: reason})
        error

      {:error, reason} = error ->
        emit(on_message, resolved_agent, session.session_id, :turn_failed, %{reason: reason})
        error
    end
  end

  @spec stop_session(map()) :: :ok
  def stop_session(session) when is_map(session) do
    _ = Client.stop_session(session)
    :ok
  end

  defp backend_on_event(on_message, session) do
    fn
      %{"type" => "session.created"} = event ->
        emit(on_message, session.resolved_agent, session.session_id, :child_session_observed, event)

      %{"type" => type} when type in ["response.completed", "response.failed", "response.incomplete"] ->
        :ok

      event when is_map(event) ->
        emit(on_message, session.resolved_agent, session.session_id, :notification, event)

      _event ->
        :ok
    end
  end

  defp emit(on_message, resolved_agent, session_id, event, payload) when is_function(on_message, 1) do
    on_message.(%{
      event: event,
      timestamp: DateTime.utc_now(),
      agent_id: agent_id(resolved_agent),
      agent_kind: agent_kind(resolved_agent),
      session_id: session_id,
      payload: payload
    })
  end

  defp expand_host_workspace(host, workspace) when is_map(host) and is_binary(workspace) do
    Map.update(host, "workspace", workspace, fn value ->
      value
      |> to_string()
      |> String.replace("{{workspace}}", workspace)
    end)
  end

  defp expand_host_workspace(host, _workspace), do: host

  defp agent_id(resolved_agent), do: Map.get(resolved_agent, :id) || Map.get(resolved_agent, "id")
  defp agent_kind(resolved_agent), do: Map.get(resolved_agent, :kind) || Map.get(resolved_agent, "kind")
  defp agent_config(resolved_agent), do: Map.get(resolved_agent, :config) || Map.get(resolved_agent, "config") || %{}
  defp default_on_message(_message), do: :ok
end
