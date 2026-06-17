defmodule SymphonyElixir.Workflow.Controller do
  @moduledoc """
  Workflow 规划结果物化与派生 issue 编排。
  """

  alias SymphonyElixir.{Tracker}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Workflow.{Artifacts, Registry}

  @spec handle_planning_completion(Issue.t(), Path.t()) :: {:ok, map()} | {:error, term()}
  def handle_planning_completion(%Issue{} = root_issue, workspace) when is_binary(workspace) do
    with {:ok, plan} <- Artifacts.load_workflow_plan(workspace) do
      root_registry = Registry.new_root(root_issue)

      case materialize_plan(root_registry, root_issue, plan) do
        {:ok, registry} ->
          :ok = Registry.save!(registry)
          maybe_comment_root(root_issue, plan, registry)
          {:ok, registry}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def handle_planning_completion(_issue, _workspace), do: {:error, :invalid_arguments}

  defp materialize_plan(registry, root_issue, %{"kind" => "direct_execution"} = plan) do
    registry =
      registry
      |> Registry.put_node("root", %{
        "issue_id" => root_issue.id,
        "issue_identifier" => root_issue.identifier,
        "node_key" => "root",
        "task_type" => "direct_execution",
        "workflow_semantics" => "executable",
        "status" => "ready",
        "summary" => plan["summary"]
      })
      |> Map.put("status", "planning_complete")

    {:ok, registry}
  end

  defp materialize_plan(registry, root_issue, %{"kind" => "issue_graph", "nodes" => nodes, "edges" => edges} = plan) do
    dependency_map = dependency_map(edges)
    handoff_map = handoff_map(edges)

    with {:ok, registry} <- create_derived_nodes(registry, root_issue, nodes, dependency_map, handoff_map, plan),
         {:ok, registry} <- attach_edges(registry, edges),
         registry <- Map.put(registry, "status", "planning_complete") do
      {:ok, registry}
    end
  end

  defp materialize_plan(registry, _root_issue, _plan) do
    {:ok, Map.put(registry, "status", "planning_complete")}
  end

  defp create_derived_nodes(registry, root_issue, nodes, dependency_map, handoff_map, plan) do
    Enum.reduce_while(nodes, {:ok, registry}, fn node, {:ok, acc} ->
      dependencies = Map.get(dependency_map, node["node_key"], node["dependencies"] || [])
      handoff = Map.get(handoff_map, node["node_key"], node["handoff"] || node["handoff_summary"])

      case Tracker.create_issue(%{
             title: node["title"],
             description: node_description(root_issue, node, dependencies, handoff, plan),
             state: "Todo",
             assignee_id: root_issue.assignee_id
           }) do
        {:ok, %Issue{} = issue} ->
          readiness = node_readiness(dependencies)

          updated_registry =
            Registry.put_node(acc, node["node_key"], %{
              "node_key" => node["node_key"],
              "issue_id" => issue.id,
              "issue_identifier" => issue.identifier,
              "task_type" => node["task_type"],
              "instructions" => node["instructions"],
              "dependencies" => dependencies,
              "handoff" => handoff,
              "handoff_summary" => handoff,
              "evidence_expectations" => node["evidence_expectations"] || [],
              "workflow_semantics" => "executable",
              "status" => readiness,
              "title" => node["title"]
            })

          {:cont, {:ok, updated_registry}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp attach_edges(registry, edges) do
    registry =
      Enum.reduce(edges, registry, fn edge, acc ->
        Registry.add_edge(acc, edge)
      end)

    {:ok, registry}
  end

  defp maybe_comment_root(root_issue, %{"kind" => "issue_graph"} = plan, registry) do
    Tracker.create_comment(root_issue.id, render_plan_comment(root_issue, plan, registry))
    :ok
  end

  defp maybe_comment_root(_root_issue, _plan, _registry), do: :ok

  defp node_description(root_issue, node, dependencies, handoff, plan) do
    """
    Root issue: #{root_issue.identifier}
    Root issue id: #{root_issue.id}
    Plan kind: #{plan["kind"]}
    Node id: #{node["node_key"]}
    Task type: #{node["task_type"]}

    Instructions:
    #{node["instructions"] || node["goal"] || ""}

    Dependencies:
    #{format_list(dependencies)}

    Handoff:
    #{handoff || ""}

    Evidence expectations:
    #{format_list(node["evidence_expectations"] || [])}
    """
    |> String.trim()
  end

  defp render_plan_comment(root_issue, plan, registry) do
    derived_lines =
      registry["nodes"]
      |> Enum.reject(fn {node_key, _node} -> node_key == "root" end)
      |> Enum.map(fn {node_key, node} ->
        "- #{node_key}: #{node["issue_identifier"]} #{node["task_type"]} #{node["status"]}"
      end)
      |> Enum.join("\n")

    """
    ## 规划摘要

    Root issue: #{root_issue.identifier}
    Root issue id: #{root_issue.id}
    Plan kind: #{plan["kind"]}
    Summary: #{plan["summary"]}

    Derived issues:
    #{derived_lines}
    """
    |> String.trim()
  end

  defp node_readiness(dependencies) do
    if dependency_list(dependencies) == [] do
      "ready"
    else
      "waiting"
    end
  end

  defp dependency_list(dependencies) do
    dependencies
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
  end

  defp dependency_map(edges) do
    Enum.reduce(edges, %{}, fn edge, acc ->
      dependency =
        edge["from"] ||
          edge[:from] ||
          edge["from_node"] ||
          edge[:from_node]

      dependent =
        edge["to"] ||
          edge[:to] ||
          edge["to_node"] ||
          edge[:to_node]

      if is_binary(dependency) and is_binary(dependent) do
        Map.update(acc, dependent, [dependency], fn existing -> Enum.uniq(existing ++ [dependency]) end)
      else
        acc
      end
    end)
  end

  defp handoff_map(edges) do
    Enum.reduce(edges, %{}, fn edge, acc ->
      dependent =
        edge["to"] ||
          edge[:to] ||
          edge["to_node"] ||
          edge[:to_node]

      handoff =
        edge["handoff_summary"] ||
          edge[:handoff_summary] ||
          edge["handoff"] ||
          edge[:handoff]

      if is_binary(dependent) and is_binary(handoff) and handoff != "" do
        Map.put(acc, dependent, handoff)
      else
        acc
      end
    end)
  end

  defp format_list(values) when is_list(values) and values != [] do
    Enum.map_join(values, "\n", &"- #{&1}")
  end

  defp format_list([]), do: "-"
  defp format_list(value) when is_binary(value), do: value
  defp format_list(_value), do: "-"
end
