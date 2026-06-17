defmodule SymphonyElixir.Workflow.Artifacts do
  @moduledoc """
  工作流规划、完成与评审文件的路径和最小校验工具。
  """

  alias SymphonyElixir.Config

  @workflow_plan_filename "workflow_plan.json"
  @completion_packet_filename "completion_packet.json"
  @review_decision_filename "review_decision.json"

  @spec workflow_plan_path(Path.t()) :: Path.t()
  def workflow_plan_path(workspace), do: artifact_path(workspace, @workflow_plan_filename)

  @spec completion_packet_path(Path.t()) :: Path.t()
  def completion_packet_path(workspace), do: artifact_path(workspace, @completion_packet_filename)

  @spec review_decision_path(Path.t()) :: Path.t()
  def review_decision_path(workspace), do: artifact_path(workspace, @review_decision_filename)

  @spec load_plan(Path.t()) :: {:ok, map()} | {:error, term()}
  def load_plan(workspace), do: load_json(workflow_plan_path(workspace), &validate_plan/1)

  @spec load_completion_packet(Path.t()) :: {:ok, map()} | {:error, term()}
  def load_completion_packet(workspace), do: load_json(completion_packet_path(workspace), &validate_completion_packet/1)

  @spec load_review_decision(Path.t()) :: {:ok, map()} | {:error, term()}
  def load_review_decision(workspace), do: load_json(review_decision_path(workspace), &validate_review_decision/1)

  @spec validate_plan(term()) :: :ok | {:error, term()}
  def validate_plan(plan) when is_map(plan) do
    case plan_mode(plan) do
      "direct_execution" ->
        :ok

      "issue_graph" ->
        validate_issue_graph_plan(plan)

      _ ->
        {:error, :invalid_workflow_plan}
    end
  end

  def validate_plan(_plan), do: {:error, :invalid_workflow_plan}

  @spec validate_completion_packet(term()) :: :ok | {:error, term()}
  def validate_completion_packet(packet) when is_map(packet) do
    if required_map_keys?(packet, ["outcome", "summary", "evidence"]) do
      :ok
    else
      {:error, :invalid_completion_packet}
    end
  end

  def validate_completion_packet(_packet), do: {:error, :invalid_completion_packet}

  @spec validate_review_decision(term()) :: :ok | {:error, term()}
  def validate_review_decision(decision) when is_map(decision) do
    if required_map_keys?(decision, ["decision", "summary", "confidence"]) do
      :ok
    else
      {:error, :invalid_review_decision}
    end
  end

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
      {:error, reason} -> {:error, {:invalid_json_artifact, path, reason}}
      other -> other
    end
  end

  defp plan_mode(plan) do
    Map.get(plan, "mode") || Map.get(plan, "kind")
  end

  defp validate_issue_graph_plan(plan) do
    with true <- required_map_keys?(plan, ["summary", "confidence", "nodes", "edges"]),
         true <- is_list(Map.get(plan, "nodes")),
         true <- is_list(Map.get(plan, "edges")),
         true <- Enum.all?(Map.get(plan, "nodes"), &valid_issue_graph_node?/1) do
      :ok
    else
      _ -> {:error, :invalid_workflow_plan}
    end
  end

  defp valid_issue_graph_node?(node) when is_map(node) do
    required_map_keys?(node, ["node_key", "task_type", "title", "goal", "agent_id"])
  end

  defp valid_issue_graph_node?(_node), do: false

  defp required_map_keys?(map, keys) when is_map(map) and is_list(keys) do
    Enum.all?(keys, &Map.has_key?(map, &1))
  end
end
