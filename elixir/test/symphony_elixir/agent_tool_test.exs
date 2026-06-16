defmodule SymphonyElixir.AgentToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.Tool

  @linear_tool_names [
    "linear_issue_read",
    "linear_comment_create",
    "linear_issue_update_state",
    "linear_graphql"
  ]

  test "specs exposes high-level Linear tools before the raw GraphQL fallback" do
    specs = Tool.specs()

    assert Enum.map(specs, & &1["name"]) == @linear_tool_names

    assert %{
             "description" => read_description,
             "inputSchema" => %{
               "additionalProperties" => false,
               "properties" => %{"issue_id" => %{"type" => "string"}},
               "required" => ["issue_id"],
               "type" => "object"
             }
           } = Enum.find(specs, &(&1["name"] == "linear_issue_read"))

    assert read_description =~ "Linear issue"

    assert %{
             "description" => comment_description,
             "inputSchema" => %{
               "additionalProperties" => false,
               "properties" => %{
                 "issue_id" => %{"type" => "string"},
                 "body" => %{"type" => "string"}
               },
               "required" => ["issue_id", "body"],
               "type" => "object"
             }
           } = Enum.find(specs, &(&1["name"] == "linear_comment_create"))

    assert comment_description =~ "verified the requested workspace evidence"

    assert %{
             "description" => update_description,
             "inputSchema" => %{
               "additionalProperties" => false,
               "properties" => %{
                 "issue_id" => %{"type" => "string"},
                 "state_name" => %{"type" => "string"}
               },
               "required" => ["issue_id", "state_name"],
               "type" => "object"
             }
           } = Enum.find(specs, &(&1["name"] == "linear_issue_update_state"))

    assert update_description =~ "last"
    assert update_description =~ "terminal"
    assert update_description =~ "Do not move to a terminal state when required workspace evidence is missing"

    assert %{
             "description" => description,
             "inputSchema" => %{
               "additionalProperties" => false,
               "properties" => %{
                 "query" => %{"type" => "string"},
                 "variables" => %{"type" => ["object", "null"]}
               },
               "required" => ["query"],
               "type" => "object"
             }
           } = Enum.find(specs, &(&1["name"] == "linear_graphql"))

    assert description =~ "Linear"
    assert description =~ "fallback"
    assert description =~ "`query`"
    assert description =~ "`variables`"
    assert description =~ "symphony-linear_linear_graphql"
    assert description =~ "Do not include Linear API tokens"
  end

  test "linear_issue_read executes the fixed issue read query" do
    test_pid = self()

    assert {:ok, %{name: "linear_issue_read", success: true, output: output, payload: payload}} =
             Tool.execute(
               "linear_issue_read",
               %{"issue_id" => "YQE-31"},
               linear_client: fn query, variables, opts ->
                 send(test_pid, {:linear_client_called, query, variables, opts})

                 {:ok,
                  %{
                    "data" => %{
                      "issue" => %{
                        "id" => "499b2b5d-808b-4e4f-ba09-1e149e986b76",
                        "identifier" => "YQE-31",
                        "title" => "测试 issue",
                        "state" => %{"name" => "In Progress"}
                      }
                    }
                  }}
               end
             )

    assert_received {:linear_client_called, query, %{"issueId" => "YQE-31"}, []}
    assert query =~ "query SymphonyLinearToolIssueRead"
    assert Jason.decode!(output)["data"]["issue"]["identifier"] == "YQE-31"
    assert payload["data"]["issue"]["state"]["name"] == "In Progress"
  end

  test "linear_comment_create resolves the issue before creating a comment" do
    test_pid = self()

    assert {:ok, %{name: "linear_comment_create", success: true, output: output}} =
             Tool.execute(
               "linear_comment_create",
               %{"issue_id" => "YQE-31", "body" => "file_verified=true"},
               linear_client: fn query, variables, opts ->
                 send(test_pid, {:linear_client_called, query, variables, opts})

                 cond do
                   query =~ "query SymphonyLinearToolResolveIssue" ->
                     {:ok, %{"data" => %{"issue" => %{"id" => "issue-uuid", "identifier" => "YQE-31"}}}}

                   query =~ "mutation SymphonyLinearToolCreateComment" ->
                     {:ok,
                      %{
                        "data" => %{
                          "commentCreate" => %{
                            "success" => true,
                            "comment" => %{"id" => "comment-uuid", "url" => "https://linear.app/comment"}
                          }
                        }
                      }}
                 end
               end
             )

    assert_received {:linear_client_called, resolve_query, %{"issueId" => "YQE-31"}, []}
    assert resolve_query =~ "query SymphonyLinearToolResolveIssue"
    assert_received {:linear_client_called, mutation, %{"issueId" => "issue-uuid", "body" => "file_verified=true"}, []}
    assert mutation =~ "mutation SymphonyLinearToolCreateComment"
    assert Jason.decode!(output)["data"]["commentCreate"]["comment"]["id"] == "comment-uuid"
  end

  test "linear_issue_update_state resolves the state before updating the issue" do
    test_pid = self()

    assert {:ok, %{name: "linear_issue_update_state", success: true, output: output}} =
             Tool.execute(
               "linear_issue_update_state",
               %{"issue_id" => "YQE-31", "state_name" => "Done"},
               linear_client: fn query, variables, opts ->
                 send(test_pid, {:linear_client_called, query, variables, opts})

                 cond do
                   query =~ "query SymphonyLinearToolResolveState" ->
                     {:ok,
                      %{
                        "data" => %{
                          "issue" => %{
                            "id" => "issue-uuid",
                            "identifier" => "YQE-31",
                            "team" => %{
                              "states" => %{"nodes" => [%{"id" => "state-done", "name" => "Done", "type" => "completed"}]}
                            }
                          }
                        }
                      }}

                   query =~ "mutation SymphonyLinearToolUpdateIssueState" ->
                     {:ok,
                      %{
                        "data" => %{
                          "issueUpdate" => %{
                            "success" => true,
                            "issue" => %{
                              "id" => "issue-uuid",
                              "identifier" => "YQE-31",
                              "state" => %{"id" => "state-done", "name" => "Done", "type" => "completed"}
                            }
                          }
                        }
                      }}
                 end
               end
             )

    assert_received {:linear_client_called, resolve_query, %{"issueId" => "YQE-31", "stateName" => "Done"}, []}
    assert resolve_query =~ "query SymphonyLinearToolResolveState"
    assert_received {:linear_client_called, mutation, %{"issueId" => "issue-uuid", "stateId" => "state-done"}, []}
    assert mutation =~ "mutation SymphonyLinearToolUpdateIssueState"
    assert Jason.decode!(output)["data"]["issueUpdate"]["issue"]["state"]["name"] == "Done"
  end

  test "linear_graphql executes successful GraphQL responses" do
    test_pid = self()

    assert {:ok, %{name: "linear_graphql", success: true, output: output, payload: payload}} =
             Tool.execute(
               "linear_graphql",
               %{
                 "query" => "query Viewer { viewer { id } }",
                 "variables" => %{"includeTeams" => false}
               },
               linear_client: fn query, variables, opts ->
                 send(test_pid, {:linear_client_called, query, variables, opts})
                 {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}
               end
             )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{"includeTeams" => false}, []}
    assert Jason.decode!(output) == %{"data" => %{"viewer" => %{"id" => "usr_123"}}}
    assert payload == %{"data" => %{"viewer" => %{"id" => "usr_123"}}}
  end

  test "linear_graphql marks GraphQL errors as unsuccessful while preserving the body" do
    assert {:ok, %{success: false, output: output, payload: payload}} =
             Tool.execute(
               "linear_graphql",
               %{"query" => "mutation BadMutation { nope }"},
               linear_client: fn _query, _variables, _opts ->
                 {:ok, %{"errors" => [%{"message" => "Unknown field `nope`"}], "data" => nil}}
               end
             )

    assert Jason.decode!(output) == %{
             "data" => nil,
             "errors" => [%{"message" => "Unknown field `nope`"}]
           }

    assert payload == %{"errors" => [%{"message" => "Unknown field `nope`"}], "data" => nil}
  end

  test "linear_graphql validates required arguments before calling Linear" do
    assert {:error, %{success: false, output: output}} =
             Tool.execute(
               "linear_graphql",
               %{"variables" => %{"commentId" => "comment-1"}},
               linear_client: fn _query, _variables, _opts ->
                 flunk("linear client should not be called when arguments are invalid")
               end
             )

    assert Jason.decode!(output) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }
  end

  test "linear_graphql rejects invalid variables" do
    assert {:error, %{success: false, output: output}} =
             Tool.execute(
               "linear_graphql",
               %{"query" => "query Viewer { viewer { id } }", "variables" => ["bad"]},
               linear_client: fn _query, _variables, _opts ->
                 flunk("linear client should not be called when variables are invalid")
               end
             )

    assert Jason.decode!(output) == %{
             "error" => %{
               "message" => "`linear_graphql.variables` must be a JSON object when provided."
             }
           }
  end

  test "linear_graphql formats auth and transport failures" do
    assert {:error, %{success: false, output: output}} =
             Tool.execute(
               "linear_graphql",
               %{"query" => "query Viewer { viewer { id } }"},
               linear_client: fn _query, _variables, _opts -> {:error, :missing_linear_api_token} end
             )

    assert Jason.decode!(output) == %{
             "error" => %{
               "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
             }
           }

    assert {:error, %{success: false, output: status_output}} =
             Tool.execute(
               "linear_graphql",
               %{"query" => "query Viewer { viewer { id } }"},
               linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_status, 503}} end
             )

    assert Jason.decode!(status_output) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed with HTTP 503.",
               "status" => 503
             }
           }

    assert {:error, %{success: false, output: graphql_error_output}} =
             Tool.execute(
               "linear_graphql",
               %{"query" => "query Viewer { viewer { id } }"},
               linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_graphql_errors, 400}} end
             )

    assert Jason.decode!(graphql_error_output) == %{
             "error" => %{
               "category" => "graphql_errors",
               "message" => "Linear GraphQL request returned GraphQL errors with HTTP 400.",
               "status" => 400
             }
           }
  end

  test "unsupported tools return a structured failure" do
    assert {:error, %{success: false, output: output, payload: payload}} = Tool.execute("not_a_real_tool", %{})

    assert Jason.decode!(output) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => @linear_tool_names
             }
           }

    assert payload == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => @linear_tool_names
             }
           }
  end
end
