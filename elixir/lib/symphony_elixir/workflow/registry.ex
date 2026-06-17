defmodule SymphonyElixir.Workflow.Registry do
  @moduledoc """
  存放在 `workspace.root/.symphony/workflows/` 下的文件型工作流注册表。
  """

  alias SymphonyElixir.{Config, Linear.Issue}

  @spec new_root(Issue.t()) :: map()
  def new_root(%Issue{} = issue) do
    %{
      "root_issue_id" => issue.id,
      "root_issue_identifier" => issue.identifier,
      "root_title" => issue.title,
      "status" => "planning",
      "nodes" => %{},
      "edges" => [],
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @spec put_node(map(), String.t(), map()) :: map()
  def put_node(registry, node_key, node) when is_map(registry) and is_binary(node_key) and is_map(node) do
    put_in(registry, ["nodes", node_key], normalize_node(node))
  end

  @spec node(map(), String.t()) :: map() | nil
  def node(registry, node_key) when is_map(registry) and is_binary(node_key) do
    get_in(registry, ["nodes", node_key])
  end

  @spec add_edge(map(), map() | {String.t(), String.t()}) :: map()
  def add_edge(registry, edge) when is_map(registry) do
    update_in(registry, ["edges"], fn edges -> (edges || []) ++ [normalize_edge(edge)] end)
  end

  @spec save!(map()) :: :ok
  def save!(registry) when is_map(registry) do
    path = registry_path(registry["root_issue_identifier"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode_to_iodata!(registry, pretty: true))
    :ok
  end

  @spec load_by_root_identifier(String.t()) :: {:ok, map()} | {:error, term()}
  def load_by_root_identifier(root_identifier) when is_binary(root_identifier) do
    path = registry_path(root_identifier)

    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         true <- valid_registry?(decoded) do
      {:ok, decoded}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, {:invalid_registry_structure, path}}
    end
  end

  @spec node_by_issue_id(map(), String.t()) :: map() | nil
  def node_by_issue_id(registry, issue_id) when is_map(registry) and is_binary(issue_id) do
    case registry_nodes(registry) do
      nodes when is_map(nodes) ->
        nodes
        |> Map.values()
        |> Enum.find(fn node -> node_issue_id(node) == issue_id end)

      _ ->
        nil
    end
  end

  def node_by_issue_id(_registry, _issue_id), do: nil

  @spec registry_path(String.t()) :: Path.t()
  def registry_path(root_identifier) when is_binary(root_identifier) do
    Path.join([Config.settings!().workspace.root, ".symphony", "workflows", "#{root_identifier}.json"])
  end

  defp normalize_node(node) do
    Enum.into(node, %{}, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end

  defp normalize_edge({from_node, to_node}) do
    %{"from" => from_node, "to" => to_node}
  end

  defp normalize_edge(%{} = edge) do
    Enum.into(edge, %{}, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end

  defp registry_nodes(registry) do
    Map.get(registry, "nodes") || Map.get(registry, :nodes)
  end

  defp node_issue_id(node) when is_map(node) do
    Map.get(node, "issue_id") || Map.get(node, :issue_id)
  end

  defp node_issue_id(_node), do: nil

  defp valid_registry?(%{"nodes" => nodes, "edges" => edges, "status" => status})
       when is_map(nodes) and is_list(edges) and is_binary(status),
       do: true

  defp valid_registry?(%{nodes: nodes, edges: edges, status: status})
       when is_map(nodes) and is_list(edges) and is_binary(status),
       do: true

  defp valid_registry?(_registry), do: false
end
