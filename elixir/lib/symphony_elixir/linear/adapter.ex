defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Client

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @project_lookup_query """
  query SymphonyResolveProject($projectSlug: String!) {
    projects(filter: {slugId: {eq: $projectSlug}}, first: 1) {
      nodes {
        id
        team {
          id
        }
      }
    }
  }
  """

  @project_state_lookup_query """
  query SymphonyResolveProjectStateId($teamId: String!, $stateName: String!) {
    team(id: $teamId) {
      states(filter: {name: {eq: $stateName}}, first: 1) {
        nodes {
          id
        }
      }
    }
  }
  """

  @create_issue_mutation """
  mutation SymphonyCreateIssue(
    $teamId: String!
    $projectId: String!
    $title: String!
    $description: String!
    $stateId: String
    $assigneeId: String
  ) {
    issueCreate(
      input: {
        teamId: $teamId
        projectId: $projectId
        title: $title
        description: $description
        stateId: $stateId
        assigneeId: $assigneeId
      }
    ) {
      success
      issue {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: 50) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  @spec create_issue(map()) :: {:ok, term()} | {:error, term()}
  def create_issue(attrs) when is_map(attrs) do
    state_name = Map.get(attrs, :state) || Map.get(attrs, "state") || "Todo"

    with {:ok, project_id, team_id} <- resolve_project(),
         {:ok, state_id} <- resolve_project_state_id(team_id, state_name),
         {:ok, response} <-
           client_module().graphql(@create_issue_mutation, issue_create_variables(attrs, team_id, project_id, state_id)),
         {:ok, issue} <- normalize_created_issue(response) do
      {:ok, issue}
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp resolve_project do
    project_slug = Config.settings!().tracker.project_slug

    with {:ok, response} <- client_module().graphql(@project_lookup_query, %{projectSlug: project_slug}),
         %{"id" => project_id, "team" => %{"id" => team_id}} <- first_project_node(response) do
      {:ok, project_id, team_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :project_not_found}
    end
  end

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end

  defp resolve_project_state_id(team_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@project_state_lookup_query, %{teamId: team_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end

  defp issue_create_variables(attrs, team_id, project_id, state_id) do
    %{
      teamId: team_id,
      projectId: project_id,
      title: Map.get(attrs, :title) || Map.get(attrs, "title"),
      description: Map.get(attrs, :description) || Map.get(attrs, "description") || "",
      stateId: state_id,
      assigneeId: Map.get(attrs, :assignee_id) || Map.get(attrs, "assignee_id")
    }
  end

  defp normalize_created_issue(%{"data" => %{"issueCreate" => %{"success" => true, "issue" => %{} = issue}}}) do
    case Client.normalize_issue_for_test(issue) do
      nil -> {:error, :issue_create_failed}
      normalized_issue -> {:ok, normalized_issue}
    end
  end

  defp normalize_created_issue(%{"data" => %{"issueCreate" => %{"success" => false}}}) do
    {:error, :issue_create_failed}
  end

  defp normalize_created_issue(_response), do: {:error, :issue_create_failed}

  defp first_project_node(response) do
    get_in(response, ["data", "projects", "nodes", Access.at(0)])
  end
end
