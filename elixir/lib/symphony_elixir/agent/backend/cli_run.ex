defmodule SymphonyElixir.Agent.Backend.CliRun do
  @moduledoc """
  Agent backend that runs a configured command once per turn.
  """

  @behaviour SymphonyElixir.Agent.Backend

  @default_timeout_ms 3_600_000
  @default_max_output_bytes 200_000

  @impl true
  def run_issue(workspace, _issue, prompt, resolved_agent, opts) do
    config = agent_config(resolved_agent)

    with {:ok, executable} <- resolve_command(Map.get(config, "command")),
         {:ok, argv} <- build_argv(config, workspace, prompt) do
      do_run(executable, argv, workspace, resolved_agent, config, opts)
    end
  end

  defp do_run(executable, argv, workspace, resolved_agent, config, opts) do
    timeout_ms = Map.get(config, "timeout_ms", @default_timeout_ms)
    max_output_bytes = Map.get(config, "max_output_bytes", @default_max_output_bytes)
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    case start_port(executable, argv, workspace) do
      {:ok, port} ->
        session_id = session_id(resolved_agent, port)
        deadline = System.monotonic_time(:millisecond) + timeout_ms

        case receive_loop(port, deadline, "", "", max_output_bytes, on_message, resolved_agent) do
          {:ok, output, 0} ->
            emit_message(on_message, resolved_agent, :turn_completed, %{
              payload: %{session_id: session_id, exit_status: 0},
              session_id: session_id,
              exit_status: 0
            })

            {:ok, %{session_id: session_id, output: output, exit_status: 0}}

          {:ok, output, status} ->
            {:error, {:cli_exit, status, output}}

          {:error, :cli_timeout} ->
            close_port(port)
            {:error, :cli_timeout}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_port(executable, argv, workspace) do
    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: Enum.map(argv, &String.to_charlist/1),
          cd: String.to_charlist(workspace)
        ]
      )

    {:ok, port}
  rescue
    error in [ArgumentError, ErlangError] ->
      {:error, {:cli_start_failed, executable, Exception.message(error)}}
  end

  defp receive_loop(port, deadline, pending_line, output, max_output_bytes, on_message, resolved_agent) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} ->
        {next_pending_line, next_output} =
          collect_output_chunk(
            to_string(chunk),
            pending_line,
            output,
            max_output_bytes,
            on_message,
            resolved_agent
          )

        receive_loop(
          port,
          deadline,
          next_pending_line,
          next_output,
          max_output_bytes,
          on_message,
          resolved_agent
        )

      {^port, {:exit_status, status}} ->
        output =
          if pending_line == "" do
            output
          else
            emit_output_line(on_message, resolved_agent, pending_line)
            append_output(output, pending_line, max_output_bytes)
          end

        {:ok, output, status}
    after
      timeout ->
        {:error, :cli_timeout}
    end
  end

  defp resolve_command(command) when is_binary(command) do
    command = String.trim(command)

    cond do
      command == "" ->
        {:error, :cli_command_missing}

      Path.type(command) == :absolute ->
        validate_absolute_command(command)

      executable = System.find_executable(command) ->
        {:ok, executable}

      true ->
        {:error, {:cli_command_not_found, command}}
    end
  end

  defp resolve_command(command), do: {:error, {:invalid_cli_command, command}}

  defp collect_output_chunk(chunk, pending_line, output, max_output_bytes, on_message, resolved_agent) do
    text = pending_line <> chunk
    parts = String.split(text, "\n")
    {complete_lines, [next_pending_line]} = Enum.split(parts, -1)

    next_output =
      Enum.reduce(complete_lines, output, fn line, output_acc ->
        emit_output_line(on_message, resolved_agent, line)
        append_output(output_acc, line <> "\n", max_output_bytes)
      end)

    {append_output("", next_pending_line, max_output_bytes), next_output}
  end

  defp validate_absolute_command(command) do
    cond do
      not File.exists?(command) ->
        {:error, {:cli_command_not_found, command}}

      not File.regular?(command) ->
        {:error, {:cli_command_not_executable, command}}

      true ->
        {:ok, command}
    end
  end

  defp build_argv(config, workspace, prompt) do
    args = Map.get(config, "args", [])

    if is_list(args) do
      argv =
        args
        |> Enum.map(&to_string/1)
        |> Enum.map(&String.replace(&1, "{{workspace}}", workspace))
        |> Kernel.++([prompt])

      {:ok, argv}
    else
      {:error, {:invalid_cli_args, args}}
    end
  end

  defp emit_output_line(on_message, resolved_agent, line) do
    payload =
      case Jason.decode(line) do
        {:ok, decoded} -> decoded
        {:error, _reason} -> %{text: line}
      end

    emit_message(on_message, resolved_agent, :cli_output, %{payload: payload})
  end

  defp emit_message(on_message, resolved_agent, event, fields) when is_function(on_message, 1) do
    message =
      fields
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())
      |> Map.put(:agent_id, agent_id(resolved_agent))
      |> Map.put(:agent_kind, agent_kind(resolved_agent))

    on_message.(message)
  end

  defp append_output(output, chunk, max_output_bytes) do
    remaining = max_output_bytes - byte_size(output)

    cond do
      remaining <= 0 -> output
      byte_size(chunk) <= remaining -> output <> chunk
      true -> output <> binary_part(chunk, 0, remaining)
    end
  end

  defp session_id(resolved_agent, port) do
    pid =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} -> os_pid
        _ -> System.unique_integer([:positive])
      end

    "#{agent_id(resolved_agent)}-#{pid}"
  end

  defp close_port(port) when is_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp agent_id(resolved_agent), do: Map.get(resolved_agent, :id) || Map.get(resolved_agent, "id")
  defp agent_kind(resolved_agent), do: Map.get(resolved_agent, :kind) || Map.get(resolved_agent, "kind")
  defp agent_config(resolved_agent), do: Map.get(resolved_agent, :config) || Map.get(resolved_agent, "config") || %{}
  defp default_on_message(_message), do: :ok
end
