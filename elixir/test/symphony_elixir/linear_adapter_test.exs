defmodule SymphonyElixir.LinearAdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.Linear.Issue

  defmodule FakeLinearClient do
    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end
  end

  setup do
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  test "create_issue resolves workspace labels for the target team" do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_project_slug: "project-slug"
    )

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "projects" => %{
               "nodes" => [%{"id" => "project-1", "teams" => %{"nodes" => [%{"id" => "team-1"}]}}]
             }
           }
         }},
        {:ok, %{"data" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}}},
        {:ok,
         %{
           "data" => %{
             "issueLabels" => %{
               "nodes" => [%{"id" => "workspace-label-1", "name" => "symphony-local-test", "team" => nil}]
             }
           }
         }},
        {:ok,
         %{
           "data" => %{
             "issueCreate" => %{
               "success" => true,
               "issue" => %{
                 "id" => "issue-1",
                 "identifier" => "MT-1",
                 "title" => "Derived task",
                 "description" => "From workflow",
                 "url" => "https://linear.app/issue/MT-1",
                 "state" => %{"name" => "Todo"},
                 "labels" => %{"nodes" => [%{"name" => "symphony-local-test"}]}
               }
             }
           }
         }}
      ]
    )

    assert {:ok, %Issue{labels: ["symphony-local-test"]}} =
             Adapter.create_issue(%{
               title: "Derived task",
               description: "From workflow",
               labels: ["symphony-local-test"]
             })

    assert_receive {:graphql_called, _project_lookup_query, %{projectSlug: "project-slug"}}
    assert_receive {:graphql_called, _state_lookup_query, %{teamId: "team-1", stateName: "Todo"}}
    assert_receive {:graphql_called, label_lookup_query, %{labelNames: ["symphony-local-test"]}}
    assert label_lookup_query =~ "issueLabels"
    refute label_lookup_query =~ "team:"

    assert_receive {:graphql_called, create_issue_query, %{labelIds: ["workspace-label-1"]}}
    assert create_issue_query =~ "issueCreate"
  end

  test "create_issue uses caller-provided project and team context" do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_project_slug: "configured-project"
    )

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok, %{"data" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}}},
        {:ok,
         %{
           "data" => %{
             "issueCreate" => %{
               "success" => true,
               "issue" => %{
                 "id" => "issue-1",
                 "identifier" => "MT-1",
                 "title" => "Derived task",
                 "description" => "From workflow",
                 "url" => "https://linear.app/issue/MT-1",
                 "state" => %{"name" => "Todo"},
                 "project" => %{"id" => "root-project"},
                 "team" => %{"id" => "root-team"},
                 "labels" => %{"nodes" => []}
               }
             }
           }
         }}
      ]
    )

    assert {:ok, %Issue{id: "issue-1"}} =
             Adapter.create_issue(%{
               title: "Derived task",
               description: "From workflow",
               project_id: "root-project",
               team_id: "root-team"
             })

    assert_receive {:graphql_called, _state_lookup_query, %{teamId: "root-team", stateName: "Todo"}}
    assert_receive {:graphql_called, create_issue_query, %{projectId: "root-project", teamId: "root-team"}}
    assert create_issue_query =~ "issueCreate"
    refute_receive {:graphql_called, _project_lookup_query, %{projectSlug: "configured-project"}}
  end
end
