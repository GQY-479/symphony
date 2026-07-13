defmodule SymphonyElixir.Workflow.GitAdapter.Command do
  @moduledoc false

  alias SymphonyElixir.Workspace

  @spec inspect_completion(Path.t(), String.t() | nil, String.t(), [Path.t()]) ::
          {:ok, map()} | {:error, term()}
  def inspect_completion(workspace, worker_host, base_sha, allowed_control_paths) do
    with {:ok, branch} <- git_value(workspace, worker_host, ["branch", "--show-current"]),
         {:ok, head_sha} <- git_value(workspace, worker_host, ["rev-parse", "HEAD"]),
         {:ok, unstaged} <- git_lines(workspace, worker_host, ["diff", "--name-only"]),
         {:ok, staged} <- git_lines(workspace, worker_host, ["diff", "--cached", "--name-only"]),
         {:ok, untracked} <-
           git_lines(workspace, worker_host, ["ls-files", "--others", "--exclude-standard"]),
         {:ok, changed} <-
           git_lines(workspace, worker_host, ["diff", "--name-only", "#{base_sha}..#{head_sha}"]) do
      dirty =
        (unstaged ++ staged ++ untracked)
        |> Enum.uniq()
        |> Enum.reject(&(&1 in allowed_control_paths))
        |> Enum.sort()

      {:ok,
       %{
         branch: branch,
         head_sha: head_sha,
         business_dirty_paths: dirty,
         business_changed_paths: Enum.sort(Enum.uniq(changed))
       }}
    end
  end

  @spec ancestor?(Path.t(), String.t() | nil, String.t(), String.t()) ::
          {:ok, boolean()} | {:error, term()}
  def ancestor?(workspace, worker_host, ancestor_sha, descendant_sha) do
    case git(workspace, worker_host, ["merge-base", "--is-ancestor", ancestor_sha, descendant_sha]) do
      {:ok, {_output, 0}} -> {:ok, true}
      {:ok, {_output, 1}} -> {:ok, false}
      {:ok, {output, status}} -> {:error, {:git_command_failed, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec initialize_candidate(Path.t(), String.t() | nil, String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def initialize_candidate(workspace, worker_host, remote, target_branch, candidate_branch) do
    with {:ok, target_sha} <- fetch_ref(workspace, worker_host, remote, target_branch) do
      case fetch_ref(workspace, worker_host, remote, candidate_branch) do
        {:ok, candidate_sha} ->
          {:ok,
           %{
             target_sha: target_sha,
             candidate_sha: candidate_sha,
             candidate_branch: candidate_branch
           }}

        {:error, {:missing_remote_ref, ^candidate_branch}} ->
          with {:ok, _output} <-
                 git_ok(workspace, worker_host, [
                   "push",
                   remote,
                   "#{target_sha}:refs/heads/#{candidate_branch}"
                 ]),
               {:ok, candidate_sha} <-
                 fetch_ref(workspace, worker_host, remote, candidate_branch) do
            {:ok,
             %{
               target_sha: target_sha,
               candidate_sha: candidate_sha,
               candidate_branch: candidate_branch
             }}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec prepare_private_branch(Path.t(), String.t() | nil, String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def prepare_private_branch(workspace, worker_host, remote, branch, base_sha) do
    with {:ok, current_branch} <-
           git_value(workspace, worker_host, ["branch", "--show-current"]),
         :ok <-
           checkout_private_branch(workspace, worker_host, current_branch, branch, base_sha),
         {:ok, head_sha} <- git_value(workspace, worker_host, ["rev-parse", "HEAD"]) do
      {:ok, %{branch: branch, head_sha: head_sha, remote: remote}}
    end
  end

  @spec checkout_commit(Path.t(), String.t() | nil, String.t()) :: :ok | {:error, term()}
  def checkout_commit(workspace, worker_host, sha) do
    case git_ok(workspace, worker_host, ["checkout", "--detach", sha]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec fetch_ref(Path.t(), String.t() | nil, String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def fetch_ref(workspace, worker_host, remote, branch) do
    with :ok <- validate_ref(remote),
         :ok <- validate_ref(branch),
         {:ok, _output} <-
           git_ok(workspace, worker_host, [
             "fetch",
             "--no-tags",
             remote,
             "+refs/heads/#{branch}:refs/remotes/#{remote}/#{branch}"
           ]),
         {:ok, sha} <-
           git_value(workspace, worker_host, ["rev-parse", "refs/remotes/#{remote}/#{branch}"]) do
      {:ok, sha}
    else
      {:error, {:git_command_failed, _status, output}} ->
        if String.contains?(output, ["couldn't find remote ref", "not a valid ref"]),
          do: {:error, {:missing_remote_ref, branch}},
          else: {:error, {:git_fetch_failed, branch, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec push_private_branch(Path.t(), String.t() | nil, String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def push_private_branch(workspace, worker_host, remote, branch, head_sha) do
    with {:ok, _output} <-
           git_ok(workspace, worker_host, [
             "push",
             remote,
             "#{head_sha}:refs/heads/#{branch}"
           ]),
         {:ok, confirmed_sha} <- fetch_ref(workspace, worker_host, remote, branch) do
      if confirmed_sha == head_sha,
        do: {:ok, confirmed_sha},
        else: {:error, {:remote_ref_mismatch, head_sha, confirmed_sha}}
    end
  end

  @spec compare_and_swap_ref(
          Path.t(),
          String.t() | nil,
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, String.t()} | {:error, term()}
  def compare_and_swap_ref(workspace, worker_host, remote, branch, expected_sha, new_sha) do
    with {:ok, true} <- ancestor?(workspace, worker_host, expected_sha, new_sha),
         {:ok, _output} <-
           git_ok(workspace, worker_host, [
             "push",
             "--force-with-lease=refs/heads/#{branch}:#{expected_sha}",
             remote,
             "#{new_sha}:refs/heads/#{branch}"
           ]),
         {:ok, confirmed_sha} <- fetch_ref(workspace, worker_host, remote, branch) do
      if confirmed_sha == new_sha,
        do: {:ok, confirmed_sha},
        else: {:error, {:remote_ref_mismatch, new_sha, confirmed_sha}}
    else
      {:ok, false} -> {:error, {:non_fast_forward, expected_sha, new_sha}}
      {:error, {:git_command_failed, _status, output}} -> classify_ref_update_error(output)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec hash_artifact(Path.t(), String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def hash_artifact(path, worker_host) do
    with {:ok, body} <- Workspace.read_file(path, worker_host) do
      {:ok, :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)}
    end
  end

  defp git_value(workspace, worker_host, args) do
    with {:ok, {output, 0}} <- git(workspace, worker_host, args) do
      {:ok, String.trim(output)}
    else
      {:ok, {output, status}} -> {:error, {:git_command_failed, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp git_ok(workspace, worker_host, args) do
    case git(workspace, worker_host, args) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, status}} -> {:error, {:git_command_failed, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp git_lines(workspace, worker_host, args) do
    with {:ok, value} <- git_value(workspace, worker_host, args) do
      {:ok, String.split(value, "\n", trim: true)}
    end
  end

  defp git(workspace, worker_host, args) do
    command = Enum.map_join(["git" | args], " ", &shell_escape/1)
    Workspace.run_command(workspace, command, worker_host)
  end

  defp checkout_private_branch(_workspace, _worker_host, branch, branch, _base_sha), do: :ok

  defp checkout_private_branch(workspace, worker_host, _current_branch, branch, base_sha) do
    case git_ok(workspace, worker_host, ["checkout", "-B", branch, base_sha]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_ref(value) when is_binary(value) do
    if value != "" and not String.contains?(value, ["\n", "\r", <<0>>, ".."]) do
      :ok
    else
      {:error, {:invalid_git_ref, value}}
    end
  end

  defp classify_ref_update_error(output) do
    cond do
      String.contains?(output, ["stale info", "rejected", "non-fast-forward"]) ->
        {:error, {:stale_remote_ref, output}}

      String.contains?(output, [
        "Could not resolve host",
        "Connection timed out",
        "Failed to connect"
      ]) ->
        {:error, {:git_remote_unavailable, output}}

      String.contains?(output, ["Permission denied", "Authentication failed", "403"]) ->
        {:error, {:git_permission_denied, output}}

      true ->
        {:error, {:git_push_failed, output}}
    end
  end

  defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
