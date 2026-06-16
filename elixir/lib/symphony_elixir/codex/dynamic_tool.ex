defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.Agent.Tool

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case Tool.execute(tool, arguments, opts) do
      {:ok, result} -> dynamic_tool_response(result.success, result.output)
      {:error, result} -> dynamic_tool_response(false, result.output)
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs, do: Tool.specs()

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end
end
