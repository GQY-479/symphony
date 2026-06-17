defmodule SymphonyElixir.Workflow.Prompts do
  @moduledoc """
  为不同工作流阶段追加固定提示词。
  """

  @review_decisions ["pass", "needs_rework", "needs_replan", "needs_human", "fail"]

  @spec append(String.t(), atom() | nil, map() | nil, Path.t() | nil) :: String.t()
  def append(base_prompt, nil, _context, _workspace), do: base_prompt

  def append(base_prompt, :planning, context, workspace) do
    base_prompt <> planning_prompt(context, workspace)
  end

  def append(base_prompt, :execution, context, workspace) do
    base_prompt <> execution_prompt(context, workspace)
  end

  def append(base_prompt, :review, context, workspace) do
    base_prompt <> review_prompt(context, workspace)
  end

  def append(base_prompt, _phase, _context, _workspace), do: base_prompt

  defp planning_prompt(context, workspace) do
    replan_context = replan_context(context_map(context))

    """

    规划阶段附加要求:

    - 生成或更新 `workflow_plan.json`。
    - 规划结果必须覆盖 `direct_execution` 和 `issue_graph` 两种路径。
    - 若使用 `issue_graph`，确保图中能够表达当前工作拆解与依赖关系。
    #{replan_context}
    - 工作区: #{workspace_text(workspace)}
    """
  end

  defp execution_prompt(context, workspace) do
    upstream_summaries =
      context
      |> context_map()
      |> upstream_packets()
      |> Enum.map_join("\n", fn packet ->
        summary = Map.get(packet, "summary") || Map.get(packet, :summary) || ""
        "- #{summary}"
      end)

    """

    执行阶段附加要求:

    - 生成或更新 `completion_packet.json`。
    - 上游摘要:
    #{upstream_summaries}
    - 工作区: #{workspace_text(workspace)}
    """
  end

  defp review_prompt(_context, workspace) do
    """

    审查阶段附加要求:

    - 生成或更新 `review_decision.json`。
    - 允许的 decision 集合: #{Enum.join(@review_decisions, ", ")}。
    - 工作区: #{workspace_text(workspace)}
    """
  end

  defp context_map(context) when is_map(context), do: context
  defp context_map(_context), do: %{}

  defp upstream_packets(context) when is_map(context) do
    Map.get(context, :upstream_packets) || Map.get(context, "upstream_packets") || []
  end

  defp replan_context(context) when is_map(context) do
    reason = Map.get(context, :replan_reason) || Map.get(context, "replan_reason")
    reviewed_issue = Map.get(context, :reviewed_issue_identifier) || Map.get(context, "reviewed_issue_identifier")

    if present?(reason) or present?(reviewed_issue) do
      """
      - 重规划原因: #{reason || "-"}
      - 被审查 issue: #{reviewed_issue || "-"}
      """
      |> String.trim_trailing()
    else
      ""
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp workspace_text(nil), do: "未提供"
  defp workspace_text(workspace) when is_binary(workspace), do: workspace
end
