defmodule SymphonyElixir.Workflow.Registry do
  @moduledoc """
  存放在 `workspace.root/.symphony/workflows/` 下的文件型工作流注册表。
  """

  alias SymphonyElixir.{Config, Linear.Issue, PathSafety}

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

  @spec put_status(map(), String.t(), map()) :: map()
  def put_status(registry, status, attrs)
      when is_map(registry) and is_binary(status) and is_map(attrs) do
    registry
    |> Map.merge(normalize_map(attrs))
    |> Map.put("status", status)
    |> Map.put("updated_at", DateTime.utc_now() |> DateTime.to_iso8601())
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
    dir = Path.dirname(path)

    temp_path =
      Path.join(
        dir,
        "#{Path.basename(path)}.#{System.os_time(:nanosecond)}.#{System.unique_integer([:positive])}.tmp"
      )

    File.mkdir_p!(dir)

    try do
      File.write!(temp_path, Jason.encode_to_iodata!(registry, pretty: true))
      File.rename!(temp_path, path)
      :ok
    after
      if File.exists?(temp_path), do: File.rm!(temp_path)
    end
  end

  @spec load_by_root_identifier(String.t()) :: {:ok, map()} | {:error, term()}
  def load_by_root_identifier(root_identifier) when is_binary(root_identifier) do
    path = registry_path(root_identifier)

    load_registry_path(path)
  end

  @spec load_by_issue_id(String.t()) :: {:ok, map(), String.t(), map()} | {:error, term()}
  def load_by_issue_id(issue_id) when is_binary(issue_id) do
    case File.ls(registry_dir()) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.reduce_while({:error, :not_found}, fn file, _acc ->
          path = Path.join(registry_dir(), file)

          case load_registry_path(path) do
            {:ok, registry} ->
              case node_entry_by_issue_id(registry, issue_id) do
                {node_key, node} -> {:halt, {:ok, registry, node_key, node}}
                nil -> {:cont, {:error, :not_found}}
              end

            {:error, _reason} ->
              {:cont, {:error, :not_found}}
          end
        end)

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec node_by_issue_id(map(), String.t()) :: map() | nil
  def node_by_issue_id(registry, issue_id) when is_map(registry) and is_binary(issue_id) do
    case node_entry_by_issue_id(registry, issue_id) do
      {_node_key, node} -> node
      nil -> nil
    end
  end

  def node_by_issue_id(_registry, _issue_id), do: nil

  @spec registry_path(String.t()) :: Path.t()
  def registry_path(root_identifier) when is_binary(root_identifier) do
    Path.join(registry_dir(), "#{root_identifier}.json")
  end

  @spec root_workspace_path(map()) :: Path.t() | nil
  def root_workspace_path(%{"root_issue_identifier" => root_issue_identifier}) when is_binary(root_issue_identifier) do
    root_issue_identifier
    |> safe_identifier()
    |> root_workspace_path_for_safe_identifier()
  end

  def root_workspace_path(_registry), do: nil

  defp root_workspace_path_for_safe_identifier(safe_identifier) do
    Config.settings!().workspace.root
    |> Path.join(safe_identifier)
    |> PathSafety.canonicalize()
    |> case do
      {:ok, path} -> path
      {:error, _reason} -> nil
    end
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp registry_dir do
    Path.join([Config.settings!().workspace.root, ".symphony", "workflows"])
  end

  defp load_registry_path(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         true <- valid_registry?(decoded) do
      {:ok, decoded}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, {:invalid_registry_structure, path}}
    end
  end

  defp node_entry_by_issue_id(registry, issue_id) do
    case registry_nodes(registry) do
      nodes when is_map(nodes) ->
        Enum.find(nodes, fn {_node_key, node} -> node_issue_id(node) == issue_id end)

      _ ->
        nil
    end
  end

  defp normalize_node(node) do
    normalize_map(node)
  end

  defp normalize_map(map) do
    Enum.into(map, %{}, fn
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
