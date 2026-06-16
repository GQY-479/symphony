defmodule SymphonyElixir.Agent.Tool.LinearIssueRead do
  @moduledoc """
  读取 Linear issue 的高层工具。
  """

  alias SymphonyElixir.Agent.Tool
  alias SymphonyElixir.Linear.Client

  @tool_name "linear_issue_read"
  @description """
  Read a Linear issue by identifier or internal id using Symphony's configured auth. Prefer this high-level tool over raw `linear_graphql` when you need issue title, description, state, labels, project, team, or URL.
  """
  @input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["issue_id"],
    "properties" => %{
      "issue_id" => %{
        "type" => "string",
        "description" => "Linear issue identifier such as YQE-31, or the Linear internal issue id."
      }
    }
  }

  @query """
  query SymphonyLinearToolIssueRead($issueId: String!) {
    issue(id: $issueId) {
      id
      identifier
      title
      url
      description
      state {
        id
        name
        type
      }
      labels {
        nodes {
          name
        }
      }
      project {
        id
        name
      }
      team {
        id
        key
        name
      }
    }
  }
  """

  @spec spec() :: map()
  def spec do
    %{
      "name" => @tool_name,
      "description" => @description,
      "inputSchema" => @input_schema
    }
  end

  @spec execute(term(), keyword()) :: {:ok, Tool.result()} | {:error, Tool.result()}
  def execute(arguments, opts \\ []) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, issue_id} <- normalize_issue_id(arguments),
         {:ok, response} <- linear_client.(@query, %{"issueId" => issue_id}, []) do
      graphql_response(response)
    else
      {:error, reason} -> {:error, Tool.failure_result(@tool_name, error_payload(reason))}
    end
  end

  defp normalize_issue_id(arguments) when is_map(arguments) do
    case string_argument(arguments, "issue_id") do
      {:ok, issue_id} -> {:ok, issue_id}
      :error -> {:error, :missing_issue_id}
    end
  end

  defp normalize_issue_id(_arguments), do: {:error, :invalid_arguments}

  defp string_argument(arguments, key) do
    value = Map.get(arguments, key) || Map.get(arguments, String.to_atom(key))

    if is_binary(value) and String.trim(value) != "" do
      {:ok, String.trim(value)}
    else
      :error
    end
  end

  defp graphql_response(response) do
    if graphql_errors?(response) do
      {:ok, Tool.failure_result(@tool_name, response)}
    else
      {:ok, Tool.success_result(@tool_name, response)}
    end
  end

  defp graphql_errors?(%{"errors" => errors}) when is_list(errors) and errors != [], do: true
  defp graphql_errors?(%{errors: errors}) when is_list(errors) and errors != [], do: true
  defp graphql_errors?(_response), do: false

  defp error_payload(:missing_issue_id) do
    %{"error" => %{"message" => "`linear_issue_read` requires a non-empty `issue_id` string."}}
  end

  defp error_payload(:invalid_arguments) do
    %{"error" => %{"message" => "`linear_issue_read` expects an object with `issue_id`."}}
  end

  defp error_payload(:missing_linear_api_token) do
    %{"error" => %{"message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."}}
  end

  defp error_payload({:linear_api_status, status}) do
    %{"error" => %{"message" => "Linear GraphQL request failed with HTTP #{status}.", "status" => status}}
  end

  defp error_payload({:linear_api_graphql_errors, status}) do
    %{
      "error" => %{
        "category" => "graphql_errors",
        "message" => "Linear GraphQL request returned GraphQL errors with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp error_payload(reason) do
    %{"error" => %{"message" => "Linear issue read failed.", "reason" => inspect(reason)}}
  end
end
