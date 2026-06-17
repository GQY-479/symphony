defmodule SymphonyElixir.Workflow.Registry do
  @moduledoc """
  以文件持久化的工作流注册表，存放在 `workspace.root/.symphony/workflows`。
  """

  alias SymphonyElixir.{Config, Linear.Issue}

  @spec new_root(Issue.t()) :: map()
  def new_root(%Issue{} = issue) do
    %{
      "root_issue_id" => issue.id,
      "root_issue_identifier" => issue.identifier,
      "root_title" => issue.title,
      "status" => issue.state,
      "nodes" => %{},
      "edges" => [],
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @spec put_node(map(), String.t(), map()) :: map()
  def put_node(registry, node_key, node) when is_map(registry) and is_binary(node_key) and is_map(node) do
    Map.update(registry, "nodes", %{node_key => node}, &Map.put(&1 || %{}, node_key, node))
  end

  @spec node(map(), String.t()) :: map() | nil
  def node(registry, node_key) when is_map(registry) and is_binary(node_key) do
    registry_nodes(registry)[node_key]
  end

  @spec add_edge(map(), term()) :: map()
  def add_edge(registry, edge) when is_map(registry) do
    normalized_edge = normalize_edge(edge)
    Map.update(registry, "edges", [normalized_edge], &(&1 ++ [normalized_edge]))
  end

  @spec save!(map()) :: {:ok, Path.t()}
  def save!(registry) when is_map(registry) do
    path = registry_path(root_identifier(registry))
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode_to_iodata!(registry, pretty: true))
    {:ok, path}
  end

  @spec load_by_root_identifier(String.t()) :: {:ok, map()} | {:error, term()}
  def load_by_root_identifier(root_identifier) when is_binary(root_identifier) do
    path = registry_path(root_identifier)

    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body) do
      {:ok, decoded}
    else
      {:error, reason} -> {:error, {:invalid_registry_json, path, reason}}
    end
  end

  @spec node_by_issue_id(map(), String.t()) :: map() | nil
  def node_by_issue_id(registry, issue_id) when is_map(registry) and is_binary(issue_id) do
    registry_nodes(registry)
    |> Map.values()
    |> Enum.find(fn node -> node_issue_id(node) == issue_id end)
  end

  @spec registry_path(String.t()) :: Path.t()
  def registry_path(root_identifier) when is_binary(root_identifier) do
    Path.join([Config.settings!().workspace.root, ".symphony", "workflows", "#{root_identifier}.json"])
  end

  defp registry_nodes(registry) do
    Map.get(registry, "nodes") || Map.get(registry, :nodes) || %{}
  end

  defp node_issue_id(node) when is_map(node) do
    Map.get(node, "issue_id") || Map.get(node, :issue_id)
  end

  defp node_issue_id(_node), do: nil

  defp root_identifier(registry) do
    Map.get(registry, "root_issue_identifier") || Map.get(registry, :root_issue_identifier) || Map.get(registry, "root_issue_id")
  end

  defp normalize_edge({from_node, to_node}) do
    %{"from" => from_node, "to" => to_node}
  end

  defp normalize_edge(%{} = edge), do: edge
  defp normalize_edge(edge), do: edge
end
