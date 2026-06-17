defmodule SymphonyElixir.Workflow.Artifacts do
  @moduledoc """
  工作流规划、完成与审查产物的路径和最小结构校验。
  """

  alias SymphonyElixir.Config

  @workflow_plan_filename "workflow_plan.json"
  @completion_packet_filename "completion_packet.json"
  @review_decision_filename "review_decision.json"
  @review_decisions ["pass", "needs_rework", "needs_replan", "needs_human", "fail"]

  @spec workflow_plan_path(Path.t()) :: Path.t()
  def workflow_plan_path(workspace), do: artifact_path(workspace, @workflow_plan_filename)

  @spec completion_packet_path(Path.t()) :: Path.t()
  def completion_packet_path(workspace), do: artifact_path(workspace, @completion_packet_filename)

  @spec review_decision_path(Path.t()) :: Path.t()
  def review_decision_path(workspace), do: artifact_path(workspace, @review_decision_filename)

  @spec load_plan(Path.t()) :: {:ok, map()} | {:error, term()}
  def load_plan(workspace), do: load_json(workflow_plan_path(workspace), &validate_plan/1)

  @spec load_workflow_plan(Path.t()) :: {:ok, map()} | {:error, term()}
  def load_workflow_plan(workspace), do: load_plan(workspace)

  @spec load_completion_packet(Path.t()) :: {:ok, map()} | {:error, term()}
  def load_completion_packet(workspace),
    do: load_json(completion_packet_path(workspace), &validate_completion_packet/1)

  @spec load_review_decision(Path.t()) :: {:ok, map()} | {:error, term()}
  def load_review_decision(workspace),
    do: load_json(review_decision_path(workspace), &validate_review_decision/1)

  @spec validate_plan(term()) :: :ok | {:error, :invalid_workflow_plan}
  def validate_plan(%{"kind" => "direct_execution", "summary" => summary, "confidence" => confidence})
      when is_binary(summary) and is_binary(confidence),
      do: :ok

  def validate_plan(%{"mode" => "direct_execution", "summary" => summary, "confidence" => confidence})
      when is_binary(summary) and is_binary(confidence),
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
         :ok <- validate_plan_edges(edges) do
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
    validate_plan_nodes(nodes)
  end

  def validate_plan(_plan), do: {:error, :invalid_workflow_plan}

  @spec validate_completion_packet(term()) :: :ok | {:error, :invalid_completion_packet}
  def validate_completion_packet(%{"outcome" => outcome, "summary" => summary, "evidence" => evidence})
      when is_binary(outcome) and is_binary(summary) and is_list(evidence),
      do: :ok

  def validate_completion_packet(_packet), do: {:error, :invalid_completion_packet}

  @spec validate_review_decision(term()) :: :ok | {:error, :invalid_review_decision}
  def validate_review_decision(%{
        "decision" => decision,
        "summary" => summary,
        "confidence" => confidence
      })
      when decision in @review_decisions and is_binary(summary) and is_binary(confidence),
      do: :ok

  def validate_review_decision(_decision), do: {:error, :invalid_review_decision}

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

  defp valid_node?(%{
         "node_key" => node_key,
         "task_type" => task_type,
         "title" => title,
         "goal" => goal,
         "agent_id" => agent_id
       })
       when is_binary(node_key) and is_binary(task_type) and is_binary(title) and is_binary(goal) and
              is_binary(agent_id),
       do: true

  defp valid_node?(_node), do: false

  defp valid_edge?(%{"from" => from_node, "to" => to_node})
       when is_binary(from_node) and is_binary(to_node),
       do: true

  defp valid_edge?(%{from: from_node, to: to_node})
       when is_binary(from_node) and is_binary(to_node),
       do: true

  defp valid_edge?(_edge), do: false
end
