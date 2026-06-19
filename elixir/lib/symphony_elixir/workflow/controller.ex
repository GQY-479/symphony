defmodule SymphonyElixir.Workflow.Controller do
  @moduledoc """
  Workflow 规划结果物化与派生 issue 编排。
  """

  alias SymphonyElixir.{Config, Tracker}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Workflow.{Artifacts, Registry}
  alias SymphonyElixir.Workspace

  @ready_statuses MapSet.new(["ready"])
  @completed_statuses MapSet.new(["completed", "done", "passed"])

  @spec handle_planning_completion(Issue.t(), Path.t()) :: {:ok, map()} | {:error, term()}
  def handle_planning_completion(%Issue{} = root_issue, workspace) when is_binary(workspace) do
    with {:ok, plan} <- Artifacts.load_workflow_plan(workspace),
         :ok <- validate_materialization_plan(plan),
         {:ok, base_registry} <- load_or_new_registry(root_issue),
         {:ok, registry} <- materialize_plan(base_registry, root_issue, plan) do
      case Registry.save!(registry) do
        :ok ->
          case maybe_comment_root(root_issue, plan, registry) do
            :ok -> {:ok, registry}
            {:error, reason} -> {:error, reason}
          end
      end
    end
  end

  def handle_planning_completion(_issue, _workspace), do: {:error, :invalid_arguments}

  @spec handle_execution_completion(Issue.t(), Path.t()) :: {:ok, {:queue_review, map()}} | {:error, term()}
  def handle_execution_completion(%Issue{} = issue, workspace) when is_binary(workspace) do
    with {:ok, packet} <- Artifacts.load_completion_packet(workspace),
         :ok <- Tracker.create_comment(issue.id, render_completion_comment(issue, packet)),
         :ok <- maybe_store_completion_packet(issue, packet) do
      root_workspace =
        case Registry.load_by_issue_id(issue.id) do
          {:ok, registry, _node_key, _node} -> root_workspace_for_registry(registry)
          _ -> nil
        end

      {:ok,
       {:queue_review,
        %{
          workflow_phase: :review,
          workflow_root_issue_id: workflow_root_identifier_for_issue(issue),
          agent_id: Config.settings!().orchestration.reviewer_agent,
          max_turns: Config.settings!().orchestration.review_max_turns,
          workflow_context: %{
            "issue_id" => issue.id,
            "issue_identifier" => issue.identifier,
            "root_issue_identifier" => workflow_root_identifier_for_issue(issue),
            "root_workspace" => root_workspace,
            "completion_summary" => packet["summary"],
            "completion_outcome" => packet["outcome"],
            "evidence" => packet["evidence"] || []
          }
        }}}
    end
  end

  def handle_execution_completion(_issue, _workspace), do: {:error, :invalid_arguments}

  @spec handle_review_completion(Issue.t(), Path.t()) ::
          {:ok, {:pass, String.t()} | {:needs_human, String.t(), String.t()} | {:needs_replan, String.t(), String.t()} | {:needs_rework, String.t(), String.t()} | {:fail, String.t(), String.t()}}
          | {:error, term()}
  def handle_review_completion(%Issue{} = issue, workspace) when is_binary(workspace) do
    with {:ok, decision} <- Artifacts.load_review_decision(workspace),
         :ok <- Tracker.create_comment(issue.id, render_review_comment(issue, decision)),
         :ok <- maybe_apply_review_registry_update(issue, decision) do
      apply_review_decision(issue, decision)
    end
  end

  def handle_review_completion(_issue, _workspace), do: {:error, :invalid_arguments}

  @spec issue_ready?(String.t()) :: boolean()
  def issue_ready?(issue_id) when is_binary(issue_id) do
    case Registry.load_by_issue_id(issue_id) do
      {:ok, registry, _node_key, node} -> node_ready?(registry, node)
      {:error, _reason} -> false
    end
  end

  def issue_ready?(_issue_id), do: false

  @spec issue_dispatch_metadata(String.t()) :: {:ok, map()} | {:error, term()}
  def issue_dispatch_metadata(issue_id) when is_binary(issue_id) do
    case Registry.load_by_issue_id(issue_id) do
      {:ok, registry, node_key, node} ->
        {:ok,
         %{
           workflow_phase: :execution,
           workflow_root_issue_id: registry["root_issue_identifier"],
           agent_id: node["agent_id"],
           max_turns: Config.settings!().agent.max_turns,
           workflow_context: workflow_context(registry, node_key, node)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def issue_dispatch_metadata(_issue_id), do: {:error, :invalid_issue_id}

  defp load_or_new_registry(%Issue{} = root_issue) do
    case Registry.load_by_root_identifier(root_issue.identifier) do
      {:ok, registry} -> {:ok, registry}
      {:error, :enoent} -> {:ok, Registry.new_root(root_issue)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_materialization_plan(%{"kind" => kind} = plan)
       when kind in ["direct_execution", "issue_graph", "needs_human_input"] do
    validate_plan_nodes(plan)
  end

  defp validate_materialization_plan(%{"mode" => mode} = plan)
       when mode in ["direct_execution", "issue_graph", "needs_human_input"] do
    validate_plan_nodes(plan)
  end

  defp validate_materialization_plan(_plan), do: {:error, :invalid_workflow_plan}

  defp validate_plan_nodes(%{"kind" => "direct_execution"}), do: :ok
  defp validate_plan_nodes(%{"mode" => "direct_execution"}), do: :ok
  defp validate_plan_nodes(%{"kind" => "needs_human_input", "request" => request}) when is_binary(request), do: :ok
  defp validate_plan_nodes(%{"mode" => "needs_human_input", "request" => request}) when is_binary(request), do: :ok

  defp validate_plan_nodes(%{"kind" => "issue_graph", "nodes" => nodes, "edges" => edges}) do
    validate_graph_nodes(nodes, edges)
  end

  defp validate_plan_nodes(%{"mode" => "issue_graph", "nodes" => nodes, "edges" => edges}) do
    validate_graph_nodes(nodes, edges)
  end

  defp validate_plan_nodes(_plan), do: {:error, :invalid_workflow_plan}

  defp validate_graph_nodes(nodes, edges) do
    with :ok <- validate_nodes(nodes),
         :ok <- validate_edges(edges),
         :ok <- validate_edge_references(nodes, edges) do
      :ok
    end
  end

  defp validate_nodes(nodes) when is_list(nodes) do
    if Enum.all?(nodes, &is_valid_node?/1), do: :ok, else: {:error, :invalid_workflow_plan}
  end

  defp validate_nodes(_nodes), do: {:error, :invalid_workflow_plan}

  defp validate_edges(edges) when is_list(edges) do
    if Enum.all?(edges, &is_valid_edge?/1), do: :ok, else: {:error, :invalid_workflow_plan}
  end

  defp validate_edges(_edges), do: {:error, :invalid_workflow_plan}

  defp validate_edge_references(nodes, edges) do
    node_keys = MapSet.new(Enum.map(nodes, & &1["node_key"]))

    if Enum.all?(edges, fn edge ->
         from = edge["from"] || edge[:from]
         to = edge["to"] || edge[:to]
         is_binary(from) and is_binary(to) and MapSet.member?(node_keys, from) and MapSet.member?(node_keys, to)
       end) do
      :ok
    else
      {:error, {:invalid_workflow_plan_edge_reference, %{node_keys: Enum.map(nodes, & &1["node_key"])}}}
    end
  end

  defp is_valid_node?(%{"node_key" => node_key, "task_type" => task_type, "title" => title, "goal" => goal, "agent_id" => agent_id})
       when is_binary(node_key) and is_binary(task_type) and is_binary(title) and is_binary(goal) and is_binary(agent_id),
       do: true

  defp is_valid_node?(_node), do: false

  defp is_valid_edge?(%{"from" => from, "to" => to}) when is_binary(from) and is_binary(to), do: true
  defp is_valid_edge?(%{from: from, to: to}) when is_binary(from) and is_binary(to), do: true
  defp is_valid_edge?(_edge), do: false

  defp materialize_plan(registry, root_issue, %{"kind" => "direct_execution"} = plan) do
    {:ok,
     registry
     |> Registry.put_node("root", %{
       "issue_id" => root_issue.id,
       "issue_identifier" => root_issue.identifier,
       "agent_id" => plan["agent_id"],
       "node_key" => "root",
       "task_type" => "direct_execution",
       "workflow_semantics" => "executable",
       "status" => "ready",
       "summary" => plan["summary"]
     })
     |> Map.put("status", "planning_complete")}
  end

  defp materialize_plan(registry, root_issue, %{"kind" => "issue_graph", "nodes" => nodes, "edges" => edges} = plan) do
    with {:ok, registry} <- create_derived_nodes(registry, root_issue, nodes, edges, plan),
         {:ok, registry} <- attach_edges(registry, edges) do
      {:ok, Map.put(registry, "status", "planning_complete")}
    end
  end

  defp materialize_plan(registry, _root_issue, %{"kind" => "needs_human_input"} = plan) do
    {:ok,
     registry
     |> Map.put("status", "needs_human_input")
     |> Map.put("human_input_request", plan["request"])
     |> Map.put("human_input_summary", plan["summary"])
     |> Map.put("human_input_confidence", plan["confidence"])}
  end

  defp materialize_plan(registry, root_issue, %{"mode" => "direct_execution"} = plan) do
    materialize_plan(registry, root_issue, Map.put(plan, "kind", "direct_execution"))
  end

  defp materialize_plan(registry, root_issue, %{"mode" => "issue_graph"} = plan) do
    materialize_plan(registry, root_issue, Map.put(plan, "kind", "issue_graph"))
  end

  defp materialize_plan(registry, root_issue, %{"mode" => "needs_human_input"} = plan) do
    materialize_plan(registry, root_issue, Map.put(plan, "kind", "needs_human_input"))
  end

  defp materialize_plan(registry, _root_issue, _plan) do
    {:ok, Map.put(registry, "status", "planning_complete")}
  end

  defp create_derived_nodes(registry, root_issue, nodes, edges, plan) do
    dependency_map = dependency_map(edges)
    handoff_map = handoff_map(edges)

    Enum.reduce_while(nodes, {:ok, registry}, fn node, {:ok, acc} ->
      node_key = node["node_key"]
      dependencies = Map.get(dependency_map, node_key, [])
      handoffs = Map.get(handoff_map, node_key, [])

      case reusable_node_issue(Registry.node(acc, node_key)) do
        {:ok, issue_ref} ->
          updated_registry = put_derived_node(acc, node_key, node, issue_ref, dependencies, handoffs)
          {:cont, {:ok, updated_registry}}

        :error ->
          case Tracker.create_issue(%{
                 title: node["title"],
                 description: node_description(root_issue, node, dependencies, handoffs, plan),
                 state: "Todo",
                 assignee_id: root_issue.assignee_id,
                 labels: inherited_labels(root_issue)
               }) do
            {:ok, %Issue{} = issue} ->
              updated_registry =
                put_derived_node(
                  acc,
                  node_key,
                  node,
                  %{"issue_id" => issue.id, "issue_identifier" => issue.identifier},
                  dependencies,
                  handoffs
                )

              :ok = Registry.save!(updated_registry)
              {:cont, {:ok, updated_registry}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
      end
    end)
  end

  defp reusable_node_issue(%{"issue_id" => issue_id, "issue_identifier" => issue_identifier})
       when is_binary(issue_id) and is_binary(issue_identifier) do
    {:ok, %{"issue_id" => issue_id, "issue_identifier" => issue_identifier}}
  end

  defp reusable_node_issue(_node), do: :error

  defp put_derived_node(registry, node_key, node, issue_ref, dependencies, handoffs) do
    Registry.put_node(registry, node_key, %{
      "node_key" => node_key,
      "issue_id" => issue_ref["issue_id"],
      "issue_identifier" => issue_ref["issue_identifier"],
      "agent_id" => node["agent_id"],
      "task_type" => node["task_type"],
      "instructions" => node["instructions"],
      "dependencies" => dependencies,
      "handoff" => handoffs,
      "handoff_summary" => handoffs,
      "evidence_expectations" => node["evidence_expectations"] || [],
      "workflow_semantics" => "executable",
      "status" => readiness_for(dependencies),
      "title" => node["title"]
    })
  end

  defp attach_edges(registry, edges) do
    registry = Map.put(registry, "edges", [])
    {:ok, Enum.reduce(edges, registry, &Registry.add_edge(&2, &1))}
  end

  defp maybe_comment_root(root_issue, %{"kind" => "issue_graph"} = plan, registry) do
    Tracker.create_comment(root_issue.id, render_plan_comment(root_issue, plan, registry))
  end

  defp maybe_comment_root(root_issue, %{"mode" => "issue_graph"} = plan, registry) do
    Tracker.create_comment(root_issue.id, render_plan_comment(root_issue, Map.put(plan, "kind", "issue_graph"), registry))
  end

  defp maybe_comment_root(root_issue, %{"kind" => "needs_human_input"} = plan, _registry) do
    Tracker.create_comment(root_issue.id, render_human_input_comment(root_issue, plan))
  end

  defp maybe_comment_root(root_issue, %{"mode" => "needs_human_input"} = plan, registry) do
    maybe_comment_root(root_issue, Map.put(plan, "kind", "needs_human_input"), registry)
  end

  defp maybe_comment_root(_root_issue, _plan, _registry), do: :ok

  defp render_completion_comment(issue, packet) do
    """
    ## Completion Packet

    Issue: #{issue.identifier}
    Outcome: #{packet["outcome"]}
    Summary: #{packet["summary"]}

    Evidence:
    #{format_list(packet["evidence"] || [])}

    Decisions:
    #{format_list(packet["decisions"] || [])}

    Open questions:
    #{format_list(packet["open_questions"] || [])}

    Next handoff:
    #{packet["next_handoff"] || "-"}
    """
    |> String.trim()
  end

  defp render_review_comment(issue, decision) do
    """
    ## Review Decision

    Issue: #{issue.identifier}
    Decision: #{decision["decision"]}
    Confidence: #{decision["confidence"]}
    Summary: #{decision["summary"]}
    """
    |> String.trim()
  end

  defp apply_review_decision(%Issue{} = issue, %{"decision" => "pass"}) do
    {:ok, {:pass, issue.id}}
  end

  defp apply_review_decision(%Issue{} = issue, %{"decision" => "needs_human", "summary" => summary}) do
    {:ok, {:needs_human, issue.id, summary}}
  end

  defp apply_review_decision(%Issue{} = issue, %{"decision" => "needs_replan", "summary" => summary}) do
    {:ok, {:needs_replan, issue.id, summary}}
  end

  defp apply_review_decision(%Issue{} = issue, %{"decision" => "needs_rework", "summary" => summary}) do
    {:ok, {:needs_rework, issue.id, summary}}
  end

  defp apply_review_decision(%Issue{} = issue, %{"decision" => "fail", "summary" => summary}) do
    {:ok, {:fail, issue.id, summary}}
  end

  defp maybe_apply_review_registry_update(%Issue{} = issue, %{"decision" => "pass"}) do
    case Registry.load_by_issue_id(issue.id) do
      {:ok, registry, node_key, _node} ->
        updated_registry =
          registry
          |> put_node_status(node_key, "completed")
          |> unlock_ready_nodes()
          |> maybe_complete_registry()

        with :ok <- Tracker.update_issue_state(issue.id, workflow_terminal_state()),
             :ok <- maybe_close_root_issue(updated_registry, issue.id) do
          Registry.save!(updated_registry)
        end

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_apply_review_registry_update(%Issue{} = issue, %{"decision" => "needs_rework"} = decision) do
    case Registry.load_by_issue_id(issue.id) do
      {:ok, registry, node_key, node} ->
        materialize_rework_issue(registry, node_key, node, issue, decision)

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_apply_review_registry_update(%Issue{} = issue, %{"decision" => "needs_replan"} = decision) do
    case Registry.load_by_issue_id(issue.id) do
      {:ok, registry, node_key, _node} ->
        updated_registry = mark_registry_for_replanning(registry, node_key, issue, decision)

        with :ok <- Registry.save!(updated_registry),
             :ok <- close_replan_superseded_issues(updated_registry) do
          :ok
        end

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_apply_review_registry_update(_issue, _decision), do: :ok

  defp mark_registry_for_replanning(registry, node_key, %Issue{} = issue, decision) do
    registry
    |> Map.put("status", "replanning")
    |> Map.put("replan_request", decision["summary"])
    |> Map.put("replan_source_node_key", node_key)
    |> Map.put("replan_source_issue_id", issue.id)
    |> Map.put("replan_source_issue_identifier", issue.identifier)
    |> supersede_unfinished_executable_nodes_for_replan(decision)
  end

  defp supersede_unfinished_executable_nodes_for_replan(registry, decision) do
    update_in(registry, ["nodes"], fn
      nodes when is_map(nodes) ->
        Enum.into(nodes, %{}, fn {node_key, node} ->
          if executable_node?(node) and not completed_status?(node["status"]) do
            {node_key,
             node
             |> Map.put("status", "superseded")
             |> Map.put("workflow_semantics", "superseded")
             |> Map.put("replan_summary", decision["summary"])}
          else
            {node_key, node}
          end
        end)

      nodes ->
        nodes
    end)
  end

  defp close_replan_superseded_issues(registry) do
    registry
    |> Map.get("nodes", %{})
    |> Map.values()
    |> Enum.filter(&replan_superseded_issue?(&1, registry))
    |> Enum.reduce_while(:ok, fn node, :ok ->
      case Tracker.update_issue_state(node["issue_id"], workflow_terminal_state()) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp replan_superseded_issue?(%{"issue_id" => issue_id} = node, %{"root_issue_id" => root_issue_id})
       when is_binary(issue_id) do
    issue_id != root_issue_id and
      node["status"] == "superseded" and
      node["workflow_semantics"] == "superseded"
  end

  defp replan_superseded_issue?(_node, _registry), do: false

  defp materialize_rework_issue(registry, node_key, node, issue, decision) do
    rework_key = next_rework_node_key(registry, node_key)
    title = rework_issue_title(node, issue)
    description = rework_issue_description(registry, node_key, node, issue, decision)

    with {:ok, %Issue{} = rework_issue} <-
           Tracker.create_issue(%{
             title: title,
             description: description,
             state: "Todo",
             assignee_id: issue.assignee_id,
             labels: inherited_labels(issue)
           }) do
      dependencies = node["dependencies"] || []

      updated_registry =
        registry
        |> supersede_node(node_key, rework_key, decision)
        |> put_rework_node(rework_key, node_key, node, rework_issue, decision, dependencies)
        |> rewire_downstream_dependencies(node_key, rework_key)
        |> rewire_downstream_edges(node_key, rework_key)
        |> Registry.add_edge(%{
          "from" => node_key,
          "to" => rework_key,
          "kind" => "rework",
          "handoff_summary" => decision["summary"]
        })
        |> Map.put("status", "planning_complete")

      with :ok <- Registry.save!(updated_registry),
           :ok <- maybe_close_superseded_issue(registry, issue) do
        :ok
      end
    end
  end

  defp maybe_close_superseded_issue(%{"root_issue_id" => root_issue_id}, %Issue{id: issue_id})
       when is_binary(root_issue_id) and is_binary(issue_id) and root_issue_id != issue_id do
    Tracker.update_issue_state(issue_id, workflow_terminal_state())
  end

  defp maybe_close_superseded_issue(_registry, _issue), do: :ok

  defp inherited_labels(%Issue{} = issue) do
    issue
    |> Issue.label_names()
    |> Kernel.++(Config.settings!().tracker.required_labels)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&String.downcase/1)
  end

  defp next_rework_node_key(registry, node_key) do
    existing_keys =
      registry
      |> Map.get("nodes", %{})
      |> Map.keys()
      |> MapSet.new()

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(&"#{node_key}-rework-#{&1}")
    |> Enum.find(&(not MapSet.member?(existing_keys, &1)))
  end

  defp rework_issue_title(%{"title" => title}, _issue) when is_binary(title) and title != "",
    do: "返工：#{title}"

  defp rework_issue_title(_node, %Issue{title: title}) when is_binary(title) and title != "",
    do: "返工：#{title}"

  defp rework_issue_title(_node, _issue), do: "返工任务"

  defp rework_issue_description(registry, node_key, node, issue, decision) do
    packet = node["completion_packet"] || %{}

    """
    Root issue: #{registry["root_issue_identifier"]}
    Reviewed issue: #{issue.identifier}
    Reviewed issue id: #{issue.id}
    Rework of node: #{node_key}
    Task type: #{node["task_type"] || "rework"}

    Review summary:
    #{decision["summary"]}

    Original task:
    #{node["instructions"] || node["title"] || issue.title || "-"}

    Previous completion summary:
    #{packet["summary"] || "-"}

    Previous evidence:
    #{format_list(packet["evidence"] || [])}
    """
    |> String.trim()
  end

  defp supersede_node(registry, node_key, rework_key, decision) do
    update_in(registry, ["nodes", node_key], fn
      %{} = node ->
        node
        |> Map.put("status", "superseded")
        |> Map.put("workflow_semantics", "superseded")
        |> Map.put("superseded_by", rework_key)
        |> Map.put("review_summary", decision["summary"])

      node ->
        node
    end)
  end

  defp put_rework_node(registry, rework_key, original_node_key, original_node, rework_issue, decision, dependencies) do
    Registry.put_node(registry, rework_key, %{
      "node_key" => rework_key,
      "issue_id" => rework_issue.id,
      "issue_identifier" => rework_issue.identifier,
      "agent_id" => original_node["agent_id"],
      "task_type" => original_node["task_type"] || "rework",
      "instructions" => rework_instructions(original_node, decision),
      "dependencies" => dependencies,
      "handoff" => original_node["handoff"] || [],
      "handoff_summary" => original_node["handoff_summary"] || original_node["handoff"] || [],
      "evidence_expectations" => original_node["evidence_expectations"] || [],
      "workflow_semantics" => "executable",
      "status" => readiness_for_existing_dependencies(registry, dependencies),
      "title" => rework_issue.title,
      "rework_of" => original_node_key,
      "review_summary" => decision["summary"],
      "previous_completion_packet" => original_node["completion_packet"]
    })
  end

  defp rework_instructions(original_node, decision) do
    """
    根据审查意见完成返工。

    审查意见：
    #{decision["summary"]}

    原任务说明：
    #{original_node["instructions"] || original_node["title"] || "-"}
    """
    |> String.trim()
  end

  defp readiness_for_existing_dependencies(registry, dependencies) do
    if dependencies_completed?(registry, dependencies || []), do: "ready", else: "waiting"
  end

  defp rewire_downstream_dependencies(registry, old_node_key, new_node_key) do
    update_in(registry, ["nodes"], fn
      nodes when is_map(nodes) ->
        Enum.into(nodes, %{}, fn {node_key, node} ->
          if node_key == old_node_key or node_key == new_node_key do
            {node_key, node}
          else
            dependencies =
              node
              |> Map.get("dependencies", [])
              |> Enum.map(fn dependency ->
                if dependency == old_node_key, do: new_node_key, else: dependency
              end)
              |> Enum.uniq()

            {node_key, Map.put(node, "dependencies", dependencies)}
          end
        end)

      nodes ->
        nodes
    end)
  end

  defp rewire_downstream_edges(registry, old_node_key, new_node_key) do
    update_in(registry, ["edges"], fn
      edges when is_list(edges) ->
        Enum.map(edges, fn
          %{"from" => ^old_node_key} = edge -> Map.put(edge, "from", new_node_key)
          %{from: ^old_node_key} = edge -> Map.put(edge, :from, new_node_key)
          edge -> edge
        end)

      edges ->
        edges
    end)
  end

  defp maybe_store_completion_packet(%Issue{} = issue, packet) when is_map(packet) do
    case Registry.load_by_issue_id(issue.id) do
      {:ok, registry, node_key, _node} ->
        registry
        |> put_node_completion_packet(node_key, packet)
        |> Registry.save!()

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put_node_completion_packet(registry, node_key, packet) do
    update_in(registry, ["nodes", node_key], fn
      %{} = node -> Map.put(node, "completion_packet", packet)
      node -> node
    end)
  end

  defp put_node_status(registry, node_key, status) do
    update_in(registry, ["nodes", node_key], fn
      %{} = node -> Map.put(node, "status", status)
      node -> node
    end)
  end

  defp maybe_complete_registry(registry) do
    if workflow_completed?(registry) do
      Map.put(registry, "status", "completed")
    else
      registry
    end
  end

  defp workflow_completed?(registry) when is_map(registry) do
    executable_nodes =
      registry
      |> Map.get("nodes", %{})
      |> Map.values()
      |> Enum.filter(&executable_node?/1)

    executable_nodes != [] and Enum.all?(executable_nodes, &completed_status?(&1["status"]))
  end

  defp workflow_completed?(_registry), do: false

  defp executable_node?(%{} = node), do: Map.get(node, "workflow_semantics", "executable") == "executable"
  defp executable_node?(_node), do: false

  defp maybe_close_root_issue(%{"status" => "completed", "root_issue_id" => root_issue_id}, reviewed_issue_id)
       when is_binary(root_issue_id) and root_issue_id != reviewed_issue_id do
    Tracker.update_issue_state(root_issue_id, workflow_terminal_state())
  end

  defp maybe_close_root_issue(_registry, _reviewed_issue_id), do: :ok

  defp workflow_terminal_state do
    terminal_states = Config.settings!().tracker.terminal_states

    Enum.find(terminal_states, &(String.downcase(String.trim(&1)) == "done")) ||
      List.first(terminal_states) ||
      "Done"
  end

  defp unlock_ready_nodes(registry) do
    Enum.reduce(registry["nodes"] || %{}, registry, fn {node_key, node}, acc ->
      if node["status"] == "waiting" and dependencies_completed?(acc, node["dependencies"] || []) do
        put_node_status(acc, node_key, "ready")
      else
        acc
      end
    end)
  end

  defp workflow_root_identifier_for_issue(%Issue{id: issue_id, identifier: identifier}) when is_binary(issue_id) do
    case Registry.load_by_issue_id(issue_id) do
      {:ok, registry, _node_key, _node} -> registry["root_issue_identifier"] || identifier
      {:error, _reason} -> identifier
    end
  end

  defp node_description(root_issue, node, dependencies, handoffs, plan) do
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
    #{format_list(handoffs)}

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

  defp render_human_input_comment(root_issue, plan) do
    """
    ## Needs Human Input

    Root issue: #{root_issue.identifier}
    Summary: #{plan["summary"]}
    Confidence: #{plan["confidence"]}

    Request:
    #{plan["request"]}
    """
    |> String.trim()
  end

  defp readiness_for([]), do: "ready"
  defp readiness_for(_dependencies), do: "waiting"

  defp node_ready?(registry, node) when is_map(registry) and is_map(node) do
    ready_status?(node["status"]) and dependencies_completed?(registry, node["dependencies"] || [])
  end

  defp node_ready?(_registry, _node), do: false

  defp ready_status?(status) when is_binary(status) do
    MapSet.member?(@ready_statuses, String.downcase(String.trim(status)))
  end

  defp ready_status?(_status), do: false

  defp dependencies_completed?(registry, dependencies) when is_list(dependencies) do
    Enum.all?(dependencies, fn dependency ->
      case Registry.node(registry, dependency) do
        %{} = node -> completed_status?(node["status"])
        _ -> false
      end
    end)
  end

  defp dependencies_completed?(_registry, _dependencies), do: false

  defp completed_status?(status) when is_binary(status) do
    MapSet.member?(@completed_statuses, String.downcase(String.trim(status)))
  end

  defp completed_status?(_status), do: false

  defp workflow_context(registry, node_key, node) do
    %{
      "root_issue_id" => registry["root_issue_id"],
      "root_issue_identifier" => registry["root_issue_identifier"],
      "root_workspace" => root_workspace_for_registry(registry),
      "node_key" => node_key,
      "task_type" => node["task_type"],
      "instructions" => node["instructions"],
      "dependencies" => node["dependencies"] || [],
      "handoff" => node["handoff"] || [],
      "upstream_packets" => upstream_packets(registry, node),
      "evidence_expectations" => node["evidence_expectations"] || [],
      "issue_identifier" => node["issue_identifier"],
      "rework_of" => node["rework_of"],
      "review_summary" => node["review_summary"],
      "previous_completion_packet" => node["previous_completion_packet"]
    }
  end

  defp root_workspace_for_registry(%{"root_issue_identifier" => identifier}) when is_binary(identifier) do
    case Workspace.create_for_issue(identifier) do
      {:ok, workspace} -> workspace
      {:error, _reason} -> nil
    end
  end

  defp root_workspace_for_registry(_registry), do: nil

  defp upstream_packets(registry, node) when is_map(registry) and is_map(node) do
    node
    |> Map.get("dependencies", [])
    |> Enum.flat_map(fn dependency ->
      case Registry.node(registry, dependency) do
        %{"completion_packet" => packet} = upstream_node when is_map(packet) ->
          [
            packet
            |> Map.put_new("node_key", upstream_node["node_key"] || dependency)
            |> Map.put_new("issue_identifier", upstream_node["issue_identifier"])
          ]

        _ ->
          []
      end
    end)
  end

  defp upstream_packets(_registry, _node), do: []

  defp dependency_map(edges) do
    Enum.reduce(edges, %{}, fn edge, acc ->
      from = edge["from"] || edge[:from]
      to = edge["to"] || edge[:to]

      if is_binary(from) and is_binary(to) do
        Map.update(acc, to, [from], fn existing -> Enum.uniq(existing ++ [from]) end)
      else
        acc
      end
    end)
  end

  defp handoff_map(edges) do
    Enum.reduce(edges, %{}, fn edge, acc ->
      from = edge["from"] || edge[:from]
      to = edge["to"] || edge[:to]
      summary = edge["handoff_summary"] || edge[:handoff_summary] || edge["handoff"] || edge[:handoff]

      if is_binary(from) and is_binary(to) and is_binary(summary) and summary != "" do
        Map.update(acc, to, [summary], fn existing -> Enum.uniq(existing ++ [summary]) end)
      else
        acc
      end
    end)
  end

  defp format_list(values) when is_list(values) and values != [] do
    Enum.map_join(values, "\n", &"- #{format_list_item(&1)}")
  end

  defp format_list([]), do: "-"
  defp format_list(value) when is_binary(value), do: value
  defp format_list(value), do: format_list_item(value)

  defp format_list_item(value) when is_binary(value), do: value
  defp format_list_item(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp format_list_item(nil), do: "null"

  defp format_list_item(value) when is_map(value) or is_list(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> encoded
      {:error, _reason} -> inspect(value)
    end
  end

  defp format_list_item(value), do: inspect(value)
end
