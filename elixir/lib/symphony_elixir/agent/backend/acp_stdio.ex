defmodule SymphonyElixir.Agent.Backend.AcpStdio do
  @moduledoc """
  Agent backend that runs an ACP-compatible agent over stdio.
  """

  @behaviour SymphonyElixir.Agent.Backend

  @impl true
  def run_issue(_workspace, _issue, _prompt, _resolved_agent, _opts) do
    {:error, :acp_stdio_session_backend_only}
  end

  @spec start_session(Path.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_session(_workspace, _resolved_agent, _opts) do
    {:error, :acp_stdio_not_implemented}
  end

  @spec run_turn(map(), Path.t(), map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(_session, _workspace, _issue, _prompt, _opts) do
    {:error, :acp_stdio_not_implemented}
  end

  @spec stop_session(map()) :: :ok
  def stop_session(_session), do: :ok
end
