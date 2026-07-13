defmodule SymphonyElixir.WorkflowGitAdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Workflow.GitAdapter
  alias SymphonyElixir.Workflow.GitAdapter.Command

  test "build subject helpers return deterministic maps" do
    assert GitAdapter.build_issue_diff_subject("branch", "base", "head") == %{
             "type" => "issue_diff",
             "branch" => "branch",
             "base_sha" => "base",
             "head_sha" => "head",
             "paths" => []
           }

    assert GitAdapter.build_candidate_range_subject("candidate", "base", "head") == %{
             "type" => "candidate_range",
             "branch" => "candidate",
             "base_sha" => "base",
             "head_sha" => "head",
             "paths" => []
           }
  end

  test "hash_artifact returns sha256 for a file" do
    path = Path.join(System.tmp_dir!(), "git-adapter-artifact-#{System.unique_integer([:positive])}.json")
    File.write!(path, "abc")

    assert {:ok, hash} = Command.hash_artifact(path, nil)
    assert hash == Base.encode16(:crypto.hash(:sha256, "abc"), case: :lower)

    File.rm!(path)
  end

  test "inspect_completion 区分业务提交、未提交文件和控制 artifact" do
    repo = SymphonyElixir.GitRepositorySupport.create!("git-inspect")
    on_exit(fn -> File.rm_rf(repo.root) end)

    base_sha = SymphonyElixir.GitRepositorySupport.run!(repo.workspace, ["rev-parse", "HEAD"])
    _head_sha = SymphonyElixir.GitRepositorySupport.commit!(repo.workspace, "lib.txt", "committed\n")
    File.write!(Path.join(repo.workspace, "pending.txt"), "pending\n")
    File.mkdir_p!(Path.join(repo.workspace, ".symphony"))
    File.write!(Path.join(repo.workspace, ".symphony/issue_result.json"), "{}")

    assert {:ok, facts} =
             Command.inspect_completion(
               repo.workspace,
               nil,
               base_sha,
               [".symphony/issue_result.json"]
             )

    assert facts.business_changed_paths == ["lib.txt"]
    assert facts.business_dirty_paths == ["pending.txt"]
    assert facts.branch == "main"
    assert facts.head_sha != base_sha
  end

  test "ancestor? 返回真实 commit 图关系" do
    repo = SymphonyElixir.GitRepositorySupport.create!("git-ancestor")
    on_exit(fn -> File.rm_rf(repo.root) end)

    base_sha = SymphonyElixir.GitRepositorySupport.run!(repo.workspace, ["rev-parse", "HEAD"])
    head_sha = SymphonyElixir.GitRepositorySupport.commit!(repo.workspace, "next.txt", "next\n")

    assert {:ok, true} = Command.ancestor?(repo.workspace, nil, base_sha, head_sha)
    assert {:ok, false} = Command.ancestor?(repo.workspace, nil, head_sha, base_sha)
  end

  test "initialize_candidate 从 remote target 创建 candidate" do
    repo = SymphonyElixir.GitRepositorySupport.create!("git-candidate")
    on_exit(fn -> File.rm_rf(repo.root) end)

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

  test "compare_and_swap_ref 只接受当前 expected SHA" do
    repo = SymphonyElixir.GitRepositorySupport.create!("git-cas")
    on_exit(fn -> File.rm_rf(repo.root) end)

    base = SymphonyElixir.GitRepositorySupport.run!(repo.workspace, ["rev-parse", "HEAD"])
    head = SymphonyElixir.GitRepositorySupport.commit!(repo.workspace, "change.txt", "change\n")

    assert {:ok, ^head} =
             Command.compare_and_swap_ref(repo.workspace, nil, "origin", "main", base, head)

    next_head =
      SymphonyElixir.GitRepositorySupport.commit!(repo.workspace, "next-change.txt", "next\n")

    assert {:error, {:stale_remote_ref, _output}} =
             Command.compare_and_swap_ref(
               repo.workspace,
               nil,
               "origin",
               "main",
               base,
               next_head
             )
  end

  test "prepare_private_branch 和 checkout_commit 准备可写与只读 workspace" do
    repo = SymphonyElixir.GitRepositorySupport.create!("git-prepare")
    on_exit(fn -> File.rm_rf(repo.root) end)

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
end
