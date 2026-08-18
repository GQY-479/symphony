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

  @spec initialize_candidate(Path.t(), worker_host(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def initialize_candidate(workspace, worker_host, remote, target_branch, candidate_branch) do
    driver().initialize_candidate(workspace, worker_host, remote, target_branch, candidate_branch)
  end

  @spec prepare_private_branch(Path.t(), worker_host(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def prepare_private_branch(workspace, worker_host, remote, branch, base_sha) do
    driver().prepare_private_branch(workspace, worker_host, remote, branch, base_sha)
  end

  @spec checkout_commit(Path.t(), worker_host(), String.t()) :: :ok | {:error, term()}
  def checkout_commit(workspace, worker_host, sha) do
    driver().checkout_commit(workspace, worker_host, sha)
  end

  @spec push_private_branch(Path.t(), worker_host(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def push_private_branch(workspace, worker_host, remote, branch, head_sha) do
    driver().push_private_branch(workspace, worker_host, remote, branch, head_sha)
  end

  @spec fetch_ref(Path.t(), worker_host(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def fetch_ref(workspace, worker_host, remote, branch) do
    driver().fetch_ref(workspace, worker_host, remote, branch)
  end

  @spec compare_and_swap_ref(
          Path.t(),
          worker_host(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, String.t()} | {:error, term()}
  def compare_and_swap_ref(workspace, worker_host, remote, branch, expected_sha, new_sha) do
    driver().compare_and_swap_ref(
      workspace,
      worker_host,
      remote,
      branch,
      expected_sha,
      new_sha
    )
  end

  @spec hash_artifact(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def hash_artifact(path), do: hash_artifact(path, nil)

  @spec hash_artifact(Path.t(), worker_host()) :: {:ok, String.t()} | {:error, term()}
  def hash_artifact(path, worker_host) do
    driver().hash_artifact(path, worker_host)
  end
end
