defmodule SymphonyElixir.Agent.Router do
  @moduledoc """
  Resolves which configured agent should handle an issue.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue

  @type routing_reason :: %{
          source: :label | :assignee | :default | :metadata_override,
          matched: String.t() | nil
        }

  @type resolved_agent :: %{
          id: String.t(),
          kind: String.t(),
          config: map(),
          routing_reason: routing_reason()
        }

  @spec resolve(Issue.t(), Schema.t()) :: {:ok, resolved_agent()} | {:error, term()}
  def resolve(%Issue{} = issue, %Schema{} = config) do
    issue
    |> selected_agent_id_with_reason(config)
    |> resolve_agent(config)
  end

  defp selected_agent_id_with_reason(issue, config) do
    case label_route(issue, config) do
      {agent_id, matched} when is_binary(agent_id) ->
        {agent_id, %{source: :label, matched: matched}}

      nil ->
        case assignee_route(issue, config) do
          {agent_id, matched} when is_binary(agent_id) ->
            {agent_id, %{source: :assignee, matched: matched}}

          nil ->
            case default_agent(config) do
              agent_id when is_binary(agent_id) ->
                {agent_id, %{source: :default, matched: nil}}

              nil ->
                {nil, nil}
            end
        end
    end
  end

  defp label_route(%Issue{} = issue, %Schema{} = config) do
    routes = config.routing.by_label |> route_map() |> normalize_label_route_map()

    issue
    |> issue_labels()
    |> Enum.find_value(fn label ->
      case Map.get(routes, normalize_label(label)) do
        agent_id when is_binary(agent_id) -> {agent_id, normalize_label(label)}
        _ -> nil
      end
    end)
  end

  defp assignee_route(%Issue{assignee_id: assignee_id}, %Schema{} = config) when is_binary(assignee_id) do
    case Map.get(route_map(config.routing.by_assignee), assignee_id) do
      agent_id when is_binary(agent_id) -> {agent_id, assignee_id}
      _ -> nil
    end
  end

  defp assignee_route(%Issue{}, %Schema{}), do: nil

  defp default_agent(%Schema{} = config) do
    case config.routing.default_agent do
      agent_id when is_binary(agent_id) and agent_id != "" -> agent_id
      _ -> nil
    end
  end

  defp resolve_agent({agent_id, routing_reason}, %Schema{} = config) do
    case Map.fetch(config.agents || %{}, agent_id) do
      {:ok, %{"enabled" => false}} ->
        {:error, {:agent_disabled, agent_id}}

      {:ok, agent_config} when is_map(agent_config) ->
        {:ok, %{id: agent_id, kind: Map.get(agent_config, "kind"), config: agent_config, routing_reason: routing_reason}}

      :error ->
        {:error, {:unknown_agent, agent_id}}
    end
  end

  defp resolve_agent({nil, _routing_reason}, %Schema{} = config) do
    case default_agent(config) do
      agent_id when is_binary(agent_id) ->
        resolve_agent({agent_id, %{source: :default, matched: nil}}, config)

      nil ->
        {:error, {:unknown_agent, nil}}
    end
  end

  defp route_map(routes) when is_map(routes), do: routes
  defp route_map(_routes), do: %{}

  defp normalize_label_route_map(routes) when is_map(routes) do
    Enum.into(routes, %{}, fn {label, agent_id} ->
      {normalize_label(label), agent_id}
    end)
  end

  defp issue_labels(%Issue{} = issue) do
    issue
    |> Issue.label_names()
    |> List.wrap()
  end

  defp normalize_label(label) when is_binary(label) do
    label
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_label(label) do
    label
    |> to_string()
    |> normalize_label()
  end
end
