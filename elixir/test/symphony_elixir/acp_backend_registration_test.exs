defmodule SymphonyElixir.AcpBackendRegistrationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.Backend

  test "module_for resolves acp_stdio backend" do
    assert Backend.module_for("acp_stdio") == SymphonyElixir.Agent.Backend.AcpStdio
  end
end
