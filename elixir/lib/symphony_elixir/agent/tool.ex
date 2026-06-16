defmodule SymphonyElixir.Agent.Tool do
  @moduledoc """
  面向不同 agent backend 的通用客户端工具注册表。
  """

  alias SymphonyElixir.Agent.Tool.LinearCommentCreate
  alias SymphonyElixir.Agent.Tool.LinearGraphql
  alias SymphonyElixir.Agent.Tool.LinearIssueRead
  alias SymphonyElixir.Agent.Tool.LinearIssueUpdateState

  @type result :: %{
          name: String.t() | nil,
          success: boolean(),
          output: String.t(),
          payload: map() | list() | term()
        }

  @spec specs() :: [map()]
  def specs do
    [
      LinearIssueRead.spec(),
      LinearCommentCreate.spec(),
      LinearIssueUpdateState.spec(),
      LinearGraphql.spec()
    ]
  end

  @spec execute(String.t() | nil, term()) :: {:ok, result()} | {:error, result()}
  def execute(tool, arguments), do: execute(tool, arguments, [])

  @spec execute(String.t() | nil, term(), keyword()) :: {:ok, result()} | {:error, result()}
  def execute("linear_issue_read", arguments, opts), do: LinearIssueRead.execute(arguments, opts)
  def execute("linear_comment_create", arguments, opts), do: LinearCommentCreate.execute(arguments, opts)
  def execute("linear_issue_update_state", arguments, opts), do: LinearIssueUpdateState.execute(arguments, opts)
  def execute("linear_graphql", arguments, opts), do: LinearGraphql.execute(arguments, opts)

  def execute(other, _arguments, _opts) do
    payload = %{
      "error" => %{
        "message" => "Unsupported dynamic tool: #{inspect(other)}.",
        "supportedTools" => supported_tool_names()
      }
    }

    {:error, failure_result(other, payload)}
  end

  @spec success_result(String.t(), term()) :: result()
  def success_result(name, payload) do
    %{
      name: name,
      success: true,
      output: encode_payload(payload),
      payload: payload
    }
  end

  @spec failure_result(String.t() | nil, term()) :: result()
  def failure_result(name, payload) do
    %{
      name: name,
      success: false,
      output: encode_payload(payload),
      payload: payload
    }
  end

  @spec encode_payload(term()) :: String.t()
  def encode_payload(payload) when is_map(payload) or is_list(payload), do: Jason.encode!(payload, pretty: true)
  def encode_payload(payload), do: inspect(payload)

  defp supported_tool_names, do: Enum.map(specs(), & &1["name"])
end
