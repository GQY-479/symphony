defmodule SymphonyElixir.Agent.Router do
  @moduledoc """
  Resolves which configured agent should handle an issue.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue

  @type resolved_agent :: %{
          id: String.t(),
          kind: String.t(),
          config: map()
        }

  @spec resolve(Issue.t(), Schema.t()) :: {:ok, resolved_agent()} | {:error, term()}
  def resolve(%Issue{} = issue, %Schema{} = config) do
    issue
    |> selected_agent_id(config)
    |> resolve_agent(config)
  end

  defp selected_agent_id(issue, config) do
    label_route(issue, config) ||
      assignee_route(issue, config) ||
      default_agent(config) ||
      "codex"
  end

  defp label_route(%Issue{} = issue, %Schema{} = config) do
    routes = config.routing.by_label |> route_map() |> normalize_label_route_map()

    issue
    |> issue_labels()
    |> Enum.find_value(fn label ->
      Map.get(routes, normalize_label(label))
    end)
  end

  defp assignee_route(%Issue{assignee_id: assignee_id}, %Schema{} = config) when is_binary(assignee_id) do
    Map.get(route_map(config.routing.by_assignee), assignee_id)
  end

  defp assignee_route(%Issue{}, %Schema{}), do: nil

  defp default_agent(%Schema{} = config) do
    case config.routing.default_agent do
      agent_id when is_binary(agent_id) and agent_id != "" -> agent_id
      _ -> nil
    end
  end

  defp resolve_agent(agent_id, %Schema{} = config) do
    case Map.fetch(config.agents || %{}, agent_id) do
      {:ok, %{"enabled" => false}} ->
        {:error, {:agent_disabled, agent_id}}

      {:ok, agent_config} when is_map(agent_config) ->
        {:ok, %{id: agent_id, kind: Map.get(agent_config, "kind"), config: agent_config}}

      :error ->
        {:error, {:unknown_agent, agent_id}}
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
