defmodule SymphonyElixir.Agent.Omnigent.Sse do
  @moduledoc false

  defstruct buffer: ""

  @type t :: %__MODULE__{buffer: binary()}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec feed(t(), binary()) :: {list(map()), t()}
  def feed(%__MODULE__{buffer: buffer} = state, chunk) when is_binary(chunk) do
    buffer = buffer <> chunk
    buffer = String.replace(buffer, "\r\n", "\n")
    {events, buffer} = collect_events(buffer, [])
    {Enum.reverse(events), %{state | buffer: buffer}}
  end

  defp collect_events(buffer, acc) do
    case :binary.match(buffer, "\n\n") do
      {index, 2} ->
        frame = binary_part(buffer, 0, index)
        rest = binary_part(buffer, index + 2, byte_size(buffer) - index - 2)
        acc = parse_frame(frame) ++ acc
        collect_events(rest, acc)

      :nomatch ->
        {acc, buffer}
    end
  end

  defp parse_frame(frame) do
    {event, data_lines} =
      frame
      |> String.split("\n")
      |> Enum.reduce({nil, []}, fn line, {event, data_lines} ->
        cond do
          line == "" ->
            {event, data_lines}

          String.starts_with?(line, ":") ->
            {event, data_lines}

          String.starts_with?(line, "event:") ->
            {parse_value(line, "event:"), data_lines}

          String.starts_with?(line, "data:") ->
            {event, [parse_value(line, "data:") | data_lines]}

          true ->
            {event, data_lines}
        end
      end)

    data =
      data_lines
      |> Enum.reverse()
      |> Enum.join("\n")

    case {event, data} do
      {nil, ""} ->
        []

      {event, data} ->
        [%{event: event, data: decode_data(data)}]
    end
  end

  defp parse_value(line, prefix) do
    line
    |> String.replace_prefix(prefix, "")
    |> String.trim_leading(" ")
    |> String.trim_trailing("\r")
  end

  defp decode_data("[DONE]"), do: "[DONE]"

  defp decode_data(data) do
    case Jason.decode(data) do
      {:ok, decoded} ->
        decoded

      {:error, _reason} ->
        %{"raw" => data, "malformed" => true}
    end
  end
end
