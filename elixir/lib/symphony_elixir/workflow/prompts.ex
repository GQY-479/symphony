defmodule SymphonyElixir.Workflow.Prompts do
  @moduledoc """
  为不同工作流阶段追加固定提示词。
  """

  alias SymphonyElixir.Workflow.Artifacts

  @review_outcomes ["pass", "needs_rework", "needs_replan", "needs_human", "fail"]

  @spec append(String.t(), atom() | nil, map() | nil, Path.t() | nil) :: String.t()
  def append(base_prompt, nil, _context, _workspace), do: base_prompt

  def append(base_prompt, :planning, context, workspace) do
    base_prompt <> planning_prompt(context, workspace)
  end

  def append(base_prompt, :issue, context, workspace) do
    base_prompt <> issue_prompt(context, workspace)
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

  defp issue_prompt(context, workspace) do
    context = context_map(context)
    task_type = Map.get(context, :task_type) || Map.get(context, "task_type") || "implementation"
    node_key = Map.get(context, :node_key) || Map.get(context, "node_key") || "-"
    root_workspace = Map.get(context, :root_workspace) || Map.get(context, "root_workspace")
    root_issue_identifier = Map.get(context, :root_issue_identifier) || Map.get(context, "root_issue_identifier")
    result_path = artifact_path_text(workspace, :issue_result)

    upstream_summaries =
      context
      |> upstream_results()
      |> Enum.map_join("\n", fn result ->
        summary = Map.get(result, "summary") || Map.get(result, :summary) || ""
        "- #{summary}"
      end)

    upstream_workspace_lines =
      context
      |> upstream_workspaces()
      |> Enum.map_join("\n", fn upstream ->
        node_key = Map.get(upstream, "node_key") || Map.get(upstream, :node_key) || "-"
        issue_identifier = Map.get(upstream, "issue_identifier") || Map.get(upstream, :issue_identifier) || "-"
        workspace = Map.get(upstream, "workspace") || Map.get(upstream, :workspace) || "未提供"

        "- #{node_key} (#{issue_identifier}): #{workspace}"
      end)

    review_rules =
      if task_type == "review" do
        """

        Review issue 附加规则:

        - review 是普通 issue node；不要把它当作内部 review phase。
        - 只允许读取相关文件、运行验证命令、判断结果，并创建或更新当前 issue 的 `issue_result.json`。
        - 不要修改源码、测试、文档或业务文件；不要把 review issue 变成返工实现 issue。
        - 不要执行 `git add`，不要 stage，不要 commit，不要 push，不要创建 PR，不要创建或切换分支。
        - 允许的 review outcome 集合: #{Enum.join(@review_outcomes, ", ")}。
        - `pass` 表示审查通过。
        - `needs_rework`、`needs_replan`、`fail` 必须包含非空 `reason`。
        - `needs_human` 必须包含非空 `reason` 和 `requested_input`。
        - `reviews` 必须列出被审查 node key；不要自行改写 controller 给出的审查对象。
        """
      else
        ""
      end

    """

    Issue 阶段附加要求:

    - 这是 workflow issue node；输出会被控制层消费，不是普通进度记录。
    - 生成或更新 `issue_result.json`；这是当前 issue node 的唯一完成 artifact。
    - 不要通过移动当前 Linear issue 状态来表示完成、交接、审查通过或关闭；当前 issue 的交接只能通过 `issue_result.json`。
    - `issue_result.json` 必须写入：`#{result_path}`。
    - `issue_result.json` 必须包含所有字段，且 `evidence` 必须是非空数组:

      ```json
      {
        "schema_version": 1,
        "node_key": "#{node_key}",
        "task_type": "#{task_type}",
        "outcome": "completed",
        "summary": "完成内容摘要",
        "evidence": ["非空验证证据，例如命令、输出摘要、文件路径或截图"],
        "decisions": [],
        "open_questions": []
      }
      ```

    - 当前派生 issue workspace: #{workspace_text(workspace)}
    - Root workflow issue: #{value_or_dash(root_issue_identifier)}
    - Root workflow workspace: #{workspace_text(root_workspace)}
    - 如果任务说明要求在 root workflow workspace 中读取或写入文件，可以在那里操作目标业务文件；但当前 issue artifact 仍然必须写在当前派生 issue workspace 的 `.symphony` 目录中。
    - 先检查依赖节点 workspace；如果当前节点依赖上游实现，必须在当前派生 issue workspace 中合入、cherry-pick 或移植必要代码后再继续，不要只依赖摘要。
    - 依赖节点 workspaces:
    #{value_or_dash(upstream_workspace_lines)}
    #{review_rules}
    - 写入并读回 `issue_result.json` 后立即结束，等待控制层推进 workflow graph。
    - 上游摘要:
    #{upstream_summaries}
    """
  end

  defp context_map(context) when is_map(context), do: context
  defp context_map(_context), do: %{}

  defp upstream_results(context) when is_map(context) do
    Map.get(context, :upstream_results) || Map.get(context, "upstream_results") || []
  end

  defp upstream_workspaces(context) when is_map(context) do
    Map.get(context, :upstream_workspaces) || Map.get(context, "upstream_workspaces") || []
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

  defp artifact_path_text(workspace, :issue_result) when is_binary(workspace),
    do: Artifacts.issue_result_path(workspace)

  defp artifact_path_text(_workspace, :issue_result), do: "`issue_result.json` 的完整路径未提供"

  defp artifact_dir_text(workspace) when is_binary(workspace),
    do: Path.dirname(Artifacts.workflow_plan_path(workspace))

  defp artifact_dir_text(_workspace), do: "artifact 目录路径未提供"
end
