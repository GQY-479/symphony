defmodule SymphonyElixir.Workflow.GitAdapter do
  @moduledoc """
  Boundary for Git facts and operations used by the workflow controller.
  """

  @type worker_host :: String.t() | nil

  @spec driver() :: module()
  def driver do
    Application.get_env(
      :symphony_elixir,
      :workflow_git_adapter_driver,
      SymphonyElixir.Workflow.GitAdapter.Command
    )
  end

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

  @spec inspect_completion(Path.t(), worker_host(), String.t(), [Path.t()]) ::
          {:ok, map()} | {:error, term()}
  def inspect_completion(workspace, worker_host, base_sha, allowed_control_paths) do
    driver().inspect_completion(workspace, worker_host, base_sha, allowed_control_paths)
  end

  @spec ancestor?(Path.t(), worker_host(), String.t(), String.t()) ::
          {:ok, boolean()} | {:error, term()}
  def ancestor?(workspace, worker_host, ancestor_sha, descendant_sha) do
    driver().ancestor?(workspace, worker_host, ancestor_sha, descendant_sha)
  end

  @spec hash_artifact(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def hash_artifact(path), do: hash_artifact(path, nil)

  @spec hash_artifact(Path.t(), worker_host()) :: {:ok, String.t()} | {:error, term()}
  def hash_artifact(path, worker_host) do
    driver().hash_artifact(path, worker_host)
  end
end
