defmodule SymphonyElixir.Agent.Backend.AcpStdio do
  @moduledoc """
  通过 ACP stdio 协议运行兼容 agent 的 session backend。
  """

  @behaviour SymphonyElixir.Agent.Backend

  require Logger

  alias SymphonyElixir.Agent.AcpStdio.Client
  alias SymphonyElixir.{Config, HttpServer}

  @default_timeout_ms 3_600_000

  @impl true
  def run_issue(_workspace, _issue, _prompt, _resolved_agent, _opts) do
    {:error, :acp_stdio_session_backend_only}
  end

  @spec start_session(Path.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_session(workspace, resolved_agent, opts) do
    config = agent_config(resolved_agent)
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    model_list = extract_model_list(config)
    current_model = List.first(model_list)

    client_config = %{
      command: Map.get(config, "command"),
      args: build_args(config, workspace),
      env: Map.get(config, "env", []),
      permission_policy: Map.get(config, "permission_policy", "reject"),
      timeout_ms: Map.get(config, "read_timeout_ms", Map.get(config, "timeout_ms", 5_000)),
      config_options: Map.get(config, "config_options", %{}),
      mcp: normalize_mcp_config(Map.get(config, "mcp", %{}))
    }

    case Client.start_session(workspace, client_config, annotated_on_message(on_message, resolved_agent)) do
      {:ok, session} ->
        {:ok,
         session
         |> Map.put(:resolved_agent, resolved_agent)
         |> Map.put(:timeout_ms, Map.get(config, "timeout_ms", @default_timeout_ms))
         |> Map.put(:close_timeout_ms, Map.get(config, "close_timeout_ms", 1_000))
         |> Map.put(:model_errors, %{})
         |> Map.put(:current_model, current_model)
         |> Map.put(:model_list, model_list)}

      other ->
        other
    end
  end

  def extract_model_list(config) do
    case get_in(config, ["config_options", "model"]) do
      list when is_list(list) -> list
      string when is_binary(string) -> [string]
      _ -> ["mimo/mimo-auto"]
    end
  end

  @spec run_turn(map(), Path.t(), map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, _workspace, _issue, prompt, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, Map.get(session, :timeout_ms, @default_timeout_ms))
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    turn_session = %{session | on_event: annotated_on_message(on_message, session.resolved_agent)}

    emit_turn_started(turn_session)

    case Client.prompt(turn_session, prompt, timeout_ms: timeout_ms) do
      {:ok, result} ->
        emit_turn_completed(turn_session, result)

        {:ok,
         %{
           session_id: turn_session.session_id,
           stop_reason: Map.get(result, "stop_reason"),
           usage: Map.get(result, "usage"),
           raw: result
         }}

      {:error, :acp_timeout} = error ->
        emit_turn_cancelled(turn_session, :acp_timeout)
        error

      {:error, reason} = error ->
        emit_turn_failed(turn_session, reason)
        error

      other ->
        other
    end
  end

  @spec stop_session(map()) :: :ok
  def stop_session(session) when is_map(session), do: Client.stop_session(session)

  defp build_args(config, workspace) do
    config
    |> Map.get("args", [])
    |> Enum.map(&String.replace(to_string(&1), "{{workspace}}", workspace))
  end

  defp normalize_mcp_config(mcp) when is_map(mcp) do
    if Map.get(mcp, "linear_tools") == true or Map.get(mcp, :linear_tools) == true do
      mcp
      |> stringify_keys()
      |> Map.put_new("type", "http")
      |> Map.put_new("url", default_mcp_url())
      |> Map.put_new("headers", [])
      |> Map.put_new("env", [])
    else
      stringify_keys(mcp)
    end
  end

  defp normalize_mcp_config(_mcp), do: %{}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp default_mcp_url do
    port = HttpServer.bound_port() || Config.server_port() || 4000
    "http://127.0.0.1:#{port}/mcp/linear-tools"
  end

  defp annotated_on_message(on_message, resolved_agent) when is_function(on_message, 1) do
    fn message ->
      annotated =
        message
        |> Map.put(:agent_id, agent_id(resolved_agent))
        |> Map.put(:agent_kind, agent_kind(resolved_agent))
        |> Map.put_new(:timestamp, DateTime.utc_now())

      log_acp_event_summary(annotated)
      on_message.(annotated)
    end
  end

  defp log_acp_event_summary(%{event: :notification, payload: %{"method" => "session/update"} = payload} = message) do
    update = nested_value(payload, ["params", "update"]) || %{}
    update_kind = string_value(update, ["kind", :kind]) || "unknown"
    tool_name = acp_tool_name(update)
    tool_status = string_value(update, ["status", :status, "state", :state]) || "unknown"
    error_category = acp_error_category(update_kind, tool_status)

    [
      "ACP session/update",
      "agent_id=#{log_plain(Map.get(message, :agent_id))}",
      "agent_kind=#{log_plain(Map.get(message, :agent_kind))}",
      "session_id=#{log_plain(Map.get(message, :session_id))}",
      "update_kind=#{log_plain(update_kind)}",
      "tool_name=#{log_quoted(tool_name)}",
      "tool_status=#{log_plain(tool_status)}",
      "error_category=#{log_plain(error_category)}"
    ]
    |> Enum.join(" ")
    |> Logger.info()
  end

  defp log_acp_event_summary(_message), do: :ok

  defp acp_tool_name(update) when is_map(update) do
    string_value(update, [
      ["toolCall", "name"],
      [:toolCall, :name],
      ["toolCall", "title"],
      [:toolCall, :title],
      "name",
      :name,
      "title",
      :title
    ])
  end

  defp acp_tool_name(_update), do: nil

  defp acp_error_category("tool_call", status) when status in ["failed", "error"], do: "tool_error"
  defp acp_error_category(_update_kind, status) when status in ["failed", "error"], do: "agent_error"
  defp acp_error_category(_update_kind, _status), do: "none"

  defp nested_value(value, []), do: value

  defp nested_value(value, [key | rest]) when is_map(value) do
    case Map.fetch(value, key) do
      {:ok, nested} -> nested_value(nested, rest)
      :error -> nil
    end
  end

  defp nested_value(_value, _path), do: nil

  defp string_value(map, candidates) when is_list(candidates) do
    Enum.find_value(candidates, fn
      path when is_list(path) ->
        value = nested_value(map, path)
        if is_binary(value) and String.trim(value) != "", do: String.trim(value)

      key ->
        value = Map.get(map, key)
        if is_binary(value) and String.trim(value) != "", do: String.trim(value)
    end)
  end

  defp log_plain(value) when is_binary(value), do: value |> String.trim() |> String.replace(~r/\s+/, "_")
  defp log_plain(nil), do: "nil"
  defp log_plain(value), do: value |> to_string() |> log_plain()

  defp log_quoted(nil), do: "nil"
  defp log_quoted(value) when is_binary(value), do: inspect(String.trim(value))
  defp log_quoted(value), do: value |> to_string() |> log_quoted()

  defp emit_turn_started(session) do
    session.on_event.(%{
      event: :turn_started,
      timestamp: DateTime.utc_now(),
      agent_id: agent_id(session.resolved_agent),
      agent_kind: agent_kind(session.resolved_agent),
      session_id: session.session_id,
      codex_app_server_pid: os_pid_string(Map.get(session, :os_pid)),
      payload: %{}
    })
  end

  defp emit_turn_completed(session, result) do
    %{
      event: :turn_completed,
      timestamp: DateTime.utc_now(),
      agent_id: agent_id(session.resolved_agent),
      agent_kind: agent_kind(session.resolved_agent),
      session_id: session.session_id,
      codex_app_server_pid: os_pid_string(Map.get(session, :os_pid)),
      payload: result
    }
    |> maybe_put_usage(Map.get(result, "usage") || Map.get(result, :usage))
    |> session.on_event.()
  end

  defp emit_turn_failed(session, reason) do
    session.on_event.(%{
      event: :turn_failed,
      timestamp: DateTime.utc_now(),
      agent_id: agent_id(session.resolved_agent),
      agent_kind: agent_kind(session.resolved_agent),
      session_id: session.session_id,
      codex_app_server_pid: os_pid_string(Map.get(session, :os_pid)),
      payload: %{reason: reason}
    })
  end

  defp emit_turn_cancelled(session, reason) do
    session.on_event.(%{
      event: :turn_cancelled,
      timestamp: DateTime.utc_now(),
      agent_id: agent_id(session.resolved_agent),
      agent_kind: agent_kind(session.resolved_agent),
      session_id: session.session_id,
      codex_app_server_pid: os_pid_string(Map.get(session, :os_pid)),
      payload: %{reason: reason}
    })
  end

  defp maybe_put_usage(message, usage) when is_map(usage), do: Map.put(message, :usage, usage)
  defp maybe_put_usage(message, _usage), do: message
  defp os_pid_string(os_pid) when is_integer(os_pid), do: Integer.to_string(os_pid)
  defp os_pid_string(_os_pid), do: nil

  defp agent_id(resolved_agent), do: Map.get(resolved_agent, :id) || Map.get(resolved_agent, "id")
  defp agent_kind(resolved_agent), do: Map.get(resolved_agent, :kind) || Map.get(resolved_agent, "kind")
  defp agent_config(resolved_agent), do: Map.get(resolved_agent, :config) || Map.get(resolved_agent, "config") || %{}
  defp default_on_message(_message), do: :ok
end
