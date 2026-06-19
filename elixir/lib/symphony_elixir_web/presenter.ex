defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard}

  @spec state_payload(GenServer.name() | {:snapshot, map()}, timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case snapshot_for(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.map(snapshot.running, &running_entry_payload/1)
        retrying = Enum.map(snapshot.retrying, &retry_entry_payload/1)
        blocked = Enum.map(Map.get(snapshot, :blocked, []), &blocked_entry_payload/1)
        workflows = workflow_payloads(running, retrying, blocked)

        %{
          generated_at: generated_at,
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying),
            blocked: length(Map.get(snapshot, :blocked, []))
          },
          running: running,
          retrying: retrying,
          blocked: blocked,
          workflows: workflows,
          attention_items: attention_items(workflows),
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  defp snapshot_for({:snapshot, snapshot}, _snapshot_timeout_ms), do: snapshot
  defp snapshot_for(orchestrator, snapshot_timeout_ms), do: Orchestrator.snapshot(orchestrator, snapshot_timeout_ms)

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))
        blocked = Enum.find(Map.get(snapshot, :blocked, []), &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) and is_nil(blocked) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry, blocked)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry, blocked) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry, blocked),
      status: issue_status(running, retry, blocked),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry, blocked),
        host: workspace_host(running, retry, blocked)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      blocked: blocked && blocked_issue_payload(blocked),
      logs: %{
        codex_session_logs: []
      },
      recent_events: recent_events_payload(running || blocked),
      last_error: (blocked && blocked.error) || (retry && retry.error),
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry, blocked),
    do: (running && running.issue_id) || (retry && retry.issue_id) || (blocked && blocked.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(running, _retry, _blocked) when not is_nil(running), do: "running"
  defp issue_status(nil, retry, _blocked) when not is_nil(retry), do: "retrying"
  defp issue_status(nil, nil, _blocked), do: "blocked"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      state: entry.state,
      agent_id: Map.get(entry, :agent_id),
      agent_kind: Map.get(entry, :agent_kind),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      workflow_phase: Map.get(entry, :workflow_phase),
      workflow_root_issue_id: Map.get(entry, :workflow_root_issue_id),
      workflow_blocked_reason: workflow_blocked_reason(entry),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      runtime_seconds: Map.get(entry, :runtime_seconds, 0),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      agent_id: Map.get(entry, :agent_id),
      agent_kind: Map.get(entry, :agent_kind),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      workflow_phase: Map.get(entry, :workflow_phase),
      workflow_root_issue_id: Map.get(entry, :workflow_root_issue_id),
      workflow_blocked_reason: workflow_blocked_reason(entry)
    }
  end

  defp blocked_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      issue_url: Map.get(entry, :issue_url),
      state: entry.state,
      error: entry.error,
      agent_id: Map.get(entry, :agent_id),
      agent_kind: Map.get(entry, :agent_kind),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      blocked_at: iso8601(entry.blocked_at),
      workflow_phase: Map.get(entry, :workflow_phase),
      workflow_root_issue_id: Map.get(entry, :workflow_root_issue_id),
      workflow_blocked_reason: workflow_blocked_reason(entry),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      last_event_at: iso8601(entry.last_codex_timestamp)
    }
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      agent_id: Map.get(running, :agent_id),
      agent_kind: Map.get(running, :agent_kind),
      workflow_phase: Map.get(running, :workflow_phase),
      workflow_root_issue_id: Map.get(running, :workflow_root_issue_id),
      workflow_blocked_reason: workflow_blocked_reason(running),
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      agent_id: Map.get(retry, :agent_id),
      agent_kind: Map.get(retry, :agent_kind),
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path),
      workflow_phase: Map.get(retry, :workflow_phase),
      workflow_root_issue_id: Map.get(retry, :workflow_root_issue_id),
      workflow_blocked_reason: workflow_blocked_reason(retry)
    }
  end

  defp blocked_issue_payload(blocked) do
    %{
      worker_host: Map.get(blocked, :worker_host),
      workspace_path: Map.get(blocked, :workspace_path),
      session_id: blocked.session_id,
      state: blocked.state,
      error: blocked.error,
      agent_id: Map.get(blocked, :agent_id),
      agent_kind: Map.get(blocked, :agent_kind),
      workflow_phase: Map.get(blocked, :workflow_phase),
      workflow_root_issue_id: Map.get(blocked, :workflow_root_issue_id),
      workflow_blocked_reason: workflow_blocked_reason(blocked),
      blocked_at: iso8601(blocked.blocked_at),
      last_event: blocked.last_codex_event,
      last_message: summarize_message(blocked.last_codex_message),
      last_event_at: iso8601(blocked.last_codex_timestamp)
    }
  end

  defp workspace_path(issue_identifier, running, retry, blocked) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      (blocked && Map.get(blocked, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry, blocked) do
    (running && Map.get(running, :worker_host)) ||
      (retry && Map.get(retry, :worker_host)) ||
      (blocked && Map.get(blocked, :worker_host))
  end

  defp recent_events_payload(nil), do: []

  defp recent_events_payload(entry) do
    [
      %{
        at: iso8601(entry.last_codex_timestamp),
        event: entry.last_codex_event,
        message: summarize_message(entry.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp workflow_payloads(running, retrying, blocked) do
    running
    |> Enum.map(&workflow_group_entry(&1, "running"))
    |> Kernel.++(Enum.map(retrying, &workflow_group_entry(&1, "retrying")))
    |> Kernel.++(Enum.map(blocked, &workflow_group_entry(&1, "blocked")))
    |> Enum.group_by(& &1.root_issue_identifier)
    |> Enum.map(fn {_root_issue_identifier, entries} -> workflow_payload(entries) end)
    |> Enum.sort_by(& &1.root_issue_identifier)
  end

  defp workflow_group_entry(entry, state) do
    root_issue_identifier = Map.get(entry, :workflow_root_issue_id) || entry.issue_identifier

    %{
      state: state,
      entry: entry,
      root_issue_identifier: root_issue_identifier,
      direct_execution?: state == "running" and is_nil(Map.get(entry, :workflow_root_issue_id))
    }
  end

  defp workflow_payload(entries) do
    root_issue_identifier = entries |> List.first() |> Map.fetch!(:root_issue_identifier)
    active_entries = Enum.map(entries, &active_entry_payload/1)
    attention_items = entries |> Enum.flat_map(&workflow_attention_items/1) |> sort_attention_items()

    %{
      root_issue_identifier: root_issue_identifier,
      root_issue_id: root_issue_id(entries, root_issue_identifier),
      title: root_issue_identifier,
      issue_url: issue_url(entries),
      status: workflow_status(entries),
      phase_summary: phase_summary(entries),
      counts: workflow_counts(entries),
      active_entries: active_entries,
      attention_items: attention_items,
      recent_event: recent_event(entries),
      tokens: workflow_tokens(entries),
      runtime_seconds: runtime_seconds(entries),
      registry_available?: false
    }
  end

  defp active_entry_payload(%{state: state, entry: entry}) do
    %{
      status: state,
      issue_id: Map.get(entry, :issue_id),
      issue_identifier: entry.issue_identifier,
      issue_url: Map.get(entry, :issue_url),
      phase: Map.get(entry, :workflow_phase)
    }
  end

  defp workflow_attention_items(%{state: "blocked", entry: entry, root_issue_identifier: root_issue_identifier}) do
    [
      %{
        kind: "blocked",
        root_issue_identifier: root_issue_identifier,
        issue_identifier: entry.issue_identifier,
        reason: Map.get(entry, :workflow_blocked_reason) || Map.get(entry, :error),
        phase: Map.get(entry, :workflow_phase)
      }
    ]
  end

  defp workflow_attention_items(%{
         state: "retrying",
         entry: %{attempt: attempt} = entry,
         root_issue_identifier: root_issue_identifier
       })
       when is_integer(attempt) and attempt > 1 do
    [
      %{
        kind: "retrying",
        root_issue_identifier: root_issue_identifier,
        issue_identifier: entry.issue_identifier,
        attempt: attempt,
        reason: Map.get(entry, :error),
        phase: Map.get(entry, :workflow_phase)
      }
    ]
  end

  defp workflow_attention_items(_entry), do: []

  defp attention_items(workflows) do
    workflows
    |> Enum.flat_map(& &1.attention_items)
    |> sort_attention_items()
  end

  defp sort_attention_items(items) do
    items
    |> Enum.sort_by(&attention_sort_key/1)
  end

  defp attention_sort_key(%{kind: "blocked", root_issue_identifier: root, issue_identifier: issue}),
    do: {0, root, issue}

  defp attention_sort_key(%{kind: "retrying", root_issue_identifier: root, issue_identifier: issue}),
    do: {1, root, issue}

  defp attention_sort_key(%{kind: kind, root_issue_identifier: root, issue_identifier: issue}),
    do: {2, root, issue, kind}

  defp root_issue_id(entries, root_issue_identifier) do
    case Enum.find(entries, &(&1.entry.issue_identifier == root_issue_identifier)) do
      %{entry: %{issue_id: issue_id}} -> issue_id
      _entry -> nil
    end
  end

  defp issue_url(entries) do
    entries
    |> Enum.find_value(&Map.get(&1.entry, :issue_url))
  end

  defp workflow_status(entries) do
    cond do
      Enum.any?(entries, &(&1.state == "blocked")) -> "blocked"
      Enum.all?(entries, & &1.direct_execution?) -> "direct_execution"
      Enum.any?(entries, &(&1.state == "running")) -> "running"
      Enum.any?(entries, &(&1.state == "retrying")) -> "retrying"
    end
  end

  defp phase_summary(entries) do
    if Enum.all?(entries, & &1.direct_execution?) do
      "direct_execution"
    else
      entries
      |> Enum.sort_by(&status_rank(&1.state))
      |> Enum.find_value(&Map.get(&1.entry, :workflow_phase))
      |> phase_label()
    end
  end

  defp status_rank("blocked"), do: 0
  defp status_rank("running"), do: 1
  defp status_rank("retrying"), do: 2
  defp status_rank(_state), do: 3

  defp phase_label(nil), do: nil
  defp phase_label(phase) when is_atom(phase), do: Atom.to_string(phase)
  defp phase_label(phase), do: to_string(phase)

  defp workflow_counts(entries) do
    %{
      running: Enum.count(entries, &(&1.state == "running")),
      retrying: Enum.count(entries, &(&1.state == "retrying")),
      blocked: Enum.count(entries, &(&1.state == "blocked")),
      completed: nil,
      total_nodes: nil
    }
  end

  defp recent_event(entries) do
    entries
    |> Enum.filter(&(&1.state in ["running", "blocked"]))
    |> Enum.filter(&Map.get(&1.entry, :last_event_at))
    |> Enum.max_by(&Map.get(&1.entry, :last_event_at), &>=/2, fn -> nil end)
    |> recent_event_payload()
  end

  defp recent_event_payload(nil), do: nil

  defp recent_event_payload(%{entry: entry}) do
    %{
      issue_identifier: entry.issue_identifier,
      event: Map.get(entry, :last_event),
      message: Map.get(entry, :last_message),
      at: Map.get(entry, :last_event_at)
    }
  end

  defp workflow_tokens(entries) do
    %{
      input_tokens: sum_entry_token(entries, :input_tokens),
      output_tokens: sum_entry_token(entries, :output_tokens),
      total_tokens: sum_entry_token(entries, :total_tokens)
    }
  end

  defp runtime_seconds(entries), do: sum_entry_field(entries, :runtime_seconds)

  defp sum_entry_token(entries, field) do
    entries
    |> Enum.map(&entry_token(&1.entry, field))
    |> Enum.filter(&is_number/1)
    |> Enum.sum()
  end

  defp entry_token(entry, field) do
    case Map.get(entry, :tokens) do
      %{^field => value} -> value
      _tokens -> Map.get(entry, field, 0)
    end
  end

  defp sum_entry_field(entries, field) do
    entries
    |> Enum.map(&Map.get(&1.entry, field, 0))
    |> Enum.filter(&is_number/1)
    |> Enum.sum()
  end

  defp workflow_blocked_reason(entry) when is_map(entry) do
    Map.get(entry, :workflow_blocked_reason) || Map.get(entry, :error)
  end

  defp workflow_blocked_reason(_entry), do: nil

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
