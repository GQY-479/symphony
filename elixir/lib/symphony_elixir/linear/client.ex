defmodule SymphonyElixir.Linear.Client do
  @moduledoc """
  Thin Linear GraphQL client for polling candidate issues.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Issue}

  @issue_page_size 50
  @context_page_size 50
  @max_error_body_log_bytes 1_000

  @query """
  query SymphonyLinearPoll(
    $projectSlug: String!
    $stateNames: [String!]!
    $first: Int!
    $relationFirst: Int!
    $contextFirst: Int!
    $after: String
  ) {
    issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
      nodes {
        ...SymphonyRichIssueFields
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }

  fragment SymphonyRichIssueFields on Issue {
    id
    identifier
    title
    description
    priority
    priorityLabel
    estimate
    sortOrder
    startedAt
    completedAt
    canceledAt
    archivedAt
    autoClosedAt
    autoArchivedAt
    dueDate
    slaStartedAt
    slaBreachesAt
    trashed
    state {
      id
      name
      type
    }
    branchName
    url
    creator {
      id
      name
      email
    }
    assignee {
      id
      name
      email
    }
    project {
      id
      name
      slugId
      url
    }
    team {
      id
      key
      name
    }
    cycle {
      id
      name
      number
      startsAt
      endsAt
    }
    labels(first: $contextFirst) {
      nodes {
        id
        name
        color
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
    comments(first: $contextFirst) {
      nodes {
        id
        body
        url
        createdAt
        updatedAt
        resolvedAt
        user {
          id
          name
          email
        }
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
    attachments(first: $contextFirst) {
      nodes {
        id
        title
        url
        sourceType
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
    relations(first: $relationFirst) {
      nodes {
        id
        type
        relatedIssue {
          id
          identifier
          title
          url
          state {
            name
            type
          }
        }
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
    inverseRelations(first: $relationFirst) {
      nodes {
        id
        type
        issue {
          id
          identifier
          title
          url
          state {
            name
            type
          }
        }
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
    history(first: $contextFirst) {
      nodes {
        id
        createdAt
        fromState {
          name
          type
        }
        toState {
          name
          type
        }
        actor {
          id
          name
          email
        }
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
    stateHistory(first: $contextFirst) {
      nodes {
        id
        startedAt
        endedAt
        state {
          name
          type
        }
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
    createdAt
    updatedAt
  }
  """

  @query_by_ids """
  query SymphonyLinearIssuesById($ids: [ID!]!, $first: Int!, $relationFirst: Int!, $contextFirst: Int!) {
    issues(filter: {id: {in: $ids}}, first: $first) {
      nodes {
        ...SymphonyRichIssueFields
      }
    }
  }

  fragment SymphonyRichIssueFields on Issue {
    id
    identifier
    title
    description
    priority
    priorityLabel
    estimate
    sortOrder
    startedAt
    completedAt
    canceledAt
    archivedAt
    autoClosedAt
    autoArchivedAt
    dueDate
    slaStartedAt
    slaBreachesAt
    trashed
    state {
      id
      name
      type
    }
    branchName
    url
    creator {
      id
      name
      email
    }
    assignee {
      id
      name
      email
    }
    project {
      id
      name
      slugId
      url
    }
    team {
      id
      key
      name
    }
    cycle {
      id
      name
      number
      startsAt
      endsAt
    }
    labels(first: $contextFirst) {
      nodes {
        id
        name
        color
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
    comments(first: $contextFirst) {
      nodes {
        id
        body
        url
        createdAt
        updatedAt
        resolvedAt
        user {
          id
          name
          email
        }
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
    attachments(first: $contextFirst) {
      nodes {
        id
        title
        url
        sourceType
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
    relations(first: $relationFirst) {
      nodes {
        id
        type
        relatedIssue {
          id
          identifier
          title
          url
          state {
            name
            type
          }
        }
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
    inverseRelations(first: $relationFirst) {
      nodes {
        id
        type
        issue {
          id
          identifier
          title
          url
          state {
            name
            type
          }
        }
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
    history(first: $contextFirst) {
      nodes {
        id
        createdAt
        fromState {
          name
          type
        }
        toState {
          name
          type
        }
        actor {
          id
          name
          email
        }
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
    stateHistory(first: $contextFirst) {
      nodes {
        id
        startedAt
        endedAt
        state {
          name
          type
        }
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
    createdAt
    updatedAt
  }
  """

  @viewer_query """
  query SymphonyLinearViewer {
    viewer {
      id
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    fetch_candidate_issues(Config.settings!(), &graphql/2)
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      fetch_issues_by_states(Config.settings!(), normalized_states, &graphql/2)
    end
  end

  @doc false
  @spec fetch_candidate_issues_for_test(keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues_for_test(opts) when is_list(opts) do
    request_fun = Keyword.fetch!(opts, :request_fun)
    fetch_candidate_issues(Config.settings!(), fn query, variables -> graphql(query, variables, request_fun: request_fun) end)
  end

  defp fetch_candidate_issues(settings, graphql_fun) when is_function(graphql_fun, 2) do
    tracker = settings.tracker

    cond do
      is_nil(tracker.api_key) ->
        {:error, :missing_linear_api_token}

      Config.tracker_project_entries(settings) == [] ->
        {:error, :missing_linear_project_slug}

      true ->
        with {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_by_project_entries(Config.tracker_project_entries(settings), tracker.active_states, assignee_filter, graphql_fun)
        end
    end
  end

  defp fetch_issues_by_states(settings, state_names, graphql_fun) when is_function(graphql_fun, 2) do
    cond do
      is_nil(settings.tracker.api_key) ->
        {:error, :missing_linear_api_token}

      Config.tracker_project_entries(settings) == [] ->
        {:error, :missing_linear_project_slug}

      true ->
        do_fetch_by_project_entries(Config.tracker_project_entries(settings), state_names, nil, graphql_fun)
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_issue_states(ids, assignee_filter)
        end
    end
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    payload = build_graphql_payload(query, variables, Keyword.get(opts, :operation_name))
    request_fun = Keyword.get(opts, :request_fun, &post_graphql_request/2)

    with {:ok, headers} <- graphql_headers(),
         {:ok, %{status: 200, body: body}} <- request_fun.(payload, headers) do
      {:ok, body}
    else
      {:ok, response} ->
        error_category = non_200_error_category(response)
        Logger.error("Linear GraphQL request failed status=#{response.status}#{linear_error_context(payload, error_category)}")

        {:error, non_200_error_reason(response.status, error_category)}

      {:error, reason} ->
        Logger.error("Linear GraphQL request failed: #{sanitize_error_reason(reason)}")
        {:error, {:linear_api_request, reason}}
    end
  end

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue) when is_map(issue) do
    normalize_issue(issue, nil, nil)
  end

  @doc false
  @spec normalize_issue_for_test(map(), String.t() | nil) :: Issue.t() | nil
  def normalize_issue_for_test(issue, assignee) when is_map(issue) do
    assignee_filter =
      case assignee do
        value when is_binary(value) ->
          case build_assignee_filter(value) do
            {:ok, filter} -> filter
            {:error, _reason} -> nil
          end

        _ ->
          nil
      end

    normalize_issue(issue, assignee_filter, nil)
  end

  @doc false
  @spec next_page_cursor_for_test(map()) :: {:ok, String.t()} | :done | {:error, term()}
  def next_page_cursor_for_test(page_info) when is_map(page_info), do: next_page_cursor(page_info)

  @doc false
  @spec merge_issue_pages_for_test([[Issue.t()]]) :: [Issue.t()]
  def merge_issue_pages_for_test(issue_pages) when is_list(issue_pages) do
    issue_pages
    |> Enum.reduce([], &prepend_page_issues/2)
    |> finalize_paginated_issues()
  end

  @doc false
  @spec fetch_issue_states_by_ids_for_test([String.t()], (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids_for_test(issue_ids, graphql_fun)
      when is_list(issue_ids) and is_function(graphql_fun, 2) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        do_fetch_issue_states(ids, nil, graphql_fun)
    end
  end

  defp do_fetch_by_project_entries(project_entries, state_names, assignee_filter, graphql_fun) do
    Enum.reduce_while(project_entries, {:ok, []}, fn project_entry, {:ok, acc_issues} ->
      case do_fetch_by_states(project_entry, state_names, assignee_filter, graphql_fun) do
        {:ok, issues} -> {:cont, {:ok, acc_issues ++ issues}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp do_fetch_by_states(project_entry, state_names, assignee_filter, graphql_fun) do
    do_fetch_by_states_page(project_entry, state_names, assignee_filter, graphql_fun, nil, [])
  end

  defp do_fetch_by_states_page(project_entry, state_names, assignee_filter, graphql_fun, after_cursor, acc_issues) do
    with {:ok, body} <-
           graphql_fun.(@query, %{
             projectSlug: project_entry.project_slug,
             stateNames: state_names,
             first: @issue_page_size,
             relationFirst: @issue_page_size,
             contextFirst: @context_page_size,
             after: after_cursor
           }),
         {:ok, issues, page_info} <- decode_linear_page_response(body, assignee_filter, project_entry) do
      updated_acc = prepend_page_issues(issues, acc_issues)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_by_states_page(project_entry, state_names, assignee_filter, graphql_fun, next_cursor, updated_acc)

        :done ->
          {:ok, finalize_paginated_issues(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp prepend_page_issues(issues, acc_issues) when is_list(issues) and is_list(acc_issues) do
    Enum.reverse(issues, acc_issues)
  end

  defp finalize_paginated_issues(acc_issues) when is_list(acc_issues), do: Enum.reverse(acc_issues)

  defp do_fetch_issue_states(ids, assignee_filter) do
    do_fetch_issue_states(ids, assignee_filter, &graphql/2)
  end

  defp do_fetch_issue_states(ids, assignee_filter, graphql_fun)
       when is_list(ids) and is_function(graphql_fun, 2) do
    issue_order_index = issue_order_index(ids)
    do_fetch_issue_states_page(ids, assignee_filter, graphql_fun, [], issue_order_index)
  end

  defp do_fetch_issue_states_page([], _assignee_filter, _graphql_fun, acc_issues, issue_order_index) do
    acc_issues
    |> finalize_paginated_issues()
    |> sort_issues_by_requested_ids(issue_order_index)
    |> then(&{:ok, &1})
  end

  defp do_fetch_issue_states_page(ids, assignee_filter, graphql_fun, acc_issues, issue_order_index) do
    {batch_ids, rest_ids} = Enum.split(ids, @issue_page_size)

    case graphql_fun.(@query_by_ids, %{
           ids: batch_ids,
           first: length(batch_ids),
           relationFirst: @issue_page_size,
           contextFirst: @context_page_size
         }) do
      {:ok, body} ->
        with {:ok, issues} <- decode_linear_response(body, assignee_filter) do
          updated_acc = prepend_page_issues(issues, acc_issues)
          do_fetch_issue_states_page(rest_ids, assignee_filter, graphql_fun, updated_acc, issue_order_index)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp issue_order_index(ids) when is_list(ids) do
    ids
    |> Enum.with_index()
    |> Map.new()
  end

  defp sort_issues_by_requested_ids(issues, issue_order_index)
       when is_list(issues) and is_map(issue_order_index) do
    fallback_index = map_size(issue_order_index)

    Enum.sort_by(issues, fn
      %Issue{id: issue_id} -> Map.get(issue_order_index, issue_id, fallback_index)
      _ -> fallback_index
    end)
  end

  defp build_graphql_payload(query, variables, operation_name) do
    %{
      "query" => query,
      "variables" => variables
    }
    |> maybe_put_operation_name(operation_name)
  end

  defp maybe_put_operation_name(payload, operation_name) when is_binary(operation_name) do
    trimmed = String.trim(operation_name)

    if trimmed == "" do
      payload
    else
      Map.put(payload, "operationName", trimmed)
    end
  end

  defp maybe_put_operation_name(payload, _operation_name), do: payload

  defp linear_error_context(_payload, error_category), do: " error_category=#{error_category}"

  defp non_200_error_category(%{body: body}) do
    if graphql_error_body?(body), do: "graphql_errors", else: "linear_api_status"
  end

  defp non_200_error_category(_response), do: "linear_api_status"

  defp non_200_error_reason(status, "graphql_errors"), do: {:linear_api_graphql_errors, status}
  defp non_200_error_reason(status, _category), do: {:linear_api_status, status}

  defp graphql_error_body?(%{"errors" => errors}) when is_list(errors) and errors != [], do: true
  defp graphql_error_body?(%{errors: errors}) when is_list(errors) and errors != [], do: true
  defp graphql_error_body?(_body), do: false

  defp sanitize_error_reason(reason) do
    reason
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> redact_linear_tokens()
    |> redact_authorization_values()
    |> truncate_error_body()
  end

  defp redact_linear_tokens(text) when is_binary(text) do
    String.replace(text, ~r/lin_api_[A-Za-z0-9_-]+/, "[REDACTED]")
  end

  defp redact_authorization_values(text) when is_binary(text) do
    text
    |> String.replace(~r/("authorization"\s*,\s*)"[^"]*"/i, "\\1\"[REDACTED]\"")
    |> String.replace(~r/("authorization"\s*=>\s*)"[^"]*"/i, "\\1\"[REDACTED]\"")
    |> String.replace(~r/(\{"Authorization",\s*)"[^"]*"/i, "\\1\"[REDACTED]\"")
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end

  defp graphql_headers do
    case Config.settings!().tracker.api_key do
      nil ->
        {:error, :missing_linear_api_token}

      token ->
        {:ok,
         [
           {"Authorization", token},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp post_graphql_request(payload, headers) do
    Req.post(Config.settings!().tracker.endpoint,
      headers: headers,
      json: payload,
      connect_options: [timeout: 30_000]
    )
  end

  defp decode_linear_response(response, assignee_filter) do
    decode_linear_response(response, assignee_filter, nil)
  end

  defp decode_linear_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter, project_entry) do
    issues =
      nodes
      |> Enum.map(&normalize_issue(&1, assignee_filter, project_entry))
      |> Enum.reject(&is_nil(&1))

    {:ok, issues}
  end

  defp decode_linear_response(%{"errors" => errors}, _assignee_filter, _project_entry) do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp decode_linear_response(_unknown, _assignee_filter, _project_entry) do
    {:error, :linear_unknown_payload}
  end

  defp decode_linear_page_response(
         %{
           "data" => %{
             "issues" => %{
               "nodes" => nodes,
               "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
             }
           }
         },
         assignee_filter,
         project_entry
       ) do
    with {:ok, issues} <- decode_linear_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter, project_entry) do
      {:ok, issues, %{has_next_page: has_next_page == true, end_cursor: end_cursor}}
    end
  end

  defp decode_linear_page_response(response, assignee_filter, _project_entry), do: decode_linear_response(response, assignee_filter)

  defp next_page_cursor(%{has_next_page: true, end_cursor: end_cursor})
       when is_binary(end_cursor) and byte_size(end_cursor) > 0 do
    {:ok, end_cursor}
  end

  defp next_page_cursor(%{has_next_page: true}), do: {:error, :linear_missing_end_cursor}
  defp next_page_cursor(_), do: :done

  defp normalize_issue(issue, assignee_filter, project_entry) when is_map(issue) do
    assignee = issue["assignee"]
    project = issue["project"]
    team = issue["team"]

    %Issue{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      description: issue["description"],
      priority: parse_priority(issue["priority"]),
      state: get_in(issue, ["state", "name"]),
      branch_name: issue["branchName"],
      url: issue["url"],
      assignee_id: assignee_field(assignee, "id"),
      project_id: project_field(project, "id"),
      project_name: project_field(project, "name"),
      project_slug: project_field(project, "slugId"),
      project_url: project_field(project, "url"),
      project_key: project_key(project, project_entry),
      project_repository: project_repository(project, project_entry),
      team_id: team_field(team, "id"),
      team_key: team_field(team, "key"),
      team_name: team_field(team, "name"),
      snapshot: issue_snapshot(issue),
      blocked_by: extract_blockers(issue),
      labels: extract_labels(issue),
      assigned_to_worker: assigned_to_worker?(assignee, assignee_filter),
      created_at: parse_datetime(issue["createdAt"]),
      updated_at: parse_datetime(issue["updatedAt"])
    }
  end

  defp normalize_issue(_issue, _assignee_filter, _project_entry), do: nil

  defp assignee_field(%{} = assignee, field) when is_binary(field), do: assignee[field]
  defp assignee_field(_assignee, _field), do: nil

  defp project_field(%{} = project, field) when is_binary(field), do: project[field]
  defp project_field(_project, _field), do: nil

  defp team_field(%{} = team, field) when is_binary(field), do: team[field]
  defp team_field(_team, _field), do: nil

  defp project_key(%{} = project, %{project_key: project_key, project_slug: configured_slug})
       when is_binary(project_key) and is_binary(configured_slug) do
    case project_field(project, "slugId") do
      ^configured_slug -> project_key
      slug when is_binary(slug) and slug != "" -> configured_project_key(slug) || slug
      _ -> project_key
    end
  end

  defp project_key(%{} = project, _project_entry) do
    case project_field(project, "slugId") do
      slug when is_binary(slug) and slug != "" -> configured_project_key(slug) || slug
      _ -> nil
    end
  end

  defp project_key(_project, %{project_key: project_key}) when is_binary(project_key), do: project_key
  defp project_key(_project, _project_entry), do: nil

  defp configured_project_key(project_slug) when is_binary(project_slug) do
    Config.settings!()
    |> Config.tracker_project_entries()
    |> Enum.find_value(fn
      %{project_key: project_key, project_slug: ^project_slug} -> project_key
      _entry -> nil
    end)
  end

  defp project_repository(%{} = project, %{project_repository: repository, project_slug: configured_slug})
       when is_binary(repository) and is_binary(configured_slug) do
    case project_field(project, "slugId") do
      ^configured_slug -> repository
      slug when is_binary(slug) and slug != "" -> configured_project_repository(slug)
      _ -> repository
    end
  end

  defp project_repository(%{} = project, _project_entry) do
    case project_field(project, "slugId") do
      slug when is_binary(slug) and slug != "" -> configured_project_repository(slug)
      _ -> nil
    end
  end

  defp project_repository(_project, %{project_repository: repository}) when is_binary(repository), do: repository
  defp project_repository(_project, _project_entry), do: nil

  defp configured_project_repository(project_slug) when is_binary(project_slug) do
    Config.settings!()
    |> Config.tracker_project_entries()
    |> Enum.find_value(fn
      %{project_repository: repository, project_slug: ^project_slug} -> repository
      _entry -> nil
    end)
  end

  defp assigned_to_worker?(_assignee, nil), do: true

  defp assigned_to_worker?(%{} = assignee, %{match_values: match_values})
       when is_struct(match_values, MapSet) do
    assignee
    |> assignee_id()
    |> then(fn
      nil -> false
      assignee_id -> MapSet.member?(match_values, assignee_id)
    end)
  end

  defp assigned_to_worker?(_assignee, _assignee_filter), do: false

  defp assignee_id(%{} = assignee), do: normalize_assignee_match_value(assignee["id"])

  defp routing_assignee_filter do
    case Config.settings!().tracker.assignee do
      nil ->
        {:ok, nil}

      assignee ->
        build_assignee_filter(assignee)
    end
  end

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    case normalize_assignee_match_value(assignee) do
      nil ->
        {:ok, nil}

      "me" ->
        resolve_viewer_assignee_filter()

      normalized ->
        {:ok, %{configured_assignee: assignee, match_values: MapSet.new([normalized])}}
    end
  end

  defp resolve_viewer_assignee_filter do
    case graphql(@viewer_query, %{}) do
      {:ok, %{"data" => %{"viewer" => viewer}}} when is_map(viewer) ->
        case assignee_id(viewer) do
          nil ->
            {:error, :missing_linear_viewer_identity}

          viewer_id ->
            {:ok, %{configured_assignee: "me", match_values: MapSet.new([viewer_id])}}
        end

      {:ok, _body} ->
        {:error, :missing_linear_viewer_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_assignee_match_value(value) when is_binary(value) do
    case value |> String.trim() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_assignee_match_value(_value), do: nil

  defp extract_labels(%{"labels" => %{"nodes" => labels}}) when is_list(labels) do
    labels
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
  end

  defp extract_labels(_), do: []

  defp extract_blockers(%{"inverseRelations" => %{"nodes" => inverse_relations}})
       when is_list(inverse_relations) do
    inverse_relations
    |> Enum.flat_map(fn
      %{"type" => relation_type, "issue" => blocker_issue}
      when is_binary(relation_type) and is_map(blocker_issue) ->
        if String.downcase(String.trim(relation_type)) == "blocks" do
          [
            %{
              id: blocker_issue["id"],
              identifier: blocker_issue["identifier"],
              state: get_in(blocker_issue, ["state", "name"])
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp extract_blockers(_), do: []

  defp issue_snapshot(issue) when is_map(issue) do
    issue
    |> Map.take([
      "id",
      "identifier",
      "title",
      "description",
      "priority",
      "priorityLabel",
      "estimate",
      "sortOrder",
      "state",
      "branchName",
      "url",
      "creator",
      "assignee",
      "project",
      "team",
      "cycle",
      "labels",
      "comments",
      "attachments",
      "relations",
      "inverseRelations",
      "history",
      "stateHistory",
      "createdAt",
      "updatedAt",
      "startedAt",
      "completedAt",
      "canceledAt",
      "archivedAt",
      "autoClosedAt",
      "autoArchivedAt",
      "dueDate",
      "slaStartedAt",
      "slaBreachesAt",
      "trashed"
    ])
    |> drop_nil_values()
  end

  defp issue_snapshot(_issue), do: %{}

  defp drop_nil_values(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {key, drop_nil_values(value)} end)
  end

  defp drop_nil_values(list) when is_list(list), do: Enum.map(list, &drop_nil_values/1)
  defp drop_nil_values(value), do: value

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_priority(priority) when is_integer(priority), do: priority
  defp parse_priority(_priority), do: nil
end
