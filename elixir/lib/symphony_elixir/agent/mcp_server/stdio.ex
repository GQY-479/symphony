defmodule SymphonyElixir.Agent.McpServer.Stdio do
  @moduledoc """
  基于 newline-delimited stdio 的 MCP JSON-RPC 循环。
  """

  alias SymphonyElixir.Agent.McpServer
  alias SymphonyElixir.Workflow

  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    :ok = prepare_runtime!(opts)

    IO.stream(:stdio, :line)
    |> Enum.each(fn line ->
      case handle_line(line, opts) do
        {:reply, encoded} -> IO.write(encoded <> "\n")
        :noreply -> :ok
      end
    end)
  end

  @spec prepare_runtime!(keyword()) :: :ok
  def prepare_runtime!(opts) do
    case Keyword.get(opts, :workflow_path) do
      workflow_path when is_binary(workflow_path) and workflow_path != "" ->
        Workflow.set_workflow_file_path(Path.expand(workflow_path))

      _ ->
        :ok
    end
  end

  @spec handle_line(String.t(), keyword()) :: {:reply, String.t()} | :noreply
  def handle_line(line, opts \\ []) when is_binary(line) do
    case Jason.decode(String.trim_trailing(line)) do
      {:ok, request} when is_map(request) ->
        request
        |> McpServer.handle(opts)
        |> response_for(request)

      {:ok, _other} ->
        {:reply, encode_error(nil, -32_600, "Invalid JSON-RPC request.")}

      {:error, _reason} ->
        {:reply, encode_error(nil, -32_700, "Parse error.")}
    end
  end

  defp response_for(:noreply, _request), do: :noreply

  defp response_for({:ok, result}, request) do
    {:reply,
     Jason.encode!(%{
       "jsonrpc" => "2.0",
       "id" => Map.get(request, "id"),
       "result" => result
     })}
  end

  defp response_for({:error, error}, request) do
    {:reply,
     Jason.encode!(%{
       "jsonrpc" => "2.0",
       "id" => Map.get(request, "id"),
       "error" => error
     })}
  end

  defp encode_error(id, code, message) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{
        "code" => code,
        "message" => message
      }
    })
  end
end
