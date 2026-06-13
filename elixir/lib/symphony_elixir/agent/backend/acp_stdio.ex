defmodule SymphonyElixir.Agent.Backend.AcpStdio do
  @moduledoc """
  Agent backend that runs an ACP-compatible agent over stdio.
  """

  @behaviour SymphonyElixir.Agent.Backend

  alias SymphonyElixir.Agent.AcpStdio.Client

  @default_timeout_ms 3_600_000

  @impl true
  def run_issue(_workspace, _issue, _prompt, _resolved_agent, _opts) do
    {:error, :acp_stdio_session_backend_only}
  end

  @spec start_session(Path.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_session(workspace, resolved_agent, opts) do
    config = agent_config(resolved_agent)
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    client_config = %{
      command: Map.get(config, "command"),
      args: build_args(config, workspace),
      env: Map.get(config, "env", []),
      permission_policy: Map.get(config, "permission_policy", "reject"),
      timeout_ms: Map.get(config, "read_timeout_ms", Map.get(config, "timeout_ms", 5_000))
    }

    case Client.start_session(workspace, client_config, annotated_on_message(on_message, resolved_agent)) do
      {:ok, session} ->
        {:ok,
         session
         |> Map.put(:resolved_agent, resolved_agent)
         |> Map.put(:timeout_ms, Map.get(config, "timeout_ms", @default_timeout_ms))}

      other ->
        other
    end
  end

  @spec run_turn(map(), Path.t(), map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, _workspace, _issue, prompt, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, Map.get(session, :timeout_ms, @default_timeout_ms))
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    turn_session = %{session | on_event: annotated_on_message(on_message, session.resolved_agent)}

    case Client.prompt(turn_session, prompt, timeout_ms: timeout_ms) do
      {:ok, result} ->
        emit_turn_completed(turn_session, result)
        {:ok, %{session_id: turn_session.session_id, stop_reason: Map.get(result, "stop_reason"), raw: result}}

      {:error, :acp_timeout} = error ->
        Client.cancel(turn_session)
        error

      other ->
        other
    end
  end

  @spec stop_session(map()) :: :ok
  def stop_session(session) when is_map(session), do: Client.stop_session(session)

  defp build_args(config, workspace) do
    config
    |> Map.get("args", [])
    |> Enum.map(&String.replace(to_string(&1), "{{workspace}}", workspace))
  end

  defp annotated_on_message(on_message, resolved_agent) when is_function(on_message, 1) do
    fn message ->
      message
      |> Map.put(:agent_id, agent_id(resolved_agent))
      |> Map.put(:agent_kind, agent_kind(resolved_agent))
      |> Map.put_new(:timestamp, DateTime.utc_now())
      |> on_message.()
    end
  end

  defp emit_turn_completed(session, result) do
    session.on_event.(%{
      event: :turn_completed,
      timestamp: DateTime.utc_now(),
      agent_id: agent_id(session.resolved_agent),
      agent_kind: agent_kind(session.resolved_agent),
      session_id: session.session_id,
      codex_app_server_pid: Map.get(session, :codex_app_server_pid),
      payload: result
    })
  end

  defp agent_id(resolved_agent), do: Map.get(resolved_agent, :id) || Map.get(resolved_agent, "id")
  defp agent_kind(resolved_agent), do: Map.get(resolved_agent, :kind) || Map.get(resolved_agent, "kind")
  defp agent_config(resolved_agent), do: Map.get(resolved_agent, :config) || Map.get(resolved_agent, "config") || %{}
  defp default_on_message(_message), do: :ok
end
