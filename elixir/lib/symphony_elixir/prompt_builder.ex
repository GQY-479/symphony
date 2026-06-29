defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  根据 Linear 工单数据和工作流阶段构建代理提示词。
  """

  alias SymphonyElixir.{Config, Workflow}
  alias SymphonyElixir.Workflow.Prompts

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    workflow_phase = Keyword.get(opts, :workflow_phase)
    workflow_context = Keyword.get(opts, :workflow_context)
    workspace = Keyword.get(opts, :workspace)

    template =
      Workflow.current()
      |> prompt_template!()
      |> parse_template!()

    template
    |> Solid.render!(
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "issue" => issue |> Map.from_struct() |> to_solid_map()
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
    |> ensure_valid_utf8()
    |> append_issue_snapshot(issue)
    |> Prompts.append(workflow_phase, workflow_context, workspace)
  end

  defp ensure_valid_utf8(binary) when is_binary(binary) do
    if String.valid?(binary) do
      binary
    else
      replace_invalid_utf8(binary, "")
    end
  end

  defp replace_invalid_utf8("", acc), do: acc

  defp replace_invalid_utf8(binary, acc) do
    case :unicode.characters_to_binary(binary, :utf8, :utf8) do
      converted when is_binary(converted) ->
        acc <> converted

      {:error, valid_prefix, <<_invalid, rest::binary>>} ->
        replace_invalid_utf8(rest, acc <> valid_prefix <> "�")

      {:incomplete, valid_prefix, _rest} ->
        acc <> valid_prefix <> "�"
    end
  end

  defp append_issue_snapshot(prompt, %{snapshot: snapshot}) when is_map(snapshot) and map_size(snapshot) > 0 do
    snapshot_json =
      snapshot
      |> to_solid_value()
      |> Jason.encode!(pretty: true)

    prompt <>
      """

      Linear issue snapshot:
      ```json
      #{snapshot_json}
      ```
      """
  end

  defp append_issue_snapshot(prompt, _issue), do: prompt

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end
