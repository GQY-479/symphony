defmodule SymphonyElixir.Agent.McpServer.LinearTools do
  @moduledoc """
  将 Symphony 通用工具结果包装为 MCP tool result。
  """

  require Logger

  alias SymphonyElixir.Agent.Tool

  @spec call(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def call(%{"name" => name} = params, opts) when is_binary(name) do
    arguments = Map.get(params, "arguments", %{})

    case Tool.execute(name, arguments, opts) do
      {:ok, result} ->
        log_tool_call(name, result)
        {:ok, tool_result(result)}

      {:error, result} ->
        log_tool_call(name, result)
        {:ok, tool_result(result)}
    end
  end

  def call(_params, _opts) do
    {:error, SymphonyElixir.Agent.McpServer.invalid_params_error("tools/call requires a string tool name.")}
  end

  defp tool_result(result) do
    %{
      "content" => [
        %{
          "type" => "text",
          "text" => result.output
        }
      ],
      "isError" => result.success == false
    }
  end

  defp log_tool_call(name, result) do
    outcome = if result.success, do: "ok", else: "error"
    error_category = error_category(result)

    Logger.info("MCP tools/call tool=#{inspect(name)} outcome=#{outcome} is_error=#{result.success == false} error_category=#{error_category}")
  end

  defp error_category(%{success: true}), do: "none"

  defp error_category(%{payload: payload}) do
    cond do
      payload_error_category?(payload, "graphql_errors") -> "graphql_errors"
      graphql_errors?(payload) -> "graphql_errors"
      unsupported_tool?(payload) -> "unsupported_tool"
      invalid_arguments?(payload) -> "invalid_arguments"
      linear_api_status?(payload) -> "linear_api_status"
      linear_auth?(payload) -> "linear_auth"
      linear_api_request?(payload) -> "linear_api_request"
      true -> "tool_error"
    end
  end

  defp error_category(_result), do: "tool_error"

  defp graphql_errors?(%{"errors" => errors}) when is_list(errors) and errors != [], do: true
  defp graphql_errors?(%{errors: errors}) when is_list(errors) and errors != [], do: true
  defp graphql_errors?(_payload), do: false

  defp payload_error_category?(payload, category) do
    nested(payload, ["error", "category"]) == category or nested(payload, [:error, :category]) == category
  end

  defp unsupported_tool?(payload) do
    is_list(nested(payload, ["error", "supportedTools"])) or is_list(nested(payload, [:error, :supportedTools]))
  end

  defp invalid_arguments?(payload) do
    message = error_message(payload)

    String.contains?(message, "requires a non-empty") or
      String.contains?(message, "expects an object with") or
      String.contains?(message, "expects either a GraphQL query string") or
      String.contains?(message, "`linear_graphql.variables` must be a JSON object")
  end

  defp linear_api_status?(payload) do
    is_integer(nested(payload, ["error", "status"])) or is_integer(nested(payload, [:error, :status]))
  end

  defp linear_auth?(payload), do: String.contains?(error_message(payload), "missing Linear auth")

  defp linear_api_request?(payload) do
    String.contains?(error_message(payload), "failed before receiving a successful response")
  end

  defp error_message(payload) do
    case nested(payload, ["error", "message"]) || nested(payload, [:error, :message]) do
      message when is_binary(message) -> message
      _ -> ""
    end
  end

  defp nested(value, []), do: value

  defp nested(value, [key | rest]) when is_map(value) do
    case Map.fetch(value, key) do
      {:ok, nested_value} -> nested(nested_value, rest)
      :error -> nil
    end
  end

  defp nested(_value, _path), do: nil
end
