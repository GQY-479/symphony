# Agent 准备式 Workflow 集成实施计划

> **供自动化执行使用：** 必须使用 `superpowers:subagent-driven-development`（推荐）或 `superpowers:executing-plans` 按任务执行本计划。每个步骤使用复选框跟踪，测试先行，每个阶段独立提交。

**目标：** 将 issue graph 的完成语义改为“agent 在私有分支准备完整提交和合并结果，Controller 校验后受保护地推进 candidate/target”，彻底阻止未提交、未集成或未发布的结果关闭 root issue。

**架构：** 保留 Orchestrator、Workflow.Controller、AgentRunner、Registry 的现有权威边界。新增可在本地或 SSH worker 执行的 GitAdapter 命令实现；Agent 负责私有分支提交和冲突解决，Controller 负责完成校验、agent continuation、共享引用 compare-and-swap、checkpoint 和 Tracker 收口。

**技术栈：** Elixir 1.19、OTP 28、Ecto embedded schema、ExUnit、Git CLI、临时 bare Git remote、现有文件型 Workflow Registry、Memory Tracker。

**设计依据：** `docs/superpowers/specs/2026-07-13-agent-prepared-workflow-integration-design.md`

---

## 文件结构

### 新增文件

- `elixir/lib/symphony_elixir/workflow/git_adapter/command.ex`
  - 在 issue workspace 所在的本地机器或 SSH worker 上执行真实 Git 命令。
  - 只返回 Git 事实和受保护引用更新结果，不解释 workflow 语义。
- `elixir/test/support/git_repository_support.exs`
  - 创建临时 bare remote、seed repository 和 clone，供 GitAdapter 集成测试复用。
- `elixir/test/support/workflow_git_adapter_stub.exs`
  - 为 Controller/Orchestrator 测试提供进程无关、可配置的高层 GitAdapter stub。

### 修改文件

- `elixir/lib/symphony_elixir/workspace.ex`
  - 提供统一的本地/SSH workspace 命令执行入口。
- `elixir/lib/symphony_elixir/config/schema.ex`
  - 增加 Git remote、target branch 和 completion continuation 上限。
- `elixir/lib/symphony_elixir/workflow/git_adapter.ex`
  - 从占位模块改为稳定 facade；默认委托给 Command driver，测试可注入 stub。
- `elixir/lib/symphony_elixir/workflow/registry.ex`
  - 保存 root Git 事实、node continuation、candidate/no-change/publication checkpoint。
- `elixir/lib/symphony_elixir/workflow/controller.ex`
  - 初始化 candidate、准备 issue workspace、执行完成校验、推进共享引用和最终发布。
- `elixir/lib/symphony_elixir/workflow/prompts.ex`
  - 固化提交、清理、基线吸收、integration 和 review 任务约束。
- `elixir/lib/symphony_elixir/agent_runner.ex`
  - agent 启动前准备 workflow Git workspace。
- `elixir/lib/symphony_elixir/orchestrator.ex`
  - 区分 agent continuation 与 controller-only retry。
- `elixir/test/support/test_support.exs`
  - 增加新配置默认值并在测试间清理 GitAdapter stub。
- `elixir/test/test_helper.exs`
  - 加载两个新测试支持模块。
- `elixir/test/symphony_elixir/workspace_and_config_test.exs`
- `elixir/test/symphony_elixir/config/schema_test.exs`
- `elixir/test/symphony_elixir/workflow_git_adapter_test.exs`
- `elixir/test/symphony_elixir/workflow_artifacts_test.exs`
- `elixir/test/symphony_elixir/workflow_controller_test.exs`
- `elixir/test/symphony_elixir/workflow_orchestrator_test.exs`
- `elixir/test/symphony_elixir/workflow_prompt_contract_test.exs`
- `elixir/test/symphony_elixir/workflow_smoke_test.exs`
- `elixir/WORKFLOW.md`
- `elixir/README.md`
- `elixir/docs/issue_driven_dynamic_workflow.md`
- `SPEC.md`
- `README.md`

---

### Task 1: 增加本地与 SSH Worker 通用命令边界

**Files:**
- Modify: `elixir/lib/symphony_elixir/workspace.ex`
- Modify: `elixir/test/symphony_elixir/workspace_and_config_test.exs`

- [ ] **Step 1: 写本地命令、失败状态和超时测试**

在 `workspace_and_config_test.exs` 增加：

```elixir
test "run_command 在指定 workspace 执行并保留退出状态" do
  workspace = Path.join(System.tmp_dir!(), "workspace-command-#{System.unique_integer([:positive])}")
  File.mkdir_p!(workspace)

  assert {:ok, {"ok\n", 0}} = Workspace.run_command(workspace, "printf 'ok\\n'")
  assert {:ok, {"failed\n", 7}} = Workspace.run_command(workspace, "printf 'failed\\n'; exit 7")
end

test "run_command 超时会终止命令" do
  workspace = Path.join(System.tmp_dir!(), "workspace-timeout-#{System.unique_integer([:positive])}")
  File.mkdir_p!(workspace)

  assert {:error, {:workspace_command_timeout, 20}} =
           Workspace.run_command(workspace, "sleep 2", nil, timeout_ms: 20)
end

test "read_file 读取 workspace 文件" do
  workspace = Path.join(System.tmp_dir!(), "workspace-read-#{System.unique_integer([:positive])}")
  File.mkdir_p!(workspace)
  File.write!(Path.join(workspace, "result.json"), "{\"ok\":true}")

  assert {:ok, "{\"ok\":true}"} = Workspace.read_file(Path.join(workspace, "result.json"))
end
```

- [ ] **Step 2: 运行测试确认失败**

Run:

```powershell
cd elixir
mix test test/symphony_elixir/workspace_and_config_test.exs
```

Expected: FAIL，提示 `Workspace.run_command/4` 未定义。

- [ ] **Step 3: 实现统一命令入口**

在 `Workspace` 中增加公共函数；复用现有 `run_remote_command/3` 和 `shell_escape/1`：

```elixir
@spec run_command(Path.t(), String.t(), worker_host(), keyword()) ::
        {:ok, {String.t(), non_neg_integer()}} | {:error, term()}
def run_command(workspace, command, worker_host \\ nil, opts \\ [])

def run_command(workspace, command, nil, opts)
    when is_binary(workspace) and is_binary(command) and is_list(opts) do
  timeout_ms = Keyword.get(opts, :timeout_ms, Config.settings!().hooks.timeout_ms)

  task =
    Task.async(fn ->
      System.cmd("sh", ["-lc", command], cd: workspace, stderr_to_stdout: true)
    end)

  case Task.yield(task, timeout_ms) do
    {:ok, result} -> {:ok, result}
    nil ->
      Task.shutdown(task, :brutal_kill)
      {:error, {:workspace_command_timeout, timeout_ms}}
  end
end

def run_command(workspace, command, worker_host, opts)
    when is_binary(workspace) and is_binary(command) and is_binary(worker_host) and is_list(opts) do
  timeout_ms = Keyword.get(opts, :timeout_ms, Config.settings!().hooks.timeout_ms)
  script = "cd #{shell_escape(workspace)} && #{command}"

  case run_remote_command(worker_host, script, timeout_ms) do
    {:ok, {output, status}} -> {:ok, {output, status}}
    {:error, {:workspace_hook_timeout, "remote_command", ^timeout_ms}} ->
      {:error, {:workspace_command_timeout, timeout_ms}}
    {:error, reason} -> {:error, reason}
  end
end

@spec read_file(Path.t(), worker_host()) :: {:ok, binary()} | {:error, term()}
def read_file(path, worker_host \\ nil)

def read_file(path, nil) when is_binary(path), do: File.read(path)

def read_file(path, worker_host) when is_binary(path) and is_binary(worker_host) do
  workspace = Path.dirname(path)
  filename = Path.basename(path)

  with {:ok, {encoded, 0}} <-
         run_command(workspace, "base64 < #{shell_escape(filename)}", worker_host),
       {:ok, body} <- Base.decode64(String.replace(encoded, ~r/\\s+/, "")) do
    {:ok, body}
  else
    {:ok, {output, status}} -> {:error, {:workspace_read_failed, status, output}}
    :error -> {:error, :invalid_base64_file_content}
    {:error, reason} -> {:error, reason}
  end
end
```

