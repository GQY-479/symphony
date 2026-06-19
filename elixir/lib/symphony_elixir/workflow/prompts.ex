defmodule SymphonyElixir.Workflow.Prompts do
  @moduledoc """
  为不同工作流阶段追加固定提示词。
  """

  alias SymphonyElixir.Workflow.Artifacts

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
    artifact_dir = artifact_dir_text(workspace)
    plan_path = artifact_path_text(workspace, :workflow_plan)

    """

    规划阶段附加要求:

    - 必须创建 artifact 目录：`mkdir -p #{artifact_dir}`。
    - 必须把规划结果写入：`#{plan_path}`。
    - 最终回复不能替代 artifact 文件；完成前必须读回该文件，确认它是合法 JSON，且符合下面三种结构之一。
    - 只允许输出一种规划形态：`direct_execution`、`issue_graph` 或 `needs_human_input`。
    - 若任务足够简单，可写入 `direct_execution`:

      ```json
      {
        "kind": "direct_execution",
        "summary": "为什么可以直接执行",
        "confidence": "high",
        "agent_id": "可选，省略时使用普通路由"
      }
      ```

    - 若任务需要拆分，写入 `issue_graph`。每个 node 必须包含 `node_key`、`task_type`、`title`、`goal`、`agent_id`，`edges` 必须是数组，且每条边的 `from`、`to` 必须引用已有 node:

      ```json
      {
        "kind": "issue_graph",
        "summary": "整体编排摘要",
        "confidence": "medium",
        "nodes": [
          {
            "node_key": "research",
            "task_type": "research",
            "title": "调研任务标题",
            "goal": "该派生 issue 要达成的目标",
            "agent_id": "codex",
            "instructions": "可选的执行说明",
            "evidence_expectations": ["可选的验收证据"]
          }
        ],
        "edges": [
          {
            "from": "research",
            "to": "implementation",
            "handoff_summary": "上游交接给下游的关键内容"
          }
        ]
      }
      ```

    - 若信息不足，写入 `needs_human_input`，不要空结束:

      ```json
      {
        "kind": "needs_human_input",
        "summary": "当前无法规划的原因",
        "confidence": "low",
        "request": "需要用户补充的具体信息"
      }
      ```

    #{replan_context}
    - 工作区: #{workspace_text(workspace)}
    """
  end

  defp execution_prompt(context, workspace) do
    context = context_map(context)

    upstream_summaries =
      context
      |> upstream_packets()
      |> Enum.map_join("\n", fn packet ->
        summary = Map.get(packet, "summary") || Map.get(packet, :summary) || ""
        "- #{summary}"
      end)

    root_workspace = Map.get(context, :root_workspace) || Map.get(context, "root_workspace")
    root_issue_identifier = Map.get(context, :root_issue_identifier) || Map.get(context, "root_issue_identifier")

    """

    执行阶段附加要求:

    - 生成或更新 `completion_packet.json`。
    - 当前派生 issue workspace: #{workspace_text(workspace)}
    - Root workflow issue: #{value_or_dash(root_issue_identifier)}
    - Root workflow workspace: #{workspace_text(root_workspace)}
    - 如果任务说明要求在 root workflow workspace 中读取或写入文件，可以在那里操作目标业务文件；但当前 phase 的 artifact 仍然必须写在当前派生 issue workspace 的 `.symphony` 目录中。
    - 上游摘要:
    #{upstream_summaries}
    """
  end

  defp review_prompt(context, workspace) do
    context = context_map(context)
    root_workspace = Map.get(context, :root_workspace) || Map.get(context, "root_workspace")
    root_issue_identifier = Map.get(context, :root_issue_identifier) || Map.get(context, "root_issue_identifier")

    """

    审查阶段附加要求:

    - 生成或更新 `review_decision.json`。
    - 允许的 decision 集合: #{Enum.join(@review_decisions, ", ")}。
    - 当前派生 issue workspace: #{workspace_text(workspace)}
    - Root workflow issue: #{value_or_dash(root_issue_identifier)}
    - Root workflow workspace: #{workspace_text(root_workspace)}
    - 如果需要验收 root workflow workspace 中的业务文件，可以直接读取那里；但当前 phase 的 `review_decision.json` 仍然必须写在当前派生 issue workspace 的 `.symphony` 目录中。
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
  defp workspace_text(_workspace), do: "未提供"

  defp value_or_dash(value) when is_binary(value) and value != "", do: value
  defp value_or_dash(_value), do: "-"

  defp artifact_path_text(workspace, :workflow_plan) when is_binary(workspace),
    do: Artifacts.workflow_plan_path(workspace)

  defp artifact_path_text(_workspace, :workflow_plan), do: "`workflow_plan.json` 的完整路径未提供"

  defp artifact_dir_text(workspace) when is_binary(workspace),
    do: Path.dirname(Artifacts.workflow_plan_path(workspace))

  defp artifact_dir_text(_workspace), do: "artifact 目录路径未提供"
end
