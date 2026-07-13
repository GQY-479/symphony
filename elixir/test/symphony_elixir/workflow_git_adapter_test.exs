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
end
