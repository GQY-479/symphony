defmodule SymphonyElixir.PreflightHealthCheck do
  @moduledoc """
  Preflight health check for local live orchestration runs.

  Validates Linear auth, workflow parsing, agent availability, and workspace
  writability before execution begins.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Client, Workflow}

  @type check_result :: {:ok, [String.t()]} | {:error, [String.t()]}

  @doc """
  Run all preflight health checks and return the result.

  Returns `{:ok, warnings}` on success or `{:error, errors}` on failure.
  Each error message is actionable and does not expose secrets.
  """
  @spec run() :: check_result()
  def run do
    checks = [
      &check_linear_auth/0,
      &check_workflow_parsing/0,
      &check_tracker_project_lookup/0,
      &check_agent_commands/0,
      &check_workspace_root/0
    ]

    results =
      Enum.map(checks, fn check ->
        try do
          check.()
        rescue
          e -> {:error, ["#{check_name(check)} failed: #{Exception.message(e)}"]}
        end
      end)

    all_warnings =
      results
      |> Enum.flat_map(fn
        {:ok, warnings} -> warnings
        _ -> []
      end)

    all_errors =
      results
      |> Enum.flat_map(fn
        {:error, errors} -> errors
        _ -> []
      end)

    case all_errors do
      [] -> {:ok, all_warnings}
      errors -> {:error, errors}
    end
  end

  @doc """
  Run preflight checks and print results to stderr.
  Returns `:ok` on success, `{:error, errors}` on failure.
  Does NOT call System.halt — the caller is responsible for halting.
  """
  @spec run!() :: :ok | {:error, [String.t()]}
  def run! do
    case run() do
      {:ok, warnings} ->
        warnings |> Enum.each(&IO.puts(:stderr, "WARNING: #{&1}"))
        IO.puts(:stderr, "Preflight health check passed")
        :ok

      {:error, errors} ->
        errors |> Enum.each(&IO.puts(:stderr, "ERROR: #{&1}"))
        IO.puts(:stderr, "Preflight health check failed")
        {:error, errors}
    end
  end

  @spec check_linear_auth() :: {:ok, [String.t()]} | {:error, [String.t()]}
  defp check_linear_auth do
    case Config.settings!() do
      %{tracker: %{kind: "linear", api_key: token}} when is_binary(token) and token != "" ->
        case Client.graphql("{ viewer { id } }", %{}) do
          {:ok, _body} ->
            {:ok, ["Linear auth verified"]}

          {:error, :missing_linear_api_token} ->
            {:error, ["Linear API token is missing or invalid"]}

          {:error, reason} ->
            {:error, ["Linear auth check failed: #{inspect(reason)}"]}
        end

      %{tracker: %{kind: "linear"}} ->
        {:error, ["Linear API token is not configured in WORKFLOW.md"]}

      %{tracker: %{kind: "memory"}} ->
        {:ok, ["Using memory tracker (no Linear auth required)"]}

      _ ->
        {:error, ["Tracker configuration is missing or invalid"]}
    end
  rescue
    e -> {:error, ["Linear auth check raised: #{Exception.message(e)}"]}
  end

  @spec check_workflow_parsing() :: {:ok, [String.t()]} | {:error, [String.t()]}
  defp check_workflow_parsing do
    case Workflow.load() do
      {:ok, %{config: config}} when is_map(config) ->
        warnings = validate_workflow_warnings(config)
        {:ok, warnings}

      {:error, :workflow_front_matter_not_a_map} ->
        {:error, ["WORKFLOW.md front matter must be a YAML map"]}

      {:error, {:missing_workflow_file, path, _reason}} ->
        {:error, ["WORKFLOW.md not found at #{path}"]}

      {:error, {:workflow_parse_error, reason}} ->
        {:error, ["WORKFLOW.md parse error: #{inspect(reason)}"]}

      {:error, reason} ->
        {:error, ["Workflow loading failed: #{inspect(reason)}"]}
    end
  end

  @spec check_tracker_project_lookup() :: {:ok, [String.t()]} | {:error, [String.t()]}
  defp check_tracker_project_lookup do
    case Config.validate!() do
      :ok ->
        {:ok, ["Tracker project configuration is valid"]}

      {:error, {:invalid_workflow_config, message}} ->
        {:error, ["Invalid workflow config: #{message}"]}

      {:error, :missing_linear_api_token} ->
        {:error, ["Linear API token is required for project lookup"]}

      {:error, :missing_linear_project_slug} ->
        {:error, ["Linear project slug is required"]}

      {:error, :missing_tracker_kind} ->
        {:error, ["Tracker kind is required"]}

      {:error, {:unsupported_tracker_kind, kind}} ->
        {:error, ["Unsupported tracker kind: #{inspect(kind)}"]}

      {:error, reason} ->
        {:error, ["Tracker validation failed: #{inspect(reason)}"]}
    end
  end

  @spec check_agent_commands() :: {:ok, [String.t()]} | {:error, [String.t()]}
  defp check_agent_commands do
    settings = Config.settings!()
    agents = settings.agents || %{}

    results =
      Enum.map(agents, fn {agent_id, agent} ->
        check_agent_command(agent_id, agent)
      end)

    warnings = Enum.flat_map(results, fn {_, warnings} -> warnings end)

    case warnings do
      [] ->
        {:ok, ["All configured agent commands are available"]}

      _ ->
        {:ok, warnings}
    end
  end

  @spec check_agent_command(String.t(), map()) :: {String.t(), [String.t()]}
  defp check_agent_command(agent_id, %{"kind" => "acp_stdio", "command" => command} = _agent)
       when is_binary(command) and command != "" do
    case System.cmd("sh", ["-c", "command -v #{command}"], stderr_to_stdout: true) do
      {_, 0} ->
        {agent_id, []}

      {_, _} ->
        {agent_id, ["Agent '#{agent_id}' command '#{command}' is not available (warning)"]}
    end
  rescue
    e -> {agent_id, ["Agent '#{agent_id}' command check failed: #{Exception.message(e)} (warning)"]}
  end

  defp check_agent_command(agent_id, %{"kind" => "codex_app_server", "command" => command} = _agent)
       when is_binary(command) and command != "" do
    base_command = command |> String.split(" ") |> List.first()

    case System.cmd("sh", ["-c", "command -v #{base_command}"], stderr_to_stdout: true) do
      {_, 0} ->
        {agent_id, []}

      {_, _} ->
        {agent_id, ["Agent '#{agent_id}' command '#{base_command}' is not available (warning)"]}
    end
  rescue
    e -> {agent_id, ["Agent '#{agent_id}' command check failed: #{Exception.message(e)} (warning)"]}
  end

  defp check_agent_command(agent_id, %{"kind" => "cli_run", "command" => command})
       when is_binary(command) and command != "" do
    case System.cmd("sh", ["-c", "command -v #{command}"], stderr_to_stdout: true) do
      {_, 0} ->
        {agent_id, []}

      {_, _} ->
        {agent_id, ["Agent '#{agent_id}' command '#{command}' is not available (warning)"]}
    end
  rescue
    e -> {agent_id, ["Agent '#{agent_id}' command check failed: #{Exception.message(e)} (warning)"]}
  end

  defp check_agent_command(agent_id, %{"kind" => "omnigent_http"} = _agent) do
    {agent_id, []}
  end

  defp check_agent_command(agent_id, agent) do
    {agent_id, ["Agent '#{agent_id}' has unknown kind: #{inspect(Map.get(agent, "kind"))} (warning)"]}
  end

  @spec check_workspace_root() :: {:ok, [String.t()]} | {:error, [String.t()]}
  defp check_workspace_root do
    settings = Config.settings!()
    workspace_root = settings.workspace.root

    expanded_root = Path.expand(workspace_root)
    parent_dir = Path.dirname(expanded_root)

    cond do
      not File.exists?(parent_dir) ->
        case File.mkdir_p(parent_dir) do
          :ok ->
            check_workspace_writeable(expanded_root)

          {:error, reason} ->
            {:error, ["Cannot create workspace root parent directory '#{parent_dir}': #{inspect(reason)}"]}
        end

      not File.dir?(parent_dir) ->
        {:error, ["Workspace root parent '#{parent_dir}' exists but is not a directory"]}

      true ->
        check_workspace_writeable(expanded_root)
    end
  rescue
    e -> {:error, ["Workspace root check failed: #{Exception.message(e)}"]}
  end

  defp check_workspace_writeable(dir) do
    # Ensure the directory exists
    case File.mkdir_p(dir) do
      :ok ->
        test_file = Path.join(dir, ".symphony-preflight-test-#{System.unique_integer([:positive])}")

        try do
          case File.write(test_file, "test") do
            :ok ->
              File.rm(test_file)
              {:ok, ["Workspace root '#{dir}' is writeable"]}

            {:error, reason} ->
              {:error, ["Cannot write to workspace root '#{dir}': #{inspect(reason)}"]}
          end
        rescue
          e -> {:error, ["Workspace write test failed: #{Exception.message(e)}"]}
        end

      {:error, reason} ->
        {:error, ["Cannot create workspace root '#{dir}': #{inspect(reason)}"]}
    end
  rescue
    e -> {:error, ["Workspace root check failed: #{Exception.message(e)}"]}
  end

  @spec validate_workflow_warnings(map()) :: [String.t()]
  defp validate_workflow_warnings(config) do
    warnings = []

    if Map.get(config, "tracker", %{}) |> Map.get("api_key") |> is_nil() do
      warnings ++ ["Linear API token is not set in WORKFLOW.md (will check LINEAR_API_KEY env var)"]
    else
      warnings
    end
  end

  @spec check_name(function()) :: String.t()
  defp check_name(check) when is_function(check, 0) do
    cond do
      check == (&check_linear_auth/0) -> "linear_auth"
      check == (&check_workflow_parsing/0) -> "workflow_parsing"
      check == (&check_tracker_project_lookup/0) -> "tracker_project_lookup"
      check == (&check_agent_commands/0) -> "agent_commands"
      check == (&check_workspace_root/0) -> "workspace_root"
      true -> "unknown"
    end
  end

  defp check_name(_), do: "unknown"
end
