defmodule SymphonyElixir.Workflow.ReportSpike.Context do
  @moduledoc """
  Loads and validates fact packages for the engineering HTML report spike.
  """

  @attention_outcomes MapSet.new(["failed", "fail", "blocked", "needs_rework", "needs_human"])

  @spec load(Path.t()) :: {:ok, map()} | {:error, term()}
  def load(path) when is_binary(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         :ok <- validate(decoded) do
      {:ok, decoded}
    end
  end

  @spec validate(term()) :: :ok | {:error, :invalid_report_context}
  def validate(%{
        "schema_version" => 1,
        "subject" => subject,
        "task" => task,
        "work_items" => work_items
      })
      when is_map(subject) and is_map(task) and is_list(work_items) do
    cond do
      not valid_subject?(subject) ->
        {:error, :invalid_report_context}

      not valid_task?(task) ->
        {:error, :invalid_report_context}

      work_items == [] ->
        {:error, :invalid_report_context}

      not Enum.all?(work_items, &valid_work_item?/1) ->
        {:error, :invalid_report_context}

      true ->
        :ok
    end
  end

  def validate(_context), do: {:error, :invalid_report_context}

  @spec attention_item?(map()) :: boolean()
  def attention_item?(%{"outcome" => outcome}) when is_binary(outcome) do
    MapSet.member?(@attention_outcomes, String.downcase(outcome))
  end

  def attention_item?(%{"status" => status}) when is_binary(status) do
    MapSet.member?(@attention_outcomes, String.downcase(status))
  end

  def attention_item?(_item), do: false

  defp valid_subject?(%{"kind" => kind, "id" => id, "title" => title}) do
    non_blank?(kind) and non_blank?(id) and non_blank?(title)
  end

  defp valid_subject?(_subject), do: false

  defp valid_task?(%{"original_request" => request, "task_type_hint" => hint}) do
    non_blank?(request) and non_blank?(hint)
  end

  defp valid_task?(_task), do: false

  defp valid_work_item?(
         %{
           "id" => id,
           "title" => title,
           "status" => status,
           "outcome" => outcome,
           "summary" => summary,
           "evidence" => evidence
         } = item
       )
       when is_list(evidence) do
    non_blank?(id) and non_blank?(title) and non_blank?(status) and non_blank?(outcome) and
      non_blank?(summary) and (evidence != [] or attention_item?(item))
  end

  defp valid_work_item?(_item), do: false

  defp non_blank?(value) when is_binary(value), do: String.trim(value) != ""
  defp non_blank?(_value), do: false
end
