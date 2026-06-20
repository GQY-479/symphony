defmodule SymphonyElixirWeb.WorkflowLive do
  @moduledoc """
  Root workflow detail page for the observability dashboard.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @impl true
  def mount(%{"root_identifier" => root_identifier}, _session, socket) do
    socket =
      socket
      |> assign(:root_identifier, root_identifier)
      |> assign(:payload_result, load_payload(root_identifier))

    if connected?(socket), do: :ok = ObservabilityPubSub.subscribe()

    {:ok, socket}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply, assign(socket, :payload_result, load_payload(socket.assigns.root_identifier))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="workflow-detail-shell">
      <a class="issue-link" href="/">Back to dashboard</a>

      <%= case @payload_result do %>
        <% {:ok, payload} -> %>
          <header class="workflow-detail-header">
            <div>
              <p class="eyebrow">Root workflow</p>
              <h1><%= payload.root_issue_identifier %></h1>
              <p><%= payload.root_title || "Runtime-only workflow" %></p>
            </div>
            <span class={state_badge_class(payload.status)}><%= payload.status || "unknown" %></span>
          </header>

          <section :if={!payload.registry_available?} class="workflow-detail-notice">
            Registry unavailable
          </section>

          <section class="workflow-detail-grid">
            <article>
              <h2>Runtime entries</h2>
              <%= if payload.runtime_entries == [] do %>
                <p class="empty-state">No runtime entries</p>
              <% else %>
                <div :for={entry <- payload.runtime_entries} class="node-row">
                  <strong><%= entry.issue_identifier %></strong>
                  <span class={state_badge_class(entry.status)}><%= entry.status %></span>
                  <span><%= phase_label(entry.phase) || "n/a" %></span>
                  <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                </div>
              <% end %>
            </article>

            <article>
              <h2>Registry nodes</h2>
              <%= if payload.nodes == [] do %>
                <p class="empty-state">No registry nodes</p>
              <% else %>
                <div class="node-list">
                  <div :for={node <- payload.nodes} class="node-row">
                    <strong><%= node.node_key %></strong>
                    <span><%= node.issue_identifier || "n/a" %></span>
                    <span class={state_badge_class(node.status)}><%= node.status || "unknown" %></span>
                    <span><%= node.task_type || "n/a" %></span>
                    <p><%= node.completion_summary || node.review_summary || node.blocked_reason || "n/a" %></p>
                  </div>
                </div>
              <% end %>
            </article>

            <article>
              <h2>Attention</h2>
              <%= if payload.attention_items == [] do %>
                <p class="empty-state">No operator action needed</p>
              <% else %>
                <div :for={item <- payload.attention_items} class="attention-item">
                  <span class="attention-kind"><%= item.kind %></span>
                  <strong><%= item.issue_identifier %></strong>
                  <p><%= item[:reason] || "Needs operator review" %></p>
                </div>
              <% end %>
            </article>
          </section>

        <% {:error, :workflow_not_found} -> %>
          <section class="error-card">
            <h1>Workflow not found</h1>
            <p>No registry or active runtime entries were found for <%= @root_identifier %>.</p>
          </section>
      <% end %>
    </section>
    """
  end

  defp load_payload(root_identifier) do
    Presenter.workflow_payload(root_identifier, orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp phase_label(nil), do: nil
  defp phase_label(phase) when is_atom(phase), do: Atom.to_string(phase)
  defp phase_label(phase), do: to_string(phase)

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
end