- [ ] **Step 4: 运行目标测试和规格检查**

Run:

```powershell
cd elixir
mix test test/symphony_elixir/workspace_and_config_test.exs
mix specs.check
```

Expected: PASS，0 failures；所有新增 public function 均有 `@spec`。

- [ ] **Step 5: 提交**

```powershell
git add elixir/lib/symphony_elixir/workspace.ex elixir/test/symphony_elixir/workspace_and_config_test.exs
git commit -m "feat(workspace): 增加 worker 命令执行边界"
```

---

### Task 2: 定义 Git 集成配置契约

**Files:**
- Modify: `elixir/lib/symphony_elixir/config/schema.ex`
- Modify: `elixir/test/symphony_elixir/config/schema_test.exs`
- Modify: `elixir/test/support/test_support.exs`

- [ ] **Step 1: 写默认值和校验失败测试**

在 `config/schema_test.exs` 增加：

```elixir
test "orchestration 提供 Git 集成默认值" do
  assert {:ok, settings} = Schema.parse(%{"orchestration" => %{}})
  assert settings.orchestration.git_remote == "origin"
  assert settings.orchestration.target_branch == "main"
  assert settings.orchestration.completion_max_continuations == 3
end

test "completion_max_continuations 必须为正数" do
  assert {:error, {:invalid_workflow_config, message}} =
           Schema.parse(%{
             "orchestration" => %{"completion_max_continuations" => 0}
           })

  assert message =~ "completion_max_continuations"
  assert message =~ "must be greater than 0"
end
```

- [ ] **Step 2: 运行测试确认失败**

Run:

```powershell
cd elixir
mix test test/symphony_elixir/config/schema_test.exs
```

Expected: FAIL，缺少三个 orchestration 字段。

- [ ] **Step 3: 增加 Schema 字段和验证**

在 `Config.Schema.Orchestration` 中加入：

```elixir
field(:git_remote, :string, default: "origin")
field(:target_branch, :string, default: "main")
field(:completion_max_continuations, :integer, default: 3)
```

将 changeset cast 列表改为包含：

```elixir
[
  :enabled,
  :mode,
  :planner_agent,
  :reviewer_agent,
  :artifact_dir,
  :planning_max_turns,
  :review_max_turns,
  :git_remote,
  :target_branch,
  :completion_max_continuations
]
```

并增加：

```elixir
|> validate_required([:git_remote, :target_branch])
|> validate_number(:completion_max_continuations, greater_than: 0)
```

- [ ] **Step 4: 更新测试 WORKFLOW 生成器**

将 `@orchestration_defaults` 增加：

```elixir
"git_remote" => "origin",
"target_branch" => "main",
"completion_max_continuations" => 3
```

并在 `orchestration_yaml/1` 输出：

```elixir
"  git_remote: #{yaml_value(Map.get(config, "git_remote"))}",
"  target_branch: #{yaml_value(Map.get(config, "target_branch"))}",
"  completion_max_continuations: #{yaml_value(Map.get(config, "completion_max_continuations"))}"
```

- [ ] **Step 5: 运行配置测试**

Run:

```powershell
cd elixir
mix test test/symphony_elixir/config/schema_test.exs test/symphony_elixir/config_test.exs
```

Expected: PASS，0 failures。

- [ ] **Step 6: 提交**

```powershell
git add elixir/lib/symphony_elixir/config/schema.ex elixir/test/symphony_elixir/config/schema_test.exs elixir/test/support/test_support.exs
git commit -m "feat(config): 定义 workflow Git 集成配置"
```

---

### Task 3: 实现 GitAdapter Facade 和真实 Git 事实读取

**Files:**
- Modify: `elixir/lib/symphony_elixir/workflow/git_adapter.ex`
- Create: `elixir/lib/symphony_elixir/workflow/git_adapter/command.ex`
- Create: `elixir/test/support/git_repository_support.exs`
- Create: `elixir/test/support/workflow_git_adapter_stub.exs`
- Modify: `elixir/test/test_helper.exs`
- Modify: `elixir/test/support/test_support.exs`
- Modify: `elixir/test/symphony_elixir/workflow_git_adapter_test.exs`

- [ ] **Step 1: 创建真实 Git 测试仓库夹具**

创建 `git_repository_support.exs`：

```elixir
defmodule SymphonyElixir.GitRepositorySupport do
  @spec create!(String.t()) :: %{root: Path.t(), remote: Path.t(), seed: Path.t(), workspace: Path.t()}
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
    run!(seed, ["-c", "user.name=Symphony Test", "-c", "user.email=symphony@example.com", "commit", "-m", "initial"])
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
    run!(workspace, ["-c", "user.name=Symphony Test", "-c", "user.email=symphony@example.com", "commit", "-m", "update #{path}"])
    run!(workspace, ["rev-parse", "HEAD"])
  end

  @spec run!(Path.t(), [String.t()]) :: String.t()
  def run!(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> raise "git failed status=#{status} args=#{inspect(args)} output=#{output}"
    end
  end
end
```

在 `test_helper.exs` 加载：

```elixir
Code.require_file("support/git_repository_support.exs", __DIR__)
Code.require_file("support/workflow_git_adapter_stub.exs", __DIR__)
```

- [ ] **Step 2: 写 workspace inspection 和祖先关系失败测试**

在 `workflow_git_adapter_test.exs` 使用真实 driver：

```elixir
alias SymphonyElixir.Workflow.GitAdapter.Command

test "inspect_completion 区分业务提交、未提交文件和控制 artifact" do
  repo = SymphonyElixir.GitRepositorySupport.create!("git-inspect")
  base_sha = SymphonyElixir.GitRepositorySupport.run!(repo.workspace, ["rev-parse", "HEAD"])
  _head_sha = SymphonyElixir.GitRepositorySupport.commit!(repo.workspace, "lib.txt", "committed\n")
  File.write!(Path.join(repo.workspace, "pending.txt"), "pending\n")
  File.mkdir_p!(Path.join(repo.workspace, ".symphony"))
  File.write!(Path.join(repo.workspace, ".symphony/issue_result.json"), "{}")

  assert {:ok, facts} = Command.inspect_completion(repo.workspace, nil, base_sha, [".symphony/issue_result.json"])
  assert facts.business_changed_paths == ["lib.txt"]
  assert facts.business_dirty_paths == ["pending.txt"]
  assert facts.branch == "main"
  assert facts.head_sha != base_sha
end

test "ancestor? 返回真实 commit 图关系" do
  repo = SymphonyElixir.GitRepositorySupport.create!("git-ancestor")
  base_sha = SymphonyElixir.GitRepositorySupport.run!(repo.workspace, ["rev-parse", "HEAD"])
  head_sha = SymphonyElixir.GitRepositorySupport.commit!(repo.workspace, "next.txt", "next\n")

  assert {:ok, true} = Command.ancestor?(repo.workspace, nil, base_sha, head_sha)
  assert {:ok, false} = Command.ancestor?(repo.workspace, nil, head_sha, base_sha)
end
```

- [ ] **Step 3: 运行测试确认失败**

Run:

```powershell
cd elixir
mix test test/symphony_elixir/workflow_git_adapter_test.exs
```

Expected: FAIL，`GitAdapter.Command` 和 inspection API 未定义。

- [ ] **Step 4: 将 GitAdapter 改为可注入 Facade**

`git_adapter.ex` 保留 subject/hash helper，并增加：

