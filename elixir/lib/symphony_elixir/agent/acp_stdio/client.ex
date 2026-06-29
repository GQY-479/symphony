defmodule SymphonyElixir.Agent.AcpStdio.Client do
  @moduledoc """
  通过 newline-delimited stdio 与 ACP JSON-RPC agent 通讯的最小客户端。
  """

  @type session :: %{
          port: port(),
          session_id: String.t(),
          os_pid: integer() | nil,
          agent_capabilities: map(),
          permission_policy: String.t(),
          on_event: (map() -> term())
        }

  @spec start_session(Path.t(), map(), (map() -> term())) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, config, on_event) when is_binary(workspace) and is_function(on_event, 1) do
    timeout_ms = Map.get(config, :timeout_ms, 5_000)

    with {:ok, executable} <- resolve_command(Map.fetch!(config, :command)),
         {:ok, port} <- start_port(executable, Map.get(config, :args, []), workspace, Map.get(config, :env, [])) do
      session0 = %{
        port: port,
        session_id: nil,
        os_pid: port_os_pid(port),
        agent_capabilities: %{},
        permission_policy: Map.get(config, :permission_policy, "reject"),
        on_event: on_event
      }

      case initialize_session(session0, workspace, config, timeout_ms) do
        {:ok, session} ->
          {:ok, session}

        {:error, reason} ->
          close_port(port)
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp initialize_session(session0, workspace, config, timeout_ms) do
    with {:ok, init} <- request(session0, "initialize", initialize_params(), timeout_ms),
         session0 <- %{session0 | agent_capabilities: agent_capabilities(init)},
         {:ok, result} <- request(session0, "session/new", session_new_params(workspace, config), timeout_ms),
         {:ok, session_id} <- extract_session_id(result),
         session = %{session0 | session_id: session_id},
         :ok <- apply_config_options(session, Map.get(config, :config_options, %{}), timeout_ms) do
      emit(session, :session_started, %{"result" => result})
      {:ok, session}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_config_options(_session, config_options, _timeout_ms) when config_options in [%{}, nil], do: :ok

  defp apply_config_options(session, config_options, timeout_ms) when is_map(config_options) do
    config_options
    |> Enum.sort_by(fn {config_id, _value} -> to_string(config_id) end)
    |> Enum.reduce_while(:ok, fn {config_id, value}, :ok ->
      params = %{
        "sessionId" => session.session_id,
        "configId" => to_string(config_id),
        "value" => value
      }

      case request(session, "session/set_config_option", params, timeout_ms) do
        {:ok, _result} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp agent_capabilities(%{"agentCapabilities" => capabilities}) when is_map(capabilities), do: capabilities
  defp agent_capabilities(%{agentCapabilities: capabilities}) when is_map(capabilities), do: capabilities
  defp agent_capabilities(_init), do: %{}

  defp session_new_params(workspace, config) do
    %{
      "cwd" => Path.expand(workspace),
      "mcpServers" => build_mcp_servers(config)
    }
  end

  defp build_mcp_servers(config) do
    mcp = Map.get(config, :mcp) || Map.get(config, "mcp") || %{}

    if mcp_value(mcp, "linear_tools") == true do
      [
        %{
          "name" => "symphony-linear",
          "type" => mcp_value(mcp, "type") || "http",
          "url" => mcp_value(mcp, "url"),
          "headers" => mcp_value(mcp, "headers") || [],
          "env" => mcp_value(mcp, "env") || []
        }
      ]
    else
      []
    end
  end

  defp mcp_value(mcp, key) when is_map(mcp), do: Map.get(mcp, key) || Map.get(mcp, String.to_atom(key))

  @spec prompt(session(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prompt(%{session_id: session_id} = session, prompt, opts) when is_binary(prompt) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 3_600_000)
    params = %{"sessionId" => session_id, "prompt" => [%{"type" => "text", "text" => prompt}]}

    case request(session, "session/prompt", params, timeout_ms, cancel_on_timeout: true) do
      {:ok, result} ->
        prompt_result =
          %{"stop_reason" => Map.get(result, "stopReason"), "raw" => result}
          |> maybe_put_usage(Map.get(result, "usage") || Map.get(result, :usage))

        {:ok, prompt_result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec cancel(session()) :: :ok
  def cancel(%{session_id: session_id} = session) do
    notify(session, "session/cancel", %{"sessionId" => session_id})
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{session_id: session_id} = session) when is_binary(session_id) do
    if close_capability?(session) do
      case request(session, "session/close", %{"sessionId" => session_id}, Map.get(session, :close_timeout_ms, 1_000)) do
        {:error, :acp_timeout} -> terminate_port_process(session)
        _result -> close_port(session.port)
      end
    else
      close_port(session.port)
    end
  end

  def stop_session(%{port: port}), do: close_port(port)

  defp initialize_params do
    %{
      "protocolVersion" => 1,
      "clientInfo" => %{"name" => "Symphony", "version" => "dev"},
      "clientCapabilities" => %{
        "fs" => %{"readTextFile" => false, "writeTextFile" => false},
        "terminal" => false
      }
    }
  end

  defp request(session, method, params, timeout_ms, opts \\ []) do
    id = System.unique_integer([:positive])
    send_json(session.port, %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    await_response(session, id, deadline_ms, "", nil, Keyword.get(opts, :cancel_on_timeout, false))
  end

  defp notify(session, method, params) do
    send_json(session.port, %{"jsonrpc" => "2.0", "method" => method, "params" => params})
    :ok
  end

  defp await_response(session, id, deadline_ms, buffer, deferred_error, cancel_on_timeout?) do
    remaining_ms = timeout_remaining_ms(deadline_ms)

    if remaining_ms <= 0 do
      if cancel_on_timeout?, do: cancel(session)
      {:error, deferred_error || :acp_timeout}
    else
      receive do
        {port, {:data, data}} when port == session.port ->
          data
          |> to_string()
          |> decode_ndjson_buffer(buffer)
          |> case do
            {lines, next_buffer} ->
              handle_lines(lines, session, id, deadline_ms, next_buffer, deferred_error, cancel_on_timeout?)
          end

        {port, {:exit_status, status}} when port == session.port ->
          {:error, {:acp_exit, status}}
      after
        remaining_ms ->
          if cancel_on_timeout?, do: cancel(session)
          {:error, deferred_error || :acp_timeout}
      end
    end
  end

  defp timeout_remaining_ms(deadline_ms) when is_integer(deadline_ms) do
    deadline_ms - System.monotonic_time(:millisecond)
  end

  defp handle_lines([], session, id, deadline_ms, buffer, deferred_error, cancel_on_timeout?),
    do: await_response(session, id, deadline_ms, buffer, deferred_error, cancel_on_timeout?)

  defp handle_lines([line | rest], session, id, deadline_ms, buffer, deferred_error, cancel_on_timeout?) do
    if timeout_remaining_ms(deadline_ms) <= 0 do
      if cancel_on_timeout?, do: cancel(session)
      {:error, deferred_error || :acp_timeout}
    else
      handle_line(line, rest, session, id, deadline_ms, buffer, deferred_error, cancel_on_timeout?)
    end
  end

  defp handle_line(line, rest, session, id, deadline_ms, buffer, deferred_error, cancel_on_timeout?) do
    case Jason.decode(line) do
      {:ok, %{"id" => ^id, "result" => result}} ->
        handle_post_response_lines(rest, session)
        maybe_deferred_response(deferred_error, {:ok, result})

      {:ok, %{"id" => ^id, "error" => error}} ->
        handle_post_response_lines(rest, session)
        maybe_deferred_response(deferred_error, {:error, {:acp_error, error}})

      {:ok, %{"id" => request_id, "method" => "session/request_permission", "params" => params}} ->
        case handle_permission_request(session, request_id, params) do
          :ok ->
            handle_lines(rest, session, id, deadline_ms, buffer, deferred_error, cancel_on_timeout?)

          {:defer_error, reason} ->
            handle_lines(rest, session, id, deadline_ms, buffer, deferred_error || reason, cancel_on_timeout?)
        end

      {:ok, %{"id" => request_id, "method" => method} = request} ->
        handle_unsupported_request(session, request_id, method, request)
        handle_lines(rest, session, id, deadline_ms, buffer, deferred_error, cancel_on_timeout?)

      {:ok, %{"method" => method} = notification} ->
        emit(session, notification_event(method), notification)
        handle_lines(rest, session, id, deadline_ms, buffer, deferred_error, cancel_on_timeout?)

      {:ok, decoded} ->
        emit(session, :other_message, decoded)
        handle_lines(rest, session, id, deadline_ms, buffer, deferred_error, cancel_on_timeout?)

      {:error, reason} ->
        emit(session, :malformed, %{"line" => line, "reason" => inspect(reason)})
        handle_lines(rest, session, id, deadline_ms, buffer, deferred_error, cancel_on_timeout?)
    end
  end

  defp maybe_deferred_response(nil, response), do: response
  defp maybe_deferred_response(reason, _response), do: {:error, reason}

  defp handle_post_response_lines([], _session), do: :ok

  defp handle_post_response_lines([line | rest], session) do
    case Jason.decode(line) do
      {:ok, %{"id" => request_id, "method" => "session/request_permission", "params" => params}} ->
        _ = handle_permission_request(session, request_id, params)

      {:ok, %{"id" => request_id, "method" => method} = request} ->
        handle_unsupported_request(session, request_id, method, request)

      {:ok, %{"method" => method} = notification} ->
        emit(session, notification_event(method), notification)

      {:ok, decoded} ->
        emit(session, :other_message, decoded)

      {:error, reason} ->
        emit(session, :malformed, %{"line" => line, "reason" => inspect(reason)})
    end

    handle_post_response_lines(rest, session)
  end

  defp decode_ndjson_buffer(chunk, buffer) when is_binary(chunk) and is_binary(buffer) do
    data = buffer <> chunk

    if String.ends_with?(data, "\n") do
      {String.split(data, "\n", trim: true), ""}
    else
      parts = String.split(data, "\n")
      {Enum.drop(parts, -1) |> Enum.reject(&(&1 == "")), List.last(parts) || ""}
    end
  end

  defp handle_permission_request(%{permission_policy: "allow"} = session, request_id, params) do
    emit(session, :approval_auto_approved, params)
    option_id = allow_permission_option_id(params)

    send_json(session.port, %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => option_id}}
    })

    :ok
  end

  defp handle_permission_request(%{permission_policy: "fail"} = session, request_id, params) do
    emit(session, :approval_required, params)

    send_json(session.port, %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "result" => %{"outcome" => %{"outcome" => "cancelled"}}
    })

    {:defer_error, {:permission_required, params}}
  end

  defp handle_permission_request(session, request_id, params) do
    emit(session, :permission_rejected, params)

    send_json(session.port, %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "result" => %{"outcome" => %{"outcome" => "rejected"}}
    })

    :ok
  end

  defp allow_permission_option_id(%{"options" => options}) when is_list(options) do
    options
    |> Enum.find_value(fn
      %{"kind" => "allow_once", "optionId" => option_id} when is_binary(option_id) -> option_id
      %{"optionId" => "once"} -> "once"
      _option -> nil
    end)
    |> case do
      nil -> "once"
      option_id -> option_id
    end
  end

  defp allow_permission_option_id(_params), do: "once"

  defp notification_event("session/update"), do: :notification
  defp notification_event(_method), do: :other_message

  defp close_capability?(%{agent_capabilities: capabilities}) when is_map(capabilities) do
    session_capabilities =
      Map.get(capabilities, "sessionCapabilities") ||
        Map.get(capabilities, :sessionCapabilities) ||
        %{}

    close = Map.get(session_capabilities, "close") || Map.get(session_capabilities, :close)
    is_map(close) or close == true
  end

  defp close_capability?(_session), do: false

  defp handle_unsupported_request(session, request_id, method, request) do
    emit(session, :unsupported_request, request)

    send_json(session.port, %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "error" => %{
        "code" => -32_601,
        "message" => "Unsupported ACP client request: #{method}"
      }
    })
  end

  defp send_json(port, payload) do
    Port.command(port, Jason.encode!(payload) <> "\n")
  end

  defp maybe_put_usage(result, usage) when is_map(usage), do: Map.put(result, "usage", usage)
  defp maybe_put_usage(result, _usage), do: result

  defp start_port(executable, args, workspace, env) do
    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          args: Enum.map(args, &String.to_charlist(to_string(&1))),
          cd: String.to_charlist(workspace),
          env: Enum.map(env, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
        ]
      )

    {:ok, port}
  rescue
    error in [ArgumentError, ErlangError] ->
      {:error, {:acp_start_failed, executable, Exception.message(error)}}
  end

  defp resolve_command(command) when is_binary(command) do
    cond do
      Path.type(command) == :absolute and File.exists?(command) -> {:ok, command}
      executable = System.find_executable(command) -> {:ok, executable}
      true -> {:error, {:acp_command_not_found, command}}
    end
  end

  defp resolve_command(command), do: {:error, {:invalid_acp_command, command}}

  defp extract_session_id(%{"sessionId" => session_id}) when is_binary(session_id), do: {:ok, session_id}
  defp extract_session_id(result), do: {:error, {:acp_session_id_missing, result}}

  defp emit(session, event, payload) do
    session.on_event.(%{
      event: event,
      timestamp: DateTime.utc_now(),
      session_id: session.session_id,
      codex_app_server_pid: os_pid_string(session.os_pid),
      payload: payload
    })
  end

  defp port_os_pid(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) -> os_pid
      _ -> nil
    end
  end

  defp os_pid_string(os_pid) when is_integer(os_pid), do: Integer.to_string(os_pid)
  defp os_pid_string(_os_pid), do: nil

  defp close_port(port) when is_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp terminate_port_process(%{port: port} = session) when is_port(port) do
    os_pid = Map.get(session, :os_pid)

    if is_integer(os_pid) do
      signal_process(os_pid, "TERM")
      close_port(port)
      Process.sleep(50)
      signal_process(os_pid, "KILL")
    else
      close_port(port)
    end

    :ok
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
end
