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
         {:ok, decoded} <- Jason.decode(body) do
      {:ok, decoded}
    end
  end

  @spec node_by_issue_id(map(), String.t()) :: map() | nil
  def node_by_issue_id(registry, issue_id) when is_map(registry) and is_binary(issue_id) do
    registry["nodes"]
    |> Map.values()
    |> Enum.find(fn node -> node["issue_id"] == issue_id end)
  end

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
end
