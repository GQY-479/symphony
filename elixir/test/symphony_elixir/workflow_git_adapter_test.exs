defmodule SymphonyElixir.WorkflowGitAdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Workflow.GitAdapter

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

    assert {:ok, hash} = GitAdapter.hash_artifact(path)
    assert hash == Base.encode16(:crypto.hash(:sha256, "abc"), case: :lower)

    File.rm!(path)
  end

  test "git operation boundary functions are not configured yet" do
    assert GitAdapter.create_candidate_branch(:root_issue, "main") ==
             {:error, :git_operation_not_configured}

    assert GitAdapter.create_issue_branch(:root_issue, :issue, "candidate-head") ==
             {:error, :git_operation_not_configured}

    assert GitAdapter.commit_issue_workspace(:issue, "/workspace") ==
             {:error, :git_operation_not_configured}

    assert GitAdapter.push_branch("branch") == {:error, :git_operation_not_configured}

    assert GitAdapter.merge_issue_to_candidate("issue-branch", "candidate") ==
             {:error, :git_operation_not_configured}

    assert GitAdapter.merge_candidate_to_target("candidate", "main", "expected-head") ==
             {:error, :git_operation_not_configured}
  end
end
