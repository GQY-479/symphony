defmodule SymphonyElixir.Config.SchemaTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema

  test "default_mimocode_agent_config supports model list" do
    config = Schema.default_mimocode_agent_config()
    model = get_in(config, ["config_options", "model"])
    assert is_list(model)
    assert model != []
  end
end
