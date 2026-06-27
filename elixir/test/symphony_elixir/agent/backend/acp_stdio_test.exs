defmodule SymphonyElixir.Agent.Backend.AcpStdioTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Agent.Backend.AcpStdio

  test "extract_model_list returns list for list config" do
    config = %{"config_options" => %{"model" => ["mimo-v2.5-pro", "mimo/mimo-auto"]}}
    result = AcpStdio.extract_model_list(config)
    assert result == ["mimo-v2.5-pro", "mimo/mimo-auto"]
  end

  test "extract_model_list returns list for string config" do
    config = %{"config_options" => %{"model" => "mimo/mimo-auto"}}
    result = AcpStdio.extract_model_list(config)
    assert result == ["mimo/mimo-auto"]
  end

  test "extract_model_list returns default for missing config" do
    config = %{}
    result = AcpStdio.extract_model_list(config)
    assert result == ["mimo/mimo-auto"]
  end
end
