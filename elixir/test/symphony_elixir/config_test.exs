defmodule SymphonyElixir.ConfigTest do
  use SymphonyElixir.TestSupport

  test "validates model list in config_options" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agents: %{
        "mimocode" => %{
          "kind" => "acp_stdio",
          "command" => "mimo",
          "config_options" => %{"model" => ["mimo-v2.5-pro", "mimo/mimo-auto"]}
        }
      }
    )

    assert {:ok, _settings} = Config.settings()
  end
end