```elixir
@type worker_host :: String.t() | nil

@spec driver() :: module()
def driver do
  Application.get_env(
    :symphony_elixir,
    :workflow_git_adapter_driver,
    SymphonyElixir.Workflow.GitAdapter.Command
  )
end

@spec inspect_completion(Path.t(), worker_host(), String.t(), [Path.t()]) :: {:ok, map()} | {:error, term()}
def inspect_completion(workspace, worker_host, base_sha, allowed_control_paths) do
  driver().inspect_completion(workspace, worker_host, base_sha, allowed_control_paths)
end

@spec ancestor?(Path.t(), worker_host(), String.t(), String.t()) :: {:ok, boolean()} | {:error, term()}
def ancestor?(workspace, worker_host, ancestor_sha, descendant_sha) do
  driver().ancestor?(workspace, worker_host, ancestor_sha, descendant_sha)
end

@spec hash_artifact(Path.t(), worker_host()) :: {:ok, String.t()} | {:error, term()}
def hash_artifact(path, worker_host \\ nil) do
  driver().hash_artifact(path, worker_host)
end
```

- [ ] **Step 5: 实现 Command 事实读取**

`Command` 使用 `Workspace.run_command/4`。所有参数先经过单引号 shell escape：

```elixir
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
         {:ok, untracked} <- git_lines(workspace, worker_host, ["ls-files", "--others", "--exclude-standard"]),
         {:ok, changed} <- git_lines(workspace, worker_host, ["diff", "--name-only", "#{base_sha}..#{head_sha}"]) do
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

  @spec ancestor?(Path.t(), String.t() | nil, String.t(), String.t()) :: {:ok, boolean()} | {:error, term()}
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

  defp shell_escape(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
end
```

- [ ] **Step 6: 创建完整测试 Stub 并清理测试环境**

创建 `workflow_git_adapter_stub.exs`。每个 API 支持通过 Application env 注入固定返回值或函数，未配置时提供稳定默认值：

```elixir
defmodule SymphonyElixir.WorkflowGitAdapterStub do
  def initialize_candidate(_workspace, _worker_host, remote, target_branch, candidate_branch) do
    respond(:initialize_candidate, [remote, target_branch, candidate_branch], {
      :ok,
      %{target_sha: "target-base", candidate_sha: "candidate-base", candidate_branch: candidate_branch}
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

  def compare_and_swap_ref(_workspace, _worker_host, _remote, branch, expected_sha, new_sha) do
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
```

`TestSupport.setup` 设置 driver，并在 `on_exit` 删除两个 env：

```elixir
Application.put_env(
  :symphony_elixir,
  :workflow_git_adapter_driver,
  SymphonyElixir.WorkflowGitAdapterStub
)

Application.delete_env(:symphony_elixir, :workflow_git_adapter_driver)
Application.delete_env(:symphony_elixir, :workflow_git_adapter_stub)
```

- [ ] **Step 7: 运行测试**

Run:

```powershell
cd elixir
mix test test/symphony_elixir/workflow_git_adapter_test.exs
mix specs.check
```

Expected: PASS，0 failures。

- [ ] **Step 8: 提交**

```powershell
git add elixir/lib/symphony_elixir/workflow/git_adapter.ex elixir/lib/symphony_elixir/workflow/git_adapter/command.ex elixir/test/support/git_repository_support.exs elixir/test/support/workflow_git_adapter_stub.exs elixir/test/test_helper.exs elixir/test/support/test_support.exs elixir/test/symphony_elixir/workflow_git_adapter_test.exs
git commit -m "feat(workflow): 实现 Git 事实读取边界"
```

---

### Task 4: 实现私有分支和共享引用受保护推进

**Files:**
- Modify: `elixir/lib/symphony_elixir/workflow/git_adapter.ex`
- Modify: `elixir/lib/symphony_elixir/workflow/git_adapter/command.ex`
- Modify: `elixir/test/support/workflow_git_adapter_stub.exs`
- Modify: `elixir/test/symphony_elixir/workflow_git_adapter_test.exs`

- [ ] **Step 1: 写 candidate、私有 branch 和 CAS 测试**

```elixir
test "initialize_candidate 从 remote target 创建 candidate" do
  repo = SymphonyElixir.GitRepositorySupport.create!("git-candidate")

  assert {:ok, facts} =
           Command.initialize_candidate(
             repo.workspace,
             nil,
             "origin",
             "main",
             "symphony/YQE-1/candidate"
           )

  assert facts.target_sha == facts.candidate_sha
  assert facts.candidate_branch == "symphony/YQE-1/candidate"
end

test "compare_and_swap_ref 拒绝过期 expected SHA" do
  repo = SymphonyElixir.GitRepositorySupport.create!("git-cas")
  base = SymphonyElixir.GitRepositorySupport.run!(repo.workspace, ["rev-parse", "HEAD"])
  head = SymphonyElixir.GitRepositorySupport.commit!(repo.workspace, "change.txt", "change\n")

  assert {:error, {:stale_remote_ref, _output}} =
           Command.compare_and_swap_ref(
             repo.workspace,
             nil,
             "origin",
             "main",
             String.duplicate("0", 40),
             head
           )

  assert {:ok, ^head} = Command.compare_and_swap_ref(repo.workspace, nil, "origin", "main", base, head)
end

test "prepare_private_branch 和 checkout_commit 准备可写与只读 workspace" do
  repo = SymphonyElixir.GitRepositorySupport.create!("git-prepare")
  base = SymphonyElixir.GitRepositorySupport.run!(repo.workspace, ["rev-parse", "HEAD"])

  assert {:ok, %{branch: "symphony/YQE-1/YQE-2", head_sha: ^base}} =
           Command.prepare_private_branch(
             repo.workspace,
             nil,
             "origin",
             "symphony/YQE-1/YQE-2",
             base
           )

  assert :ok = Command.checkout_commit(repo.workspace, nil, base)
  assert "" == SymphonyElixir.GitRepositorySupport.run!(repo.workspace, ["branch", "--show-current"])
end
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd elixir; mix test test/symphony_elixir/workflow_git_adapter_test.exs`

Expected: FAIL，缺少 mutation API。

- [ ] **Step 3: 增加 Facade API**

```elixir
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

@spec fetch_ref(Path.t(), worker_host(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
def fetch_ref(workspace, worker_host, remote, branch) do
  driver().fetch_ref(workspace, worker_host, remote, branch)
end

@spec compare_and_swap_ref(Path.t(), worker_host(), String.t(), String.t(), String.t(), String.t()) ::
        {:ok, String.t()} | {:error, term()}
def compare_and_swap_ref(workspace, worker_host, remote, branch, expected_sha, new_sha) do
  driver().compare_and_swap_ref(workspace, worker_host, remote, branch, expected_sha, new_sha)
end
```

- [ ] **Step 4: 实现真实命令**

关键命令固定为：

