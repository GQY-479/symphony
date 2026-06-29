defmodule SymphonyElixir.Workflow do
  @moduledoc """
  Loads workflow configuration and prompt from WORKFLOW.md.
  """

  alias SymphonyElixir.WorkflowStore

  @workflow_file_name "WORKFLOW.md"

  @spec workflow_file_path() :: Path.t()
  def workflow_file_path do
    Application.get_env(:symphony_elixir, :workflow_file_path) ||
      Path.join(File.cwd!(), @workflow_file_name)
  end

  @spec set_workflow_file_path(Path.t()) :: :ok
  def set_workflow_file_path(path) when is_binary(path) do
    Application.put_env(:symphony_elixir, :workflow_file_path, path)
    maybe_reload_store()
    :ok
  end

  @spec clear_workflow_file_path() :: :ok
  def clear_workflow_file_path do
    Application.delete_env(:symphony_elixir, :workflow_file_path)
    maybe_reload_store()
    :ok
  end

  @type loaded_workflow :: %{
          config: map(),
          prompt: String.t(),
          prompt_template: String.t()
        }

  @spec current() :: {:ok, loaded_workflow()} | {:error, term()}
  def current do
    case Process.whereis(WorkflowStore) do
      pid when is_pid(pid) ->
        WorkflowStore.current()

      _ ->
        load()
    end
  end

  @spec load() :: {:ok, loaded_workflow()} | {:error, term()}
  def load do
    load(workflow_file_path())
  end

  @spec load(Path.t(), keyword()) :: {:ok, loaded_workflow()} | {:error, term()}
  def load(path, opts \\ []) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        with {:ok, workflow} <- parse(content),
             {:ok, workflow} <- apply_local_overlay(path, workflow, opts) do
          {:ok, workflow}
        end

      {:error, reason} ->
        {:error, {:missing_workflow_file, path, reason}}
    end
  end

  defp parse(content) do
    {front_matter_lines, prompt_lines} =
      content
      |> strip_utf8_bom()
      |> split_front_matter()

    case front_matter_yaml_to_map(front_matter_lines) do
      {:ok, front_matter} ->
        prompt = Enum.join(prompt_lines, "\n") |> String.trim()

        {:ok,
         %{
           config: front_matter,
           prompt: prompt,
           prompt_template: prompt
         }}

      {:error, :workflow_front_matter_not_a_map} ->
        {:error, :workflow_front_matter_not_a_map}

      {:error, reason} ->
        {:error, {:workflow_parse_error, reason}}
    end
  end

  defp apply_local_overlay(path, %{config: config} = workflow, opts) do
    overlay_path = local_overlay_path(path)

    cond do
      not local_overlay_enabled?(opts) ->
        {:ok, workflow}

      legacy_local_workflow?(path) ->
        {:ok, workflow}

      not File.regular?(overlay_path) ->
        {:ok, workflow}

      true ->
        case File.read(overlay_path) do
          {:ok, content} ->
            case yaml_to_map(content) do
              {:ok, overlay} ->
                {:ok, %{workflow | config: deep_merge(config, overlay)}}

              {:error, :workflow_front_matter_not_a_map} ->
                {:error, {:workflow_local_overlay_not_a_map, overlay_path}}

              {:error, reason} ->
                {:error, {:workflow_local_overlay_parse_error, overlay_path, reason}}
            end

          {:error, reason} ->
            {:error, {:workflow_local_overlay_read_error, overlay_path, reason}}
        end
    end
  end

  defp local_overlay_path(path) do
    Path.join(Path.dirname(path), "WORKFLOW.local.yml")
  end

  defp local_overlay_enabled?(opts) do
    Keyword.get_lazy(opts, :local_overlay, fn ->
      Application.get_env(:symphony_elixir, :local_workflow_overlay, true)
    end)
  end

  defp legacy_local_workflow?(path) do
    Path.basename(path) == "WORKFLOW.local.md"
  end

  defp strip_utf8_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_utf8_bom(content), do: content

  defp split_front_matter(content) do
    lines = String.split(content, ~r/\R/, trim: false)

    case lines do
      ["---" | tail] ->
        {front, rest} = Enum.split_while(tail, &(&1 != "---"))

        case rest do
          ["---" | prompt_lines] -> {front, prompt_lines}
          _ -> {front, []}
        end

      _ ->
        {[], lines}
    end
  end

  defp front_matter_yaml_to_map(lines) do
    lines
    |> Enum.join("\n")
    |> yaml_to_map()
  end

  defp yaml_to_map(yaml) do
    if String.trim(yaml) == "" do
      {:ok, %{}}
    else
      case YamlElixir.read_from_string(yaml) do
        {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
        {:ok, _} -> {:error, :workflow_front_matter_not_a_map}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: right

  defp maybe_reload_store do
    if Process.whereis(WorkflowStore) do
      _ = WorkflowStore.force_reload()
    end

    :ok
  end
end
