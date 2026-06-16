defmodule SymphonyElixir.McpServerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.McpServer
  alias SymphonyElixir.Agent.McpServer.Stdio
  alias SymphonyElixir.Workflow

  @linear_tool_names [
    "linear_issue_read",
    "linear_comment_create",
    "linear_issue_update_state",
    "linear_graphql"
  ]

  test "initialize advertises the linear tool server" do
    assert {:ok, result} =
             McpServer.handle(%{
               "id" => 1,
               "method" => "initialize",
               "params" => %{"protocolVersion" => "2025-06-18"}
             })

    assert result["serverInfo"]["name"] == "symphony-linear-tools"
    assert result["capabilities"]["tools"] == %{}
  end

  test "initialized notification does not produce a response" do
    assert :noreply = McpServer.handle(%{"method" => "notifications/initialized", "params" => %{}})
  end

  test "tools/list exposes high-level Linear tools and the raw GraphQL fallback" do
    assert {:ok, %{"tools" => tools}} = McpServer.handle(%{"id" => 2, "method" => "tools/list", "params" => %{}})

    assert Enum.map(tools, & &1["name"]) == @linear_tool_names
    assert %{"inputSchema" => %{"required" => ["issue_id"]}} = Enum.find(tools, &(&1["name"] == "linear_issue_read"))
    assert %{"inputSchema" => %{"required" => ["issue_id", "body"]}} = Enum.find(tools, &(&1["name"] == "linear_comment_create"))

    assert %{"inputSchema" => %{"required" => ["issue_id", "state_name"]}} =
             Enum.find(tools, &(&1["name"] == "linear_issue_update_state"))

    assert %{"inputSchema" => %{"required" => ["query"]}} = Enum.find(tools, &(&1["name"] == "linear_graphql"))
  end

  test "tools/call executes linear_graphql through the shared tool core" do
    test_pid = self()

    request = %{
      "id" => 3,
      "method" => "tools/call",
      "params" => %{
        "name" => "linear_graphql",
        "arguments" => %{"query" => "query Viewer { viewer { id } }"}
      }
    }

    assert {:ok, result} =
             McpServer.handle(request,
               linear_client: fn query, variables, opts ->
                 send(test_pid, {:linear_client_called, query, variables, opts})
                 {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}
               end
             )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert result["isError"] == false
    assert [%{"type" => "text", "text" => output}] = result["content"]
    assert Jason.decode!(output) == %{"data" => %{"viewer" => %{"id" => "usr_123"}}}
  end

  test "tools/call logs tool name and result without GraphQL arguments" do
    request = %{
      "id" => 31,
      "method" => "tools/call",
      "params" => %{
        "name" => "linear_graphql",
        "arguments" => %{"query" => "query SecretProbe { viewer { id } }"}
      }
    }

    log =
      capture_log(fn ->
        assert {:ok, %{"isError" => false}} =
                 McpServer.handle(request,
                   linear_client: fn _query, _variables, _opts ->
                     {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}
                   end
                 )
      end)

    assert log =~ "MCP tools/call tool=\"linear_graphql\" outcome=ok is_error=false"
    refute log =~ "SecretProbe"
    refute log =~ "viewer"
  end

  test "tools/call 失败日志包含低敏错误分类且不泄露参数" do
    request = %{
      "id" => 32,
      "method" => "tools/call",
      "params" => %{
        "name" => "linear_graphql",
        "arguments" => %{"variables" => %{"secret" => "hidden-value"}}
      }
    }

    log =
      capture_log(fn ->
        assert {:ok, %{"isError" => true}} = McpServer.handle(request)
      end)

    assert log =~ "MCP tools/call tool=\"linear_graphql\" outcome=error is_error=true error_category=invalid_arguments"
    refute log =~ "hidden-value"
    refute log =~ "secret"
  end

  test "tools/call 高层工具参数错误日志归类为 invalid_arguments" do
    request = %{
      "id" => 321,
      "method" => "tools/call",
      "params" => %{
        "name" => "linear_issue_read",
        "arguments" => %{"unused" => "hidden-value"}
      }
    }

    log =
      capture_log(fn ->
        assert {:ok, %{"isError" => true}} = McpServer.handle(request)
      end)

    assert log =~ "MCP tools/call tool=\"linear_issue_read\" outcome=error is_error=true error_category=invalid_arguments"
    refute log =~ "hidden-value"
    refute log =~ "unused"
  end

  test "tools/call GraphQL errors 日志标记为 graphql_errors 且不泄露查询内容" do
    request = %{
      "id" => 33,
      "method" => "tools/call",
      "params" => %{
        "name" => "linear_graphql",
        "arguments" => %{"query" => "mutation SecretMutationName { nope }"}
      }
    }

    log =
      capture_log(fn ->
        assert {:ok, %{"isError" => true}} =
                 McpServer.handle(request,
                   linear_client: fn _query, _variables, _opts ->
                     {:ok, %{"errors" => [%{"message" => "Unknown field nope"}], "data" => nil}}
                   end
                 )
      end)

    assert log =~ "MCP tools/call tool=\"linear_graphql\" outcome=error is_error=true error_category=graphql_errors"
    refute log =~ "SecretMutationName"
    refute log =~ "Unknown field"
    refute log =~ "nope"
  end

  test "tools/call Linear 非 200 GraphQL errors 日志标记为 graphql_errors" do
    request = %{
      "id" => 34,
      "method" => "tools/call",
      "params" => %{
        "name" => "linear_graphql",
        "arguments" => %{"query" => "mutation SecretStatusBody { nope }"}
      }
    }

    log =
      capture_log(fn ->
        assert {:ok, %{"isError" => true}} =
                 McpServer.handle(request,
                   linear_client: fn _query, _variables, _opts ->
                     {:error, {:linear_api_graphql_errors, 400}}
                   end
                 )
      end)

    assert log =~ "MCP tools/call tool=\"linear_graphql\" outcome=error is_error=true error_category=graphql_errors"
    refute log =~ "SecretStatusBody"
  end

  test "tools/call returns isError for invalid arguments" do
    request = %{
      "id" => 4,
      "method" => "tools/call",
      "params" => %{"name" => "linear_graphql", "arguments" => %{"variables" => %{}}}
    }

    assert {:ok, result} = McpServer.handle(request)
    assert result["isError"] == true
    assert [%{"type" => "text", "text" => output}] = result["content"]
    assert Jason.decode!(output)["error"]["message"] =~ "requires a non-empty"
  end

  test "unsupported methods return json-rpc method errors" do
    assert {:error, error} = McpServer.handle(%{"id" => 5, "method" => "not/real", "params" => %{}})

    assert error == %{
             "code" => -32601,
             "message" => "Unsupported MCP method: not/real"
           }
  end

  test "stdio handle_line wraps replies as json-rpc responses" do
    line = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 6, "method" => "tools/list", "params" => %{}})

    assert {:reply, encoded} = Stdio.handle_line(line)
    assert %{"id" => 6, "jsonrpc" => "2.0", "result" => %{"tools" => tools}} = Jason.decode!(encoded)
    assert Enum.map(tools, & &1["name"]) == @linear_tool_names
  end

  test "stdio handle_line returns parse errors for malformed json" do
    assert {:reply, encoded} = Stdio.handle_line("{not json")
    assert %{"error" => %{"code" => -32700}, "jsonrpc" => "2.0"} = Jason.decode!(encoded)
  end

  test "stdio runtime prepares workflow path before serving tool calls" do
    original_workflow_path = Workflow.workflow_file_path()
    on_exit(fn -> Workflow.set_workflow_file_path(original_workflow_path) end)

    workflow_path =
      Path.join(System.tmp_dir!(), "symphony-mcp-workflow-#{System.unique_integer([:positive])}.md")

    File.write!(workflow_path, "---\ntracker:\n  kind: linear\n---\nPrompt\n")

    assert :ok = Stdio.prepare_runtime!(workflow_path: workflow_path)
    assert Workflow.workflow_file_path() == Path.expand(workflow_path)
  end
end
