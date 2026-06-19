---
name: linear
description: |
  Use when Codex must interact with Linear from Symphony: query or audit issues,
  create test issues, add/edit comments, move states, attach PRs, upload assets,
  or use the local Elixir fallback when `linear_graphql` is unavailable.
---

# Linear GraphQL

Use this skill for Linear GraphQL work during Symphony app-server sessions and
for local Symphony issue lifecycle tests when the app-server tool is not exposed
in the current Codex session.

## Primary tool

Use the `linear_graphql` client tool exposed by Symphony's app-server session.
It reuses Symphony's configured Linear auth for the session.

Tool input:

```json
{
  "query": "query or mutation document",
  "variables": {
    "optional": "graphql variables object"
  }
}
```

Tool behavior:

- Send one GraphQL operation per tool call.
- Treat a top-level `errors` array as a failed GraphQL operation even if the
  tool call itself completed.
- Keep queries/mutations narrowly scoped; ask only for the fields you need.

## Local fallback when `linear_graphql` is unavailable

If the current session does not expose `linear_graphql`, use Symphony's Elixir
client instead of inventing a new raw-token helper. The client reads normal
Symphony config and sends the same Linear GraphQL request path.

From the repo root:

```bash
cd elixir
LINEAR_API_KEY="$(sed -n '1p' /mnt/c/Users/GQY47/.linear_api_key)" \
  mise exec -- mix run --no-start -e '
Application.ensure_all_started(:req)
query = """
query IssueByKey($key: String!) {
  issue(id: $key) {
    id
    identifier
    title
    url
    branchName
    createdAt
    updatedAt
    startedAt
    completedAt
    canceledAt
    archivedAt
    state { id name type }
    assignee { id name }
    project { id name slugId }
    comments(first: 10) {
      nodes { id body createdAt updatedAt resolvedAt user { id name } }
    }
    attachments(first: 10) {
      nodes { id title url sourceType createdAt updatedAt }
    }
    history(first: 20) {
      nodes {
        id
        createdAt
        fromState { name type }
        toState { name type }
        actor { name }
      }
    }
    stateHistory(first: 20) {
      nodes { id startedAt endedAt state { name type } }
    }
  }
}
"""
case SymphonyElixir.Linear.Client.graphql(query, %{"key" => "YQE-50"}) do
  {:ok, body} -> IO.puts(Jason.encode!(body, pretty: true))
  {:error, reason} -> IO.inspect(reason, label: "linear_error")
end
'
```

Notes:

- Do not print, commit, or write `LINEAR_API_KEY` anywhere. The command above
  only passes it through the process environment.
- `/mnt/c/Users/GQY47/.linear_api_key` is the local fallback used by
  `elixir/start-local.ps1`; first check existence with `test -s ...`, not by
  printing it.
- Use `mise exec -- mix ...` in this repo. Plain `mix` may not be on PATH.
- The same fallback runs mutations; replace the GraphQL document and variables
  inside the Elixir snippet, then read back the changed issue for verification.
- If a GraphQL query fails with HTTP 400 and `graphql_errors`, remove optional
  fields and introspect the schema before retrying.

## Discovering unfamiliar operations

When you need an unfamiliar mutation, input type, or object field, use targeted
introspection through `linear_graphql`.

List mutation names:

```graphql
query ListMutations {
  __type(name: "Mutation") {
    fields {
      name
    }
  }
}
```

Inspect a specific input object:

```graphql
query CommentCreateInputShape {
  __type(name: "CommentCreateInput") {
    inputFields {
      name
      type {
        kind
        name
        ofType {
          kind
          name
        }
      }
    }
  }
}
```

## Common workflows

### Create a safe test issue lifecycle

For smoke tests, create issues in `Backlog` or immediately move them to
`Canceled`. Never leave synthetic `linear-capability-smoke` issues in `Todo` or
`In Progress`.

First resolve IDs instead of hardcoding them:

