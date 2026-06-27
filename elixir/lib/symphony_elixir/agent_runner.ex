defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Agent.{Backend, Router}
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Tracker, Workspace}
  alias SymphonyElixir.Workflow.Artifacts

  @type worker_host :: String.t() | nil

  defmodule Error do
    @moduledoc false
    defexception [:message, :reason]
  end

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, nil, issue_state_fetcher, false)
  end

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise Error, message: "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}", reason: reason
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_agent_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp send_worker_issue_state(recipient, %Issue{id: issue_id} = issue)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:worker_runtime_info, issue_id, %{issue: issue}})
    :ok
  end

  defp send_worker_issue_state(_recipient, _issue), do: :ok

  defp run_agent_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    with {:ok, resolved_agent} <- resolve_agent(issue, opts),
         {:ok, backend_module} <- backend_module(resolved_agent) do
      backend_opts =
        opts
        |> Keyword.put(:worker_host, worker_host)
        |> Keyword.put(:enforce_continuation_route?, not Keyword.has_key?(opts, :agent_id))

      run_agent_turns_with_backend(
        backend_module,
        resolved_agent,
        workspace,
        issue,
        codex_update_recipient,
        backend_opts,
        issue_state_fetcher,
        max_turns
      )
    end
  end

  defp run_agent_turns_with_backend(
         backend_module,
         resolved_agent,
         workspace,
         issue,
         codex_update_recipient,
         backend_opts,
         issue_state_fetcher,
         max_turns
       ) do
    if session_backend?(backend_module) do
      run_session_agent_turns(
        backend_module,
        resolved_agent,
        workspace,
        issue,
        codex_update_recipient,
        backend_opts,
        issue_state_fetcher,
        max_turns
      )
    else
      run_turn = fn turn_issue, prompt, turn_opts ->
        backend_module.run_issue(workspace, turn_issue, prompt, resolved_agent, turn_opts)
      end

      do_run_agent_turns(
        run_turn,
        workspace,
        issue,
        resolved_agent,
        codex_update_recipient,
        backend_opts,
        issue_state_fetcher,
        1,
        max_turns
      )
    end
  end

  defp run_session_agent_turns(
         backend_module,
         resolved_agent,
         workspace,
         issue,
         codex_update_recipient,
         backend_opts,
         issue_state_fetcher,
         max_turns
       ) do
    with {:ok, session} <- backend_module.start_session(workspace, resolved_agent, backend_opts) do
      run_turn = fn turn_issue, prompt, turn_opts ->
        backend_module.run_turn(session, workspace, turn_issue, prompt, turn_opts)
      end

      try do
        do_run_agent_turns(
          run_turn,
          workspace,
          issue,
          resolved_agent,
          codex_update_recipient,
          backend_opts,
          issue_state_fetcher,
          1,
          max_turns
        )
      after
        backend_module.stop_session(session)
      end
    end
  end

  defp do_run_agent_turns(
         run_turn,
         workspace,
         issue,
         resolved_agent,
         codex_update_recipient,
         opts,
         issue_state_fetcher,
         turn_number,
         max_turns
       ) do
    prompt = build_turn_prompt(issue, workspace, opts, turn_number, max_turns, resolved_agent)

    turn_opts =
      Keyword.put(
        opts,
        :on_message,
        workflow_artifact_message_handler(codex_update_recipient, issue, workspace, opts)
      )

    with {:ok, verified_turn_session} <-
           verify_agent_turn_result(
             run_turn,
             workspace,
             issue,
             opts,
             turn_opts,
             run_workflow_artifact_aware_turn(run_turn, issue, prompt, turn_opts, opts)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{session_id(verified_turn_session)} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      if workflow_artifact_accepted?(verified_turn_session) do
        :ok
      else
        case continue_with_issue?(issue, resolved_agent, issue_state_fetcher, Keyword.get(opts, :enforce_continuation_route?, true)) do
          {:continue, refreshed_issue} when turn_number < max_turns ->
            send_worker_issue_state(codex_update_recipient, refreshed_issue)

            Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

            do_run_agent_turns(
              run_turn,
              workspace,
              refreshed_issue,
              resolved_agent,
              codex_update_recipient,
              opts,
              issue_state_fetcher,
              turn_number + 1,
              max_turns
            )

          {:continue, refreshed_issue} ->
            send_worker_issue_state(codex_update_recipient, refreshed_issue)

            Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

            :ok

          {:done, refreshed_issue} ->
            send_worker_issue_state(codex_update_recipient, refreshed_issue)

            :ok

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  defp run_workflow_artifact_aware_turn(run_turn, issue, prompt, turn_opts, opts) do
    run_turn.(issue, prompt, turn_opts)
  catch
    {:workflow_artifact_ready, session_id} ->
      workflow_phase = Keyword.get(opts, :workflow_phase)

      Logger.info("Workflow artifact became valid during ACP turn for #{issue_context(issue)} phase=#{workflow_phase}; accepting artifact and returning control to orchestrator")

      {:ok,
       %{
         session_id: session_id,
         accepted_after_workflow_artifact: workflow_phase
       }}
  end

  defp verify_agent_turn_result(run_turn, workspace, issue, opts, turn_opts, {:ok, turn_session}) do
    ensure_workflow_artifact(run_turn, workspace, issue, opts, turn_opts, turn_session)
  end

  defp verify_agent_turn_result(_run_turn, workspace, issue, opts, _turn_opts, {:error, :acp_timeout}) do
    accept_valid_workflow_artifact_after_timeout(workspace, issue, opts)
  end

  defp verify_agent_turn_result(_run_turn, _workspace, _issue, _opts, _turn_opts, other), do: other

  defp build_turn_prompt(issue, workspace, opts, 1, _max_turns, resolved_agent) do
    issue
    |> PromptBuilder.build_prompt(
      opts
      |> Keyword.put(:workflow_phase, Keyword.get(opts, :workflow_phase))
      |> Keyword.put(:workflow_context, Keyword.get(opts, :workflow_context))
      |> Keyword.put(:workspace, workspace)
    )
    |> append_runtime_guidance(resolved_agent)
  end

  defp build_turn_prompt(_issue, _workspace, _opts, turn_number, max_turns, _resolved_agent) do
    """
    Continuation guidance:

    - The previous agent turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace, Workflow registry, and artifact state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp ensure_workflow_artifact(run_turn, workspace, issue, opts, turn_opts, turn_session) do
    workflow_phase = Keyword.get(opts, :workflow_phase)

    case load_workflow_artifact(workflow_phase, workspace) do
      :skip ->
        {:ok, turn_session}

      {:ok, _artifact} ->
        {:ok, accept_workflow_artifact(turn_session, issue, workflow_phase, :post_turn_verification)}

      {:error, artifact_path, reason} ->
        repair_prompt = workflow_artifact_repair_prompt(workflow_phase, workspace, artifact_path, reason)

        Logger.warning("Workflow artifact missing or invalid for #{issue_context(issue)} phase=#{workflow_phase} path=#{artifact_path} reason=#{inspect(reason)}; requesting artifact repair turn")

        with {:ok, repair_session} <- run_turn.(issue, repair_prompt, turn_opts),
             {:ok, _artifact} <- expect_workflow_artifact(workflow_phase, workspace) do
          {:ok, accept_workflow_artifact(repair_session, issue, workflow_phase, :repair)}
        else
          {:error, repair_reason} ->
            {:error, {:workflow_artifact_repair_failed, workflow_phase, artifact_path, repair_reason}}

          other ->
            {:error, {:workflow_artifact_repair_failed, workflow_phase, artifact_path, other}}
        end
    end
  end

  defp accept_valid_workflow_artifact_after_timeout(workspace, issue, opts) do
    workflow_phase = Keyword.get(opts, :workflow_phase)

    case load_workflow_artifact(workflow_phase, workspace) do
      {:ok, _artifact} ->
        Logger.warning("ACP turn timed out after producing a valid workflow artifact for #{issue_context(issue)} phase=#{workflow_phase}; accepting artifact and returning control to orchestrator")

        {:ok,
         %{
           session_id: nil,
           accepted_after_turn_error: :acp_timeout,
           accepted_after_workflow_artifact: workflow_phase
         }}

      :skip ->
        {:error, :acp_timeout}

      {:error, _artifact_path, _reason} ->
        {:error, :acp_timeout}
    end
  end

  defp load_workflow_artifact(:planning, workspace) when is_binary(workspace) do
    path = Artifacts.workflow_plan_path(workspace)
    artifact_result(path, Artifacts.load_workflow_plan(workspace))
  end

  defp load_workflow_artifact(:issue, workspace) when is_binary(workspace) do
    path = Artifacts.issue_result_path(workspace)
    artifact_result(path, Artifacts.load_issue_result(workspace))
  end

  defp load_workflow_artifact(:execution, workspace) when is_binary(workspace) do
    path = Artifacts.completion_packet_path(workspace)
    artifact_result(path, Artifacts.load_completion_packet(workspace))
  end

  defp load_workflow_artifact(:review, workspace) when is_binary(workspace) do
    path = Artifacts.review_decision_path(workspace)
    artifact_result(path, Artifacts.load_review_decision(workspace))
  end

  defp load_workflow_artifact(_workflow_phase, _workspace), do: :skip

  defp expect_workflow_artifact(workflow_phase, workspace) do
    case load_workflow_artifact(workflow_phase, workspace) do
      {:ok, artifact} -> {:ok, artifact}
      {:error, _path, reason} -> {:error, reason}
      :skip -> {:ok, :skipped}
    end
  end

  defp artifact_result(_path, {:ok, artifact}), do: {:ok, artifact}
  defp artifact_result(path, {:error, reason}), do: {:error, path, reason}

  defp accept_workflow_artifact(turn_session, _issue, _workflow_phase, _source)
       when is_map(turn_session) and is_map_key(turn_session, :accepted_after_workflow_artifact) do
    turn_session
  end

  defp accept_workflow_artifact(turn_session, issue, workflow_phase, source) when is_map(turn_session) do
    Logger.info("Workflow artifact valid after ACP turn for #{issue_context(issue)} phase=#{workflow_phase} source=#{source}; returning control to orchestrator")

    turn_session
    |> Map.put(:accepted_after_workflow_artifact, workflow_phase)
    |> Map.put(:workflow_artifact_acceptance_source, source)
  end

  defp workflow_artifact_accepted?(%{accepted_after_workflow_artifact: workflow_phase})
       when not is_nil(workflow_phase),
       do: true

  defp workflow_artifact_accepted?(_turn_session), do: false

  defp workflow_artifact_message_handler(recipient, issue, workspace, opts) do
    handler = codex_message_handler(recipient, issue)
    workflow_phase = Keyword.get(opts, :workflow_phase)

    fn message ->
      result = handler.(message)
      maybe_halt_on_valid_workflow_artifact(message, workflow_phase, workspace)
      result
    end
  end

  defp maybe_halt_on_valid_workflow_artifact(%{event: :notification} = message, workflow_phase, workspace) do
    case load_workflow_artifact(workflow_phase, workspace) do
      {:ok, _artifact} -> throw({:workflow_artifact_ready, Map.get(message, :session_id)})
      :skip -> :ok
      {:error, _artifact_path, _reason} -> :ok
    end
  end

  defp maybe_halt_on_valid_workflow_artifact(_message, _workflow_phase, _workspace), do: :ok

  defp workflow_artifact_repair_prompt(:planning, workspace, artifact_path, reason) do
    """
    上一轮 planning 已正常结束，但缺少必需 artifact 或 artifact 无法通过校验。

    现在只做 artifact 修复，不要执行 issue，不要改 Linear 状态，不要写其他文件。

    - 工作区: #{workspace}
    - 必须创建目录: #{Path.dirname(artifact_path)}
    - 必须写入文件: #{artifact_path}
    - 当前错误: #{inspect(reason)}

    写入的 JSON 必须是以下三种之一：`direct_execution`、`issue_graph`、`needs_human_input`。

    `direct_execution` 示例：
    ```json
    {
      "kind": "direct_execution",
      "summary": "为什么可以直接执行",
      "confidence": "medium"
    }
    ```

    `issue_graph` 示例：
    ```json
    {
      "kind": "issue_graph",
      "summary": "整体编排摘要",
      "confidence": "medium",
      "nodes": [
        {
          "node_key": "implementation",
          "task_type": "implementation",
          "title": "派生任务标题",
          "goal": "派生任务目标",
          "agent_id": "codex"
        }
      ],
      "edges": []
    }
    ```

    `needs_human_input` 示例：
    ```json
    {
      "kind": "needs_human_input",
      "summary": "无法规划的原因",
      "confidence": "low",
      "request": "需要用户补充的具体信息"
    }
    ```

    完成前必须读回 #{artifact_path}，确认 JSON 可以解析，并且不要只在最终回复里描述计划。
    """
  end

  defp workflow_artifact_repair_prompt(:issue, workspace, artifact_path, reason) do
    """
    上一轮 issue 已正常结束，但缺少必需 artifact 或 artifact 无法通过校验。

    现在只做 artifact 修复，不要继续实现或审查新内容，不要改 Linear 状态，不要写其他文件。

    - 工作区: #{workspace}
    - 必须创建目录: #{Path.dirname(artifact_path)}
    - 必须写入文件: #{artifact_path}
    - 当前错误: #{inspect(reason)}

    写入的 JSON 至少必须包含：
    ```json
    {
      "schema_version": 1,
      "node_key": "implementation",
      "task_type": "implementation",
      "outcome": "completed",
      "summary": "本 issue 完成情况",
      "evidence": ["验证或证据"],
      "decisions": [],
      "open_questions": []
    }
    ```

    如果这是 review issue，`task_type` 必须是 `review`，`outcome` 只能是
    `pass`、`needs_rework`、`needs_replan`、`needs_human` 或 `fail`，并且必须包含
    非空 `reviews` 数组。非 pass outcome 还必须包含 `reason`；`needs_human`
    还必须包含 `requested_input`。

    完成前必须读回 #{artifact_path}，确认 JSON 可以解析。
    """
  end

  defp workflow_artifact_repair_prompt(:execution, workspace, artifact_path, reason) do
    """
    上一轮 execution 已正常结束，但缺少必需 artifact 或 artifact 无法通过校验。

    现在只做 artifact 修复，不要继续实现新功能，不要改 Linear 状态，不要写其他文件。

    - 工作区: #{workspace}
    - 必须创建目录: #{Path.dirname(artifact_path)}
    - 必须写入文件: #{artifact_path}
    - 当前错误: #{inspect(reason)}

    写入的 JSON 至少必须包含：
    ```json
    {
      "outcome": "completed",
      "summary": "本阶段完成情况",
      "evidence": ["验证或证据"],
      "decisions": [],
      "open_questions": [],
      "next_handoff": "交给 review 或下游节点的交接"
    }
    ```

    完成前必须读回 #{artifact_path}，确认 JSON 可以解析。
    """
  end

  defp workflow_artifact_repair_prompt(:review, workspace, artifact_path, reason) do
    """
    上一轮 review 已正常结束，但缺少必需 artifact 或 artifact 无法通过校验。

    现在只做 artifact 修复，不要继续审查以外的工作，不要改 Linear 状态，不要写其他文件。

    - 工作区: #{workspace}
    - 必须创建目录: #{Path.dirname(artifact_path)}
    - 必须写入文件: #{artifact_path}
    - 当前错误: #{inspect(reason)}

    写入的 JSON 至少必须包含：
    ```json
    {
      "decision": "pass",
      "summary": "审查结论",
      "confidence": "medium"
    }
    ```

    `decision` 只能是 `pass`、`needs_rework`、`needs_replan`、`needs_human`、`fail`。
    `needs_rework`、`needs_replan`、`fail` 必须包含非空 `reason`。
    `needs_human` 必须包含非空 `reason` 和 `requested_input`。
    完成前必须读回 #{artifact_path}，确认 JSON 可以解析。
    """
  end

  defp append_runtime_guidance(prompt, %{kind: "acp_stdio", config: config}) when is_map(config) do
    if linear_mcp_enabled?(Map.get(config, "mcp") || Map.get(config, :mcp)) do
      prompt <> acp_linear_mcp_guidance()
    else
      prompt
    end
  end

  defp append_runtime_guidance(prompt, _resolved_agent), do: prompt

  defp linear_mcp_enabled?(mcp) when is_map(mcp) do
    Map.get(mcp, "linear_tools") == true or Map.get(mcp, :linear_tools) == true
  end

  defp linear_mcp_enabled?(_mcp), do: false

  defp acp_linear_mcp_guidance do
    """

    Runtime tools available through Symphony:

    - Prefer the high-level Linear MCP tools for common issue work: `linear_issue_read` to read the current issue, `linear_comment_create` to add issue comments, and `linear_issue_update_state` only when the task explicitly asks for a Linear state operation.
    - Use `linear_graphql` as a lower-level fallback only when the high-level tools do not cover the needed Linear operation. If your tool list shows the namespaced form, use `symphony-linear_linear_graphql`. Provide a GraphQL `query` string and optional `variables` object.
    - Do not use shell, git, push, skill, or unsupported tools for Linear updates; they are not part of the Symphony Linear tool surface.
    - Do not load local Symphony skills such as `linear` or `push` for Linear work; the MCP tools listed above are the Linear tool surface for this run.
    - Use normal workspace file-editing capabilities only for repository or file changes, then use the high-level Linear MCP tools for issue comments and explicitly requested Linear operations.
    - Do not use Linear state changes to finish, hand off, review, or close the current workflow issue; Symphony advances the current workflow issue after reading the required artifact.
    - Treat target file names and exact file contents in the issue description as literal task data; do not treat strings such as `$fileName` or `$phrase` as variables to resolve.
    - Do not substitute an existing repository file for a requested target file. If the task requests a target file, create or update that exact file and read it back before reporting success.
    - Before creating a success comment, read back the exact target file and verify its exact required content.
    - If the target file name or exact content is missing or ambiguous, report blocked in a Linear comment and leave the current workflow issue state unchanged.
    - Do not expose Linear API tokens in files, logs, commits, or issue comments.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, resolved_agent, issue_state_fetcher, enforce_route?)
       when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) and
             issue_routable?(refreshed_issue) and
             issue_still_routed_to_agent?(refreshed_issue, resolved_agent, enforce_route?) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _resolved_agent, _issue_state_fetcher, _enforce_route?), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp issue_still_routed_to_agent?(_issue, _resolved_agent, false), do: true

  defp issue_still_routed_to_agent?(_issue, nil, true), do: true

  defp issue_still_routed_to_agent?(%Issue{} = issue, %{id: agent_id, kind: agent_kind}, true) do
    case Router.resolve(issue, Config.settings!()) do
      {:ok, %{id: ^agent_id, kind: ^agent_kind}} -> true
      _other -> false
    end
  end

  defp resolve_agent(%Issue{} = issue, opts) do
    settings = Config.settings!()

    case Keyword.get(opts, :agent_id) do
      nil -> Router.resolve(issue, settings)
      agent_id -> resolve_agent_by_id(to_string(agent_id), settings)
    end
  end

  defp resolve_agent_by_id(agent_id, settings) do
    case Map.fetch(settings.agents || %{}, agent_id) do
      {:ok, %{"enabled" => false}} ->
        {:error, {:agent_disabled, agent_id}}

      {:ok, agent_config} when is_map(agent_config) ->
        {:ok, %{id: agent_id, kind: Map.get(agent_config, "kind"), config: agent_config}}

      :error ->
        {:error, {:unknown_agent, agent_id}}
    end
  end

  defp backend_module(%{kind: kind}) do
    {:ok, Backend.module_for(kind)}
  rescue
    error in ArgumentError -> {:error, error}
  end

  defp session_backend?(backend_module) when is_atom(backend_module) do
    Code.ensure_loaded?(backend_module) and
      function_exported?(backend_module, :start_session, 3) and
      function_exported?(backend_module, :run_turn, 5) and
      function_exported?(backend_module, :stop_session, 1)
  end

  defp session_id(turn_session) when is_map(turn_session) do
    Map.get(turn_session, :session_id) || Map.get(turn_session, "session_id")
  end

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
