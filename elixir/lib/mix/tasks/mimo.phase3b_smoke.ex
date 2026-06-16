defmodule Mix.Tasks.Mimo.Phase3bSmoke do
  use Mix.Task

  @shortdoc "Print a MiMo phase 3B Linear smoke issue template"

  @moduledoc """
  生成 MiMo-Code 阶段 3B 真实 Linear smoke 的 issue 模板。

  该任务只输出可复制到 Linear 的标题、标签和描述，不读取或写入 Linear API。

  Usage:

      mix mimo.phase3b_smoke
      mix mimo.phase3b_smoke --timestamp 20260614-202500
  """

  @switches [timestamp: :string, help: :boolean]
  @aliases [h: :help]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      true ->
        timestamp = opts[:timestamp] || default_timestamp()
        Mix.shell().info(template(timestamp))
    end

    :ok
  end

  defp default_timestamp do
    now = DateTime.utc_now()

    [
      pad(now.year, 4),
      pad(now.month, 2),
      pad(now.day, 2),
      "-",
      pad(now.hour, 2),
      pad(now.minute, 2),
      pad(now.second, 2)
    ]
    |> IO.iodata_to_binary()
  end

  defp pad(value, width) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.pad_leading(width, "0")
  end

  defp template(timestamp) do
    target_file = "mimo-phase-3b-smoke-#{timestamp}.txt"
    exact_content = "MiMo phase 3B smoke passed #{timestamp}"

    """
    Title: MiMo phase 3B guidance smoke #{timestamp}
    Labels: agent:mimo, symphony-local-test

    Description:
    MiMo phase 3B guidance smoke.

    目标文件名：#{target_file}
    精确文件内容：#{exact_content}

    要求：
    1. 在 workspace 根目录创建或覆盖“目标文件名”指定的文件。
    2. 写入“精确文件内容”指定的完整内容，不要添加额外内容。
    3. 读回该目标文件，确认内容完全一致。
    4. 使用 `linear_issue_read` 读取当前 issue。
    5. 使用 `linear_comment_create` 评论 `file_verified=true`、`phase_3b_guidance=true` 和 issue identifier。
    6. 最后才使用 `linear_issue_update_state` 移动到 `Done`。
    7. 如果目标文件名或精确文件内容缺失/含糊，评论 blocked，不要移动到 `Done`。
    8. 不要使用已有 `docs/` 文件替代目标文件；不要使用 `linear_graphql`，除非高层工具无法覆盖。
    """
  end
end
