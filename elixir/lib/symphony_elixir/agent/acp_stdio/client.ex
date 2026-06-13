defmodule SymphonyElixir.Agent.AcpStdio.Client do
  @moduledoc """
  Minimal ACP JSON-RPC client over newline-delimited stdio.
  """

  @type session :: %{
          port: port(),
          session_id: String.t(),
          os_pid: integer() | nil,
          permission_policy: String.t(),
          on_event: (map() -> term())
        }

  @spec start_session(Path.t(), map(), (map() -> term())) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, config, on_event) when is_binary(workspace) and is_function(on_event, 1) do
    timeout_ms = Map.get(config, :timeout_ms, 5_000)

    with {:ok, executable} <- resolve_command(Map.fetch!(config, :command)),
         {:ok, port} <- start_port(executable, Map.get(config, :args, []), workspace, Map.get(config, :env, [])),
         session0 <- %{
           port: port,
           session_id: nil,
           os_pid: port_os_pid(port),
           permission_policy: Map.get(config, :permission_policy, "reject"),
           on_event: on_event
         },
         {:ok, _init} <- request(session0, "initialize", initialize_params(), timeout_ms),
         {:ok, result} <- request(session0, "session/new", %{"cwd" => Path.expand(workspace)}, timeout_ms),
         {:ok, session_id} <- extract_session_id(result) do
      session = %{session0 | session_id: session_id}
      emit(session, :session_started, %{"result" => result})
      {:ok, session}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec prompt(session(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prompt(%{session_id: session_id} = session, prompt, opts) when is_binary(prompt) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 3_600_000)
    params = %{"sessionId" => session_id, "prompt" => [%{"type" => "text", "text" => prompt}]}

    case request(session, "session/prompt", params, timeout_ms) do
      {:ok, result} ->
        {:ok, %{"stop_reason" => Map.get(result, "stopReason"), "raw" => result}}

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
    _ = request(session, "session/close", %{"sessionId" => session_id}, 1_000)
    close_port(session.port)
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

  defp request(session, method, params, timeout_ms) do
    id = System.unique_integer([:positive])
    send_json(session.port, %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
    await_response(session, id, timeout_ms)
  end

  defp notify(session, method, params) do
    send_json(session.port, %{"jsonrpc" => "2.0", "method" => method, "params" => params})
    :ok
  end

  defp await_response(session, id, timeout_ms) do
    receive do
      {port, {:data, data}} when port == session.port ->
        data
        |> to_string()
        |> String.split("\n", trim: true)
        |> handle_lines(session, id, timeout_ms)

      {port, {:exit_status, status}} when port == session.port ->
        {:error, {:acp_exit, status}}
    after
      timeout_ms ->
        cancel(session)
        {:error, :acp_timeout}
    end
  end

  defp handle_lines([], session, id, timeout_ms), do: await_response(session, id, timeout_ms)

  defp handle_lines([line | rest], session, id, timeout_ms) do
    case Jason.decode(line) do
      {:ok, %{"id" => ^id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^id, "error" => error}} ->
        {:error, {:acp_error, error}}

      {:ok, %{"id" => request_id, "method" => "session/request_permission", "params" => params}} ->
        handle_permission_request(session, request_id, params)
        handle_lines(rest, session, id, timeout_ms)

      {:ok, %{"method" => method} = notification} ->
        emit(session, notification_event(method), notification)
        handle_lines(rest, session, id, timeout_ms)

      {:ok, decoded} ->
        emit(session, :other_message, decoded)
        handle_lines(rest, session, id, timeout_ms)

      {:error, reason} ->
        emit(session, :malformed, %{"line" => line, "reason" => inspect(reason)})
        handle_lines(rest, session, id, timeout_ms)
    end
  end

  defp handle_permission_request(%{permission_policy: "allow"} = session, request_id, params) do
    emit(session, :approval_auto_approved, params)

    send_json(session.port, %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "allow_once"}}
    })
  end

  defp handle_permission_request(%{permission_policy: "fail"} = session, request_id, params) do
    emit(session, :approval_required, params)

    send_json(session.port, %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "result" => %{"outcome" => %{"outcome" => "cancelled"}}
    })
  end

  defp handle_permission_request(session, request_id, params) do
    emit(session, :permission_rejected, params)

    send_json(session.port, %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "result" => %{"outcome" => %{"outcome" => "rejected"}}
    })
  end

  defp notification_event("session/update"), do: :notification
  defp notification_event(_method), do: :other_message

  defp send_json(port, payload) do
    Port.command(port, Jason.encode!(payload) <> "\n")
  end

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
end