```graphql
query ProjectTeamStates($slug: String!) {
  projects(filter: { slugId: { eq: $slug } }, first: 1) {
    nodes {
      id
      name
      slugId
      teams {
        nodes {
          id
          key
          name
          states { nodes { id name type } }
        }
      }
    }
  }
  viewer { id name }
}
```

Create the issue:

```graphql
mutation CreateTestIssue($input: IssueCreateInput!) {
  issueCreate(input: $input) {
    success
    issue {
      id
      identifier
      title
      url
      state { id name type }
      project { id name slugId }
      team { id key name }
    }
  }
}
```

Use variables shaped like:

```json
{
  "input": {
    "teamId": "team-id",
    "projectId": "project-id",
    "stateId": "backlog-state-id",
    "assigneeId": "optional-viewer-id",
    "title": "Linear capability smoke 2026-06-19T15:59:55Z",
    "description": "linear-capability-smoke\n\nCreated by Codex to verify Linear issue creation. Move to Canceled after the smoke.",
    "priority": 0
  }
}
```

Then create a comment and move the issue to a terminal state:

```graphql
mutation CommentOnIssue($issueId: String!, $body: String!) {
  commentCreate(input: { issueId: $issueId, body: $body }) {
    success
    comment { id url createdAt }
  }
}
```

```graphql
mutation MoveIssueToState($id: String!, $stateId: String!) {
  issueUpdate(id: $id, input: { stateId: $stateId }) {
    success
    issue {
      id
      identifier
      url
      state { id name type }
      updatedAt
    }
  }
}
```

For derived workflow issues, prefer `parentId` in `IssueCreateInput` when the
new issue is a true child of the root. For looser links, use
`issueRelationCreate` with `type` from `IssueRelationType` (`blocks`,
`duplicate`, `related`, `similar`) after introspecting the current schema.

### Query an issue by key, identifier, or id

Use these progressively:

- Start with `issue(id: $key)` when you have a ticket key such as `MT-686`.
- Fall back to `issues(filter: ...)` when you need identifier search semantics.
- Once you have the internal issue id, prefer `issue(id: $id)` for narrower reads.

Lookup by issue key:

```graphql
query IssueByKey($key: String!) {
  issue(id: $key) {
    id
    identifier
    title
    state {
      id
      name
      type
    }
    project {
      id
      name
    }
    branchName
    url
    description
    updatedAt
    attachments {
      nodes {
        id
        title
        url
        sourceType
      }
    }
  }
}
```

Lookup by identifier filter:

```graphql
query IssueByIdentifier($identifier: String!) {
  issues(filter: { identifier: { eq: $identifier } }, first: 1) {
    nodes {
      id
      identifier
      title
      state {
        id
        name
        type
      }
      project {
        id
        name
      }
      branchName
      url
      description
      updatedAt
    }
  }
}
```

Resolve a key to an internal id:

```graphql
query IssueByIdOrKey($id: String!) {
  issue(id: $id) {
    id
    identifier
    title
  }
}
```

Read the issue once the internal id is known:

```graphql
query IssueDetails($id: String!) {
  issue(id: $id) {
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
    project {
      id
      name
    }
    attachments {
      nodes {
        id
        title
        url
        sourceType
      }
    }
  }
}
```

### Audit completed orchestration issues

For smoke tests and dynamic-workflow validation, do not trust final state alone.
Read both issue status and completion evidence:

- `state { name type }`, `completedAt`, `updatedAt`
- `comments(first: ...)` for `Completion Packet`, `Review Decision`, blocked
  notes, and handoff evidence
- `history` and `stateHistory` for state transitions
- `attachments`, PR links, or local `.symphony/*` files if the issue references
  workspace artifacts

For issue-graph roots, also verify derived work against the root workspace paths
named in the issue description or workflow plan. A derived issue in `Done` with
`outcome: blocked` in its completion packet is not a valid pass.

### Query team workflow states for an issue

Use this before changing issue state when you need the exact `stateId`:

