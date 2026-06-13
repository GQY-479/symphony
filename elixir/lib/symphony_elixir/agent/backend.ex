defmodule SymphonyElixir.Agent.Backend do
  @moduledoc """
  Behaviour and dispatcher for agent execution backends.
  """

  @type resolved_agent :: %{
          id: String.t(),
          kind: String.t(),
          config: map()
        }

  @callback run_issue(
              workspace :: Path.t(),
              issue :: map(),
              prompt :: String.t(),
              resolved_agent :: resolved_agent(),
              opts :: keyword()
            ) :: {:ok, map()} | {:error, term()}

  @spec module_for(String.t()) :: module()
  def module_for("codex_app_server"), do: SymphonyElixir.Agent.Backend.CodexAppServer
  def module_for("cli_run"), do: SymphonyElixir.Agent.Backend.CliRun
  def module_for("acp_stdio"), do: SymphonyElixir.Agent.Backend.AcpStdio

  def module_for(kind) do
    raise ArgumentError, "unknown agent backend kind: #{inspect(kind)}"
  end
end