```elixir
@spec initialize_candidate(Path.t(), String.t() | nil, String.t(), String.t(), String.t()) ::
        {:ok, map()} | {:error, term()}
def initialize_candidate(workspace, worker_host, remote, target_branch, candidate_branch) do
  with {:ok, target_sha} <- fetch_ref(workspace, worker_host, remote, target_branch) do
    case fetch_ref(workspace, worker_host, remote, candidate_branch) do
      {:ok, candidate_sha} ->
        {:ok, %{target_sha: target_sha, candidate_sha: candidate_sha, candidate_branch: candidate_branch}}

      {:error, {:missing_remote_ref, ^candidate_branch}} ->
        with {:ok, _output} <-
               git_ok(workspace, worker_host, ["push", remote, "#{target_sha}:refs/heads/#{candidate_branch}"]),
             {:ok, candidate_sha} <- fetch_ref(workspace, worker_host, remote, candidate_branch) do
          {:ok, %{target_sha: target_sha, candidate_sha: candidate_sha, candidate_branch: candidate_branch}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end

@spec prepare_private_branch(Path.t(), String.t() | nil, String.t(), String.t(), String.t()) ::
        {:ok, map()} | {:error, term()}
def prepare_private_branch(workspace, worker_host, remote, branch, base_sha) do
  with {:ok, current_branch} <- git_value(workspace, worker_host, ["branch", "--show-current"]),
       :ok <- checkout_private_branch(workspace, worker_host, current_branch, branch, base_sha),
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

@spec fetch_ref(Path.t(), String.t() | nil, String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
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
       {:ok, sha} <- git_value(workspace, worker_host, ["rev-parse", "refs/remotes/#{remote}/#{branch}"]) do
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
         git_ok(workspace, worker_host, ["push", remote, "#{head_sha}:refs/heads/#{branch}"]),
       {:ok, confirmed_sha} <- fetch_ref(workspace, worker_host, remote, branch) do
    if confirmed_sha == head_sha,
      do: {:ok, confirmed_sha},
      else: {:error, {:remote_ref_mismatch, head_sha, confirmed_sha}}
  end
end

defp checkout_private_branch(_workspace, _worker_host, branch, branch, _base_sha), do: :ok

defp checkout_private_branch(workspace, worker_host, _current_branch, branch, base_sha) do
  case git_ok(workspace, worker_host, ["checkout", "-B", branch, base_sha]) do
    {:ok, _output} -> :ok
    {:error, reason} -> {:error, reason}
  end
end

defp validate_ref(value) when is_binary(value) do
  if value != "" and not String.contains?(value, ["\n", "\r", <<0>>, ".."]),
    do: :ok,
    else: {:error, {:invalid_git_ref, value}}
end

@spec compare_and_swap_ref(Path.t(), String.t() | nil, String.t(), String.t(), String.t(), String.t()) ::
        {:ok, String.t()} | {:error, term()}
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

defp classify_ref_update_error(output) do
  cond do
    String.contains?(output, ["stale info", "rejected", "non-fast-forward"]) ->
      {:error, {:stale_remote_ref, output}}

    String.contains?(output, ["Could not resolve host", "Connection timed out", "Failed to connect"]) ->
      {:error, {:git_remote_unavailable, output}}

    String.contains?(output, ["Permission denied", "Authentication failed", "403"]) ->
      {:error, {:git_permission_denied, output}}

    true ->
      {:error, {:git_push_failed, output}}
  end
end
```

上述实现显式 fetch `refs/heads/<branch>` 后读取 `refs/remotes/<remote>/<branch>`；branch 和 remote 拒绝换行、NUL 和 `..`。

- [ ] **Step 5: 验证 Stub 的 Mutation API 注入能力并运行测试**

在 `workflow_git_adapter_test.exs` 增加：

```elixir
test "stub 可以注入 compare_and_swap_ref 竞争结果" do
  Application.put_env(:symphony_elixir, :workflow_git_adapter_stub, %{
    compare_and_swap_ref: {:error, {:stale_remote_ref, "rejected"}}
  })

  assert {:error, {:stale_remote_ref, "rejected"}} =
           SymphonyElixir.WorkflowGitAdapterStub.compare_and_swap_ref(
             "/workspace",
             nil,
             "origin",
             "main",
             "old",
             "new"
           )
end
```

Task 3 创建的完整 Stub 已实现本 Task 的所有 mutation API，因此这里不再增加第二套 stub 逻辑。

Run:

```powershell
cd elixir
mix test test/symphony_elixir/workflow_git_adapter_test.exs
mix specs.check
```

Expected: PASS，0 failures。

- [ ] **Step 6: 提交**

```powershell
git add elixir/lib/symphony_elixir/workflow/git_adapter.ex elixir/lib/symphony_elixir/workflow/git_adapter/command.ex elixir/test/support/workflow_git_adapter_stub.exs elixir/test/symphony_elixir/workflow_git_adapter_test.exs
git commit -m "feat(workflow): 增加受保护 Git 引用推进"
```

---

### Task 5: 扩展 Registry Git 事实和幂等 Checkpoint

**Files:**
- Modify: `elixir/lib/symphony_elixir/workflow/registry.ex`
- Modify: `elixir/test/symphony_elixir/workflow_artifacts_test.exs`

- [ ] **Step 1: 写 Registry helper 测试**

```elixir
test "registry 保存 workflow Git、node continuation 和幂等 checkpoint" do
  root = %Issue{id: "root-git", identifier: "YQE-GIT", title: "root", state: "In Progress"}

  registry =
    root
    |> Registry.new_root()
    |> Registry.put_workflow_git(%{
      "remote" => "origin",
      "target_branch" => "main",
      "target_base_sha" => "base",
      "candidate_branch" => "symphony/YQE-GIT/candidate",
      "candidate_head_sha" => "base"
    })
    |> Registry.put_node("implementation", %{"status" => "running"})
    |> Registry.put_node_git("implementation", %{"branch" => "issue-branch", "base_candidate_sha" => "base"})
    |> Registry.put_node_continuation("implementation", %{"reason" => "candidate_advanced", "attempt" => 1})
    |> Registry.add_checkpoint_once(%{"id" => "cp-1", "kind" => "candidate_promotion"})
    |> Registry.add_checkpoint_once(%{"id" => "cp-1", "kind" => "candidate_promotion"})

  assert registry["publication"]["status"] == "pending"
  assert Registry.node(registry, "implementation")["branch"] == "issue-branch"
  assert Registry.node(registry, "implementation")["continuation"]["reason"] == "candidate_advanced"
  assert Enum.count(registry["checkpoints"]) == 1
end
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd elixir; mix test test/symphony_elixir/workflow_artifacts_test.exs`

Expected: FAIL，三个 Registry helper 未定义。

- [ ] **Step 3: 实现 Registry helper**

```elixir
@spec put_node_git(map(), String.t(), map()) :: map()
def put_node_git(registry, node_key, attrs) do
  update_in(registry, ["nodes", node_key], fn node ->
    Map.merge(node || %{}, normalize_map(attrs))
  end)
end

@spec put_node_continuation(map(), String.t(), map()) :: map()
def put_node_continuation(registry, node_key, continuation) do
  put_in(registry, ["nodes", node_key, "continuation"], normalize_map(continuation))
end

@spec clear_node_continuation(map(), String.t()) :: map()
def clear_node_continuation(registry, node_key) do
  update_in(registry, ["nodes", node_key], &Map.delete(&1 || %{}, "continuation"))
end

@spec add_checkpoint_once(map(), map()) :: map()
def add_checkpoint_once(registry, %{"id" => checkpoint_id} = checkpoint) do
  if Enum.any?(registry["checkpoints"] || [], &(&1["id"] == checkpoint_id)) do
    registry
  else
    add_checkpoint(registry, checkpoint)
  end
end

@spec put_publication(map(), map()) :: map()
def put_publication(registry, publication) do
  Map.put(registry, "publication", normalize_map(publication))
end
```

`new_root/1` 增加：

```elixir
"publication" => %{"status" => "pending"}
```

`valid_registry?/1` 允许旧 Registry 缺少 publication，但存在时必须为 map。

- [ ] **Step 4: 运行测试并提交**

Run:

```powershell
cd elixir
mix test test/symphony_elixir/workflow_artifacts_test.exs
```

Expected: PASS，0 failures。

```powershell
git add elixir/lib/symphony_elixir/workflow/registry.ex elixir/test/symphony_elixir/workflow_artifacts_test.exs
git commit -m "feat(workflow): 保存 Git 集成事实"
```

---

### Task 6: 初始化 Candidate 并准备 Agent 私有 Workspace

**Files:**
- Modify: `elixir/lib/symphony_elixir/workflow/controller.ex`
- Modify: `elixir/lib/symphony_elixir/workflow/artifacts.ex`
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Modify: `elixir/test/symphony_elixir/workflow_controller_test.exs`
- Modify: `elixir/test/symphony_elixir/workflow_artifacts_test.exs`
- Modify: `elixir/test/symphony_elixir/acp_agent_runner_test.exs`

- [ ] **Step 1: 写 planning 初始化和 workspace 准备测试**

Controller 测试必须断言：

```elixir
assert {:ok, registry} = Controller.handle_planning_completion(root_issue, root_workspace)
assert registry["remote"] == "origin"
assert registry["target_branch"] == "main"
assert registry["candidate_branch"] == "symphony/YQE-ROOT/candidate"
assert registry["candidate_head_sha"] == "candidate-base"
assert Registry.node(registry, "implementation")["base_candidate_sha"] == "candidate-base"
assert Registry.node(registry, "implementation")["branch"] == "symphony/YQE-ROOT/YQE-CHILD"
```

