defmodule SymphonyElixir.Workflow.GitAdapter do
  @moduledoc """
  Boundary for Git facts and operations used by the workflow controller.
  """

  @not_configured {:error, :git_operation_not_configured}

  @spec build_issue_diff_subject(String.t(), String.t(), String.t()) :: map()
  def build_issue_diff_subject(branch, base_sha, head_sha) do
    %{
      "type" => "issue_diff",
      "branch" => branch,
      "base_sha" => base_sha,
      "head_sha" => head_sha,
      "paths" => []
    }
  end

  @spec build_candidate_range_subject(String.t(), String.t(), String.t()) :: map()
  def build_candidate_range_subject(branch, base_sha, head_sha) do
    %{
      "type" => "candidate_range",
      "branch" => branch,
      "base_sha" => base_sha,
      "head_sha" => head_sha,
      "paths" => []
    }
  end

  @spec hash_artifact(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def hash_artifact(path) when is_binary(path) do
    with {:ok, body} <- File.read(path) do
      {:ok, :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)}
    end
  end

  @spec create_candidate_branch(term(), String.t()) :: {:error, :git_operation_not_configured}
  def create_candidate_branch(_root_issue, _target_branch), do: @not_configured

  @spec create_issue_branch(term(), term(), String.t()) :: {:error, :git_operation_not_configured}
  def create_issue_branch(_root_issue, _issue, _candidate_head_sha), do: @not_configured

  @spec commit_issue_workspace(term(), Path.t()) :: {:error, :git_operation_not_configured}
  def commit_issue_workspace(_issue, _workspace), do: @not_configured

  @spec push_branch(String.t()) :: {:error, :git_operation_not_configured}
  def push_branch(_branch), do: @not_configured

  @spec merge_issue_to_candidate(String.t(), String.t()) :: {:error, :git_operation_not_configured}
  def merge_issue_to_candidate(_issue_branch, _candidate_branch), do: @not_configured

  @spec merge_candidate_to_target(String.t(), String.t(), String.t()) ::
          {:error, :git_operation_not_configured}
  def merge_candidate_to_target(_candidate_branch, _target_branch, _expected_head_sha),
    do: @not_configured
end
