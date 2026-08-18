defmodule SymphonyElixir.Workflow.ReportSpike.Renderer do
  @moduledoc """
  Renders report spike contexts and briefs to self-contained HTML and short Markdown.
  """

  alias SymphonyElixir.Workflow.ReportSpike.Context

  @spec render(map(), map()) :: {:ok, %{html: String.t(), summary: String.t()}} | {:error, term()}
  def render(%{"subject" => subject, "work_items" => work_items} = context, brief)
      when is_list(work_items) and is_map(brief) do
    attention_items = Enum.filter(work_items, &Context.attention_item?/1)

    html =
      [
        "<!doctype html>",
        ~s(<html lang="zh-CN">),
        "<head>",
        ~s(<meta charset="utf-8">),
        ~s(<meta name="viewport" content="width=device-width, initial-scale=1">),
        "<title>#{h(subject["id"])} #{h(subject["title"])}</title>",
        "<style>",
        css(),
        "</style>",
        "</head>",
        "<body>",
        header(context, brief, attention_items),
        attention_section(attention_items),
        work_item_section(work_items),
        verification_section(context),
        risk_section(context),
        evidence_section(work_items),
        raw_artifacts_section(context),
        "</body>",
        "</html>"
      ]
      |> Enum.join("\n")

    {:ok, %{html: html, summary: markdown_summary(context, attention_items)}}
  end

  def render(_context, _brief), do: {:error, :invalid_report_input}

  defp header(%{"subject" => subject, "work_items" => work_items}, brief, attention_items) do
    status = if attention_items == [], do: "可继续", else: "需要关注"

    """
    <main>
      <section id="top-summary" class="hero">
        <p class="eyebrow">#{h(brief["report_kind"])} · #{h(status)}</p>
        <h1>#{h(subject["id"])} #{h(subject["title"])}</h1>
        <p class="reader-goal">#{h(brief["reader_goal"])}</p>
        <div class="stats">
          <div><strong>#{length(work_items)}</strong><span>Work items</span></div>
          <div><strong>#{completed_count(work_items)}</strong><span>Completed</span></div>
          <div><strong>#{length(attention_items)}</strong><span>Need attention</span></div>
        </div>
        <ul class="top-questions">
          #{brief["top_questions"] |> Enum.map(&"<li>#{h(&1)}</li>") |> Enum.join("\n")}
        </ul>
      </section>
    """
  end

  defp attention_section([]) do
    """
      <section id="attention" class="section ok">
        <h2>需要关注</h2>
        <p>当前样例没有阻断、返工或失败项。请继续查看验证和证据索引。</p>
      </section>
    """
  end

  defp attention_section(items) do
    rows =
      items
      |> Enum.map(fn item ->
        """
        <article class="attention-card">
          <h3>#{h(item["id"])} #{h(item["title"])}</h3>
          <p><strong>状态：</strong>#{h(item["status"])} / #{h(item["outcome"])}</p>
          <p>#{h(item["summary"])}</p>
          <p><strong>证据数量：</strong>#{length(item["evidence"] || [])}</p>
        </article>
        """
      end)
      |> Enum.join("\n")

    """
      <section id="attention" class="section attention">
        <h2>需要关注</h2>
        #{rows}
      </section>
    """
  end

  defp work_item_section(work_items) do
    rows =
      work_items
      |> Enum.map(fn item ->
        """
        <tr>
          <td>#{h(item["id"])}</td>
          <td>#{h(item["title"])}</td>
          <td><span class="pill">#{h(item["status"])}</span></td>
          <td><span class="pill">#{h(item["outcome"])}</span></td>
          <td>#{h(item["summary"])}</td>
        </tr>
        """
      end)
      |> Enum.join("\n")

    """
      <section id="work-items" class="section">
        <h2>Issue 结果矩阵</h2>
        <div class="table-wrap">
          <table>
            <thead><tr><th>ID</th><th>标题</th><th>状态</th><th>结果</th><th>摘要</th></tr></thead>
            <tbody>#{rows}</tbody>
          </table>
        </div>
      </section>
    """
  end

  defp verification_section(%{"verification" => %{"commands" => commands}}) when is_list(commands) do
    items =
      commands
      |> Enum.map(fn command ->
        "<li><code>#{h(command["command"])}</code> · #{h(command["status"])} · #{h(command["summary"])}</li>"
      end)
      |> Enum.join("\n")

    """
      <section id="verification" class="section">
        <h2>验证结果</h2>
        <ul>#{items}</ul>
      </section>
    """
  end

  defp verification_section(_context) do
    """
      <section id="verification" class="section warning">
        <h2>验证结果</h2>
        <p>未提供验证命令。该报告不能作为完成证明。</p>
      </section>
    """
  end

  defp risk_section(%{"risks" => risks, "open_questions" => questions}) do
    risk_items = Enum.map(risks || [], &"<li>#{h(&1)}</li>") |> Enum.join("\n")
    question_items = Enum.map(questions || [], &"<li>#{h(&1)}</li>") |> Enum.join("\n")

    """
      <section id="risks" class="section">
        <h2>风险、后续动作和未决问题</h2>
        <h3>风险</h3>
        <ul>#{empty_message(risk_items, "无已知风险")}</ul>
        <h3>未决问题</h3>
        <ul>#{empty_message(question_items, "无未决问题")}</ul>
      </section>
    """
  end

  defp risk_section(_context), do: ""

  defp evidence_section(work_items) do
    items =
      work_items
      |> Enum.flat_map(fn item ->
        Enum.map(item["evidence"] || [], fn evidence ->
          href = evidence["href"] || "#"
          ~s(<li><a href="#{h(href)}">#{h(item["id"])} · #{h(evidence["label"])}</a></li>)
        end)
      end)
      |> Enum.join("\n")

    """
      <section id="evidence" class="section">
        <h2>证据索引</h2>
        <ul>#{empty_message(items, "没有可用证据")}</ul>
      </section>
    """
  end

  defp raw_artifacts_section(%{"raw_artifacts" => artifacts}) when is_list(artifacts) do
    details =
      artifacts
      |> Enum.map(fn artifact ->
        """
        <details class="raw-artifact">
          <summary>#{h(artifact["label"])} · #{h(artifact["kind"])}</summary>
          <p>路径：<code>#{h(artifact["path"])}</code></p>
        </details>
        """
      end)
      |> Enum.join("\n")

    """
      <section id="raw-artifacts" class="section">
        <h2>原始材料</h2>
        #{details}
      </section>
    </main>
    """
  end

  defp raw_artifacts_section(_context), do: "</main>"

  defp markdown_summary(%{"subject" => subject, "work_items" => work_items} = context, attention_items) do
    lines = [
      "# Workflow 汇报：#{subject["id"]} #{subject["title"]}",
      "",
      "状态：#{if attention_items == [], do: "可继续", else: "需要关注"}",
      "Work items：#{length(work_items)}",
      "需要关注：#{length(attention_items)}",
      "",
      "## 结论",
      "- #{context["task"]["original_request"]}",
      "",
      "## 需要关注",
      attention_markdown(attention_items),
      "",
      "## 证据",
      "- 完整 HTML 报告见 index.html。"
    ]

    Enum.join(lines, "\n")
  end

  defp attention_markdown([]), do: "- 当前没有阻断、返工或失败项。"

  defp attention_markdown(items) do
    items
    |> Enum.map(&"- #{&1["id"]} #{&1["title"]}: #{&1["outcome"]}")
    |> Enum.join("\n")
  end

  defp completed_count(work_items) do
    Enum.count(work_items, &(&1["status"] == "completed" and &1["outcome"] == "completed"))
  end

  defp empty_message("", message), do: "<li>#{h(message)}</li>"
  defp empty_message(items, _message), do: items

  defp css do
    """
    :root { color-scheme: light; font-family: Arial, sans-serif; }
    body { margin: 0; background: #f6f7f9; color: #17202a; }
    main { max-width: 1120px; margin: 0 auto; padding: 32px 20px 56px; }
    .hero, .section { background: #fff; border: 1px solid #d8dee6; border-radius: 8px; padding: 24px; margin-bottom: 18px; }
    .eyebrow { color: #52616f; font-weight: 700; text-transform: uppercase; font-size: 12px; letter-spacing: .04em; }
    h1 { font-size: 30px; line-height: 1.2; margin: 8px 0 12px; }
    h2 { font-size: 20px; margin: 0 0 16px; }
    h3 { font-size: 16px; margin: 14px 0 8px; }
    .reader-goal { font-size: 16px; max-width: 820px; }
    .stats { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 12px; margin: 18px 0; }
    .stats div { border: 1px solid #e1e6ee; border-radius: 8px; padding: 14px; background: #fbfcfe; }
    .stats strong { display: block; font-size: 28px; }
    .stats span { color: #52616f; }
    .top-questions { display: flex; flex-wrap: wrap; gap: 8px; padding: 0; list-style: none; }
    .top-questions li, .pill { border: 1px solid #cad3df; border-radius: 999px; padding: 5px 9px; background: #f8fafc; }
    .attention { border-color: #e4a11b; background: #fffaf0; }
    .warning { border-color: #e4a11b; }
    .ok { border-color: #61a36f; }
    .attention-card { border-top: 1px solid #e7c77d; padding-top: 12px; margin-top: 12px; }
    .table-wrap { overflow-x: auto; }
    table { width: 100%; border-collapse: collapse; min-width: 760px; }
    th, td { border-bottom: 1px solid #e1e6ee; padding: 10px; text-align: left; vertical-align: top; }
    code { background: #eef2f6; border-radius: 4px; padding: 2px 5px; }
    a { color: #155c9c; }
    details { border: 1px solid #d8dee6; border-radius: 8px; padding: 10px 12px; margin: 8px 0; background: #fbfcfe; }
    @media (max-width: 720px) { .stats { grid-template-columns: 1fr; } h1 { font-size: 24px; } }
    """
  end

  defp h(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
