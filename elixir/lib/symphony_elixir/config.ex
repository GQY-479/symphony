defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @supported_agent_kinds ["codex_app_server", "cli_run", "acp_stdio", "omnigent_http"]
  @acp_permission_policies ["reject", "fail", "allow"]

  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        Schema.parse(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings() do
      with {:ok, turn_sandbox_policy} <-
             Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts) do
        {:ok,
         %{
           approval_policy: settings.codex.approval_policy,
           thread_sandbox: settings.codex.thread_sandbox,
           turn_sandbox_policy: turn_sandbox_policy
         }}
      end
    end
  end

  defp validate_semantics(settings) do
    with :ok <- validate_agents(settings),
         :ok <- validate_routing(settings),
         :ok <- validate_orchestration(settings) do
      cond do
        is_nil(settings.tracker.kind) ->
          {:error, :missing_tracker_kind}

        settings.tracker.kind not in ["linear", "memory"] ->
          {:error, {:unsupported_tracker_kind, settings.tracker.kind}}

        settings.tracker.kind == "linear" and not is_binary(settings.tracker.api_key) ->
          {:error, :missing_linear_api_token}

        settings.tracker.kind == "linear" and not is_binary(settings.tracker.project_slug) ->
          {:error, :missing_linear_project_slug}

        true ->
          :ok
      end
    end
  end

  defp validate_orchestration(settings) do
    orchestration = settings.orchestration

    if orchestration.enabled != true do
      :ok
    else
      agent_ids = MapSet.new(Map.keys(settings.agents || %{}))

      with :ok <-
             validate_orchestration_agent(
               agent_ids,
               "orchestration.planner_agent",
               orchestration.planner_agent
             ),
           :ok <-
             validate_orchestration_agent(
               agent_ids,
               "orchestration.reviewer_agent",
               orchestration.reviewer_agent
             ) do
        validate_non_blank_string("orchestration.artifact_dir", orchestration.artifact_dir)
      end
    end
  end

  defp validate_agents(settings) do
    Enum.reduce_while(settings.agents || %{}, :ok, fn {agent_id, agent}, :ok ->
      case validate_agent(agent_id, agent, settings.agents_configured) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_agent(agent_id, agent, agents_configured) when is_map(agent) do
    with :ok <- validate_agent_id(agent_id),
         :ok <- validate_agent_kind(agent_id, Map.get(agent, "kind")),
         :ok <- validate_agent_command(agent_id, Map.get(agent, "command"), agents_configured),
         :ok <- validate_agent_integer(agent_id, agent, "timeout_ms", greater_than: 0),
         :ok <- validate_agent_integer(agent_id, agent, "read_timeout_ms", greater_than: 0),
         :ok <- validate_agent_integer(agent_id, agent, "close_timeout_ms", greater_than: 0),
         :ok <- validate_agent_integer(agent_id, agent, "stall_timeout_ms", greater_than_or_equal_to: 0),
         :ok <- validate_agent_integer(agent_id, agent, "max_output_bytes", greater_than: 0) do
      validate_kind_specific_agent_config(agent_id, agent)
    end
  end

  defp validate_agent(agent_id, _agent, _agents_configured) do
    invalid_config("agents.#{agent_id} must be a map")
  end

  defp validate_agent_id(agent_id) when is_binary(agent_id) do
    if String.trim(agent_id) == "" do
      invalid_config("agents contains a blank agent id")
    else
      :ok
    end
  end

  defp validate_agent_kind(_agent_id, kind) when kind in @supported_agent_kinds, do: :ok

  defp validate_agent_kind(agent_id, kind) do
    invalid_config("agents.#{agent_id}.kind must be one of #{Enum.join(@supported_agent_kinds, ", ")}, got #{inspect(kind)}")
  end

  defp validate_agent_command("codex", command, false) when is_binary(command) do
    if command == "" do
      invalid_config("agents.codex.command must be a non-empty string")
    else
      :ok
    end
  end

  defp validate_agent_command(agent_id, command, _agents_configured) when is_binary(command) do
    if String.trim(command) == "" do
      invalid_config("agents.#{agent_id}.command must be a non-empty string")
    else
      :ok
    end
  end

  defp validate_agent_command(agent_id, command, _agents_configured) do
    invalid_config("agents.#{agent_id}.command must be a non-empty string, got #{inspect(command)}")
  end

  defp validate_agent_integer(agent_id, agent, field, opts) do
    case Map.fetch(agent, field) do
      :error ->
        :ok

      {:ok, value} when is_integer(value) ->
        validate_integer_bound(agent_id, field, value, opts)

      {:ok, value} ->
        invalid_config("agents.#{agent_id}.#{field} must be an integer, got #{inspect(value)}")
    end
  end

  defp validate_integer_bound(agent_id, field, value, opts) do
    cond do
      min = Keyword.get(opts, :greater_than) ->
        if value > min,
          do: :ok,
          else: invalid_config("agents.#{agent_id}.#{field} must be an integer greater than #{min}")

      min = Keyword.get(opts, :greater_than_or_equal_to) ->
        if value >= min,
          do: :ok,
          else: invalid_config("agents.#{agent_id}.#{field} must be an integer greater than or equal to #{min}")
    end
  end

  defp validate_kind_specific_agent_config(agent_id, %{"kind" => "codex_app_server"} = agent) do
    with :ok <- validate_optional_string_or_map(agent_id, agent, "approval_policy"),
         :ok <- validate_optional_string(agent_id, agent, "thread_sandbox") do
      validate_optional_map(agent_id, agent, "turn_sandbox_policy")
    end
  end

  defp validate_kind_specific_agent_config(agent_id, %{"kind" => "acp_stdio"} = agent) do
    with :ok <- validate_optional_string_list(agent_id, agent, "args"),
         :ok <- validate_optional_string_map(agent_id, agent, "config_options"),
         :ok <- validate_optional_acp_mcp_config(agent_id, agent) do
      validate_optional_enum(agent_id, agent, "permission_policy", @acp_permission_policies)
    end
  end

  defp validate_kind_specific_agent_config(agent_id, %{"kind" => "omnigent_http"} = agent) do
    with :ok <- validate_required_non_empty_string(agent_id, agent, "base_url"),
         :ok <- validate_optional_map(agent_id, agent, "host"),
         {:ok, omnigent_agent} <- validate_required_map(agent_id, agent, "agent"),
         :ok <- validate_agent_integer(agent_id, agent, "stream_timeout_ms", greater_than: 0),
         :ok <- validate_agent_integer(agent_id, agent, "runner_ready_timeout_ms", greater_than_or_equal_to: 0),
         :ok <- validate_agent_integer(agent_id, agent, "runner_ready_poll_ms", greater_than: 0),
         :ok <- validate_omnigent_host(agent_id, Map.get(agent, "host") || %{}),
         :ok <- validate_omnigent_agent(agent_id, omnigent_agent) do
      :ok
    end
  end

  defp validate_kind_specific_agent_config(_agent_id, _agent), do: :ok

  defp validate_required_non_empty_string(agent_id, agent, field) do
    case Map.fetch(agent, field) do
      {:ok, value} when is_binary(value) ->
        if String.trim(value) == "" do
          invalid_config("agents.#{agent_id}.#{field} must be a non-empty string")
        else
          :ok
        end

      {:ok, value} ->
        invalid_config("agents.#{agent_id}.#{field} must be a non-empty string, got #{inspect(value)}")

      :error ->
        invalid_config("agents.#{agent_id}.#{field} must be a non-empty string")
    end
  end

  defp validate_omnigent_host(agent_id, host) when is_map(host) do
    mode = Map.get(host, "mode", "external")

    cond do
      mode != "external" ->
        invalid_config("agents.#{agent_id}.host.mode must be external")

      :ok != validate_optional_non_empty_string(host, "host_id") ->
        invalid_config("agents.#{agent_id}.host.host_id must be a non-empty string")

      :ok != validate_optional_non_empty_string(host, "workspace") ->
        invalid_config("agents.#{agent_id}.host.workspace must be a non-empty string")

      true ->
        :ok
    end
  end

  defp validate_omnigent_host(agent_id, host) do
    invalid_config("agents.#{agent_id}.host must be a map, got #{inspect(host)}")
  end

  defp validate_required_map(agent_id, agent, field) do
    case Map.fetch(agent, field) do
      {:ok, value} when is_map(value) ->
        {:ok, value}

      {:ok, value} ->
        invalid_config("agents.#{agent_id}.#{field} must be a map, got #{inspect(value)}")

      :error ->
        invalid_config("agents.#{agent_id}.#{field} must be a map")
    end
  end

  defp validate_optional_non_empty_string(map, field) when is_map(map) do
    case Map.fetch(map, field) do
      :error ->
        :ok

      {:ok, value} when is_binary(value) ->
        if String.trim(value) == "" do
          :blank
        else
          :ok
        end

      {:ok, value} ->
        invalid_config("agents.omnigent.host.#{field} must be a string, got #{inspect(value)}")
    end
  end

  defp validate_omnigent_agent(agent_id, %{"type" => "agent_id"} = agent) do
    case Map.get(agent, "id") do
      id when is_binary(id) ->
        if String.trim(id) == "" do
          invalid_config("agents.#{agent_id}.agent.id must be a non-empty string")
        else
          :ok
        end

      _ ->
        invalid_config("agents.#{agent_id}.agent.id must be a non-empty string")
    end
  end

  defp validate_omnigent_agent(agent_id, %{"type" => "bundle_path"} = agent) do
    case Map.get(agent, "path") do
      path when is_binary(path) ->
        if String.trim(path) == "" do
          invalid_config("agents.#{agent_id}.agent.path must be a non-empty string")
        else
          :ok
        end

      _ ->
        invalid_config("agents.#{agent_id}.agent.path must be a non-empty string")
    end
  end

  defp validate_omnigent_agent(agent_id, %{"type" => type}) do
    invalid_config("agents.#{agent_id}.agent.type must be one of agent_id, bundle_path, got #{inspect(type)}")
  end

  defp validate_omnigent_agent(agent_id, agent) when is_map(agent) do
    invalid_config("agents.#{agent_id}.agent.type must be one of agent_id, bundle_path")
  end

  defp validate_omnigent_agent(agent_id, agent) do
    invalid_config("agents.#{agent_id}.agent must be a map, got #{inspect(agent)}")
  end

  defp validate_optional_string_or_map(agent_id, agent, field) do
    case Map.fetch(agent, field) do
      :error -> :ok
      {:ok, value} when is_binary(value) or is_map(value) -> :ok
      {:ok, value} -> invalid_config("agents.#{agent_id}.#{field} must be a string or map, got #{inspect(value)}")
    end
  end

  defp validate_optional_string(agent_id, agent, field) do
    case Map.fetch(agent, field) do
      :error -> :ok
      {:ok, value} when is_binary(value) -> :ok
      {:ok, value} -> invalid_config("agents.#{agent_id}.#{field} must be a string, got #{inspect(value)}")
    end
  end

  defp validate_optional_map(agent_id, agent, field) do
    case Map.fetch(agent, field) do
      :error -> :ok
      {:ok, nil} -> :ok
      {:ok, value} when is_map(value) -> :ok
      {:ok, value} -> invalid_config("agents.#{agent_id}.#{field} must be a map, got #{inspect(value)}")
    end
  end

  defp validate_optional_string_list(agent_id, agent, field) do
    case Map.fetch(agent, field) do
      :error ->
        :ok

      {:ok, value} when is_list(value) ->
        if Enum.all?(value, &is_binary/1) do
          :ok
        else
          invalid_config("agents.#{agent_id}.#{field} must be a list of strings")
        end

      {:ok, value} ->
        invalid_config("agents.#{agent_id}.#{field} must be a list of strings, got #{inspect(value)}")
    end
  end

  defp validate_optional_string_map(agent_id, agent, field) do
    case Map.fetch(agent, field) do
      :error ->
        :ok

      {:ok, value} when is_map(value) ->
        if Enum.all?(value, fn {key, option_value} -> is_binary(key) and is_binary(option_value) end) do
          :ok
        else
          invalid_config("agents.#{agent_id}.#{field} must be a map of string keys to string values")
        end

      {:ok, value} ->
        invalid_config("agents.#{agent_id}.#{field} must be a map of string keys to string values, got #{inspect(value)}")
    end
  end

  defp validate_optional_acp_mcp_config(agent_id, agent) do
    case Map.fetch(agent, "mcp") do
      :error ->
        :ok

      {:ok, nil} ->
        :ok

      {:ok, mcp} when is_map(mcp) ->
        with :ok <- validate_optional_boolean(agent_id, mcp, "mcp.linear_tools"),
             :ok <- validate_nested_optional_string(agent_id, mcp, "mcp.url"),
             :ok <- validate_nested_optional_enum(agent_id, mcp, "mcp.type", ["http", "sse"]),
             :ok <- validate_nested_optional_list(agent_id, mcp, "mcp.headers") do
          validate_nested_optional_list(agent_id, mcp, "mcp.env")
        end

      {:ok, value} ->
        invalid_config("agents.#{agent_id}.mcp must be a map, got #{inspect(value)}")
    end
  end

  defp validate_optional_boolean(agent_id, config, field) do
    key = nested_field_key(field)

    case Map.fetch(config, key) do
      :error -> :ok
      {:ok, value} when is_boolean(value) -> :ok
      {:ok, value} -> invalid_config("agents.#{agent_id}.#{field} must be a boolean, got #{inspect(value)}")
    end
  end

  defp validate_nested_optional_string(agent_id, config, field) do
    key = nested_field_key(field)

    case Map.fetch(config, key) do
      :error -> :ok
      {:ok, value} when is_binary(value) -> :ok
      {:ok, value} -> invalid_config("agents.#{agent_id}.#{field} must be a string, got #{inspect(value)}")
    end
  end

  defp validate_nested_optional_list(agent_id, config, field) do
    key = nested_field_key(field)

    case Map.fetch(config, key) do
      :error -> :ok
      {:ok, value} when is_list(value) -> :ok
      {:ok, value} -> invalid_config("agents.#{agent_id}.#{field} must be a list, got #{inspect(value)}")
    end
  end

  defp validate_nested_optional_enum(agent_id, config, field, allowed) do
    key = nested_field_key(field)

    case Map.fetch(config, key) do
      :error ->
        :ok

      {:ok, value} ->
        if value in allowed do
          :ok
        else
          invalid_config("agents.#{agent_id}.#{field} must be one of #{Enum.join(allowed, ", ")}, got #{inspect(value)}")
        end
    end
  end

  defp nested_field_key(field), do: field |> String.split(".") |> List.last()

  defp validate_optional_enum(agent_id, agent, field, allowed) do
    case Map.fetch(agent, field) do
      :error ->
        :ok

      {:ok, value} ->
        if Enum.member?(allowed, value) do
          :ok
        else
          invalid_config("agents.#{agent_id}.#{field} must be one of #{Enum.join(allowed, ", ")}, got #{inspect(value)}")
        end
    end
  end

  defp validate_routing(settings) do
    agent_ids = MapSet.new(Map.keys(settings.agents || %{}))

    with :ok <- validate_route_target(agent_ids, "routing.default_agent", settings.routing.default_agent),
         :ok <- validate_route_targets(agent_ids, "routing.by_label", settings.routing.by_label) do
      validate_route_targets(agent_ids, "routing.by_assignee", settings.routing.by_assignee)
    end
  end

  defp validate_route_targets(agent_ids, field, routes) when is_map(routes) do
    Enum.reduce_while(routes, :ok, fn {key, target}, :ok ->
      field_with_key = "#{field}[#{key}]"

      with :ok <- validate_route_key(field_with_key, key),
           :ok <- validate_route_target(agent_ids, field_with_key, target) do
        {:cont, :ok}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_route_targets(_agent_ids, field, routes) do
    invalid_config("#{field} must be a map, got #{inspect(routes)}")
  end

  defp validate_route_key(field, key) when is_binary(key) do
    if String.trim(key) == "" do
      invalid_config("#{field} must not be blank")
    else
      :ok
    end
  end

  defp validate_route_key(_field, _key), do: :ok

  defp validate_route_target(agent_ids, field, target) do
    cond do
      not is_binary(target) or String.trim(target) == "" ->
        invalid_config("#{field} references blank agent")

      MapSet.member?(agent_ids, target) ->
        :ok

      true ->
        invalid_config("#{field} references unknown agent #{inspect(target)}")
    end
  end

  defp validate_orchestration_agent(agent_ids, field, agent_id) do
    cond do
      not is_binary(agent_id) or String.trim(agent_id) == "" ->
        invalid_config("#{field} references blank agent")

      MapSet.member?(agent_ids, agent_id) ->
        :ok

      true ->
        invalid_config("#{field} references unknown agent #{inspect(agent_id)}")
    end
  end

  defp validate_non_blank_string(field, value) when is_binary(value) do
    if String.trim(value) == "" do
      invalid_config("#{field} must be a non-empty string")
    else
      :ok
    end
  end

  defp validate_non_blank_string(field, value) do
    invalid_config("#{field} must be a non-empty string, got #{inspect(value)}")
  end

  defp invalid_config(message), do: {:error, {:invalid_workflow_config, message}}

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end
end
