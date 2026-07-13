defmodule SymphonyElixir.WorkflowGitAdapterStub do
  def initialize_candidate(_workspace, _worker_host, remote, target_branch, candidate_branch) do
    respond(:initialize_candidate, [remote, target_branch, candidate_branch], {
      :ok,
      %{
        target_sha: "target-base",
        candidate_sha: "candidate-base",
        candidate_branch: candidate_branch
      }
    })
  end

  def prepare_private_branch(_workspace, _worker_host, remote, branch, base_sha) do
    respond(:prepare_private_branch, [remote, branch, base_sha], {
      :ok,
      %{remote: remote, branch: branch, head_sha: base_sha}
    })
  end

  def checkout_commit(_workspace, _worker_host, sha) do
    respond(:checkout_commit, [sha], :ok)
  end

  def inspect_completion(_workspace, _worker_host, _base_sha, _allowed_paths) do
    respond(:inspect_completion, [], {
      :ok,
      %{
        branch: "symphony/test/issue",
        head_sha: "candidate-base",
        business_dirty_paths: [],
        business_changed_paths: []
      }
    })
  end

  def ancestor?(_workspace, _worker_host, ancestor_sha, descendant_sha) do
    respond(:ancestor?, [ancestor_sha, descendant_sha], {:ok, true})
  end

  def fetch_ref(_workspace, _worker_host, _remote, branch) do
    default = if String.contains?(branch, "candidate"), do: "candidate-base", else: "target-base"
    respond(:fetch_ref, [branch], {:ok, default})
  end

  def push_private_branch(_workspace, _worker_host, _remote, branch, head_sha) do
    respond(:push_private_branch, [branch, head_sha], {:ok, head_sha})
  end

  def compare_and_swap_ref(
        _workspace,
        _worker_host,
        _remote,
        branch,
        expected_sha,
        new_sha
      ) do
    respond(:compare_and_swap_ref, [branch, expected_sha, new_sha], {:ok, new_sha})
  end

  def hash_artifact(path, _worker_host) do
    respond(:hash_artifact, [path], {:ok, "artifact-hash"})
  end

  defp respond(key, args, default) do
    case Application.get_env(:symphony_elixir, :workflow_git_adapter_stub, %{}) |> Map.get(key) do
      fun when is_function(fun) -> apply(fun, args)
      nil -> default
      value -> value
    end
  end
end
