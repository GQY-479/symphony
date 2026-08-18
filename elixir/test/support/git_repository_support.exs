defmodule SymphonyElixir.GitRepositorySupport do
  @spec create!(String.t()) :: %{
          root: Path.t(),
          remote: Path.t(),
          seed: Path.t(),
          workspace: Path.t()
        }
  def create!(name) do
    root = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
    remote = Path.join(root, "remote.git")
    seed = Path.join(root, "seed")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(root)

    run!(root, ["init", "--bare", remote])
    run!(root, ["init", "-b", "main", seed])
    File.write!(Path.join(seed, "README.md"), "initial\n")
    run!(seed, ["add", "README.md"])

    run!(seed, [
      "-c",
      "user.name=Symphony Test",
      "-c",
      "user.email=symphony@example.com",
      "commit",
      "-m",
      "initial"
    ])

    run!(seed, ["remote", "add", "origin", remote])
    run!(seed, ["push", "-u", "origin", "main"])
    run!(root, ["clone", remote, workspace])
    run!(workspace, ["checkout", "main"])

    %{root: root, remote: remote, seed: seed, workspace: workspace}
  end

  @spec commit!(Path.t(), String.t(), String.t()) :: String.t()
  def commit!(workspace, path, body) do
    File.write!(Path.join(workspace, path), body)
    run!(workspace, ["add", path])

    run!(workspace, [
      "-c",
      "user.name=Symphony Test",
      "-c",
      "user.email=symphony@example.com",
      "commit",
      "-m",
      "update #{path}"
    ])

    run!(workspace, ["rev-parse", "HEAD"])
  end

  @spec run!(Path.t(), [String.t()]) :: String.t()
  def run!(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {output, 0} ->
        String.trim(output)

      {output, status} ->
        raise "git 命令失败 status=#{status} args=#{inspect(args)} output=#{output}"
    end
  end
end
