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

    - 这是工作流控制层规划；输出会被控制层消费，不是普通进度记录。
    - `workflow_plan.json` 是控制信号，不是 progress note。
    - Linear comment/workpad 只用于 visibility，不是 authoritative source of truth。
    - 规划阶段只允许创建或更新 planning artifact：`workflow_plan.json`。
    - 不要修改源码、测试、文档或其他业务文件；这些只能在后续 execution phase 中处理。
    - 不要执行 direct_execution 的实现内容；`direct_execution` 只是 planner 给控制层的决策。
    - 不要修改当前 Linear issue 状态；Symphony 控制层会根据 artifact 推进当前 workflow issue。
    - 必须创建 artifact 目录：`mkdir -p #{artifact_dir}`。
    - 必须把规划结果写入：`#{plan_path}`。
    - 最终回复不能替代 artifact 文件；完成前必须读回该文件，确认它是合法 JSON，且符合下面三种结构之一。
    - 写入并读回 `workflow_plan.json` 后立即结束，等待控制层进入 execution、创建派生 issue 或请求人工输入。
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
            "evidence_expectations": ["可选的验收证据"],
            "completion_conditions": ["可选的完成条件，描述该步骤必须满足的条件"]
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

    - 生成或更新 `completion_packet.json`；这是交给控制层和审查阶段消费的 Completion Packet。
    - 不要通过移动当前 Linear issue 状态来表示完成、交接、进入 review 或关闭；当前 phase 的交接只能通过 `completion_packet.json`。
    - `completion_packet.json` 必须包含所有字段，且 `evidence` 必须是非空数组:

      ```json
      {
        "outcome": "completed | blocked | partial | failed",
        "summary": "完成内容摘要",
        "evidence": ["非空验证证据，例如命令、输出摘要、文件路径或截图"],
        "decisions": ["执行期间作出的关键决定"],
        "open_questions": ["仍未解决的问题，没有则为空数组"],
        "next_handoff": "交给审查或下一阶段的简短说明"
      }
      ```

    - 当前派生 issue workspace: #{workspace_text(workspace)}
    - Root workflow issue: #{value_or_dash(root_issue_identifier)}
    - Root workflow workspace: #{workspace_text(root_workspace)}
    - 如果任务说明要求在 root workflow workspace 中读取或写入文件，可以在那里操作目标业务文件；但当前 phase 的 artifact 仍然必须写在当前派生 issue workspace 的 `.symphony` 目录中。
    - 写入并读回 `completion_packet.json` 后立即结束，等待控制层进入 review 或推进下游阶段。
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

    - 生成或更新 `review_decision.json`；这是控制层消费的 Review Decision，不能被最终回复或 Linear comment 替代。
    - 审查阶段只允许读取相关文件、运行验证命令、判断结果，并创建或更新当前 phase 的 `review_decision.json`。
    - 不要修改源码、测试、文档或业务文件；不要把审查阶段变成返工实现阶段。
    - 不要通过移动当前 Linear issue 状态来表示审查通过、返工、重规划、需要人工输入或关闭；当前 phase 的交接只能通过 `review_decision.json`。
    - 不要执行 `git add`，不要 stage，不要 commit，不要 push，不要创建 PR，不要创建或切换分支，不要加载提交、发布或 PR 相关 skill。
    - 允许的 decision 集合: #{Enum.join(@review_decisions, ", ")}。
    - `review_decision.json` 必须包含非空 `decision`、`summary` 和 `confidence`。
    - 如果 Completion Packet 缺少 `evidence` 或证据不足，`pass` 无效；必须选择 `needs_rework`、`needs_replan`、`needs_human` 或 `fail` 并说明原因。
    - `needs_rework`、`needs_replan`、`fail` 必须包含非空 `reason`；`needs_human` 必须包含非空 `reason` 和 `requested_input`。
    - `pass` 示例:

      ```json
      {
        "decision": "pass",
        "summary": "审查通过的原因和证据摘要",
        "confidence": "high"
      }
      ```

    - `needs_rework` 示例:

      ```json
      {
        "decision": "needs_rework",
        "summary": "需要返工的摘要",
        "confidence": "medium",
        "reason": "具体返工原因"
      }
      ```

    - 当前派生 issue workspace: #{workspace_text(workspace)}
    - Root workflow issue: #{value_or_dash(root_issue_identifier)}
    - Root workflow workspace: #{workspace_text(root_workspace)}
    - 如果需要验收 root workflow workspace 中的业务文件，可以直接读取那里；但当前 phase 的 `review_decision.json` 仍然必须写在当前派生 issue workspace 的 `.symphony` 目录中。
    - 写入并读回 `review_decision.json` 后立即结束，等待控制层根据 Review Decision 推进。
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