AgentRunner 测试必须通过 fake backend 观察到 `run_before_run_hook` 前，私有 branch prepare 已被调用；review node 则 checkout subject SHA，不创建可写 issue branch。

- [ ] **Step 2: 运行测试确认失败**

Run:

```powershell
cd elixir
mix test test/symphony_elixir/workflow_controller_test.exs test/symphony_elixir/acp_agent_runner_test.exs
```

Expected: FAIL，Registry 没有 candidate/branch 事实，AgentRunner 未准备 workspace，Artifacts 也不能读取 worker 文件。

- [ ] **Step 3: 让 Artifacts 通过 Workspace 边界读取本地或远程文件**

保留现有 `/1` API，并增加 worker host 参数：

```elixir
@spec load_workflow_plan(Path.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
def load_workflow_plan(workspace, worker_host \\ nil) do
  load_json(workflow_plan_path(workspace), worker_host, &validate_plan/1)
end

@spec load_issue_result(Path.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
def load_issue_result(workspace, worker_host \\ nil) do
  load_json(issue_result_path(workspace), worker_host, &validate_issue_result/1)
end

defp load_json(path, worker_host, validator) do
  with {:ok, body} <- Workspace.read_file(path, worker_host),
       {:ok, decoded} <- Jason.decode(body),
       :ok <- validator.(decoded) do
    {:ok, decoded}
  end
end
```

AgentRunner 的 artifact verification 从 opts 读取 `worker_host` 并传给 Artifacts；Controller planning/completion 同样传递。增加本地兼容测试，确认 `/1` 仍可用；`Workspace.read_file/2` 的 SSH 分支由 Task 1 覆盖。

- [ ] **Step 4: 扩展 Controller planning API**

保留 `/2`，新增 opts 版本用于传入 worker host：

```elixir
@spec handle_planning_completion(Issue.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
def handle_planning_completion(root_issue, workspace, opts) do
  worker_host = Keyword.get(opts, :worker_host)
  settings = Config.settings!().orchestration
  target_branch = settings.target_branch
  candidate_branch = candidate_branch_name(root_issue.identifier)

  with {:ok, plan} <- Artifacts.load_workflow_plan(workspace),
       :ok <- validate_materialization_plan(plan),
       {:ok, base_registry} <- load_or_new_registry(root_issue),
       {:ok, git} <-
         GitAdapter.initialize_candidate(
           workspace,
           worker_host,
           settings.git_remote,
           target_branch,
           candidate_branch
         ),
       git_registry <-
         Registry.put_workflow_git(base_registry, %{
           "remote" => settings.git_remote,
           "target_branch" => target_branch,
           "target_base_sha" => git.target_sha,
           "candidate_branch" => git.candidate_branch,
           "candidate_head_sha" => git.candidate_sha
         }),
       {:ok, registry} <- materialize_plan(git_registry, root_issue, plan),
       :ok <- Registry.save!(registry),
       :ok <- maybe_comment_root(root_issue, plan, registry) do
    {:ok, registry}
  end
end
```

`put_derived_node/6` 为非 review node 保存确定性 branch name 和当前 candidate base；review node 保存待解析 subject，不给 agent 自由填写 SHA。

- [ ] **Step 5: 增加 workspace prepare API 并接入 AgentRunner**

Controller 增加：

```elixir
@spec prepare_issue_workspace(Issue.t(), Path.t(), keyword()) :: :ok | {:error, term()}
def prepare_issue_workspace(issue, workspace, opts) do
  worker_host = Keyword.get(opts, :worker_host)

  with {:ok, registry, _node_key, node} <- Registry.load_by_issue_id(issue.id) do
    if node["task_type"] == "review" do
      GitAdapter.checkout_commit(workspace, worker_host, review_subject_head(registry, node))
      |> normalize_prepare_result()
    else
      GitAdapter.prepare_private_branch(
        workspace,
        worker_host,
        registry["remote"],
        node["branch"],
        node["base_candidate_sha"]
      )
      |> normalize_prepare_result()
    end
  end
end

defp review_subject_head(registry, node) do
  case get_in(registry, ["subjects", node["subject_id"]]) do
    %{"head_sha" => sha} when is_binary(sha) -> sha
    %{"candidate_sha" => sha} when is_binary(sha) -> sha
    _subject -> registry["candidate_head_sha"]
  end
end
```

AgentRunner 在 `Workspace.create_for_issue/2` 成功后、`run_before_run_hook/3` 之前调用：

```elixir
with :ok <- maybe_prepare_workflow_workspace(issue, workspace, opts, worker_host),
     :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
  run_agent_turns(workspace, issue, codex_update_recipient, opts, worker_host)
end
```

Planning phase跳过该 prepare；issue phase 调用 Controller。Continuation 检测当前 branch 已存在时不得 reset agent commit。

- [ ] **Step 6: Orchestrator 传入 worker host**

Planning 和 issue completion 调用都改为三参数版本：

```elixir
Controller.handle_planning_completion(
  running_entry.issue,
  workspace,
  worker_host: Map.get(running_entry, :worker_host)
)
```

- [ ] **Step 7: 运行测试并提交**

Run:

```powershell
cd elixir
mix test test/symphony_elixir/workflow_artifacts_test.exs test/symphony_elixir/workflow_controller_test.exs test/symphony_elixir/acp_agent_runner_test.exs
mix specs.check
```

Expected: PASS，0 failures。

```powershell
git add elixir/lib/symphony_elixir/workflow/controller.ex elixir/lib/symphony_elixir/workflow/artifacts.ex elixir/lib/symphony_elixir/agent_runner.ex elixir/lib/symphony_elixir/orchestrator.ex elixir/test/symphony_elixir/workflow_controller_test.exs elixir/test/symphony_elixir/workflow_artifacts_test.exs elixir/test/symphony_elixir/acp_agent_runner_test.exs
git commit -m "feat(workflow): 初始化 agent 私有集成分支"
```

---

### Task 7: 固化 Agent 提交、Continuation、Integration 和 Review Prompt

**Files:**
- Modify: `elixir/lib/symphony_elixir/workflow/prompts.ex`
- Modify: `elixir/test/symphony_elixir/workflow_prompt_contract_test.exs`
- Modify: `elixir/WORKFLOW.md`

- [ ] **Step 1: 写四类任务责任测试**

测试分别生成 implementation、带 completion continuation 的 implementation、integration、review prompt，并断言：

```elixir
assert implementation =~ "提交所有需要交付的业务变更"
assert implementation =~ "不要直接 push candidate 或 target"
assert implementation =~ "Root workflow workspace 只读"

assert continuation =~ "candidate 已从 candidate-old 前进到 candidate-new"
assert continuation =~ "合入 candidate-new"
assert continuation =~ "不要重新实现已经完成的功能"

assert integration =~ "将 target-new 合入当前 preparation branch"
assert integration =~ "解决冲突、重新验证并提交"

assert review =~ "不要执行 `git add`"
assert review =~ "不要修改源码、测试、文档或业务文件"
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd elixir; mix test test/symphony_elixir/workflow_prompt_contract_test.exs`

Expected: FAIL，当前 implementation prompt 没有提交/共享引用约束，并允许写 root workspace。

- [ ] **Step 3: 重写 issue prompt 责任段**

普通可写任务加入：

```text
- 所有受版本控制的业务修改只能发生在当前 issue workspace。
- Root workflow workspace 和上游 workspace 只读，只能用于理解上下文。
- 检查 tracked、staged、unstaged 和 untracked 文件。
- 提交所有需要交付的业务变更，清理不属于当前 issue 的临时修改。
- 不要直接 push 或更新 candidate/target；共享引用由 Controller 推进。
- 完成提交和验证后再更新 issue_result.json。
```

根据 `workflow_context["completion_continuation"]` 追加精确 continuation；`task_type == "integration"` 追加 target sync 规则；review 规则保持严格只读。

