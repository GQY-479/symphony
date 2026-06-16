defmodule SymphonyElixir.Agent.Backend.OmnigentHttp do
  @moduledoc false

  @behaviour SymphonyElixir.Agent.Backend

  @impl true
  def run_issue(_workspace, _issue, _prompt, _resolved_agent, _opts),
    do: {:error, :omnigent_http_session_backend_only}
end
