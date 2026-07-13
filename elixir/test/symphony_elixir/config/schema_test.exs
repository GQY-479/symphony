defmodule SymphonyElixir.Config.SchemaTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema

  test "default_mimocode_agent_config supports model list" do
    config = Schema.default_mimocode_agent_config()
    model = get_in(config, ["config_options", "model"])
    assert is_list(model)
    assert model != []
  end

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
end