- [ ] **Step 4: 更新 WORKFLOW.md 当前契约**

将当前“artifact 被验证即推进”的表述改为：

```text
- issue_result.json 是完成申请；Symphony 还会校验私有分支提交、最新 candidate 祖先关系和远程 checkpoint。
- 可写任务必须在自己的 workspace 完成 commit；不得 push candidate 或 target。
- Controller 要求 continuation 时，复用当前 workspace，只处理未提交内容、基线漂移或冲突，不重新开始任务。
```

- [ ] **Step 5: 运行测试并提交**

Run:

```powershell
cd elixir
mix test test/symphony_elixir/workflow_prompt_contract_test.exs
```

Expected: PASS，0 failures。

```powershell
git add elixir/lib/symphony_elixir/workflow/prompts.ex elixir/test/symphony_elixir/workflow_prompt_contract_test.exs elixir/WORKFLOW.md
git commit -m "docs(workflow): 固化 agent 分支交付契约"
```

---

### Task 8: 将 Issue Result 改为完成申请并触发 Agent Continuation

**Files:**
- Modify: `elixir/lib/symphony_elixir/workflow/controller.ex`
- Modify: `elixir/test/symphony_elixir/workflow_controller_test.exs`

- [ ] **Step 1: 写 dirty、no-change、candidate advanced 测试**

三个测试使用 GitAdapter stub 返回不同 facts：

```elixir
assert {:ok, {:continue_agent, issue_id, :dirty_worktree, context}} =
         Controller.handle_issue_completion(issue, workspace)
assert context["dirty_paths"] == ["lib/pending.ex"]
assert Registry.node(saved_registry, "implementation")["status"] == "running"
refute_receive {:memory_tracker_state_update, ^issue_id, _}

assert {:ok, {:completed, issue_id}} = Controller.handle_issue_completion(no_change_issue, workspace)
assert [%{"kind" => "no_change"}] = saved_registry["checkpoints"]

assert {:ok, {:continue_agent, issue_id, :candidate_advanced, context}} =
         Controller.handle_issue_completion(stale_issue, workspace)
assert context["previous_candidate_sha"] == "candidate-old"
assert context["current_candidate_sha"] == "candidate-new"
```

再增加两类测试：

```elixir
assert {:ok, {:needs_human, review_issue_id, reason}} =
         Controller.handle_issue_completion(modified_review_issue, workspace)
assert reason =~ "review workspace changed"
refute_receive {:memory_tracker_state_update, ^review_issue_id, _}
```

- review workspace 有业务 dirty path 或 HEAD 不等于 subject HEAD 时，不能接受 review result；
- 存量 active Registry 缺少 remote、candidate branch 或 candidate SHA 时返回 `needs_human`，不得退回旧的“result 直接完成”路径；
- 超过 `completion_max_continuations` 后返回 `needs_human`。

- [ ] **Step 2: 运行测试确认失败**

Run: `cd elixir; mix test test/symphony_elixir/workflow_controller_test.exs`

Expected: FAIL，当前 Controller 仍直接完成 node。

- [ ] **Step 3: 拆分 review 和可写任务完成路径**

`handle_issue_completion/3` 先加载 result 和 Registry，不再先写评论：

```elixir
def handle_issue_completion(issue, workspace, opts) do
  with {:ok, result} <- Artifacts.load_issue_result(workspace),
       {:ok, registry, node_key, node} <- Registry.load_by_issue_id(issue.id),
       :ok <- validate_result_matches_node(result, node_key, node) do
    if node["task_type"] == "review" do
      validate_review_completion(issue, workspace, registry, node_key, node, result, opts)
    else
      validate_writable_completion(issue, workspace, registry, node_key, node, result, opts)
    end
  end
end
```

`validate_review_completion/7` 使用 review subject 的 HEAD 调用 `inspect_completion`。只有 `business_dirty_paths == []` 且实际 `head_sha == subject_head_sha` 才进入 `apply_review_result`；否则返回 `needs_human` 并保持 node 未完成。

可写任务使用 `GitAdapter.inspect_completion/4`。判定顺序固定：

```elixir
cond do
  facts.business_dirty_paths != [] ->
    continue_agent(registry, node_key, issue.id, :dirty_worktree, %{
      "dirty_paths" => facts.business_dirty_paths,
      "head_sha" => facts.head_sha
    })

  facts.business_changed_paths == [] ->
    complete_no_change(issue, registry, node_key, result)

  true ->
    validate_candidate_ancestry(issue, workspace, registry, node_key, facts, result, opts)
end
```

`continue_agent/5` 增加 attempt，保存 Registry continuation，node 保持 running；超过配置上限返回 `needs_human`。

`complete_no_change/4` 使用 artifact hash 生成稳定 checkpoint id：

```elixir
checkpoint_id = "#{node_key}:no-change:#{artifact_hash}"
```

只有保存 checkpoint、node completed 和 Registry 后才写 Issue Result 评论和更新 Tracker。

- [ ] **Step 4: 运行目标测试**

Run:

```powershell
cd elixir
mix test test/symphony_elixir/workflow_controller_test.exs
```

Expected: PASS，旧的“有效 result 直接完成”测试已改为 no-change 或带 candidate promotion facts。

- [ ] **Step 5: 提交**

```powershell
git add elixir/lib/symphony_elixir/workflow/controller.ex elixir/test/symphony_elixir/workflow_controller_test.exs
git commit -m "feat(workflow): 校验 issue 分支完成申请"
```

---

### Task 9: Orchestrator 区分 Agent Continuation 和 Controller Retry

**Files:**
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`
- Modify: `elixir/test/symphony_elixir/workflow_orchestrator_test.exs`

- [ ] **Step 1: 写 continuation 和 controller retry 调度测试**

```elixir
test "continue_agent 保留 claim、workspace、agent 和 continuation context" do
  result = {:continue_agent, "issue-1", :candidate_advanced, %{"current_candidate_sha" => "new"}}
  state = Orchestrator.apply_workflow_issue_result_for_test(base_state(), "issue-1", running_entry(), result)

  assert MapSet.member?(state.claimed, "issue-1")
  assert state.retry_attempts["issue-1"].retry_kind == :agent
  assert state.retry_attempts["issue-1"].workflow_context["completion_continuation"]["current_candidate_sha"] == "new"
end

test "retry_controller 不派发 agent" do
  result = {:retry_controller, "issue-1", :remote_unavailable, %{}}
  state = Orchestrator.apply_workflow_issue_result_for_test(base_state(), "issue-1", running_entry(), result)

  assert state.retry_attempts["issue-1"].retry_kind == :controller
  assert state.retry_attempts["issue-1"].workspace_path == "/tmp/issue-1"
end
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd elixir; mix test test/symphony_elixir/workflow_orchestrator_test.exs`

Expected: FAIL，缺少结果分支和 `retry_kind`。

- [ ] **Step 3: 扩展 apply_workflow_issue_result**

```elixir
defp apply_workflow_issue_result(
       state,
       issue_id,
       running_entry,
       {:continue_agent, _result_issue_id, reason, context}
     ) do
  continuation = Map.put(context, "reason", Atom.to_string(reason))
  workflow_context = Map.put(running_entry.workflow_context || %{}, "completion_continuation", continuation)

  state
  |> complete_issue(issue_id)
  |> schedule_issue_retry(issue_id, 1, %{
    retry_kind: :agent,
    delay_type: :continuation,
    identifier: running_entry.identifier,
    issue_url: running_entry.issue.url,
    agent_id: running_entry.agent_id,
    agent_kind: running_entry.agent_kind,
    worker_host: running_entry.worker_host,
    workspace_path: running_entry.workspace_path,
    workflow_phase: :issue,
    workflow_context: workflow_context
  })
end

