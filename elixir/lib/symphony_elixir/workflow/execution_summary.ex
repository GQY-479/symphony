defmodule SymphonyElixir.Workflow.ExecutionSummary do
  @moduledoc """
  Generates a concise local execution summary for orchestrated workflow issues.

  The summary captures key information about an orchestration run including:
  - Issue identifier
  - Selected agent
  - Planner decision (from workflow plan)
  - Turn count
  - Artifact paths
  - Final issue state
  - Failure reason when present
  """

  alias SymphonyElixir.Workflow.Artifacts

  @summary_filename "execution_summary.json"

  @type t :: %{
          issue_identifier: String.t(),
          selected_agent: String.t() | nil,
          planner_decision: map() | nil,
          turn_count: non_neg_integer(),
          artifact_paths: [String.t()],
          final_issue_state: String.t() | nil,
          failure_reason: String.t() | nil
        }

  @spec summary_path(Path.t()) :: Path.t()
  def summary_path(workspace) when is_binary(workspace) do
    Path.join([workspace, Artifacts.artifact_dir(), @summary_filename])
  end

  @spec generate(map()) :: {:ok, t()} | {:error, term()}
  def generate(running_entry) when is_map(running_entry) do
    with {:ok, workspace} <- running_workspace(running_entry),
         {:ok, plan} <- load_plan(workspace) do
      summary = %{
        issue_identifier: Map.get(running_entry, :identifier) || Map.get(running_entry, "identifier"),
        selected_agent: Map.get(running_entry, :agent_id) || Map.get(running_entry, "agent_id"),
        planner_decision: extract_planner_decision(plan),
        turn_count: Map.get(running_entry, :turn_count, 0) || Map.get(running_entry, "turn_count", 0),
        artifact_paths: collect_artifact_paths(workspace),
        final_issue_state: extract_issue_state(running_entry),
        failure_reason: extract_failure_reason(running_entry)
      }

      {:ok, summary}
    end
  end

  def generate(_running_entry), do: {:error, :invalid_running_entry}

  @spec save(t(), Path.t()) :: :ok | {:error, term()}
  def save(summary, workspace) when is_map(summary) and is_binary(workspace) do
    path = summary_path(workspace)
    dir = Path.dirname(path)

    temp_path =
      Path.join(
        dir,
        "#{Path.basename(path)}.#{System.os_time(:nanosecond)}.#{System.unique_integer([:positive])}.tmp"
      )

    File.mkdir_p!(dir)

    try do
      File.write!(temp_path, Jason.encode_to_iodata!(summary, pretty: true))
      File.rename!(temp_path, path)
      :ok
    after
      if File.exists?(temp_path), do: File.rm!(temp_path)
    end
  end

  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(workspace) when is_binary(workspace) do
    path = summary_path(workspace)

    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body) do
      {:ok, normalize_loaded_summary(decoded)}
    end
  end

  defp running_workspace(%{workspace_path: workspace}) when is_binary(workspace) and workspace != "" do
    {:ok, workspace}
  end

  defp running_workspace(%{"workspace_path" => workspace}) when is_binary(workspace) and workspace != "" do
    {:ok, workspace}
  end

  defp running_workspace(_running_entry), do: {:error, :missing_workspace_path}

  defp load_plan(workspace) do
    case Artifacts.load_workflow_plan(workspace) do
      {:ok, plan} -> {:ok, plan}
      {:error, _reason} -> {:ok, %{}}
    end
  end

  defp extract_planner_decision(%{"summary" => summary} = plan) when is_binary(summary) do
    %{
      "summary" => summary,
      "kind" => plan["kind"] || plan["mode"],
      "confidence" => plan["confidence"]
    }
  end

  defp extract_planner_decision(_plan), do: nil

  defp collect_artifact_paths(workspace) do
    [
      Artifacts.workflow_plan_path(workspace),
      Artifacts.completion_packet_path(workspace),
      Artifacts.review_decision_path(workspace)
    ]
    |> Enum.filter(&File.exists?/1)
  end

  defp extract_issue_state(%{issue: %{state: state}}) when is_binary(state), do: state
  defp extract_issue_state(%{issue: %{"state" => state}}) when is_binary(state), do: state
  defp extract_issue_state(%{"issue" => %{state: state}}) when is_binary(state), do: state
  defp extract_issue_state(%{"issue" => %{"state" => state}}) when is_binary(state), do: state
  defp extract_issue_state(_running_entry), do: nil

  defp extract_failure_reason(%{error: error}) when is_binary(error), do: error
  defp extract_failure_reason(%{"error" => error}) when is_binary(error), do: error
  defp extract_failure_reason(_running_entry), do: nil

  defp normalize_loaded_summary(summary) when is_map(summary) do
    %{
      issue_identifier: summary["issue_identifier"],
      selected_agent: summary["selected_agent"],
      planner_decision: summary["planner_decision"],
      turn_count: summary["turn_count"] || 0,
      artifact_paths: summary["artifact_paths"] || [],
      final_issue_state: summary["final_issue_state"],
      failure_reason: summary["failure_reason"]
    }
  end

  defp normalize_loaded_summary(_summary), do: %{}
end
