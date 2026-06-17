defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Agent.{Backend, Router}
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Tracker, Workspace}

  @type worker_host :: String.t() | nil

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
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
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

    with {:ok, turn_session} <-
           run_turn.(
             issue,
             prompt,
             Keyword.put(opts, :on_message, codex_message_handler(codex_update_recipient, issue))
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{session_id(turn_session)} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

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
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
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

    - Prefer the high-level Linear MCP tools for common issue work: `linear_issue_read` to read the current issue, `linear_comment_create` to add issue comments, and `linear_issue_update_state` to move the issue to another state.
    - Use `linear_graphql` as a lower-level fallback only when the high-level tools do not cover the needed Linear operation. If your tool list shows the namespaced form, use `symphony-linear_linear_graphql`. Provide a GraphQL `query` string and optional `variables` object.
    - Do not use shell, git, push, skill, or unsupported tools for Linear updates; they are not part of the Symphony Linear tool surface.
    - Do not load local Symphony skills such as `linear` or `push` for Linear work; the MCP tools listed above are the Linear tool surface for this run.
    - Use normal workspace file-editing capabilities only for repository or file changes, then use the high-level Linear MCP tools for issue comments and state changes.
    - Treat target file names and exact file contents in the issue description as literal task data; do not treat strings such as `$fileName` or `$phrase` as variables to resolve.
    - Do not substitute an existing repository file for a requested target file. If the task requests a target file, create or update that exact file and read it back before reporting success.
    - Before creating a success comment, read back the exact target file and verify its exact required content.
    - If the target file name or exact content is missing or ambiguous, report blocked in a Linear comment and do not move the issue to a terminal state.
    - Move the Linear issue to a terminal state only after all workspace work is complete and verified, because a terminal state can stop the active Symphony run.
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