defp apply_workflow_issue_result(
       state,
       issue_id,
       running_entry,
       {:retry_controller, _result_issue_id, reason, context}
     ) do
  state
  |> complete_issue(issue_id)
  |> schedule_issue_retry(issue_id, 1, %{
    retry_kind: :controller,
    error: inspect(reason),
    controller_context: context,
    identifier: running_entry.identifier,
    worker_host: running_entry.worker_host,
    workspace_path: running_entry.workspace_path,
    workflow_phase: :issue
  })
end
```

在 retry entry 中持久化 `retry_kind` 和 `controller_context`。

- [ ] **Step 4: Controller-only retry 路径**

`handle_retry_issue_lookup/5` 在 `retry_kind == :controller` 时不调用 `dispatch_issue/5`，而是直接重新调用：

```elixir
Controller.handle_issue_completion(
  issue,
  metadata.workspace_path,
  worker_host: metadata.worker_host,
  controller_retry: true
)
```

成功后复用 `apply_workflow_issue_result/4`；再次 transient failure 时继续指数退避。

- [ ] **Step 5: AgentRunner continuation prompt 使用 Controller context**

确保跨 run 的首次 turn 通过 `PromptBuilder` 获得 `completion_continuation`；AgentRunner 内部第二 turn 的通用 guidance 不覆盖该 context。

- [ ] **Step 6: 运行测试并提交**

Run:

```powershell
cd elixir
mix test test/symphony_elixir/workflow_orchestrator_test.exs test/symphony_elixir/acp_agent_runner_test.exs
```

Expected: PASS，0 failures。

```powershell
git add elixir/lib/symphony_elixir/orchestrator.ex elixir/lib/symphony_elixir/agent_runner.ex elixir/test/symphony_elixir/workflow_orchestrator_test.exs
git commit -m "feat(orchestrator): 区分 agent 与 controller 重试"
```

---

### Task 10: 推进 Candidate、记录 Checkpoint 并恢复中断

**Files:**
- Modify: `elixir/lib/symphony_elixir/workflow/controller.ex`
- Modify: `elixir/test/symphony_elixir/workflow_controller_test.exs`
- Modify: `elixir/test/symphony_elixir/workflow_smoke_test.exs`

- [ ] **Step 1: 写 promotion、CAS 竞争和恢复测试**

覆盖：

```elixir
assert {:ok, {:completed, issue_id}} = Controller.handle_issue_completion(issue, workspace)
assert saved_registry["candidate_head_sha"] == "issue-head"
assert Registry.node(saved_registry, "implementation")["checkpoint_id"] == "implementation:candidate:issue-head"
assert_receive {:memory_tracker_state_update, ^issue_id, "Closed"}

assert {:ok, {:continue_agent, issue_id, :candidate_advanced, _context}} =
         Controller.handle_issue_completion(racing_issue, workspace)

assert {:ok, {:completed, issue_id}} =
         Controller.handle_issue_completion(already_promoted_issue, workspace)
assert Enum.count(saved_registry["checkpoints"], &(&1["id"] == "implementation:candidate:issue-head")) == 1
```

第三个场景模拟 remote candidate 已是 issue HEAD、Registry 尚未保存 checkpoint。

增加 accepted subject 失效测试：新 checkpoint 的 `paths` 与 accepted subject 的 `paths` 相交时，subject 和对应 review 状态都变为 `stale`；无交集时保持 accepted。

- [ ] **Step 2: 运行测试确认失败**

Run: `cd elixir; mix test test/symphony_elixir/workflow_controller_test.exs`

Expected: FAIL，Controller 尚未推进 candidate。

- [ ] **Step 3: 实现 candidate promotion**

完成校验通过后：

```elixir
with {:ok, current_candidate_sha} <-
       GitAdapter.fetch_ref(workspace, worker_host, registry["remote"], registry["candidate_branch"]),
     {:ok, true} <- GitAdapter.ancestor?(workspace, worker_host, current_candidate_sha, facts.head_sha),
     {:ok, _private_sha} <-
       GitAdapter.push_private_branch(workspace, worker_host, registry["remote"], node["branch"], facts.head_sha),
     {:ok, promoted_sha} <-
       promote_or_confirm_candidate(workspace, worker_host, registry, current_candidate_sha, facts.head_sha),
     {:ok, artifact_hash} <-
       GitAdapter.hash_artifact(Artifacts.issue_result_path(workspace), worker_host),
     updated_registry <-
       record_candidate_completion(registry, node_key, node, result, current_candidate_sha, promoted_sha, artifact_hash),
     :ok <- Registry.save!(updated_registry),
     :ok <- Tracker.create_comment(issue.id, render_issue_result_comment(issue, result)),
     :ok <- Tracker.update_issue_state(issue.id, workflow_terminal_state()) do
  {:ok, {:completed, issue.id}}
end
```

`promote_or_confirm_candidate/5` 先处理 `current_candidate_sha == issue_head_sha` 的恢复场景，再调用 CAS。CAS stale 返回 agent continuation；网络、Registry、Tracker 暂时失败返回 controller retry。

Checkpoint id 固定为：

```elixir
"#{node_key}:candidate:#{issue_head_sha}"
```

Checkpoint 同时保存 `paths: facts.business_changed_paths`。只有 checkpoint 和 node completed 已保存后才解锁下游。

记录 checkpoint 后先执行保守失效规则：

```elixir
defp invalidate_overlapping_subjects(registry, changed_paths) do
  Enum.reduce(registry["subjects"] || %{}, registry, fn {subject_id, subject}, acc ->
    overlaps? = not MapSet.disjoint?(MapSet.new(subject["paths"] || []), MapSet.new(changed_paths))

    if subject["status"] == "accepted" and overlaps? do
      acc
      |> put_in(["subjects", subject_id, "status"], "stale")
      |> stale_reviews_for_subject(subject_id)
    else
      acc
    end
  end)
end
```

普通 review node 进入 ready 前，由 Controller 根据 `reviews` 引用的 checkpoint 创建 subject，不由 agent 填写：

```elixir
defp attach_ready_review_subject(registry, node_key, node) do
  checkpoints = checkpoints_for_reviewed_nodes(registry, node["reviews"] || [])
  base_sha = checkpoints |> List.first() |> Map.fetch!("candidate_before_sha")
  head_sha = registry["candidate_head_sha"]
  subject_id = "#{node_key}:candidate:#{base_sha}:#{head_sha}"

  subject = %{
    "id" => subject_id,
    "type" => "candidate_range",
    "branch" => registry["candidate_branch"],
    "base_sha" => base_sha,
    "head_sha" => head_sha,
    "paths" => checkpoints |> Enum.flat_map(&(&1["paths"] || [])) |> Enum.uniq() |> Enum.sort(),
    "status" => "pending"
  }

  registry
  |> Registry.put_subject(subject_id, subject)
  |> Registry.put_node_git(node_key, %{"subject_id" => subject_id})
end
```

Final review subject 不在这里生成，继续由 Task 11 的 target freshness 检查生成。

- [ ] **Step 4: 更新 smoke fake GitAdapter**

Smoke tests 使用 stub 驱动 candidate 从 `candidate-base` 推进到每个 node 的 `head_sha`，并断言 comment 和 terminal state 发生在 checkpoint 后。

- [ ] **Step 5: 运行测试并提交**

Run:

```powershell
cd elixir
mix test test/symphony_elixir/workflow_controller_test.exs test/symphony_elixir/workflow_smoke_test.exs
```

Expected: PASS，0 failures。

```powershell
git add elixir/lib/symphony_elixir/workflow/controller.ex elixir/test/symphony_elixir/workflow_controller_test.exs elixir/test/symphony_elixir/workflow_smoke_test.exs
git commit -m "feat(workflow): 受保护推进 candidate"
```

---

### Task 11: Target Sync、Final Review 漂移和最终发布

**Files:**
- Modify: `elixir/lib/symphony_elixir/workflow/controller.ex`
- Modify: `elixir/test/symphony_elixir/workflow_controller_test.exs`
- Modify: `elixir/test/symphony_elixir/workflow_smoke_test.exs`
- Modify: `elixir/docs/issue_driven_dynamic_workflow.md`
- Modify: `elixir/README.md`
- Modify: `SPEC.md`
- Modify: `README.md`

- [ ] **Step 1: 写 target sync 物化测试**

当 final review 依赖完成但 target 不是 candidate 祖先时，断言：

```elixir
assert_receive {:memory_tracker_issue_created, %Issue{} = sync_issue}
sync_node = Registry.node(saved_registry, "target_sync-1")
assert sync_node["task_type"] == "integration"
assert sync_node["issue_id"] == sync_issue.id
assert sync_node["base_candidate_sha"] == "candidate-head"
assert sync_node["target_sha"] == "target-new"
assert Registry.node(saved_registry, "final_review")["status"] == "waiting"
assert Registry.node(saved_registry, "final_review")["dependencies"] == ["target_sync-1"]
```

当 target 已是 candidate 祖先时，不创建 sync issue，直接生成包含 target/candidate SHA 的 final subject。

- [ ] **Step 2: 写 final publication 和漂移测试**

```elixir
assert {:ok, {:completed, final_review_issue_id}} =
         Controller.handle_issue_completion(final_review_issue, workspace)
