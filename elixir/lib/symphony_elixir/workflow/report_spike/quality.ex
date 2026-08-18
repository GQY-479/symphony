defmodule SymphonyElixir.Workflow.ReportSpike.Quality do
  @moduledoc """
  Runs rule-based readability floor checks for report spike artifacts.
  """

  alias SymphonyElixir.Workflow.ReportSpike.Context

  @spec check(map(), map(), %{html: String.t(), summary: String.t()}) :: {:ok, map()} | {:error, map()}
  def check(%{"work_items" => work_items}, brief, %{html: html, summary: summary})
      when is_list(work_items) and is_map(brief) and is_binary(html) and is_binary(summary) do
    checks = %{
      "has_first_screen_summary" => String.contains?(html, ~s(id="top-summary")),
      "has_exception_section" => exception_section_ok?(work_items, html),
      "has_evidence_index" => String.contains?(html, ~s(id="evidence")),
      "has_next_actions" => has_next_actions?(brief, html),
      "raw_logs_are_collapsed" => raw_materials_collapsed?(html),
      "linear_summary_is_short" => String.length(summary) < 2_000,
      "has_no_external_resources" => no_external_resources?(html)
    }

    failed =
      checks
      |> Enum.reject(fn {_name, passed?} -> passed? end)
      |> Enum.map(fn {name, _passed?} -> name end)

    quality = %{
      "status" => if(failed == [], do: "pass", else: "draft"),
      "score" => score(checks),
      "checks" => checks,
      "failed_checks" => failed
    }

    if failed == [], do: {:ok, quality}, else: {:error, quality}
  end

  def check(_context, _brief, _rendered) do
    {:error,
     %{
       "status" => "draft",
       "score" => 0.0,
       "checks" => %{},
       "failed_checks" => ["invalid_quality_input"]
     }}
  end

  defp exception_section_ok?(work_items, html) do
    if Enum.any?(work_items, &Context.attention_item?/1) do
      String.contains?(html, ~s(id="attention"))
    else
      true
    end
  end

  defp has_next_actions?(%{"sections" => sections}, html) when is_list(sections) do
    ("后续动作" in sections and String.contains?(html, "后续")) or
      ("风险和后续" in sections and String.contains?(html, ~s(id="risks"))) or
      "后续动作" not in sections
  end

  defp has_next_actions?(_brief, _html), do: false

  defp raw_materials_collapsed?(html) do
    not String.contains?(html, "validation.log") or String.contains?(html, "<details")
  end

  defp no_external_resources?(html) do
    not String.contains?(html, "<script src=") and not String.contains?(html, "<link href=")
  end

  defp score(checks) do
    total = map_size(checks)
    passed = checks |> Map.values() |> Enum.count(& &1)
    Float.round(passed / total, 2)
  end
end
