defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Symphony 运行观测首页。
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell-ops">
      <header class="ops-topbar">
        <div>
          <p class="eyebrow">Symphony Observability</p>
          <h1>Root Workflows</h1>
        </div>

        <div class="status-stack">
          <span class="status-badge status-badge-live">
            <span class="status-badge-dot"></span>
            Live
          </span>
          <span class="status-badge status-badge-offline">
            <span class="status-badge-dot"></span>
            Offline
          </span>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">Snapshot unavailable</h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="ops-metrics">
          <article>
            <span>Workflows</span>
            <strong class="numeric"><%= length(@payload.workflows) %></strong>
          </article>
          <article>
            <span>Running</span>
            <strong class="numeric"><%= @payload.counts.running %></strong>
          </article>
          <article>
            <span>Blocked</span>
            <strong class="numeric"><%= @payload.counts.blocked %></strong>
          </article>
          <article>
            <span>Total tokens</span>
            <strong class="numeric"><%= format_int(@payload.codex_totals.total_tokens) %></strong>
          </article>
          <article>
            <span>Runtime</span>
            <strong class="numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></strong>
          </article>
        </section>

        <section class="ops-grid">
          <aside class="ops-sidebar" aria-label="Workflow filters">
            <div>
              <h2>Filters</h2>
              <nav class="filter-list">
                <a href="/" class="filter-pill is-active">All</a>
                <a href="/" class="filter-pill">Running</a>
                <a href="/" class="filter-pill">Review</a>
                <a href="/" class="filter-pill">Blocked</a>
                <a href="/" class="filter-pill">Retrying</a>
              </nav>
            </div>

            <div class="rate-limit-box">
              <h2>Rate limits</h2>
              <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
            </div>
          </aside>

          <main class="workflow-list" aria-label="Root workflow list">
            <div class="workflow-list-heading">
              <h2>Workflow queue</h2>
              <p>Operations Dashboard · Codex update</p>
            </div>

            <%= if @payload.workflows == [] do %>
              <p class="empty-state">No active root workflows</p>
            <% else %>
              <article :for={workflow <- @payload.workflows} class="workflow-card">
                <div class="workflow-card-head">
                  <div>
                    <a class="issue-id issue-id-link" href={workflow_link(workflow)}>
                      <%= workflow.root_issue_identifier %>
                    </a>
                    <h3><%= workflow_title(workflow) %></h3>
                  </div>
                  <span class={workflow_status_badge_class(workflow.status)}><%= workflow.status %></span>
                </div>

                <div class="workflow-phase-row">
                  <span><%= phase_label(workflow.phase_summary) || "unassigned" %></span>
                  <span class="muted">Runtime <%= format_runtime_seconds(workflow.runtime_seconds) %></span>
                </div>

                <dl class="workflow-counts">
                  <div>
                    <dt>Running</dt>
                    <dd class="numeric"><%= workflow.counts.running %></dd>
                  </div>
                  <div>
                    <dt>Retrying</dt>
                    <dd class="numeric"><%= workflow.counts.retrying %></dd>
                  </div>
                  <div>
                    <dt>Blocked</dt>
                    <dd class="numeric"><%= workflow.counts.blocked %></dd>
                  </div>
                  <div>
                    <dt>Tokens</dt>
                    <dd class="numeric"><%= format_int(workflow.tokens.total_tokens) %></dd>
                  </div>
                </dl>

                <div class="active-entry-list">
                  <div :for={entry <- workflow.active_entries} class="active-entry-row">
                    <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                    <span class={state_badge_class(entry.status)}><%= entry.status %></span>
                    <span><%= phase_label(entry.phase) || "n/a" %></span>
                    <span class="event-text"><%= entry_message(entry) %></span>
                    <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                    <button
                      :if={entry.session_id}
                      type="button"
                      class="subtle-button"
                      data-label="Copy ID"
                      data-copy={entry.session_id}
                      onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                    >
                      Copy ID
                    </button>
                  </div>
                </div>

                <p :if={workflow.recent_event} class="workflow-event">
                  <span><%= recent_event_message(workflow.recent_event) %></span>
                  <span class="muted mono"><%= workflow.recent_event.at || "n/a" %></span>
                </p>
              </article>
            <% end %>
          </main>

          <aside class="attention-panel" aria-label="Attention Inbox">
            <h2>Attention Inbox</h2>

            <%= if @payload.attention_items == [] do %>
              <p class="empty-state">No operator action needed</p>
            <% else %>
              <div :for={item <- @payload.attention_items} class="attention-item">
                <span class={attention_kind_class(item.kind)}><%= item.kind %></span>
                <a href={workflow_link(item)}><%= item.root_issue_identifier %></a>
                <strong><%= item.issue_identifier %></strong>
                <p><%= attention_reason(item) %></p>
                <small><%= phase_label(item.phase) || "n/a" %></small>
              </div>
            <% end %>
          </aside>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  attr(:identifier, :string, required: true)
  attr(:url, :string, default: nil)

  defp issue_identifier(assigns) do
    assigns = assign(assigns, :href, external_issue_url(assigns.url))

    ~H"""
    <%= if @href do %>
      <a
        class="issue-id issue-id-link"
        href={@href}
        target="_blank"
        rel="noopener noreferrer"
        aria-label={"Open #{@identifier} in the issue tracker"}
      ><%= @identifier %></a>
    <% else %>
      <span class="issue-id"><%= @identifier %></span>
    <% end %>
    """
  end

  defp external_issue_url(url) when is_binary(url) do
    url = String.trim(url)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        url

      _ ->
        nil
    end
  end

  defp external_issue_url(_url), do: nil

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp workflow_link(%{root_issue_identifier: root_identifier}) do
    "/workflows/#{URI.encode(root_identifier)}"
  end

  defp workflow_title(%{title: title, root_issue_identifier: root_identifier}) when is_binary(title) do
    if String.trim(title) == root_identifier, do: "Root workflow", else: title
  end

  defp workflow_title(_workflow), do: "Root workflow"

  defp phase_label(nil), do: nil
  defp phase_label(phase) when is_atom(phase), do: Atom.to_string(phase)
  defp phase_label(phase), do: to_string(phase)

  defp attention_reason(%{reason: reason}) when is_binary(reason), do: reason
  defp attention_reason(%{attempt: attempt}) when is_integer(attempt), do: "Retry attempt #{attempt}"
  defp attention_reason(_item), do: "Needs operator review"

  defp entry_message(%{last_message: message}) when is_binary(message), do: message
  defp entry_message(%{last_event: event}) when not is_nil(event), do: to_string(event)
  defp entry_message(_entry), do: "n/a"

  defp recent_event_message(%{message: message}) when is_binary(message), do: message
  defp recent_event_message(%{event: event}) when not is_nil(event), do: to_string(event)
  defp recent_event_message(_event), do: "n/a"

  defp attention_kind_class(kind), do: "attention-kind attention-kind-#{kind}"

  defp workflow_status_badge_class(status), do: state_badge_class(status)

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
