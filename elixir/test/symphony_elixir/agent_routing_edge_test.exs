defmodule SymphonyElixir.AgentRoutingEdgeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.Router
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.Routing

  defp parse!(attrs) do
    {:ok, settings} = Schema.parse(Map.put_new(attrs, :tracker, %{kind: "memory"}))
    settings
  end

  test "blank default_agent falls back to the codex agent" do
    settings =
      parse!(%{
        agents: %{codex: %{kind: "codex_app_server", command: "codex app-server"}},
        routing: %{default_agent: ""}
      })

    assert {:ok, %{id: "codex", kind: "codex_app_server"}} =
             Router.resolve(%Issue{labels: [], assignee_id: nil}, settings)
  end

  test "routing to a disabled agent returns an error" do
    settings =
      parse!(%{
        agents: %{
          codex: %{kind: "codex_app_server", command: "codex app-server"},
          mimocode: %{kind: "cli_run", command: "mimo", enabled: false}
        },
        routing: %{default_agent: "codex", by_label: %{"agent:mimo" => "mimocode"}}
      })

    assert {:error, {:agent_disabled, "mimocode"}} =
             Router.resolve(%Issue{labels: ["agent:mimo"]}, settings)
  end

  test "routing to an agent that is not configured returns an error" do
    settings =
      parse!(%{
        agents: %{codex: %{kind: "codex_app_server", command: "codex app-server"}},
        routing: %{default_agent: "codex", by_label: %{"agent:ghost" => "ghost"}}
      })

    assert {:error, {:unknown_agent, "ghost"}} =
             Router.resolve(%Issue{labels: ["agent:ghost"]}, settings)
  end

  test "non-map route tables are treated as empty" do
    settings = %Schema{
      agents: %{"codex" => %{"kind" => "codex_app_server", "command" => "codex app-server", "enabled" => true}},
      routing: %Routing{default_agent: "codex", by_label: nil, by_assignee: nil}
    }

    assert {:ok, %{id: "codex"}} =
             Router.resolve(%Issue{labels: ["whatever"], assignee_id: "nobody"}, settings)
  end

  test "non-binary issue labels are coerced before matching" do
    settings =
      parse!(%{
        agents: %{
          codex: %{kind: "codex_app_server", command: "codex app-server"},
          mimocode: %{kind: "cli_run", command: "mimo"}
        },
        routing: %{default_agent: "codex", by_label: %{"123" => "mimocode"}}
      })

    assert {:ok, %{id: "mimocode"}} =
             Router.resolve(%Issue{labels: [123]}, settings)
  end

  test "empty agents map synthesizes the default codex agent" do
    settings = parse!(%{agents: %{}})

    assert Map.keys(settings.agents) == ["codex"]
    assert settings.agents["codex"]["kind"] == "codex_app_server"
  end

  test "non-map agent definitions pass through for later validation" do
    settings = parse!(%{agents: %{weird: 123}})

    assert settings.agents["weird"] == 123
  end

  test "null routing maps normalize to empty maps" do
    settings = parse!(%{routing: %{by_assignee: nil, by_label: nil}})

    assert settings.routing.by_assignee == %{}
    assert settings.routing.by_label == %{}
  end
end