assert saved_registry["publication"] == %{
         "status" => "published",
         "reviewed_candidate_sha" => "candidate-reviewed",
         "expected_target_sha" => "target-reviewed",
         "published_target_sha" => "candidate-reviewed"
       }
assert_receive {:memory_tracker_state_update, ^root_issue_id, "Closed"}

assert {:ok, {:completed, stale_review_issue_id}} =
         Controller.handle_issue_completion(stale_review_issue, workspace)
assert saved_registry["reviews"]["final_review"]["status"] == "stale"
refute_receive {:memory_tracker_state_update, ^root_issue_id, _}
assert_receive {:memory_tracker_issue_created, %Issue{} = replacement_sync_or_review}
```

- [ ] **Step 3: 运行测试确认失败**

Run:

```powershell
cd elixir
mix test test/symphony_elixir/workflow_controller_test.exs
```

Expected: FAIL，当前 final review pass 仍直接关闭 root。

- [ ] **Step 4: 在下游解锁前准备 Final Review**

把 `unlock_ready_nodes/1` 改为返回 `{:ok, registry}` 的推进函数。普通 node 维持依赖解锁；`final_review` 特殊处理：

```elixir
defp prepare_final_review(registry, root_issue) do
  with {:ok, target_sha} <- fetch_target_ref(registry),
       {:ok, candidate_sha} <- fetch_candidate_ref(registry),
       {:ok, contains_target?} <- candidate_contains_target?(registry, target_sha, candidate_sha) do
    if contains_target? do
      {:ok, attach_final_subject_and_ready(registry, target_sha, candidate_sha)}
    else
      materialize_target_sync(registry, root_issue, target_sha, candidate_sha)
    end
  end
end
```

调用前通过现有 Tracker 边界读取 root issue 上下文：

```elixir
defp fetch_root_issue(registry) do
  case Tracker.fetch_issue_states_by_ids([registry["root_issue_id"]]) do
    {:ok, [%Issue{} = root_issue | _rest]} -> {:ok, root_issue}
    {:ok, []} -> {:error, :root_issue_not_found}
    {:error, reason} -> {:error, reason}
  end
end
```

`materialize_target_sync/4` 使用该 root issue 的 project、team、assignee 和 labels 创建普通 derived issue，`task_type = "integration"`，agent id 留空以使用正常 routing，而不是创建新的 agent 实体；rewire final review 依赖到该 node。

- [ ] **Step 5: 实现 final review publication**

Final review pass 时先校验 Registry subject 与远程引用：

```elixir
cond do
  subject["candidate_sha"] != current_candidate_sha ->
    stale_final_review(registry, node_key, result, :candidate_changed)

  subject["target_sha"] != current_target_sha ->
    stale_final_review(registry, node_key, result, :target_changed)

  true ->
    publish_reviewed_candidate(issue, registry, node_key, result, subject, opts)
end
```

`stale_final_review/4` 将旧 subject 和 review 标记 `stale`，把旧 final review node 的 `workflow_semantics` 设为 `superseded`，随后创建新的 target sync 或 replacement final review node；旧 node 不再参与 `all_executable_nodes_completed?/1`。

发布使用：

```elixir
GitAdapter.compare_and_swap_ref(
  workspace,
  worker_host,
  registry["remote"],
  registry["target_branch"],
  subject["target_sha"],
  subject["candidate_sha"]
)
```

确认远程 target 后，先保存 publication checkpoint、final review completed、Registry completed，再依次关闭 final review issue 和 root issue。

`workflow_completed?/1` 改为同时要求：

```elixir
all_executable_nodes_completed?(registry) and
  get_in(registry, ["publication", "status"]) == "published" and
  is_binary(get_in(registry, ["publication", "published_target_sha"]))
```

- [ ] **Step 6: 更新文档和端到端 smoke**

`issue_driven_dynamic_workflow.md`、两级 README 和 `SPEC.md` 说明：

- task type 只是任务责任，不是独立 agent 实体；
- candidate/target 由 Controller 受保护推进；
- target drift 会使 final review stale；
- root Done 对应远程 target publication。

Smoke test 必须覆盖 YQE-134 类型场景：第一次 result 带未提交业务变更时不关闭；continuation 清理并提交、candidate 推进、target sync、replacement final review 和 target 发布后才关闭。

- [ ] **Step 7: 运行 workflow 测试**

Run:

```powershell
cd elixir
mix test test/symphony_elixir/workflow_git_adapter_test.exs test/symphony_elixir/workflow_artifacts_test.exs test/symphony_elixir/workflow_controller_test.exs test/symphony_elixir/workflow_orchestrator_test.exs test/symphony_elixir/workflow_prompt_contract_test.exs test/symphony_elixir/workflow_smoke_test.exs
```

Expected: PASS，0 failures。

- [ ] **Step 8: 提交**

```powershell
git add elixir/lib/symphony_elixir/workflow/controller.ex elixir/test/symphony_elixir/workflow_controller_test.exs elixir/test/symphony_elixir/workflow_smoke_test.exs elixir/docs/issue_driven_dynamic_workflow.md elixir/README.md SPEC.md README.md
git commit -m "feat(workflow): 发布审查通过的 candidate"
```

---

## 全量验证

- [ ] **Step 1: 格式化并检查 public specs**

Run:

```powershell
cd elixir
mix format
mix format --check-formatted
mix specs.check
```

Expected: PASS，无格式差异，无缺失 public `@spec`。

- [ ] **Step 2: 运行完整质量门**

Run:

```powershell
cd elixir
make all
```

Expected: PASS；format、lint、coverage、dialyzer 全部通过。

- [ ] **Step 3: 搜索旧责任残留**

Run:

```powershell
rg -n "commit_issue_workspace|merge_issue_to_candidate|merge_candidate_to_target" elixir/lib elixir/test elixir/docs elixir/README.md elixir/WORKFLOW.md
```

Expected: 无运行时代码或当前契约残留；只允许历史规格文档明确说明这些接口已被替代。

- [ ] **Step 4: 验证变更范围**

Run:

```powershell
git status --short
git log --oneline --decorate -12
```

Expected: 只出现本计划涉及的实现文件，以及执行前已经存在且未被修改的用户工作树内容；每个 Task 有独立提交。

---

## 自检映射

- Workspace 本地/SSH 命令边界：Task 1。
- Git 配置与 continuation 上限：Task 2。
- Git 事实、私有分支和受保护引用：Task 3、4。
- Registry Git/checkpoint/publication：Task 5。
- Planning candidate 初始化和 workspace prepare：Task 6。
- 单一 coding agent 执行能力下的不同任务责任：Task 7。
- `issue_result` 作为完成申请、dirty/no-change/candidate advanced：Task 8。
- Agent continuation 与 Controller-only retry：Task 9。
- Candidate promotion、checkpoint 和中断恢复：Task 10。
- Target sync、final review stale、publication 和 root closure：Task 11。
- YQE-134/YQE-155/YQE-160 回归：Task 11 smoke test。
