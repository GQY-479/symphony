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
        os_pid = port_os_pid(port)
        deadline = System.monotonic_time(:millisecond) + timeout_ms

        emit_message(on_message, resolved_agent, :session_started, %{
          payload: %{session_id: session_id, os_pid: os_pid},
          session_id: session_id,
          codex_app_server_pid: os_pid_string(os_pid)
        })

        try do
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
              terminate_port_process(port)
              {:error, :cli_timeout}
          end
        after
          close_port(port)
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

  defp terminate_port_process(port) when is_port(port) do
    os_pid = port_os_pid(port)
    pids = process_tree_pids(os_pid)

    Enum.each(pids, &signal_process(&1, "TERM"))
    close_port(port)
    Process.sleep(50)
    Enum.each(pids, &signal_process(&1, "KILL"))
  end

  defp terminate_port_process(_port), do: :ok

  defp process_tree_pids(nil), do: []

  defp process_tree_pids(os_pid) when is_integer(os_pid) do
    descendants = descendant_pids(os_pid)
    Enum.uniq(Enum.reverse(descendants) ++ [os_pid])
  end

  defp descendant_pids(pid) when is_integer(pid) do
    pid
    |> child_pids()
    |> Enum.flat_map(fn child_pid -> descendant_pids(child_pid) ++ [child_pid] end)
  end

  defp child_pids(pid) when is_integer(pid) do
    case System.find_executable("pgrep") do
      nil ->
        []

      pgrep ->
        case System.cmd(pgrep, ["-P", Integer.to_string(pid)], stderr_to_stdout: true) do
          {output, 0} -> parse_pids(output)
          {_output, _status} -> []
        end
    end
  end

  defp parse_pids(output) when is_binary(output) do
    output
    |> String.split()
    |> Enum.flat_map(fn value ->
      case Integer.parse(value) do
        {pid, ""} when pid > 0 -> [pid]
        _ -> []
      end
    end)
  end

  defp signal_process(pid, signal) when is_integer(pid) and is_binary(signal) do
    case System.find_executable("kill") do
      nil ->
        :ok

      kill ->
        System.cmd(kill, ["-#{signal}", Integer.to_string(pid)], stderr_to_stdout: true)
        :ok
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

    emit_message(on_message, resolved_agent, :cli_output, cli_output_fields(payload))
  end

  defp cli_output_fields(payload) do
    %{
      payload: payload,
      session_id: cli_session_id(payload),
      usage: cli_usage(payload)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp cli_session_id(payload) when is_map(payload) do
    Map.get(payload, "sessionID") ||
      Map.get(payload, "session_id") ||
      Map.get(payload, :session_id)
  end

  defp cli_session_id(_payload), do: nil

  defp cli_usage(payload) when is_map(payload) do
    tokens =
      map_at_path(payload, ["part", "tokens"]) ||
        map_at_path(payload, [:part, :tokens]) ||
        Map.get(payload, "tokens") ||
        Map.get(payload, :tokens)

    normalize_usage(tokens)
  end

  defp cli_usage(_payload), do: nil

  defp normalize_usage(tokens) when is_map(tokens) do
    usage =
      %{}
      |> maybe_put_usage("input_tokens", token_value(tokens, ["input", :input, "input_tokens", :input_tokens]))
      |> maybe_put_usage("output_tokens", token_value(tokens, ["output", :output, "output_tokens", :output_tokens]))
      |> maybe_put_usage("total_tokens", token_value(tokens, ["total", :total, "total_tokens", :total_tokens]))

    if map_size(usage) > 0, do: usage
  end

  defp normalize_usage(_tokens), do: nil

  defp token_value(tokens, keys) when is_map(tokens) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      tokens
      |> Map.get(key)
      |> integer_like()
    end)
  end

  defp maybe_put_usage(usage, _key, nil), do: usage
  defp maybe_put_usage(usage, key, value), do: Map.put(usage, key, value)

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, ""} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil

  defp port_os_pid(port) when is_port(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) -> os_pid
      _ -> nil
    end
  end

  defp os_pid_string(os_pid) when is_integer(os_pid), do: Integer.to_string(os_pid)
  defp os_pid_string(_os_pid), do: nil

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
