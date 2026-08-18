defmodule SymphonyElixir.Workflow.ReportSpike.Brief do
  @moduledoc """
  Builds report design metadata from a validated fact package.
  """

  alias SymphonyElixir.Workflow.ReportSpike.Context

  @spec build(map()) :: {:ok, map()} | {:error, term()}
  def build(%{"task" => task, "work_items" => work_items} = context) when is_list(work_items) do
    kind = report_kind(task["task_type_hint"], work_items)

    {:ok,
     %{
       "schema_version" => 1,
       "report_kind" => kind,
       "audience" => "workflow owner",
       "reader_goal" => reader_goal(kind),
       "top_questions" => top_questions(kind),
       "sections" => sections(kind),
       "attention_policy" => attention_policy(context)
     }}
  end

  def build(_context), do: {:error, :invalid_report_context}

  defp report_kind(_hint, work_items) do
    cond do
      Enum.any?(work_items, &Context.attention_item?/1) -> "workflow_with_attention"
      length(work_items) > 1 -> "workflow_batch"
      true -> "feature_implementation"
    end
  end

  defp reader_goal("feature_implementation") do
    "快速判断功能是否完成、怎么验证、风险在哪里、证据在哪里"
  end

  defp reader_goal("workflow_batch") do
    "快速判断整批 issue 是否完成、每个节点结果如何、证据在哪里"
  end

  defp reader_goal("workflow_with_attention") do
    "快速判断哪些 issue 需要介入、为什么不能视为完成、证据在哪里"
  end

  defp top_questions("workflow_with_attention") do
    ["哪里需要我介入？", "哪些结果不可信？", "证据在哪里？", "下一步是什么？"]
  end

  defp top_questions(_kind) do
    ["完成了吗？", "做了什么？", "怎么验证？", "风险在哪里？", "证据在哪里？"]
  end

  defp sections("feature_implementation") do
    ["结论", "用户可见变化", "核心实现", "验证结果", "风险和后续", "证据索引"]
  end

  defp sections("workflow_batch") do
    ["整体状态", "Issue 结果矩阵", "验证和证据索引", "风险和后续"]
  end

  defp sections("workflow_with_attention") do
    ["整体状态", "需要关注", "Issue 结果矩阵", "验证和证据索引", "后续动作"]
  end

  defp attention_policy(%{"work_items" => work_items}) do
    if Enum.any?(work_items, &Context.attention_item?/1) do
      "failed、blocked、needs_rework、needs_human 和证据缺失必须置顶"
    else
      "无阻断项时压缩成功项，并保留证据入口"
    end
  end
end
