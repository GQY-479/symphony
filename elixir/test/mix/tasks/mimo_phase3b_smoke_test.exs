defmodule Mix.Tasks.Mimo.Phase3BSmokeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Mimo.Phase3bSmoke

  setup do
    Mix.Task.reenable("mimo.phase3b_smoke")
    :ok
  end

  test "is registered as mix mimo.phase3b_smoke" do
    assert Mix.Task.task_name(Phase3bSmoke) == "mimo.phase3b_smoke"
    assert Mix.Task.get("mimo.phase3b_smoke") == Phase3bSmoke
  end

  test "prints an explicit Linear issue template for phase 3B smoke" do
    output =
      capture_io(fn ->
        assert :ok = Phase3bSmoke.run(["--timestamp", "20260614-202500"])
      end)

    assert output =~ "Title: MiMo phase 3B guidance smoke 20260614-202500"
    assert output =~ "Labels: agent:mimo, symphony-local-test"
    assert output =~ "目标文件名：mimo-phase-3b-smoke-20260614-202500.txt"
    assert output =~ "精确文件内容：MiMo phase 3B smoke passed 20260614-202500"
    assert output =~ "在 workspace 根目录创建或覆盖“目标文件名”指定的文件"
    assert output =~ "读回该目标文件，确认内容完全一致"
    assert output =~ "`linear_issue_read`"
    assert output =~ "`linear_comment_create`"
    assert output =~ "`linear_issue_update_state`"
    assert output =~ "最后才使用 `linear_issue_update_state` 移动到 `Done`"
    assert output =~ "如果目标文件名或精确文件内容缺失/含糊，评论 blocked，不要移动到 `Done`"
    refute output =~ "$fileName"
    refute output =~ "$phrase"
  end

  test "prints help" do
    output =
      capture_io(fn ->
        Phase3bSmoke.run(["--help"])
      end)

    assert output =~ "mix mimo.phase3b_smoke"
    assert output =~ "--timestamp"
  end

  test "rejects invalid options" do
    assert_raise Mix.Error, ~r/Invalid option/, fn ->
      Phase3bSmoke.run(["--unknown"])
    end
  end
end