```graphql
query IssueTeamStates($id: String!) {
  issue(id: $id) {
    id
    team {
      id
      key
      name
      states {
        nodes {
          id
          name
          type
        }
      }
    }
  }
}
```

### Edit an existing comment

Use `commentUpdate` through `linear_graphql`:

```graphql
mutation UpdateComment($id: String!, $body: String!) {
  commentUpdate(id: $id, input: { body: $body }) {
    success
    comment {
      id
      body
    }
  }
}
```

### Create a comment

Use `commentCreate` through `linear_graphql`:

```graphql
mutation CreateComment($issueId: String!, $body: String!) {
  commentCreate(input: { issueId: $issueId, body: $body }) {
    success
    comment {
      id
      url
    }
  }
}
```

### Move an issue to a different state

Use `issueUpdate` with the destination `stateId`:

```graphql
mutation MoveIssueToState($id: String!, $stateId: String!) {
  issueUpdate(id: $id, input: { stateId: $stateId }) {
    success
    issue {
      id
      identifier
      state {
        id
        name
      }
    }
  }
}
```

### Attach a GitHub PR to an issue

Use the GitHub-specific attachment mutation when linking a PR:

```graphql
mutation AttachGitHubPR($issueId: String!, $url: String!, $title: String) {
  attachmentLinkGitHubPR(
    issueId: $issueId
    url: $url
    title: $title
    linkKind: links
  ) {
    success
    attachment {
      id
      title
      url
    }
  }
}
```

If you only need a plain URL attachment and do not care about GitHub-specific
link metadata, use:

```graphql
mutation AttachURL($issueId: String!, $url: String!, $title: String) {
  attachmentLinkURL(issueId: $issueId, url: $url, title: $title) {
    success
    attachment {
      id
      title
      url
    }
  }
}
```

### Introspection patterns used during schema discovery

Use these when the exact field or mutation shape is unclear:

```graphql
query QueryFields {
  __type(name: "Query") {
    fields {
      name
    }
  }
}
```

```graphql
query IssueFieldArgs {
  __type(name: "Query") {
    fields {
      name
      args {
        name
        type {
          kind
          name
          ofType {
            kind
            name
            ofType {
              kind
              name
            }
          }
        }
      }
    }
  }
}
```

### Upload a video to a comment

Do this in three steps:

1. Call `linear_graphql` with `fileUpload` to get `uploadUrl`, `assetUrl`, and
   any required upload headers.
2. Upload the local file bytes to `uploadUrl` with `curl -X PUT` and the exact
   headers returned by `fileUpload`.
3. Call `linear_graphql` again with `commentCreate` (or `commentUpdate`) and
   include the resulting `assetUrl` in the comment body.

Useful mutations:

```graphql
mutation FileUpload(
  $filename: String!
  $contentType: String!
  $size: Int!
  $makePublic: Boolean
) {
  fileUpload(
    filename: $filename
    contentType: $contentType
    size: $size
    makePublic: $makePublic
  ) {
    success
    uploadFile {
      uploadUrl
      assetUrl
      headers {
        key
        value
      }
    }
  }
}
```

## Usage rules

- Use `linear_graphql` for comment edits, uploads, and ad-hoc Linear API
  queries.
- Prefer the narrowest issue lookup that matches what you already know:
  key -> identifier search -> internal id.
- For state transitions, fetch team states first and use the exact `stateId`
  instead of hardcoding names inside mutations.
- For live test issue creation, use a clear `linear-capability-smoke` marker,
  create in `Backlog` when possible, add a smoke comment, then move the issue
  to `Canceled` or another agreed terminal state before finishing.
- Prefer `attachmentLinkGitHubPR` over a generic URL attachment when linking a
  GitHub PR to a Linear issue.
- Do not introduce new raw-token shell helpers for GraphQL access.
- If you need shell work for uploads, only use it for signed upload URLs
  returned by `fileUpload`; those URLs already carry the needed authorization.
