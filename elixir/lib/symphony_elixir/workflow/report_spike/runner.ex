defmodule SymphonyElixir.Workflow.ReportSpike.Runner do
  @moduledoc """
  Generates local report spike artifacts for human review.
  """

  alias SymphonyElixir.Workflow.ReportSpike.{Brief, Context, Quality, Renderer}

  @spec run(Path.t(), Path.t()) :: {:ok, map()} | {:error, term()}
  def run(context_path, output_dir) when is_binary(context_path) and is_binary(output_dir) do
    with {:ok, context} <- Context.load(context_path),
         {:ok, brief} <- Brief.build(context),
         {:ok, rendered} <- Renderer.render(context, brief) do
      quality_result = Quality.check(context, brief, rendered)
      quality = quality_payload(quality_result)
      manifest = manifest(context, quality)

      File.mkdir_p!(output_dir)
      write_json!(Path.join(output_dir, "report_context.json"), context)
      write_json!(Path.join(output_dir, "report_brief.json"), brief)
      File.write!(Path.join(output_dir, "index.html"), rendered.html)
      File.write!(Path.join(output_dir, "summary.md"), rendered.summary)
      write_json!(Path.join(output_dir, "manifest.json"), manifest)
      File.write!(Path.join(output_dir, "review.md"), review_template(context))

      {:ok, manifest}
    end
  end

  defp quality_payload({:ok, quality}), do: quality
  defp quality_payload({:error, quality}), do: quality

  defp manifest(%{"subject" => subject}, quality) do
    %{
      "schema_version" => 1,
      "report_id" => subject["id"],
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "generator" => "report-readability-spike",
      "html_path" => "index.html",
      "markdown_path" => "summary.md",
      "brief_path" => "report_brief.json",
      "review_path" => "review.md",
      "quality" => quality
    }
  end

  defp write_json!(path, value) do
    File.write!(path, Jason.encode_to_iodata!(value, pretty: true))
  end

  defp review_template(%{"subject" => subject}) do
    """
    # 汇报可读性审阅

    样例：#{subject["id"]}
    审阅人：<name>
    结论：pass / fail

    ## 快速判断
    - 1 到 3 分钟内能否判断整体状态：是 / 否
    - 是否清楚知道需要关注什么：是 / 否
    - 是否清楚知道证据在哪里：是 / 否
    - 是否愿意把它作为默认汇报入口：是 / 否

    ## 评分
    - 首屏判断价值：1-5
    - 结论清晰度：1-5
    - 异常呈现：1-5
    - 证据可追踪性：1-5
    - 信息密度：1-5
    - 视觉和排版：1-5

    ## 必须修改
    - 无阻断项时填写“无”；否则逐条列出必须修改的问题。

    ## 可以后续优化
    - 无建议时填写“无”；否则逐条列出非阻断优化建议。
    """
  end
end
