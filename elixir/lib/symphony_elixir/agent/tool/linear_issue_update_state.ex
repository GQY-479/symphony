defmodule SymphonyElixir.Agent.Tool.LinearIssueUpdateState do
  @moduledoc """
  更新 Linear issue 状态的高层工具。
  """

  alias SymphonyElixir.Agent.Tool
  alias SymphonyElixir.Linear.Client

  @tool_name "linear_issue_update_state"
  @description """
  Move a Linear issue to a state by state name using Symphony's configured auth. Prefer this high-level tool over raw `linear_graphql` when finishing or handing off a task. Use it last when moving to a terminal state, after all workspace changes and issue comments are complete, because terminal states can stop the active Symphony run. Do not move to a terminal state when required workspace evidence is missing, ambiguous, or not yet verified.
  """
  @input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["issue_id", "state_name"],
    "properties" => %{
      "issue_id" => %{
        "type" => "string",
        "description" => "Linear issue identifier such as YQE-31, or the Linear internal issue id."
      },
      "state_name" => %{
        "type" => "string",
        "description" => "Target Linear workflow state name, such as Done."
      }
    }
  }

  @resolve_state_query """
  query SymphonyLinearToolResolveState($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      id
      identifier
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
            name
            type
          }
        }
      }
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyLinearToolUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
      issue {
        id
        identifier
        state {
          id
          name
          type
        }
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

    with {:ok, issue_id, state_name} <- normalize_arguments(arguments),
         {:ok, resolved} <- resolve_state(linear_client, issue_id, state_name),
         {:ok, response} <-
           linear_client.(@update_state_mutation, %{"issueId" => resolved.issue_id, "stateId" => resolved.state_id}, []) do
      graphql_response(response)
    else
      {:graphql_error, response} -> {:ok, Tool.failure_result(@tool_name, response)}
      {:error, reason} -> {:error, Tool.failure_result(@tool_name, error_payload(reason))}
    end
  end

  defp normalize_arguments(arguments) when is_map(arguments) do
    with {:ok, issue_id} <- string_argument(arguments, "issue_id", :missing_issue_id),
         {:ok, state_name} <- string_argument(arguments, "state_name", :missing_state_name) do
      {:ok, issue_id, state_name}
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

  defp resolve_state(linear_client, issue_id, state_name) do
    case linear_client.(@resolve_state_query, %{"issueId" => issue_id, "stateName" => state_name}, []) do
      {:ok, response} ->
        cond do
          graphql_errors?(response) -> {:graphql_error, response}
          true -> extract_issue_and_state(response)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_issue_and_state(%{"data" => %{"issue" => %{"id" => issue_id, "team" => %{"states" => %{"nodes" => states}}}}})
       when is_binary(issue_id) and is_list(states) do
    extract_state(issue_id, states)
  end

  defp extract_issue_and_state(%{data: %{issue: %{id: issue_id, team: %{states: %{nodes: states}}}}})
       when is_binary(issue_id) and is_list(states) do
    extract_state(issue_id, states)
  end

  defp extract_issue_and_state(_response), do: {:error, :issue_or_state_not_found}

  defp extract_state(issue_id, [%{"id" => state_id} | _]) when is_binary(state_id) do
    {:ok, %{issue_id: issue_id, state_id: state_id}}
  end

  defp extract_state(issue_id, [%{id: state_id} | _]) when is_binary(state_id) do
    {:ok, %{issue_id: issue_id, state_id: state_id}}
  end

  defp extract_state(_issue_id, _states), do: {:error, :issue_or_state_not_found}

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
    %{"error" => %{"message" => "`linear_issue_update_state` requires a non-empty `issue_id` string."}}
  end

  defp error_payload(:missing_state_name) do
    %{"error" => %{"message" => "`linear_issue_update_state` requires a non-empty `state_name` string."}}
  end

  defp error_payload(:invalid_arguments) do
    %{"error" => %{"message" => "`linear_issue_update_state` expects an object with `issue_id` and `state_name`."}}
  end

  defp error_payload(:issue_or_state_not_found) do
    %{"error" => %{"message" => "`linear_issue_update_state` could not resolve the issue or target state."}}
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
    %{"error" => %{"message" => "Linear issue state update failed.", "reason" => inspect(reason)}}
  end
end
