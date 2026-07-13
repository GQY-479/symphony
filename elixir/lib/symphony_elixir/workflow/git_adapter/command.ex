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

  defp git_lines(workspace, worker_host, args) do
    with {:ok, value} <- git_value(workspace, worker_host, args) do
      {:ok, String.split(value, "\n", trim: true)}
    end
  end

  defp git(workspace, worker_host, args) do
    command = Enum.map_join(["git" | args], " ", &shell_escape/1)
    Workspace.run_command(workspace, command, worker_host)
  end

  defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
