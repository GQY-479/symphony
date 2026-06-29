defmodule SymphonyElixir.Workflow.Artifacts do
  @moduledoc """
  工作流规划、完成与审查产物的路径和最小结构校验。
  """

  alias SymphonyElixir.Config

  @workflow_plan_filename "workflow_plan.json"
  @issue_result_filename "issue_result.json"
  @review_outcomes MapSet.new(["pass", "needs_rework", "needs_replan", "needs_human", "fail"])

  @spec workflow_plan_path(Path.t()) :: Path.t()
  def workflow_plan_path(workspace), do: artifact_path(workspace, @workflow_plan_filename)

  @spec issue_result_path(Path.t()) :: Path.t()
  def issue_result_path(workspace), do: artifact_path(workspace, @issue_result_filename)

  @spec load_plan(Path.t()) :: {:ok, map()} | {:error, term()}
  def load_plan(workspace), do: load_json(workflow_plan_path(workspace), &validate_plan/1)

  @spec load_workflow_plan(Path.t()) :: {:ok, map()} | {:error, term()}
  def load_workflow_plan(workspace), do: load_plan(workspace)

  @spec load_issue_result(Path.t()) :: {:ok, map()} | {:error, term()}
  def load_issue_result(workspace),
    do: load_json(issue_result_path(workspace), &validate_issue_result/1)

  @spec validate_plan(term()) :: :ok | {:error, :invalid_workflow_plan}
  def validate_plan(%{
        "kind" => "needs_human_input",
        "summary" => summary,
        "confidence" => confidence,
        "request" => request
      })
      when is_binary(summary) and is_binary(confidence) and is_binary(request),
      do: :ok

  def validate_plan(%{
        "mode" => "needs_human_input",
        "summary" => summary,
        "confidence" => confidence,
        "request" => request
      })
      when is_binary(summary) and is_binary(confidence) and is_binary(request),
      do: :ok

  def validate_plan(%{
        "kind" => "issue_graph",
        "summary" => summary,
        "confidence" => confidence,
        "nodes" => nodes,
        "edges" => edges
      })
      when is_binary(summary) and is_binary(confidence) and is_list(nodes) and is_list(edges) do
    with :ok <- validate_plan_nodes(nodes),
         :ok <- validate_plan_edges(edges),
         :ok <- validate_plan_node_keys(nodes),
         :ok <- validate_plan_edge_references(nodes, edges),
         :ok <- validate_plan_final_review(nodes) do
      :ok
    end
  end

  def validate_plan(%{
        "mode" => "issue_graph",
        "summary" => summary,
        "confidence" => confidence,
        "nodes" => nodes,
        "edges" => edges
      })
      when is_binary(summary) and is_binary(confidence) and is_list(nodes) and is_list(edges) do
    with :ok <- validate_plan_nodes(nodes),
         :ok <- validate_plan_edges(edges),
         :ok <- validate_plan_node_keys(nodes),
         :ok <- validate_plan_edge_references(nodes, edges),
         :ok <- validate_plan_final_review(nodes) do
      :ok
    end
  end

  def validate_plan(_plan), do: {:error, :invalid_workflow_plan}

  @spec validate_issue_result(term()) :: :ok | {:error, :invalid_issue_result}
  def validate_issue_result(
        %{
          "schema_version" => 1,
          "node_key" => node_key,
          "task_type" => "review",
          "outcome" => outcome,
          "reviews" => reviews,
          "summary" => summary,
          "evidence" => evidence,
          "decisions" => decisions,
          "open_questions" => open_questions
        } = result
      )
      when is_list(reviews) and is_list(evidence) and is_list(decisions) and is_list(open_questions) do
    cond do
      not non_blank?(node_key) or not non_blank?(summary) ->
        {:error, :invalid_issue_result}

      not MapSet.member?(@review_outcomes, outcome) ->
        {:error, :invalid_issue_result}

      reviews == [] or not Enum.all?(reviews, &non_blank?/1) ->
        {:error, :invalid_issue_result}

      outcome != "pass" and not non_blank?(result["reason"]) ->
        {:error, :invalid_issue_result}

      outcome == "needs_human" and not non_blank?(result["requested_input"]) ->
        {:error, :invalid_issue_result}

      true ->
        :ok
    end
  end

  def validate_issue_result(%{
        "schema_version" => 1,
        "node_key" => node_key,
        "task_type" => task_type,
        "outcome" => outcome,
        "summary" => summary,
        "evidence" => evidence,
        "decisions" => decisions,
        "open_questions" => open_questions
      })
      when is_list(evidence) and is_list(decisions) and is_list(open_questions) do
    if task_type != "review" and non_blank?(node_key) and non_blank?(task_type) and non_blank?(outcome) and
         non_blank?(summary) and evidence != [] do
      :ok
    else
      {:error, :invalid_issue_result}
    end
  end

  def validate_issue_result(_result), do: {:error, :invalid_issue_result}

  defp non_blank?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_blank?(_value), do: false

  defp artifact_path(workspace, filename) when is_binary(workspace) and is_binary(filename) do
    Path.join([workspace, artifact_dir(), filename])
  end

  defp artifact_dir do
    Config.settings!().orchestration.artifact_dir
  end

  defp load_json(path, validator) when is_function(validator, 1) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         :ok <- validator.(decoded) do
      {:ok, decoded}
    else
      {:error, reason} -> {:error, reason}
      other -> other
    end
  end

  defp validate_plan_nodes(nodes) do
    if Enum.all?(nodes, &valid_node?/1) do
      :ok
    else
      {:error, :invalid_workflow_plan}
    end
  end

  defp validate_plan_edges(edges) do
    if Enum.all?(edges, &valid_edge?/1) do
      :ok
    else
      {:error, :invalid_workflow_plan}
    end
  end

  defp validate_plan_node_keys(nodes) do
    node_keys = Enum.map(nodes, & &1["node_key"])

    if Enum.all?(node_keys, &non_blank?/1) and Enum.uniq(node_keys) == node_keys do
      :ok
    else
      {:error, :invalid_workflow_plan}
    end
  end

  defp validate_plan_edge_references(nodes, edges) do
    node_keys = MapSet.new(Enum.map(nodes, & &1["node_key"]))

    if Enum.all?(edges, &valid_edge_references?(&1, node_keys)) do
      :ok
    else
      {:error, :invalid_workflow_plan}
    end
  end

  defp valid_edge_references?(%{"from" => from_node, "to" => to_node}, node_keys),
    do: MapSet.member?(node_keys, from_node) and MapSet.member?(node_keys, to_node)

  defp valid_edge_references?(%{from: from_node, to: to_node}, node_keys),
    do: MapSet.member?(node_keys, from_node) and MapSet.member?(node_keys, to_node)

  defp valid_edge_references?(_edge, _node_keys), do: false

  defp validate_plan_final_review(nodes) do
    case Enum.find(nodes, &(&1["node_key"] == "final_review")) do
      %{"task_type" => "review", "reviews" => ["__root_candidate__"], "subject_selector" => %{"type" => "final_candidate_range"}} ->
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
       when is_binary(task_type) and is_binary(title) and is_binary(goal) and is_binary(agent_id) do
    non_blank?(node_key) and valid_completion_conditions?(node) and valid_review_node?(node)
  end

  defp valid_node?(_node), do: false

  defp valid_completion_conditions?(node) do
    case Map.get(node, "completion_conditions") do
      nil -> true
      conditions when is_list(conditions) -> Enum.all?(conditions, &is_binary/1)
      _ -> false
    end
  end

  defp valid_review_node?(%{"task_type" => "review"} = node) do
    reviews = Map.get(node, "reviews")
    subject_selector = Map.get(node, "subject_selector")

    is_list(reviews) and reviews != [] and Enum.all?(reviews, &non_blank?/1) and
      is_map(subject_selector)
  end

  defp valid_review_node?(_node), do: true

  defp valid_edge?(%{"from" => from_node, "to" => to_node})
       when is_binary(from_node) and is_binary(to_node),
       do: true

  defp valid_edge?(%{from: from_node, to: to_node})
       when is_binary(from_node) and is_binary(to_node),
       do: true

  defp valid_edge?(_edge), do: false
end
