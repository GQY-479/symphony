defmodule SymphonyElixir.Agent.McpServer do
  @moduledoc """
  Symphony 内置 MCP server 的最小协议分发层。
  """

  alias SymphonyElixir.Agent.McpServer.LinearTools
  alias SymphonyElixir.Agent.Tool

  @type request :: map()
  @type result :: map()
  @type error :: map()

  @spec handle(request()) :: {:ok, result()} | {:error, error()} | :noreply
  def handle(request), do: handle(request, [])

  @spec handle(request(), keyword()) :: {:ok, result()} | {:error, error()} | :noreply
  def handle(%{"method" => "initialize"} = request, _opts) do
    protocol_version = get_in(request, ["params", "protocolVersion"]) || "2025-06-18"

    {:ok,
     %{
       "protocolVersion" => protocol_version,
       "serverInfo" => %{
         "name" => "symphony-linear-tools",
         "version" => "dev"
       },
       "capabilities" => %{
         "tools" => %{}
       }
     }}
  end

  def handle(%{"method" => "notifications/initialized"}, _opts), do: :noreply

  def handle(%{"method" => "tools/list"}, _opts) do
    {:ok, %{"tools" => Tool.specs()}}
  end

  def handle(%{"method" => "tools/call", "params" => params}, opts) when is_map(params) do
    LinearTools.call(params, opts)
  end

  def handle(%{"method" => "tools/call"}, _opts), do: {:error, invalid_params_error("tools/call requires params.")}

  def handle(%{"method" => method}, _opts) when is_binary(method) do
    {:error,
     %{
       "code" => -32601,
       "message" => "Unsupported MCP method: #{method}"
     }}
  end

  def handle(_request, _opts), do: {:error, invalid_params_error("MCP request requires a method.")}

  @spec invalid_params_error(String.t()) :: error()
  def invalid_params_error(message) do
    %{
      "code" => -32602,
      "message" => message
    }
  end
end
