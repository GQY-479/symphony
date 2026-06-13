defmodule SymphonyElixir.Agent.Backend.CodexAppServer do
  @moduledoc """
  Agent backend that runs Codex through the app-server protocol.
  """

  @behaviour SymphonyElixir.Agent.Backend

  alias SymphonyElixir.Codex.AppServer

  @impl true
  def run_issue(workspace, issue, prompt, resolved_agent, opts) do
    app_server_module = Keyword.get(opts, :app_server_module, AppServer)

    app_server_module.run(
      workspace,
      prompt,
      issue,
      app_server_opts(opts, resolved_agent)
    )
  end

  @spec start_session(Path.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_session(workspace, resolved_agent, opts) do
    app_server_module = Keyword.get(opts, :app_server_module, AppServer)

    case app_server_module.start_session(workspace, app_server_opts(opts, resolved_agent)) do
      {:ok, session} when is_map(session) ->
        {:ok,
         session
         |> Map.put(:app_server_module, app_server_module)
         |> Map.put(:resolved_agent, resolved_agent)}

      other ->
        other
    end
  end

  @spec run_turn(map(), Path.t(), map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, _workspace, issue, prompt, opts) do
    resolved_agent = Map.fetch!(session, :resolved_agent)
    app_server_module = Map.get(session, :app_server_module, AppServer)

    app_server_module.run_turn(
      session,
      prompt,
      issue,
      app_server_opts(opts, resolved_agent)
    )
  end

  @spec stop_session(map()) :: :ok
  def stop_session(session) when is_map(session) do
    app_server_module = Map.get(session, :app_server_module, AppServer)
    app_server_module.stop_session(session)
  end

  defp app_server_opts(opts, resolved_agent) do
    opts
    |> Keyword.delete(:app_server_module)
    |> Keyword.put(:agent_config, agent_config(resolved_agent))
    |> Keyword.update(:on_message, annotated_on_message(&default_on_message/1, resolved_agent), fn on_message ->
      annotated_on_message(on_message, resolved_agent)
    end)
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

  defp agent_id(resolved_agent), do: Map.get(resolved_agent, :id) || Map.get(resolved_agent, "id")
  defp agent_kind(resolved_agent), do: Map.get(resolved_agent, :kind) || Map.get(resolved_agent, "kind")
  defp agent_config(resolved_agent), do: Map.get(resolved_agent, :config) || Map.get(resolved_agent, "config") || %{}
  defp default_on_message(_message), do: :ok
end
