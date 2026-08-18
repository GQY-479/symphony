defmodule SymphonyElixir.Workflow.Controller do
  @moduledoc """
  Workflow 规划结果物化与派生 issue 编排。
  """

  alias SymphonyElixir.{Config, Tracker}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Workflow.{Artifacts, GitAdapter, Registry}

  @ready_statuses MapSet.new(["ready"])
  @completed_statuses MapSet.new(["completed", "done", "passed"])

  @spec handle_planning_completion(Issue.t(), Path.t()) :: {:ok, map()} | {:error, term()}
  def handle_planning_completion(%Issue{} = root_issue, workspace) when is_binary(workspace) do
    handle_planning_completion(root_issue, workspace, [])
  end

  def handle_planning_completion(_issue, _workspace), do: {:error, :invalid_arguments}

  @spec handle_planning_completion(Issue.t(), Path.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def handle_planning_completion(%Issue{} = root_issue, workspace, opts)
      when is_binary(workspace) and is_list(opts) do
    worker_host = Keyword.get(opts, :worker_host)
    settings = Config.settings!().orchestration
    candidate_branch = candidate_branch_name(root_issue.identifier)

    with {:ok, plan} <- Artifacts.load_workflow_plan(workspace, worker_host),
         :ok <- validate_materialization_plan(plan),
         {:ok, base_registry} <- load_or_new_registry(root_issue),
         {:ok, git} <-
           GitAdapter.initialize_candidate(
             workspace,
             worker_host,
             settings.git_remote,
             settings.target_branch,
             candidate_branch
           ),
         git_registry <-
           Registry.put_workflow_git(base_registry, %{
             "remote" => settings.git_remote,
             "target_branch" => settings.target_branch,
             "target_base_sha" => git.target_sha,
             "candidate_branch" => git.candidate_branch,
             "candidate_head_sha" => git.candidate_sha
           }),
         {:ok, registry} <- materialize_plan(git_registry, root_issue, plan) do
      case Registry.save!(registry) do
        :ok ->
          case maybe_comment_root(root_issue, plan, registry) do
            :ok -> {:ok, registry}
            {:error, reason} -> {:error, reason}
          end
      end
    end
  end

  def handle_planning_completion(_issue, _workspace, _opts), do: {:error, :invalid_arguments}

  @spec handle_issue_completion(Issue.t(), Path.t()) ::
          {:ok,
           {:completed, String.t()}
           | {:pass, String.t()}
           | {:continue_agent, String.t(), atom(), map()}
           | {:retry_controller, String.t(), atom(), map()}
           | {:needs_human, String.t(), String.t()}
           | {:needs_replan, String.t(), String.t()}
           | {:needs_rework, String.t(), String.t()}
           | {:fail, String.t(), String.t()}}
          | {:error, term()}
  def handle_issue_completion(%Issue{} = issue, workspace) when is_binary(workspace) do
    handle_issue_completion(issue, workspace, [])
  end

  def handle_issue_completion(_issue, _workspace), do: {:error, :invalid_arguments}

  @spec handle_issue_completion(Issue.t(), Path.t(), keyword()) ::
          {:ok,
           {:completed, String.t()}
           | {:pass, String.t()}
           | {:continue_agent, String.t(), atom(), map()}
           | {:retry_controller, String.t(), atom(), map()}
           | {:needs_human, String.t(), String.t()}
           | {:needs_replan, String.t(), String.t()}
           | {:needs_rework, String.t(), String.t()}
           | {:fail, String.t(), String.t()}}
          | {:error, term()}
  def handle_issue_completion(%Issue{} = issue, workspace, opts)
      when is_binary(workspace) and is_list(opts) do
    worker_host = Keyword.get(opts, :worker_host)

    with {:ok, result} <- Artifacts.load_issue_result(workspace, worker_host),
         {:ok, registry, node_key, node} <- Registry.load_by_issue_id(issue.id),
         :ok <- validate_result_matches_node(result, node_key, node) do
      if node["task_type"] == "review" do
        validate_review_completion(
          issue,
          workspace,
          registry,
          node_key,
          node,
          result,
          opts
        )
      else
        validate_writable_completion(
          issue,
          workspace,
          registry,
          node_key,
          node,
          result,
          opts
        )
      end
    end
  end

  def handle_issue_completion(_issue, _workspace, _opts), do: {:error, :invalid_arguments}

  @spec prepare_issue_workspace(Issue.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def prepare_issue_workspace(%Issue{} = issue, workspace, opts)
      when is_binary(workspace) and is_list(opts) do
    worker_host = Keyword.get(opts, :worker_host)

    with {:ok, registry, _node_key, node} <- Registry.load_by_issue_id(issue.id) do
      if node["task_type"] == "review" do
        GitAdapter.checkout_commit(workspace, worker_host, review_subject_head(registry, node))
        |> normalize_prepare_result()
      else
        GitAdapter.prepare_private_branch(
          workspace,
          worker_host,
          registry["remote"],
          node["branch"],
          node["base_candidate_sha"]
        )
        |> normalize_prepare_result()
      end
    end
  end

  def prepare_issue_workspace(_issue, _workspace, _opts), do: {:error, :invalid_arguments}

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
           workflow_phase: :issue,
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
       when kind in ["issue_graph", "needs_human_input"] do
    validate_plan_nodes(plan)
  end

  defp validate_materialization_plan(%{"mode" => mode} = plan)
       when mode in ["issue_graph", "needs_human_input"] do
    validate_plan_nodes(plan)
  end

  defp validate_materialization_plan(_plan), do: {:error, :invalid_workflow_plan}

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
         :ok <- validate_node_agents(nodes),
         :ok <- validate_edges(edges),
         :ok <- validate_edge_references(nodes, edges),
         :ok <- validate_final_review(nodes) do
      :ok
    end
  end

  defp validate_nodes(nodes) when is_list(nodes) do
    if Enum.all?(nodes, &valid_node?/1), do: :ok, else: {:error, :invalid_workflow_plan}
  end

  defp validate_nodes(_nodes), do: {:error, :invalid_workflow_plan}

  defp validate_node_agents(nodes) when is_list(nodes) do
    configured_agents = Config.settings!().agents || %{}

    case Enum.find(nodes, fn node -> not Map.has_key?(configured_agents, node["agent_id"]) end) do
      %{"agent_id" => agent_id} -> {:error, {:unknown_workflow_agent, agent_id}}
      _ -> :ok
    end
  end

  defp validate_node_agents(_nodes), do: {:error, :invalid_workflow_plan}

  defp validate_edges(edges) when is_list(edges) do
    if Enum.all?(edges, &valid_edge?/1), do: :ok, else: {:error, :invalid_workflow_plan}
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

  defp validate_final_review(nodes) do
    case Enum.find(nodes, &(&1["node_key"] == "final_review")) do
      %{
        "task_type" => "review",
        "reviews" => ["__root_candidate__"],
        "subject_selector" => %{"type" => "final_candidate_range"}
      } ->
        :ok

      _other ->
        {:error, :invalid_workflow_plan}
    end
  end

  defp valid_node?(
         %{
           "node_key" => node_key,
           "task_type" => task_type,
           "title" => title,
           "goal" => goal,
           "agent_id" => agent_id
         } = node
       )
       when is_binary(node_key) and is_binary(task_type) and is_binary(title) and
              is_binary(goal) and is_binary(agent_id) do
    valid_review_node?(node)
  end

  defp valid_node?(_node), do: false

  defp valid_review_node?(%{"task_type" => "review"} = node) do
    reviews = Map.get(node, "reviews")
    subject_selector = Map.get(node, "subject_selector")

    is_list(reviews) and reviews != [] and Enum.all?(reviews, &non_blank?/1) and
      is_map(subject_selector)
  end

  defp valid_review_node?(_node), do: true

  defp valid_edge?(%{"from" => from, "to" => to}) when is_binary(from) and is_binary(to), do: true
  defp valid_edge?(%{from: from, to: to}) when is_binary(from) and is_binary(to), do: true
  defp valid_edge?(_edge), do: false

  defp materialize_plan(registry, root_issue, %{"kind" => "issue_graph", "nodes" => nodes, "edges" => edges} = plan) do
    with {:ok, registry} <- create_derived_nodes(registry, root_issue, nodes, edges, plan),
         {:ok, registry} <- attach_edges(registry, edges) do
      {:ok, Registry.put_status(registry, "planning_complete", %{})}
    end
  end

  defp materialize_plan(registry, _root_issue, %{"kind" => "needs_human_input"} = plan) do
    {:ok,
     registry
     |> Registry.put_status("needs_human_input", %{
       "human_input_request" => plan["request"],
       "human_input_summary" => plan["summary"],
       "human_input_confidence" => plan["confidence"]
     })}
  end

  defp materialize_plan(registry, root_issue, %{"mode" => "issue_graph"} = plan) do
    materialize_plan(registry, root_issue, Map.put(plan, "kind", "issue_graph"))
  end

  defp materialize_plan(registry, root_issue, %{"mode" => "needs_human_input"} = plan) do
    materialize_plan(registry, root_issue, Map.put(plan, "kind", "needs_human_input"))
  end

  defp materialize_plan(registry, _root_issue, _plan) do
    {:ok, Registry.put_status(registry, "planning_complete", %{})}
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
          case Tracker.create_issue(
                 %{
                   title: node["title"],
                   description: node_description(root_issue, node, dependencies, handoffs, plan),
                   state: "Todo",
                   assignee_id: root_issue.assignee_id,
                   labels: inherited_labels(root_issue)
                 }
                 |> Map.merge(issue_tracker_context(root_issue))
               ) do
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

  defp reusable_node_issue(%{"status" => "superseded"}), do: :error
  defp reusable_node_issue(%{"workflow_semantics" => "superseded"}), do: :error

  defp reusable_node_issue(%{"issue_id" => issue_id, "issue_identifier" => issue_identifier})
       when is_binary(issue_id) and is_binary(issue_identifier) do
    {:ok, %{"issue_id" => issue_id, "issue_identifier" => issue_identifier}}
  end

  defp reusable_node_issue(_node), do: :error

  defp put_derived_node(registry, node_key, node, issue_ref, dependencies, handoffs) do
    node_attrs = %{
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
      "completion_conditions" => node["completion_conditions"] || [],
      "reviews" => node["reviews"],
      "subject_selector" => node["subject_selector"],
      "workflow_semantics" => "executable",
      "status" => readiness_for(dependencies),
      "title" => node["title"]
    }

    node_attrs =
      if node["task_type"] == "review" do
        node_attrs
      else
        Map.merge(node_attrs, %{
          "branch" =>
            private_branch_name(
              registry["root_issue_identifier"],
              issue_ref["issue_identifier"]
            ),
          "base_candidate_sha" => registry["candidate_head_sha"]
        })
      end

    Registry.put_node(registry, node_key, node_attrs)
  end

  defp attach_edges(registry, edges) do
    registry = Map.put(registry, "edges", [])
    {:ok, Enum.reduce(edges, registry, &Registry.add_edge(&2, &1))}
  end

  defp review_subject_head(registry, node) do
    case get_in(registry, ["subjects", node["subject_id"]]) do
      %{"head_sha" => sha} when is_binary(sha) -> sha
      %{"candidate_sha" => sha} when is_binary(sha) -> sha
      _subject -> registry["candidate_head_sha"]
    end
  end

  defp normalize_prepare_result(:ok), do: :ok
  defp normalize_prepare_result({:ok, _facts}), do: :ok
  defp normalize_prepare_result({:error, reason}), do: {:error, reason}

  defp candidate_branch_name(root_identifier) do
    "symphony/#{branch_segment(root_identifier)}/candidate"
  end

  defp private_branch_name(root_identifier, issue_identifier) do
    "symphony/#{branch_segment(root_identifier)}/#{branch_segment(issue_identifier)}"
  end

  defp branch_segment(value) when is_binary(value) do
    value
    |> String.replace(~r/[^a-zA-Z0-9._-]/, "-")
    |> String.trim("-")
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

  defp validate_result_matches_node(result, node_key, node) do
    cond do
      result["node_key"] != node_key ->
        {:error, {:issue_result_node_mismatch, node_key, result["node_key"]}}

      result["task_type"] != node["task_type"] ->
        {:error, {:issue_result_task_type_mismatch, node["task_type"], result["task_type"]}}

      true ->
        :ok
    end
  end

  defp validate_review_completion(
         issue,
         workspace,
         registry,
         node_key,
         node,
         result,
         opts
       ) do
    worker_host = Keyword.get(opts, :worker_host)

    with :ok <- validate_registry_git_facts(registry),
         {:ok, subject_head_sha} <- strict_review_subject_head(registry, node),
         {:ok, facts} <-
           GitAdapter.inspect_completion(
             workspace,
             worker_host,
             subject_head_sha,
             allowed_control_paths(workspace)
           ) do
      dirty_paths = facts.business_dirty_paths || []

      cond do
        dirty_paths != [] or facts.head_sha != subject_head_sha ->
          needs_human(
            issue.id,
            "审查 workspace 已改变：dirty_paths=#{inspect(dirty_paths)} " <>
              "expected_head=#{subject_head_sha} actual_head=#{facts.head_sha}"
          )

        final_review_node?(node) and result["outcome"] == "pass" ->
          apply_final_review_result(
            issue,
            workspace,
            registry,
            node_key,
            node,
            result,
            opts
          )

        true ->
          apply_review_result(
            issue,
            workspace,
            registry,
            node_key,
            node,
            result,
            opts
          )
      end
    else
      {:needs_human, reason} -> needs_human(issue.id, reason)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_writable_completion(
         issue,
         workspace,
         registry,
         node_key,
         node,
         result,
         opts
       ) do
    worker_host = Keyword.get(opts, :worker_host)

    with :ok <- validate_registry_git_facts(registry),
         :ok <- validate_writable_node_git_facts(node),
         {:ok, facts} <-
           GitAdapter.inspect_completion(
             workspace,
             worker_host,
             node["base_candidate_sha"],
             allowed_control_paths(workspace)
           ) do
      cond do
        facts.business_dirty_paths != [] ->
          continue_agent(registry, node_key, issue.id, :dirty_worktree, %{
            "dirty_paths" => facts.business_dirty_paths,
            "head_sha" => facts.head_sha
          })

        facts.business_changed_paths == [] ->
          complete_no_change(issue, workspace, registry, node_key, result, opts)

        true ->
          validate_candidate_ancestry(
            issue,
            workspace,
            registry,
            node_key,
            node,
            facts,
            result,
            opts
          )
      end
    else
      {:needs_human, reason} -> needs_human(issue.id, reason)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_registry_git_facts(registry) do
    required = ["remote", "target_branch", "candidate_branch", "candidate_head_sha"]
    missing = Enum.reject(required, &non_blank?(registry[&1]))

    if missing == [] do
      :ok
    else
      {:needs_human, "缺少 workflow Git 事实：#{Enum.join(missing, ", ")}"}
    end
  end

  defp validate_writable_node_git_facts(node) do
    required = ["branch", "base_candidate_sha"]
    missing = Enum.reject(required, &non_blank?(node[&1]))

    if missing == [] do
      :ok
    else
      {:needs_human, "可写节点缺少 Git 事实：#{Enum.join(missing, ", ")}"}
    end
  end

  defp strict_review_subject_head(registry, node) do
    case get_in(registry, ["subjects", node["subject_id"]]) do
      %{"head_sha" => sha} when is_binary(sha) and sha != "" -> {:ok, sha}
      %{"candidate_sha" => sha} when is_binary(sha) and sha != "" -> {:ok, sha}
      _subject -> {:needs_human, "审查节点缺少 Controller 记录的 subject HEAD"}
    end
  end

  defp continue_agent(registry, node_key, issue_id, reason, context) do
    previous_attempt = get_in(registry, ["nodes", node_key, "continuation", "attempt"]) || 0
    attempt = previous_attempt + 1
    max_attempts = Config.settings!().orchestration.completion_max_continuations

    if attempt > max_attempts do
      needs_human(
        issue_id,
        "completion continuation 已超过上限 #{max_attempts}：reason=#{reason}"
      )
    else
      continuation =
        context
        |> Map.put("reason", Atom.to_string(reason))
        |> Map.put("attempt", attempt)

      updated_registry =
        registry
        |> Registry.put_node_continuation(node_key, continuation)
        |> put_node_status(node_key, "running")

      with :ok <- Registry.save!(updated_registry) do
        {:ok, {:continue_agent, issue_id, reason, continuation}}
      end
    end
  end

  defp complete_no_change(issue, workspace, registry, node_key, result, opts) do
    worker_host = Keyword.get(opts, :worker_host)

    with {:ok, artifact_hash} <-
           GitAdapter.hash_artifact(Artifacts.issue_result_path(workspace), worker_host) do
      checkpoint_id = "#{node_key}:no-change:#{artifact_hash}"

      updated_registry =
        registry
        |> Registry.add_checkpoint_once(%{
          "id" => checkpoint_id,
          "kind" => "no_change",
          "node_key" => node_key,
          "artifact_hash" => artifact_hash
        })
        |> put_node_issue_result(node_key, result)
        |> Registry.put_node_git(node_key, %{"checkpoint_id" => checkpoint_id})
        |> Registry.clear_node_continuation(node_key)
        |> put_node_status(node_key, "completed")
        |> unlock_ready_nodes()
        |> maybe_complete_registry()

      persist_candidate_completion(
        issue,
        workspace,
        worker_host,
        updated_registry,
        result,
        checkpoint_id
      )
    end
  end

  defp validate_candidate_ancestry(
         issue,
         workspace,
         registry,
         node_key,
         node,
         facts,
         result,
         opts
       ) do
    worker_host = Keyword.get(opts, :worker_host)

    case GitAdapter.fetch_ref(
           workspace,
           worker_host,
           registry["remote"],
           registry["candidate_branch"]
         ) do
      {:ok, current_candidate_sha} ->
        validate_candidate_state(
          issue,
          workspace,
          worker_host,
          registry,
          node_key,
          node,
          facts,
          result,
          current_candidate_sha
        )

      {:error, reason} ->
        controller_git_failure(issue.id, reason, "fetch_candidate", %{
          "candidate_branch" => registry["candidate_branch"]
        })
    end
  end

  defp validate_candidate_state(
         issue,
         workspace,
         worker_host,
         registry,
         node_key,
         node,
         facts,
         result,
         current_candidate_sha
       ) do
    cond do
      current_candidate_sha != node["base_candidate_sha"] and
          current_candidate_sha != facts.head_sha ->
        continue_candidate_advanced(
          registry,
          node_key,
          issue.id,
          node["base_candidate_sha"],
          current_candidate_sha,
          facts.head_sha
        )

      true ->
        expected_ancestor_sha =
          if current_candidate_sha == facts.head_sha,
            do: node["base_candidate_sha"],
            else: current_candidate_sha

        case GitAdapter.ancestor?(
               workspace,
               worker_host,
               expected_ancestor_sha,
               facts.head_sha
             ) do
          {:ok, true} ->
            promote_candidate_completion(
              issue,
              workspace,
              worker_host,
              registry,
              node_key,
              node,
              facts,
              result,
              current_candidate_sha
            )

          {:ok, false} ->
            needs_human(issue.id, "issue HEAD 不包含当前 candidate 基线")

          {:error, reason} ->
            needs_human(issue.id, "无法验证 issue HEAD 的 candidate 祖先关系：#{inspect(reason)}")
        end
    end
  end

  defp promote_candidate_completion(
         issue,
         workspace,
         worker_host,
         registry,
         node_key,
         node,
         facts,
         result,
         current_candidate_sha
       ) do
    case GitAdapter.push_private_branch(
           workspace,
           worker_host,
           registry["remote"],
           node["branch"],
           facts.head_sha
         ) do
      {:ok, _private_sha} ->
        promote_or_confirm_candidate(
          issue,
          workspace,
          worker_host,
          registry,
          node_key,
          node,
          facts,
          result,
          current_candidate_sha
        )

      {:error, reason} ->
        controller_git_failure(issue.id, reason, "push_private_branch", %{
          "branch" => node["branch"],
          "head_sha" => facts.head_sha
        })
    end
  end

  defp promote_or_confirm_candidate(
         issue,
         workspace,
         worker_host,
         registry,
         node_key,
         node,
         facts,
         result,
         current_candidate_sha
       ) do
    promotion_result =
      if current_candidate_sha == facts.head_sha do
        {:ok, facts.head_sha}
      else
        GitAdapter.compare_and_swap_ref(
          workspace,
          worker_host,
          registry["remote"],
          registry["candidate_branch"],
          current_candidate_sha,
          facts.head_sha
        )
      end

    case promotion_result do
      {:ok, promoted_sha} when promoted_sha == facts.head_sha ->
        record_candidate_completion(
          issue,
          workspace,
          worker_host,
          registry,
          node_key,
          node,
          facts,
          result,
          promoted_sha
        )

      {:ok, promoted_sha} ->
        controller_git_failure(
          issue.id,
          {:remote_ref_mismatch, facts.head_sha, promoted_sha},
          "promote_candidate",
          %{"head_sha" => facts.head_sha}
        )

      {:error, {:stale_remote_ref, _detail}} ->
        handle_stale_candidate_promotion(
          issue,
          workspace,
          worker_host,
          registry,
          node_key,
          node,
          facts,
          result,
          current_candidate_sha
        )

      {:error, {:remote_ref_mismatch, _expected_sha, _actual_sha}} ->
        handle_stale_candidate_promotion(
          issue,
          workspace,
          worker_host,
          registry,
          node_key,
          node,
          facts,
          result,
          current_candidate_sha
        )

      {:error, reason} ->
        controller_git_failure(issue.id, reason, "promote_candidate", %{
          "candidate_branch" => registry["candidate_branch"],
          "expected_sha" => current_candidate_sha,
          "head_sha" => facts.head_sha
        })
    end
  end

  defp handle_stale_candidate_promotion(
         issue,
         workspace,
         worker_host,
         registry,
         node_key,
         node,
         facts,
         result,
         previous_candidate_sha
       ) do
    case GitAdapter.fetch_ref(
           workspace,
           worker_host,
           registry["remote"],
           registry["candidate_branch"]
         ) do
      {:ok, current_candidate_sha} when current_candidate_sha == facts.head_sha ->
        record_candidate_completion(
          issue,
          workspace,
          worker_host,
          registry,
          node_key,
          node,
          facts,
          result,
          current_candidate_sha
        )

      {:ok, current_candidate_sha} ->
        continue_candidate_advanced(
          registry,
          node_key,
          issue.id,
          previous_candidate_sha,
          current_candidate_sha,
          facts.head_sha
        )

      {:error, reason} ->
        controller_git_failure(issue.id, reason, "refresh_candidate_after_cas", %{
          "candidate_branch" => registry["candidate_branch"],
          "previous_candidate_sha" => previous_candidate_sha,
          "head_sha" => facts.head_sha
        })
    end
  end

  defp continue_candidate_advanced(
         registry,
         node_key,
         issue_id,
         previous_candidate_sha,
         current_candidate_sha,
         head_sha
       ) do
    continue_agent(registry, node_key, issue_id, :candidate_advanced, %{
      "previous_candidate_sha" => previous_candidate_sha,
      "current_candidate_sha" => current_candidate_sha,
      "head_sha" => head_sha
    })
  end

  defp record_candidate_completion(
         issue,
         workspace,
         worker_host,
         registry,
         node_key,
         node,
         facts,
         result,
         promoted_sha
       ) do
    case GitAdapter.hash_artifact(Artifacts.issue_result_path(workspace), worker_host) do
      {:ok, artifact_hash} ->
        checkpoint_id = "#{node_key}:candidate:#{facts.head_sha}"

        updated_registry =
          registry
          |> invalidate_overlapping_subjects(facts.business_changed_paths)
          |> Registry.add_checkpoint_once(%{
            "id" => checkpoint_id,
            "kind" => "candidate_promotion",
            "node_key" => node_key,
            "issue_branch" => node["branch"],
            "base_candidate_sha" => node["base_candidate_sha"],
            "issue_head_sha" => facts.head_sha,
            "candidate_before_sha" => node["base_candidate_sha"],
            "candidate_after_sha" => promoted_sha,
            "result_artifact_hash" => artifact_hash,
            "paths" => facts.business_changed_paths
          })
          |> Registry.put_workflow_git(%{"candidate_head_sha" => promoted_sha})
          |> put_node_issue_result(node_key, result)
          |> Registry.put_node_git(node_key, %{
            "head_sha" => facts.head_sha,
            "checkpoint_id" => checkpoint_id
          })
          |> Registry.clear_node_continuation(node_key)
          |> put_node_status(node_key, "completed")
          |> unlock_ready_nodes()
          |> maybe_complete_registry()

        persist_candidate_completion(
          issue,
          workspace,
          worker_host,
          updated_registry,
          result,
          checkpoint_id
        )

      {:error, reason} ->
        retry_controller(issue.id, reason, "hash_issue_result", %{
          "node_key" => node_key,
          "head_sha" => facts.head_sha
        })
    end
  end

  defp persist_candidate_completion(
         issue,
         workspace,
         worker_host,
         registry,
         result,
         checkpoint_id
       ) do
    case save_registry(registry) do
      :ok ->
        case prepare_ready_final_reviews(registry, workspace, worker_host) do
          {:ok, prepared_registry} ->
            prepared_registry = maybe_complete_registry(prepared_registry)

            case save_registry(prepared_registry) do
              :ok ->
                persist_candidate_tracker_updates(
                  issue,
                  prepared_registry,
                  result,
                  checkpoint_id
                )

              {:error, reason} ->
                retry_controller(issue.id, reason, "save_final_review_preparation", %{
                  "checkpoint_id" => checkpoint_id
                })
            end

          {:retry, reason, operation, context} ->
            retry_controller(issue.id, reason, operation, context)
        end

      {:error, reason} ->
        retry_controller(issue.id, reason, "save_candidate_checkpoint", %{
          "checkpoint_id" => checkpoint_id
        })
    end
  end

  defp persist_candidate_tracker_updates(issue, registry, result, checkpoint_id) do
    case Tracker.create_comment(issue.id, render_issue_result_comment(issue, result)) do
      :ok ->
        case Tracker.update_issue_state(issue.id, workflow_terminal_state()) do
          :ok ->
            case maybe_close_root_issue(registry, issue.id) do
              :ok ->
                {:ok, {:completed, issue.id}}

              {:error, reason} ->
                retry_controller(issue.id, reason, "close_root_issue", %{
                  "checkpoint_id" => checkpoint_id
                })
            end

          {:error, reason} ->
            retry_controller(issue.id, reason, "update_issue_state", %{
              "checkpoint_id" => checkpoint_id
            })
        end

      {:error, reason} ->
        retry_controller(issue.id, reason, "create_issue_result_comment", %{
          "checkpoint_id" => checkpoint_id
        })
    end
  end

  defp save_registry(registry) do
    Registry.save!(registry)
  rescue
    error -> {:error, {:registry_save_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:registry_save_failed, {kind, reason}}}
  end

  defp controller_git_failure(issue_id, reason, operation, context) do
    if retryable_git_error?(reason) do
      retry_controller(issue_id, reason, operation, context)
    else
      needs_human(issue_id, "Git 操作 #{operation} 无法安全完成：#{inspect(reason)}")
    end
  end

  defp retryable_git_error?({reason, _detail})
       when reason in [
              :git_remote_unavailable,
              :git_push_failed,
              :git_command_failed,
              :workspace_command_timeout,
              :workspace_hook_timeout
            ],
       do: true

  defp retryable_git_error?({reason, _context, _detail})
       when reason in [:git_fetch_failed, :git_command_failed],
       do: true

  defp retryable_git_error?(_reason), do: false

  defp retry_controller(issue_id, reason, operation, context) do
    retry_reason =
      case reason do
        {name, _context, _detail} when is_atom(name) -> name
        {name, _detail} when is_atom(name) -> name
        name when is_atom(name) -> name
        _other -> :controller_operation_failed
      end

    retry_context =
      context
      |> Map.put("operation", operation)
      |> Map.put("error", inspect(reason))

    {:ok, {:retry_controller, issue_id, retry_reason, retry_context}}
  end

  defp apply_review_result(issue, workspace, registry, node_key, node, result, opts) do
    if result["outcome"] == "pass" do
      complete_regular_review(issue, workspace, registry, node_key, node, result, opts)
    else
      case apply_issue_result(issue, result) do
        {:ok, _outcome} = ok ->
          case Tracker.create_comment(issue.id, render_issue_result_comment(issue, result)) do
            :ok -> ok
            {:error, reason} -> {:error, reason}
          end

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp complete_regular_review(issue, workspace, registry, node_key, node, result, opts) do
    worker_host = Keyword.get(opts, :worker_host)

    updated_registry =
      registry
      |> put_node_issue_result(node_key, result)
      |> put_node_status(node_key, "completed")
      |> accept_review_subject(node)
      |> Registry.put_review_state(
        node_key,
        review_state(result, "accepted", node["subject_id"])
      )
      |> unlock_ready_nodes()
      |> maybe_complete_registry()

    persist_candidate_completion(
      issue,
      workspace,
      worker_host,
      updated_registry,
      result,
      "#{node_key}:review"
    )
  end

  defp apply_final_review_result(issue, workspace, registry, node_key, node, result, opts) do
    worker_host = Keyword.get(opts, :worker_host)
    subject = get_in(registry, ["subjects", node["subject_id"]]) || %{}

    with {:ok, current_target_sha} <-
           GitAdapter.fetch_ref(
             workspace,
             worker_host,
             registry["remote"],
             registry["target_branch"]
           ),
         {:ok, current_candidate_sha} <-
           GitAdapter.fetch_ref(
             workspace,
             worker_host,
             registry["remote"],
             registry["candidate_branch"]
           ) do
      cond do
        subject["candidate_sha"] == current_candidate_sha and
            current_target_sha == current_candidate_sha ->
          record_final_publication(
            issue,
            registry,
            node_key,
            node,
            result,
            subject,
            current_target_sha
          )

        subject["candidate_sha"] != current_candidate_sha ->
          stale_final_review(
            issue,
            workspace,
            worker_host,
            registry,
            node_key,
            node,
            result,
            subject,
            current_target_sha,
            current_candidate_sha,
            :candidate_changed
          )

        subject["target_sha"] != current_target_sha ->
          stale_final_review(
            issue,
            workspace,
            worker_host,
            registry,
            node_key,
            node,
            result,
            subject,
            current_target_sha,
            current_candidate_sha,
            :target_changed
          )

        true ->
          validate_final_review_publication(
            issue,
            workspace,
            worker_host,
            registry,
            node_key,
            node,
            result,
            subject,
            current_target_sha,
            current_candidate_sha
          )
      end
    else
      {:error, reason} ->
        retry_controller(issue.id, reason, "fetch_final_review_refs", %{
          "node_key" => node_key,
          "subject_id" => node["subject_id"]
        })
    end
  end

  defp validate_final_review_publication(
         issue,
         workspace,
         worker_host,
         registry,
         node_key,
         node,
         result,
         subject,
         current_target_sha,
         current_candidate_sha
       ) do
    case GitAdapter.ancestor?(
           workspace,
           worker_host,
           current_target_sha,
           current_candidate_sha
         ) do
      {:ok, true} ->
        publish_reviewed_candidate(
          issue,
          workspace,
          worker_host,
          registry,
          node_key,
          node,
          result,
          subject
        )

      {:ok, false} ->
        stale_final_review(
          issue,
          workspace,
          worker_host,
          registry,
          node_key,
          node,
          result,
          subject,
          current_target_sha,
          current_candidate_sha,
          :target_not_in_candidate
        )

      {:error, reason} ->
        retry_controller(issue.id, reason, "validate_final_review_ancestry", %{
          "node_key" => node_key,
          "target_sha" => current_target_sha,
          "candidate_sha" => current_candidate_sha
        })
    end
  end

  defp publish_reviewed_candidate(
         issue,
         workspace,
         worker_host,
         registry,
         node_key,
         node,
         result,
         subject
       ) do
    expected_candidate_sha = subject["candidate_sha"]

    case GitAdapter.compare_and_swap_ref(
           workspace,
           worker_host,
           registry["remote"],
           registry["target_branch"],
           subject["target_sha"],
           subject["candidate_sha"]
         ) do
      {:ok, published_sha} when published_sha == expected_candidate_sha ->
        record_final_publication(
          issue,
          registry,
          node_key,
          node,
          result,
          subject,
          published_sha
        )

      {:ok, published_sha} ->
        retry_controller(issue.id, {:remote_ref_mismatch, subject["candidate_sha"], published_sha}, "publish_target", %{
          "node_key" => node_key
        })

      {:error, {:stale_remote_ref, _detail}} ->
        refresh_stale_final_review(
          issue,
          workspace,
          worker_host,
          registry,
          node_key,
          node,
          result,
          subject
        )

      {:error, reason} ->
        controller_git_failure(issue.id, reason, "publish_target", %{
          "node_key" => node_key,
          "target_sha" => subject["target_sha"],
          "candidate_sha" => subject["candidate_sha"]
        })
    end
  end

  defp refresh_stale_final_review(
         issue,
         workspace,
         worker_host,
         registry,
         node_key,
         node,
         result,
         subject
       ) do
    with {:ok, current_target_sha} <-
           GitAdapter.fetch_ref(
             workspace,
             worker_host,
             registry["remote"],
             registry["target_branch"]
           ),
         {:ok, current_candidate_sha} <-
           GitAdapter.fetch_ref(
             workspace,
             worker_host,
             registry["remote"],
             registry["candidate_branch"]
           ) do
      if subject["candidate_sha"] == current_candidate_sha and
           current_target_sha == current_candidate_sha do
        record_final_publication(
          issue,
          registry,
          node_key,
          node,
          result,
          subject,
          current_target_sha
        )
      else
        stale_final_review(
          issue,
          workspace,
          worker_host,
          registry,
          node_key,
          node,
          result,
          subject,
          current_target_sha,
          current_candidate_sha,
          :target_changed_during_publication
        )
      end
    else
      {:error, reason} ->
        retry_controller(issue.id, reason, "refresh_final_review_refs", %{
          "node_key" => node_key
        })
    end
  end

  defp record_final_publication(
         issue,
         registry,
         node_key,
         node,
         result,
         subject,
         published_sha
       ) do
    checkpoint_id = "publication:#{registry["target_branch"]}:#{published_sha}"

    updated_registry =
      registry
      |> Registry.add_checkpoint_once(%{
        "id" => checkpoint_id,
        "kind" => "publication",
        "node_key" => node_key,
        "expected_target_sha" => subject["target_sha"],
        "published_target_sha" => published_sha
      })
      |> put_node_issue_result(node_key, result)
      |> put_node_status(node_key, "completed")
      |> accept_review_subject(node)
      |> Registry.put_review_state(
        node_key,
        review_state(result, "accepted", node["subject_id"])
      )
      |> Registry.put_publication(%{
        "status" => "published",
        "reviewed_candidate_sha" => subject["candidate_sha"],
        "expected_target_sha" => subject["target_sha"],
        "published_target_sha" => published_sha
      })
      |> maybe_complete_registry()

    case save_registry(updated_registry) do
      :ok ->
        persist_candidate_tracker_updates(issue, updated_registry, result, checkpoint_id)

      {:error, reason} ->
        retry_controller(issue.id, reason, "save_publication_checkpoint", %{
          "checkpoint_id" => checkpoint_id
        })
    end
  end

  defp stale_final_review(
         issue,
         workspace,
         worker_host,
         registry,
         node_key,
         node,
         result,
         subject,
         current_target_sha,
         current_candidate_sha,
         reason
       ) do
    with {:ok, root_issue} <- fetch_root_issue(registry),
         {:ok, %Issue{} = replacement_issue} <-
           Tracker.create_issue(
             %{
               title: "重新执行最终审查",
               description:
                 replacement_final_review_description(
                   registry,
                   reason,
                   current_target_sha,
                   current_candidate_sha
                 ),
               state: "Todo",
               assignee_id: root_issue.assignee_id,
               labels: inherited_labels(root_issue)
             }
             |> Map.merge(issue_tracker_context(root_issue))
           ) do
      replacement_node_key = next_numbered_node_key(registry, "final_review-retry")

      stale_registry =
        registry
        |> put_in(["subjects", node["subject_id"], "status"], "stale")
        |> Registry.put_review_state(
          node_key,
          review_state(result, "stale", node["subject_id"])
        )
        |> update_in(["nodes", node_key], fn old_node ->
          old_node
          |> Map.put("status", "superseded")
          |> Map.put("workflow_semantics", "superseded")
          |> Map.put("stale_reason", Atom.to_string(reason))
          |> Map.put("issue_result", result)
        end)
        |> Registry.put_node(replacement_node_key, %{
          "node_key" => replacement_node_key,
          "issue_id" => replacement_issue.id,
          "issue_identifier" => replacement_issue.identifier,
          "agent_id" => node["agent_id"],
          "task_type" => "review",
          "workflow_semantics" => "executable",
          "status" => "waiting",
          "dependencies" => node["dependencies"] || [],
          "reviews" => ["__root_candidate__"],
          "subject_selector" => %{"type" => "final_candidate_range"},
          "instructions" => node["instructions"],
          "title" => replacement_issue.title,
          "replaces" => node_key
        })
        |> Registry.put_publication(%{"status" => "pending"})
        |> Registry.put_status("planning_complete", %{})

      case prepare_ready_final_reviews(stale_registry, workspace, worker_host) do
        {:ok, prepared_registry} ->
          case save_registry(prepared_registry) do
            :ok ->
              close_stale_final_review_issue(issue, result)

            {:error, save_reason} ->
              retry_controller(issue.id, save_reason, "save_stale_final_review", %{
                "node_key" => node_key,
                "replacement_node_key" => replacement_node_key
              })
          end

        {:retry, retry_reason, operation, context} ->
          retry_controller(issue.id, retry_reason, operation, context)
      end
    else
      {:error, stale_error} ->
        retry_controller(issue.id, stale_error, "replace_stale_final_review", %{
          "node_key" => node_key,
          "subject_id" => subject["id"] || node["subject_id"]
        })
    end
  end

  defp close_stale_final_review_issue(issue, result) do
    with :ok <- Tracker.create_comment(issue.id, render_issue_result_comment(issue, result)),
         :ok <- Tracker.update_issue_state(issue.id, workflow_terminal_state()) do
      {:ok, {:completed, issue.id}}
    else
      {:error, reason} ->
        retry_controller(issue.id, reason, "close_stale_final_review", %{})
    end
  end

  defp replacement_final_review_description(
         registry,
         reason,
         current_target_sha,
         current_candidate_sha
       ) do
    """
    Root issue: #{registry["root_issue_identifier"]}
    Previous final review is stale: #{reason}
    Current target SHA: #{current_target_sha}
    Current candidate SHA: #{current_candidate_sha}

    仅审查 Controller 新生成的 final candidate subject，不修改仓库或共享引用。
    """
    |> String.trim()
  end

  defp needs_human(issue_id, reason) when is_binary(issue_id) and is_binary(reason) do
    {:ok, {:needs_human, issue_id, reason}}
  end

  defp allowed_control_paths(workspace) do
    [Path.relative_to(Artifacts.issue_result_path(workspace), workspace)]
  end

  defp render_issue_result_comment(issue, result) do
    """
    ## Issue Result

    Issue: #{issue.identifier}
    Node: #{result["node_key"]}
    Task type: #{result["task_type"]}
    Outcome: #{result["outcome"]}
    Summary: #{result["summary"]}

    Evidence:
    #{format_list(result["evidence"] || [])}

    Decisions:
    #{format_list(result["decisions"] || [])}

    Open questions:
    #{format_list(result["open_questions"] || [])}
    """
    |> String.trim()
  end

  defp apply_issue_result(%Issue{} = issue, %{"task_type" => "review", "outcome" => "pass"} = result) do
    case Registry.load_by_issue_id(issue.id) do
      {:ok, registry, node_key, node} ->
        updated_registry =
          registry
          |> put_node_issue_result(node_key, result)
          |> put_node_status(node_key, "completed")
          |> accept_review_subject(node)
          |> Registry.put_review_state(
            node_key,
            review_state(result, "accepted", node["subject_id"])
          )
          |> unlock_ready_nodes()
          |> maybe_complete_registry()

        with :ok <- Registry.save!(updated_registry),
             :ok <- Tracker.update_issue_state(issue.id, workflow_terminal_state()),
             :ok <- maybe_close_root_issue(updated_registry, issue.id) do
          {:ok, {:completed, issue.id}}
        end

      {:error, :not_found} ->
        {:ok, {:completed, issue.id}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_issue_result(%Issue{} = issue, %{"task_type" => "review"} = result) do
    outcome = review_result_to_outcome(result)

    with :ok <- maybe_apply_review_registry_update(issue, outcome) do
      apply_review_outcome(issue, outcome)
    end
  end

  defp apply_issue_result(%Issue{} = issue, result) do
    case Registry.load_by_issue_id(issue.id) do
      {:ok, registry, node_key, _node} ->
        updated_registry =
          registry
          |> put_node_issue_result(node_key, result)
          |> put_node_status(node_key, "completed")
          |> unlock_ready_nodes()
          |> maybe_complete_registry()

        with :ok <- Registry.save!(updated_registry),
             :ok <- Tracker.update_issue_state(issue.id, workflow_terminal_state()),
             :ok <- maybe_close_root_issue(updated_registry, issue.id) do
          {:ok, {:completed, issue.id}}
        end

      {:error, :not_found} ->
        {:ok, {:completed, issue.id}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp review_state(result, status, subject_id) do
    state = %{
      "decision" => result["outcome"],
      "status" => status,
      "summary" => result["summary"],
      "reviews" => result["reviews"] || [],
      "decided_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    if is_binary(subject_id), do: Map.put(state, "subject_id", subject_id), else: state
  end

  defp accept_review_subject(registry, %{"subject_id" => subject_id}) when is_binary(subject_id) do
    update_in(registry, ["subjects", subject_id], fn
      %{} = subject -> Map.put(subject, "status", "accepted")
      subject -> subject
    end)
  end

  defp accept_review_subject(registry, _node), do: registry

  defp review_result_to_outcome(result) do
    %{
      "decision" => result["outcome"],
      "summary" => result["summary"],
      "reason" => result["reason"],
      "requested_input" => result["requested_input"],
      "confidence" => result["confidence"] || "not_applicable",
      "reviews" => result["reviews"] || [],
      "issue_result" => result
    }
  end

  defp apply_review_outcome(%Issue{} = issue, %{"decision" => "pass"}) do
    {:ok, {:pass, issue.id}}
  end

  defp apply_review_outcome(%Issue{} = issue, %{"decision" => "needs_human", "summary" => summary}) do
    {:ok, {:needs_human, issue.id, summary}}
  end

  defp apply_review_outcome(%Issue{} = issue, %{"decision" => "needs_replan", "summary" => summary}) do
    {:ok, {:needs_replan, issue.id, summary}}
  end

  defp apply_review_outcome(%Issue{} = issue, %{"decision" => "needs_rework", "summary" => summary}) do
    {:ok, {:needs_rework, issue.id, summary}}
  end

  defp apply_review_outcome(%Issue{} = issue, %{"decision" => "fail", "summary" => summary}) do
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
        target_key = review_rework_target_node_key(registry, node_key, decision)
        target_node = Registry.node(registry, target_key) || node
        review_node_key = if target_key == node_key, do: nil, else: node_key

        materialize_rework_issue(registry, target_key, target_node, issue, decision, review_node_key)

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

  defp maybe_apply_review_registry_update(%Issue{} = issue, %{"decision" => "needs_human"} = decision) do
    case Registry.load_by_issue_id(issue.id) do
      {:ok, registry, node_key, _node} ->
        registry
        |> mark_registry_blocked_by_review(node_key, decision)
        |> Registry.save!()

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_apply_review_registry_update(%Issue{} = issue, %{"decision" => "fail"} = decision) do
    case Registry.load_by_issue_id(issue.id) do
      {:ok, registry, node_key, _node} ->
        registry
        |> mark_registry_failed_by_review(node_key, decision)
        |> Registry.save!()

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_apply_review_registry_update(_issue, _decision), do: :ok

  defp review_rework_target_node_key(registry, fallback_node_key, %{"reviews" => [reviewed_node_key | []]})
       when is_binary(reviewed_node_key) do
    if reviewed_node_key != "__root_candidate__" and Registry.node(registry, reviewed_node_key) do
      reviewed_node_key
    else
      fallback_node_key
    end
  end

  defp review_rework_target_node_key(_registry, fallback_node_key, _decision), do: fallback_node_key

  defp mark_registry_for_replanning(registry, node_key, %Issue{} = issue, decision) do
    registry
    |> Registry.put_status("replanning", %{
      "replan_request" => decision["summary"],
      "replan_source_node_key" => node_key,
      "replan_source_issue_id" => issue.id,
      "replan_source_issue_identifier" => issue.identifier
    })
    |> supersede_unfinished_executable_nodes_for_replan(decision)
  end

  defp mark_registry_blocked_by_review(registry, node_key, decision) do
    registry
    |> put_node_review_outcome(node_key, "blocked", decision)
    |> Registry.put_status("blocked", %{
      "blocked_reason" => decision["summary"],
      "human_input_request" => decision["requested_input"] || decision["reason"]
    })
  end

  defp mark_registry_failed_by_review(registry, node_key, decision) do
    registry
    |> put_node_review_outcome(node_key, "failed", decision)
    |> Registry.put_status("failed", %{"failure_reason" => decision["summary"]})
  end

  defp put_node_review_outcome(registry, node_key, status, decision) do
    update_in(registry, ["nodes", node_key], fn
      %{} = node ->
        node
        |> Map.put("status", status)
        |> Map.put("review_summary", decision["summary"])
        |> maybe_put_issue_result(decision["issue_result"])

      node ->
        node
    end)
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

  defp materialize_rework_issue(registry, node_key, node, issue, decision, review_node_key) do
    rework_key = next_rework_node_key(registry, node_key)
    title = rework_issue_title(node, issue)
    description = rework_issue_description(registry, node_key, node, issue, decision)
    review_node = review_node(registry, review_node_key)

    with {:ok, %Issue{} = rework_issue} <-
           Tracker.create_issue(
             %{
               title: title,
               description: description,
               state: "Todo",
               assignee_id: issue.assignee_id,
               labels: inherited_labels(issue)
             }
             |> Map.merge(issue_tracker_context(issue))
           ),
         {:ok, replacement_review} <-
           maybe_create_replacement_final_review_issue(
             registry,
             review_node_key,
             review_node,
             rework_issue,
             issue,
             decision
           ) do
      dependencies = node["dependencies"] || []
      downstream_source_key = review_node_key || node_key

      updated_registry =
        registry
        |> supersede_node(node_key, rework_key, decision)
        |> maybe_supersede_review_node(review_node_key, rework_key, decision)
        |> put_rework_node(rework_key, node_key, node, rework_issue, decision, dependencies)
        |> rewire_downstream_dependencies(downstream_source_key, rework_key)
        |> rewire_downstream_edges(downstream_source_key, rework_key)
        |> Registry.add_edge(%{
          "from" => downstream_source_key,
          "to" => rework_key,
          "kind" => "rework",
          "handoff_summary" => decision["summary"]
        })
        |> maybe_put_replacement_final_review_node(replacement_review, rework_key, decision)
        |> maybe_add_replacement_final_review_edge(rework_key, replacement_review, decision)
        |> Registry.put_status("planning_complete", %{})

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

  defp review_node(registry, review_node_key) when is_binary(review_node_key), do: Registry.node(registry, review_node_key)
  defp review_node(_registry, _review_node_key), do: nil

  defp maybe_create_replacement_final_review_issue(
         registry,
         review_node_key,
         review_node,
         %Issue{} = rework_issue,
         %Issue{} = issue,
         decision
       ) do
    if replacement_final_review_needed?(review_node_key, review_node) do
      replacement_key = next_rework_node_key(registry, review_node_key)

      case Tracker.create_issue(
             %{
               title: replacement_final_review_issue_title(review_node),
               description:
                 replacement_final_review_issue_description(
                   registry,
                   review_node_key,
                   review_node,
                   rework_issue,
                   decision
                 ),
               state: "Todo",
               assignee_id: issue.assignee_id,
               labels: inherited_labels(issue)
             }
             |> Map.merge(issue_tracker_context(issue))
           ) do
        {:ok, %Issue{} = replacement_issue} ->
          {:ok, %{key: replacement_key, issue: replacement_issue, node: review_node}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, nil}
    end
  end

  defp replacement_final_review_needed?(_review_node_key, nil), do: false

  defp replacement_final_review_needed?("final_review", %{"task_type" => "review"}), do: true

  defp replacement_final_review_needed?(_review_node_key, %{
         "task_type" => "review",
         "subject_selector" => %{"type" => "final_candidate_range"}
       }),
       do: true

  defp replacement_final_review_needed?(_review_node_key, %{"task_type" => "review", "reviews" => ["__root_candidate__"]}),
    do: true

  defp replacement_final_review_needed?(_review_node_key, _review_node), do: false

  defp replacement_final_review_issue_title(%{"title" => title}) when is_binary(title) and title != "",
    do: "返工后：#{title}"

  defp replacement_final_review_issue_title(_review_node), do: "返工后最终审查"

  defp replacement_final_review_issue_description(registry, review_node_key, review_node, rework_issue, decision) do
    """
    Root issue: #{registry["root_issue_identifier"]}
    Rework issue: #{rework_issue.identifier}
    Replacement review of node: #{review_node_key}
    Reviews: #{format_list(review_node["reviews"] || ["__root_candidate__"])}

    Review summary that triggered rework:
    #{decision["summary"]}

    Original review instructions:
    #{review_node["instructions"] || review_node["title"] || "-"}
    """
    |> String.trim()
  end

  defp inherited_labels(%Issue{} = issue) do
    issue
    |> Issue.label_names()
    |> Kernel.++(Config.settings!().tracker.required_labels)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&String.downcase/1)
  end

  defp issue_tracker_context(%Issue{} = issue) do
    %{
      project_id: issue.project_id,
      project_slug: issue.project_slug,
      project_name: issue.project_name,
      team_id: issue.team_id,
      team_key: issue.team_key,
      team_name: issue.team_name
    }
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp blank?(value), do: is_nil(value) or value == ""

  defp non_blank?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_blank?(_value), do: false

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
    result = node["issue_result"] || %{}

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

    Previous issue result summary:
    #{result["summary"] || "-"}

    Previous evidence:
    #{format_list(result["evidence"] || [])}
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
        |> maybe_put_issue_result(decision["issue_result"])

      node ->
        node
    end)
  end

  defp maybe_supersede_review_node(registry, nil, _rework_key, _decision), do: registry

  defp maybe_supersede_review_node(registry, review_node_key, rework_key, decision) do
    supersede_node(registry, review_node_key, rework_key, decision)
  end

  defp maybe_put_issue_result(node, nil), do: node
  defp maybe_put_issue_result(node, issue_result) when is_map(issue_result), do: Map.put(node, "issue_result", issue_result)
  defp maybe_put_issue_result(node, _issue_result), do: node

  defp maybe_put_replacement_final_review_node(registry, nil, _rework_key, _decision), do: registry

  defp maybe_put_replacement_final_review_node(
         registry,
         %{key: replacement_key, issue: %Issue{} = replacement_issue, node: review_node},
         rework_key,
         decision
       ) do
    Registry.put_node(registry, replacement_key, %{
      "node_key" => replacement_key,
      "issue_id" => replacement_issue.id,
      "issue_identifier" => replacement_issue.identifier,
      "agent_id" => review_node["agent_id"],
      "task_type" => "review",
      "instructions" => replacement_final_review_instructions(review_node, decision),
      "dependencies" => [rework_key],
      "reviews" => review_node["reviews"] || ["__root_candidate__"],
      "subject_selector" => review_node["subject_selector"] || %{"type" => "final_candidate_range"},
      "workflow_semantics" => "executable",
      "status" => readiness_for_existing_dependencies(registry, [rework_key]),
      "title" => replacement_issue.title,
      "rework_of" => review_node["node_key"],
      "review_summary" => decision["summary"]
    })
  end

  defp maybe_add_replacement_final_review_edge(registry, _rework_key, nil, _decision), do: registry

  defp maybe_add_replacement_final_review_edge(registry, rework_key, %{key: replacement_key}, decision) do
    Registry.add_edge(registry, %{
      "from" => rework_key,
      "to" => replacement_key,
      "kind" => "review",
      "handoff_summary" => decision["summary"]
    })
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
      "branch" =>
        private_branch_name(
          registry["root_issue_identifier"],
          rework_issue.identifier
        ),
      "base_candidate_sha" => registry["candidate_head_sha"],
      "rework_of" => original_node_key,
      "review_summary" => decision["summary"],
      "previous_issue_result" => original_node["issue_result"]
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

  defp replacement_final_review_instructions(review_node, decision) do
    """
    根据返工结果重新执行最终审查。

    触发返工的审查意见：
    #{decision["summary"]}

    原审查说明：
    #{review_node["instructions"] || review_node["title"] || "-"}
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

  defp put_node_issue_result(registry, node_key, result) do
    update_in(registry, ["nodes", node_key], fn
      %{} = node -> Map.put(node, "issue_result", result)
      node -> node
    end)
  end

  defp put_node_status(registry, node_key, status) do
    update_in(registry, ["nodes", node_key], fn
      %{} = node -> Map.put(node, "status", status)
      node -> node
    end)
  end

  defp invalidate_overlapping_subjects(registry, changed_paths) do
    changed_path_set = MapSet.new(changed_paths || [])

    Enum.reduce(registry["subjects"] || %{}, registry, fn {subject_id, subject}, acc ->
      subject_path_set = MapSet.new(subject["paths"] || [])

      if subject["status"] == "accepted" and
           not MapSet.disjoint?(subject_path_set, changed_path_set) do
        acc
        |> put_in(["subjects", subject_id, "status"], "stale")
        |> stale_reviews_for_subject(subject_id)
      else
        acc
      end
    end)
  end

  defp stale_reviews_for_subject(registry, subject_id) do
    review_node_keys =
      registry
      |> Map.get("nodes", %{})
      |> Enum.filter(fn {_node_key, node} -> node["subject_id"] == subject_id end)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    update_in(registry, ["reviews"], fn reviews ->
      Enum.into(reviews || %{}, %{}, fn {review_node_key, review} ->
        if review["subject_id"] == subject_id or MapSet.member?(review_node_keys, review_node_key) do
          {review_node_key, Map.put(review, "status", "stale")}
        else
          {review_node_key, review}
        end
      end)
    end)
  end

  defp maybe_complete_registry(registry) do
    if workflow_completed?(registry) do
      Registry.put_status(registry, "completed", %{})
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

    executable_nodes != [] and Enum.all?(executable_nodes, &completed_status?(&1["status"])) and
      get_in(registry, ["publication", "status"]) == "published" and
      non_blank?(get_in(registry, ["publication", "published_target_sha"]))
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
        if final_review_node?(node) do
          acc
        else
          acc
          |> attach_ready_review_subject(node_key, node)
          |> put_node_status(node_key, "ready")
        end
      else
        acc
      end
    end)
  end

  defp final_review_node?(node) do
    node["task_type"] == "review" and
      (get_in(node, ["subject_selector", "type"]) == "final_candidate_range" or
         "__root_candidate__" in (node["reviews"] || []))
  end

  defp prepare_ready_final_reviews(registry, workspace, worker_host) do
    Enum.reduce_while(registry["nodes"] || %{}, {:ok, registry}, fn {node_key, node}, {:ok, acc} ->
      if node["status"] == "waiting" and final_review_node?(node) and
           dependencies_completed?(acc, node["dependencies"] || []) do
        case prepare_final_review(acc, node_key, node, workspace, worker_host) do
          {:ok, updated_registry} -> {:cont, {:ok, updated_registry}}
          {:retry, _reason, _operation, _context} = retry -> {:halt, retry}
        end
      else
        {:cont, {:ok, acc}}
      end
    end)
  end

  defp prepare_final_review(registry, node_key, node, workspace, worker_host) do
    with {:ok, target_sha} <-
           GitAdapter.fetch_ref(
             workspace,
             worker_host,
             registry["remote"],
             registry["target_branch"]
           ),
         {:ok, candidate_sha} <-
           GitAdapter.fetch_ref(
             workspace,
             worker_host,
             registry["remote"],
             registry["candidate_branch"]
           ),
         {:ok, contains_target?} <-
           GitAdapter.ancestor?(workspace, worker_host, target_sha, candidate_sha) do
      registry = Registry.put_workflow_git(registry, %{"candidate_head_sha" => candidate_sha})

      if contains_target? do
        {:ok, attach_final_subject_and_ready(registry, node_key, target_sha, candidate_sha)}
      else
        materialize_target_sync(registry, node_key, node, target_sha, candidate_sha)
      end
    else
      {:error, reason} ->
        {:retry, reason, "prepare_final_review_git_facts", %{"node_key" => node_key}}
    end
  end

  defp attach_final_subject_and_ready(registry, node_key, target_sha, candidate_sha) do
    subject_id = "#{node_key}:final:#{target_sha}:#{candidate_sha}"

    subject = %{
      "id" => subject_id,
      "type" => "final_candidate_range",
      "branch" => registry["candidate_branch"],
      "target_sha" => target_sha,
      "candidate_sha" => candidate_sha,
      "base_sha" => target_sha,
      "head_sha" => candidate_sha,
      "paths" => all_checkpoint_paths(registry),
      "status" => "pending"
    }

    registry
    |> Registry.put_subject(subject_id, subject)
    |> Registry.put_node_git(node_key, %{"subject_id" => subject_id})
    |> put_node_status(node_key, "ready")
  end

  defp all_checkpoint_paths(registry) do
    (registry["checkpoints"] || [])
    |> Enum.flat_map(&(&1["paths"] || []))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp materialize_target_sync(registry, final_node_key, final_node, target_sha, candidate_sha) do
    with {:ok, root_issue} <- fetch_root_issue(registry),
         {:ok, %Issue{} = sync_issue} <-
           Tracker.create_issue(
             %{
               title: "同步 target 到 candidate",
               description: target_sync_issue_description(registry, target_sha, candidate_sha),
               state: "Todo",
               assignee_id: root_issue.assignee_id,
               labels: inherited_labels(root_issue)
             }
             |> Map.merge(issue_tracker_context(root_issue))
           ) do
      sync_node_key = next_target_sync_node_key(registry)

      updated_registry =
        registry
        |> Registry.put_node(sync_node_key, %{
          "node_key" => sync_node_key,
          "issue_id" => sync_issue.id,
          "issue_identifier" => sync_issue.identifier,
          "agent_id" => nil,
          "task_type" => "integration",
          "workflow_semantics" => "executable",
          "status" => "ready",
          "dependencies" => final_node["dependencies"] || [],
          "instructions" => target_sync_instructions(target_sha, candidate_sha),
          "title" => sync_issue.title,
          "branch" => private_branch_name(registry["root_issue_identifier"], sync_issue.identifier),
          "base_candidate_sha" => candidate_sha,
          "target_sha" => target_sha,
          "integration_purpose" => "target_sync"
        })
        |> Registry.add_edge(%{
          "from" => sync_node_key,
          "to" => final_node_key,
          "kind" => "target_sync"
        })
        |> update_in(["nodes", final_node_key], fn node ->
          node
          |> Map.put("status", "waiting")
          |> Map.put("dependencies", [sync_node_key])
          |> Map.delete("subject_id")
        end)
        |> Registry.put_status("planning_complete", %{})

      {:ok, updated_registry}
    else
      {:error, reason} ->
        {:retry, reason, "materialize_target_sync",
         %{
           "final_node_key" => final_node_key,
           "target_sha" => target_sha,
           "candidate_sha" => candidate_sha
         }}
    end
  end

  defp fetch_root_issue(registry) do
    case Tracker.fetch_issue_states_by_ids([registry["root_issue_id"]]) do
      {:ok, [%Issue{} = root_issue | _rest]} -> {:ok, root_issue}
      {:ok, []} -> {:error, :root_issue_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp next_target_sync_node_key(registry) do
    next_numbered_node_key(registry, "target_sync")
  end

  defp next_numbered_node_key(registry, prefix) do
    existing_keys = registry |> Map.get("nodes", %{}) |> Map.keys() |> MapSet.new()

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(&"#{prefix}-#{&1}")
    |> Enum.find(&(not MapSet.member?(existing_keys, &1)))
  end

  defp target_sync_issue_description(registry, target_sha, candidate_sha) do
    """
    Root issue: #{registry["root_issue_identifier"]}
    Task type: integration
    Purpose: target_sync
    Target SHA: #{target_sha}
    Candidate SHA: #{candidate_sha}

    将指定 target 合入当前 candidate，在私有分支解决冲突、运行验证并提交结果。
    """
    |> String.trim()
  end

  defp target_sync_instructions(target_sha, candidate_sha) do
    """
    从 candidate #{candidate_sha} 开始，将 target #{target_sha} 合入当前私有分支。
    解决冲突、运行受影响验证、提交完整结果，并更新 issue_result.json。
    不得直接更新共享 candidate 或 target 引用。
    """
    |> String.trim()
  end

  defp attach_ready_review_subject(registry, node_key, node) do
    cond do
      not ordinary_review_node?(node) ->
        registry

      valid_node_subject?(registry, node) ->
        registry

      true ->
        checkpoints = checkpoints_for_reviewed_nodes(registry, node["reviews"] || [])
        base_sha = first_checkpoint_base_sha(checkpoints, registry["candidate_head_sha"])
        head_sha = registry["candidate_head_sha"]
        subject_id = "#{node_key}:candidate:#{base_sha}:#{head_sha}"

        subject = %{
          "id" => subject_id,
          "type" => "candidate_range",
          "branch" => registry["candidate_branch"],
          "base_sha" => base_sha,
          "head_sha" => head_sha,
          "paths" =>
            checkpoints
            |> Enum.flat_map(&(&1["paths"] || []))
            |> Enum.uniq()
            |> Enum.sort(),
          "status" => "pending"
        }

        registry
        |> Registry.put_subject(subject_id, subject)
        |> Registry.put_node_git(node_key, %{"subject_id" => subject_id})
    end
  end

  defp ordinary_review_node?(node) do
    node["task_type"] == "review" and
      get_in(node, ["subject_selector", "type"]) != "final_candidate_range" and
      "__root_candidate__" not in (node["reviews"] || [])
  end

  defp valid_node_subject?(registry, %{"subject_id" => subject_id}) when is_binary(subject_id) do
    is_map(get_in(registry, ["subjects", subject_id]))
  end

  defp valid_node_subject?(_registry, _node), do: false

  defp checkpoints_for_reviewed_nodes(registry, reviewed_node_keys) do
    Enum.flat_map(reviewed_node_keys, fn reviewed_node_key ->
      with %{} = reviewed_node <- Registry.node(registry, reviewed_node_key),
           checkpoint_id when is_binary(checkpoint_id) <- reviewed_node["checkpoint_id"],
           %{} = checkpoint <-
             Enum.find(registry["checkpoints"] || [], &(&1["id"] == checkpoint_id)) do
        [checkpoint]
      else
        _missing -> []
      end
    end)
  end

  defp first_checkpoint_base_sha(checkpoints, fallback_sha) do
    Enum.find_value(checkpoints, fallback_sha, & &1["candidate_before_sha"])
  end

  defp node_description(root_issue, node, dependencies, handoffs, plan) do
    completion_conditions = node["completion_conditions"] || []

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

    Completion conditions:
    #{format_list(completion_conditions)}

    Handoff:
    #{format_list(handoffs)}

    Evidence expectations:
    #{format_list(node["evidence_expectations"] || [])}
    """
    |> String.trim()
  end

  defp render_plan_comment(root_issue, plan, registry) do
    edges = registry["edges"] || []
    dependency_map = dependency_map(edges)

    derived_lines =
      registry["nodes"]
      |> Enum.reject(fn {node_key, _node} -> node_key == "root" end)
      |> Enum.map(fn {node_key, node} ->
        deps = Map.get(dependency_map, node_key, [])

        dep_info =
          case deps do
            [] -> " (no dependencies)"
            _ -> " (depends on: #{Enum.join(deps, ", ")})"
          end

        conditions = node["completion_conditions"] || []

        cond_info =
          case conditions do
            [] -> ""
            _ -> " (completion: #{Enum.join(conditions, "; ")})"
          end

        "- #{node_key}: #{node["issue_identifier"]} #{node["task_type"]} #{node["status"]}#{dep_info}#{cond_info}"
      end)
      |> Enum.join("\n")

    edge_lines =
      case edges do
        [] ->
          ""

        _ ->
          formatted_edges =
            edges
            |> Enum.map(fn edge ->
              from = edge["from"] || edge[:from]
              to = edge["to"] || edge[:to]
              "- #{from} -> #{to}"
            end)
            |> Enum.join("\n")

          "\n\nDependencies (edges):\n#{formatted_edges}"
      end

    """
    ## 规划摘要

    Root issue: #{root_issue.identifier}
    Root issue id: #{root_issue.id}
    Plan kind: #{plan["kind"]}
    Summary: #{plan["summary"]}

    Derived issues:
    #{derived_lines}#{edge_lines}
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
      "upstream_results" => upstream_results(registry, node),
      "upstream_workspaces" => upstream_workspaces(registry, node),
      "evidence_expectations" => node["evidence_expectations"] || [],
      "issue_identifier" => node["issue_identifier"],
      "rework_of" => node["rework_of"],
      "review_summary" => node["review_summary"],
      "previous_issue_result" => node["previous_issue_result"],
      "completion_continuation" => node["continuation"],
      "remote" => registry["remote"],
      "target_branch" => registry["target_branch"],
      "candidate_branch" => registry["candidate_branch"],
      "candidate_head_sha" => registry["candidate_head_sha"],
      "branch" => node["branch"],
      "base_candidate_sha" => node["base_candidate_sha"],
      "target_sha" => node["target_sha"],
      "subject" => get_in(registry, ["subjects", node["subject_id"]])
    }
  end

  defp root_workspace_for_registry(registry), do: Registry.root_workspace_path(registry)

  defp upstream_results(registry, node) when is_map(registry) and is_map(node) do
    node
    |> Map.get("dependencies", [])
    |> Enum.flat_map(fn dependency ->
      case Registry.node(registry, dependency) do
        %{"issue_result" => result} = upstream_node when is_map(result) ->
          [
            result
            |> Map.put_new("node_key", upstream_node["node_key"] || dependency)
            |> Map.put_new("issue_identifier", upstream_node["issue_identifier"])
          ]

        _ ->
          []
      end
    end)
  end

  defp upstream_results(_registry, _node), do: []

  defp upstream_workspaces(registry, node) when is_map(registry) and is_map(node) do
    node
    |> Map.get("dependencies", [])
    |> Enum.flat_map(fn dependency ->
      case Registry.node(registry, dependency) do
        %{} = upstream_node ->
          upstream_workspace(dependency, upstream_node)

        _ ->
          []
      end
    end)
  end

  defp upstream_workspaces(_registry, _node), do: []

  defp upstream_workspace(dependency, upstream_node) do
    issue_identifier = upstream_node["issue_identifier"]
    workspace = Registry.issue_workspace_path(issue_identifier)

    if is_binary(issue_identifier) and is_binary(workspace) do
      [
        %{
          "node_key" => upstream_node["node_key"] || dependency,
          "issue_id" => upstream_node["issue_id"],
          "issue_identifier" => issue_identifier,
          "workspace" => workspace
        }
      ]
    else
      []
    end
  end

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
