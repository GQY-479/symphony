defmodule Mix.Tasks.Symphony.ReportSpike.Generate do
  @moduledoc """
  Generates a local engineering HTML report readability spike sample.
  """

  use Mix.Task

  alias SymphonyElixir.Workflow.ReportSpike.Runner

  @shortdoc "Generate a local report readability spike sample"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, invalid} =
      OptionParser.parse(args,
        strict: [context: :string, out: :string],
        aliases: [c: :context, o: :out]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    context_path = Keyword.get(opts, :context) || Mix.raise("Missing --context")
    output_dir = Keyword.get(opts, :out) || default_output_dir(context_path)

    case Runner.run(context_path, output_dir) do
      {:ok, manifest} ->
        Mix.shell().info("Generated report spike: #{Path.expand(output_dir)}")
        Mix.shell().info("Quality status: #{manifest["quality"]["status"]}")

      {:error, reason} ->
        Mix.raise("Failed to generate report spike: #{inspect(reason)}")
    end
  end

  defp default_output_dir(context_path) do
    sample_id =
      context_path
      |> Path.basename(".json")
      |> String.replace("_context", "")
      |> String.replace("_", "-")

    Path.join(["..", ".symphony", "report-spikes", sample_id])
  end
end
