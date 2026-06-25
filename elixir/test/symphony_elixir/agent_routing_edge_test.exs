defmodule SymphonyElixir.AgentRoutingEdgeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.Router
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.Routing

  defp parse!(attrs) do
    {:ok, settings} = Schema.parse(Map.put_new(attrs, :tracker, %{kind: "memory"}))
    settings
  end

  test "blank default_agent does not hard-code a fallback agent" do
    settings =
      parse!(%{
        agents: %{mimocode: %{kind: "acp_stdio", command: "mimo-code", args: ["acp"]}},
        routing: %{default_agent: ""}
      })

    assert {:error, {:unknown_agent, nil}} =
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

    assert {:ok, %{id: "codex", routing_reason: %{source: :default, matched: nil}}} =
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

    assert {:ok, %{id: "mimocode", routing_reason: %{source: :label, matched: "123"}}} =
             Router.resolve(%Issue{labels: [123]}, settings)
  end

  test "empty agents map synthesizes the default mimocode agent and codex opt-in agent" do
    settings = parse!(%{agents: %{}})

    assert Map.keys(settings.agents) |> Enum.sort() == ["codex", "mimocode"]
    assert settings.routing.default_agent == "mimocode"
    assert settings.agents["mimocode"]["kind"] == "acp_stdio"
    assert settings.agents["mimocode"]["command"] == "mimo-code"
    assert settings.agents["mimocode"]["mcp"] == %{"linear_tools" => true}
    assert settings.agents["codex"]["kind"] == "codex_app_server"
  end

  test "legacy top-level codex config remains a compatibility template for codex agent defaults" do
    settings =
      parse!(%{
        codex: %{
          command: "legacy-codex app-server",
          approval_policy: "never",
          thread_sandbox: "danger-full-access",
          turn_sandbox_policy: %{type: "dangerFullAccess"}
        }
      })

    assert settings.agents["codex"]["command"] == "legacy-codex app-server"
    assert settings.agents["codex"]["approval_policy"] == "never"
    assert settings.agents["codex"]["thread_sandbox"] == "danger-full-access"
    assert settings.agents["codex"]["turn_sandbox_policy"] == %{"type" => "dangerFullAccess"}
    assert settings.routing.default_agent == "mimocode"
  end

  test "agents.codex override takes precedence over legacy top-level codex template" do
    settings =
      parse!(%{
        codex: %{command: "legacy-codex app-server"},
        agents: %{
          codex: %{kind: "codex_app_server", command: "agents-codex app-server"}
        },
        routing: %{default_agent: "codex"}
      })

    assert settings.agents["codex"]["command"] == "agents-codex app-server"
    assert settings.routing.default_agent == "codex"
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

  test "assignee route diagnostics reports source and matched assignee" do
    settings =
      parse!(%{
        agents: %{
          mimocode: %{kind: "acp_stdio", command: "mimo-code", args: ["acp"]}
        },
        routing: %{default_agent: "mimocode", by_assignee: %{"user-123" => "mimocode"}}
      })

    assert {:ok, %{id: "mimocode", routing_reason: %{source: :assignee, matched: "user-123"}}} =
             Router.resolve(%Issue{labels: [], assignee_id: "user-123"}, settings)
  end

  test "label route diagnostics reports source and matched label" do
    settings =
      parse!(%{
        agents: %{
          mimocode: %{kind: "acp_stdio", command: "mimo-code", args: ["acp"]},
          codex: %{kind: "codex_app_server", command: "codex app-server"}
        },
        routing: %{default_agent: "codex", by_label: %{"agent:mimo" => "mimocode"}}
      })

    assert {:ok, %{id: "mimocode", routing_reason: %{source: :label, matched: "agent:mimo"}}} =
             Router.resolve(%Issue{labels: ["agent:mimo"], assignee_id: nil}, settings)
  end

  test "default route diagnostics reports source with nil matched" do
    settings =
      parse!(%{
        agents: %{
          mimocode: %{kind: "acp_stdio", command: "mimo-code", args: ["acp"]}
        },
        routing: %{default_agent: "mimocode"}
      })

    assert {:ok, %{id: "mimocode", routing_reason: %{source: :default, matched: nil}}} =
             Router.resolve(%Issue{labels: [], assignee_id: nil}, settings)
  end
end
