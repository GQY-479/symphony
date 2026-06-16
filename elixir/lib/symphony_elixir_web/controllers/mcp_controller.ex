defmodule SymphonyElixirWeb.McpController do
  @moduledoc """
  HTTP MCP endpoint for Symphony-provided agent tools.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Agent.McpServer
  alias SymphonyElixirWeb.Endpoint

  @spec linear_tools(Conn.t(), map()) :: Conn.t()
  def linear_tools(conn, request) when is_map(request) do
    request
    |> McpServer.handle(mcp_opts())
    |> response_for(conn, request)
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    conn
    |> put_status(405)
    |> json(%{error: %{code: "method_not_allowed", message: "Method not allowed"}})
  end

  defp response_for(:noreply, conn, _request) do
    send_resp(conn, 202, "")
  end

  defp response_for({:ok, result}, conn, request) do
    json(conn, %{
      "jsonrpc" => "2.0",
      "id" => Map.get(request, "id"),
      "result" => result
    })
  end

  defp response_for({:error, error}, conn, request) do
    json(conn, %{
      "jsonrpc" => "2.0",
      "id" => Map.get(request, "id"),
      "error" => error
    })
  end

  defp mcp_opts do
    case Endpoint.config(:mcp_linear_client) do
      nil -> []
      linear_client -> [linear_client: linear_client]
    end
  end
end
