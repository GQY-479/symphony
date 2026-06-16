defmodule SymphonyElixir.Agent.Tool.LinearCommentCreate do
  @moduledoc """
  创建 Linear issue 评论的高层工具。
  """

  alias SymphonyElixir.Agent.Tool
  alias SymphonyElixir.Linear.Client

  @tool_name "linear_comment_create"
  @description """
  Create a comment on a Linear issue by identifier or internal id using Symphony's configured auth. Prefer this high-level tool over raw `linear_graphql` when writing task results back to Linear. Only report task success after you have verified the requested workspace evidence, such as reading back the exact target file and confirming its required content.
  """
  @input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["issue_id", "body"],
    "properties" => %{
      "issue_id" => %{
        "type" => "string",
        "description" => "Linear issue identifier such as YQE-31, or the Linear internal issue id."
      },
      "body" => %{
        "type" => "string",
        "description" => "Markdown comment body to create on the issue."
      }
    }
  }

  @resolve_issue_query """
  query SymphonyLinearToolResolveIssue($issueId: String!) {
    issue(id: $issueId) {
      id
      identifier
    }
  }
  """

  @create_comment_mutation """
  mutation SymphonyLinearToolCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
      comment {
        id
        url
        body
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

    with {:ok, issue_id, body} <- normalize_arguments(arguments),
         {:ok, issue_id} <- resolve_issue_id(linear_client, issue_id),
         {:ok, response} <- linear_client.(@create_comment_mutation, %{"issueId" => issue_id, "body" => body}, []) do
      graphql_response(response)
    else
      {:graphql_error, response} -> {:ok, Tool.failure_result(@tool_name, response)}
      {:error, reason} -> {:error, Tool.failure_result(@tool_name, error_payload(reason))}
    end
  end

  defp normalize_arguments(arguments) when is_map(arguments) do
    with {:ok, issue_id} <- string_argument(arguments, "issue_id", :missing_issue_id),
         {:ok, body} <- string_argument(arguments, "body", :missing_body) do
      {:ok, issue_id, body}
    end
  end

  defp normalize_arguments(_arguments), do: {:error, :invalid_arguments}

  defp string_argument(arguments, key, error) do
    value = Map.get(arguments, key) || Map.get(arguments, String.to_atom(key))

    if is_binary(value) and String.trim(value) != "" do
      {:ok, String.trim(value)}
    else
      {:error, error}
    end
  end

  defp resolve_issue_id(linear_client, issue_id) do
    case linear_client.(@resolve_issue_query, %{"issueId" => issue_id}, []) do
      {:ok, response} ->
        cond do
          graphql_errors?(response) -> {:graphql_error, response}
          true -> extract_issue_id(response)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_issue_id(%{"data" => %{"issue" => %{"id" => issue_id}}}) when is_binary(issue_id), do: {:ok, issue_id}
  defp extract_issue_id(%{data: %{issue: %{id: issue_id}}}) when is_binary(issue_id), do: {:ok, issue_id}
  defp extract_issue_id(_response), do: {:error, :issue_not_found}

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
    %{"error" => %{"message" => "`linear_comment_create` requires a non-empty `issue_id` string."}}
  end

  defp error_payload(:missing_body) do
    %{"error" => %{"message" => "`linear_comment_create` requires a non-empty `body` string."}}
  end

  defp error_payload(:invalid_arguments) do
    %{"error" => %{"message" => "`linear_comment_create` expects an object with `issue_id` and `body`."}}
  end

  defp error_payload(:issue_not_found) do
    %{"error" => %{"message" => "`linear_comment_create` could not resolve the Linear issue."}}
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
    %{"error" => %{"message" => "Linear comment creation failed.", "reason" => inspect(reason)}}
  end
end
