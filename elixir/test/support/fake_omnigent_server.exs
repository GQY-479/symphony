defmodule SymphonyElixir.FakeOmnigentServer do
  @moduledoc false

  use GenServer

  @default_stream_events [
    {"session.status", %{"type" => "session.status", "status" => "running"}},
    {"response.output_text.delta", %{"type" => "response.output_text.delta", "delta" => "hi"}},
    {"response.completed", %{"type" => "response.completed"}},
    {nil, "[DONE]"}
  ]

  def start!(behavior \\ %{}) do
    {:ok, server} = GenServer.start_link(__MODULE__, behavior)
    server
  end

  def stop!(server) do
    if Process.alive?(server) do
      GenServer.call(server, :stop)
    else
      :ok
    end
  end

  def requests(server) do
    GenServer.call(server, :requests)
  end

  def port(server) do
    GenServer.call(server, :port)
  end

  def base_url(server), do: "http://127.0.0.1:#{port(server)}"

  def record_request(server, request) do
    GenServer.call(server, {:record, request})
  end

  def record_create_session_request(server, conn, body) do
    record_request(server,
      %{
        name: "create_session",
        method: conn.method,
        path: conn.request_path,
        query: conn.query_string,
        headers: conn.req_headers,
        body: decode_request_body(body)
      }
    )
  end

  def record_get_session_request(server, conn, session_id) do
    record_request(server,
      %{
        name: "get_session",
        session_id: session_id,
        method: conn.method,
        path: conn.request_path,
        query: conn.query_string,
        headers: conn.req_headers,
        body: decode_request_body("")
      }
    )
  end

  def record_post_event_request(server, conn, session_id, body) do
    record_request(server,
      %{
        name: "post_event",
        session_id: session_id,
        method: conn.method,
        path: conn.request_path,
        query: conn.query_string,
        headers: conn.req_headers,
        body: decode_request_body(body)
      }
    )
  end

  def record_stream_request(server, conn, session_id) do
    record_request(server,
      %{
        name: "stream",
        session_id: session_id,
        method: conn.method,
        path: conn.request_path,
        query: conn.query_string,
        headers: conn.req_headers,
        body: decode_request_body("")
      }
    )
  end

  def format_stream_event({event, data}), do: format_stream_event(%{event: event, data: data})

  def format_stream_event(%{event: event, data: data}) do
    lines =
      []
      |> maybe_add_event_line(event)
      |> Kernel.++(format_data_lines(data))

    Enum.join(lines, "\n") <> "\n\n"
  end

  @impl true
  def init(behavior) do
    behavior = normalize_behavior(behavior)

    {:ok, bandit_pid} =
      Bandit.start_link(
        plug: {SymphonyElixir.FakeOmnigentServer.Plug, [server: self(), behavior: behavior]},
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    case ThousandIsland.listener_info(bandit_pid) do
      {:ok, {_address, port}} ->
        {:ok,
         %{
           bandit_pid: bandit_pid,
           behavior: behavior,
           port: port,
           requests: []
         }}

      :error ->
        {:stop, :listener_info_unavailable}
    end
  end

  @impl true
  def handle_call(:requests, _from, state) do
    {:reply, Enum.reverse(state.requests), state}
  end

  @impl true
  def handle_call(:port, _from, state) do
    {:reply, state.port, state}
  end

  @impl true
  def handle_call(:stop, _from, state) do
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_call({:record, request}, _from, state) do
    {:reply, :ok, %{state | requests: [request | state.requests]}}
  end

  @impl true
  def terminate(_reason, state) do
    if is_pid(state.bandit_pid) do
      Supervisor.stop(state.bandit_pid, :normal)
    end

    :ok
  end

  def response_body(nil, session_id), do: %{"id" => session_id}

  def response_body(body_template, session_id) when is_function(body_template, 1) do
    body_template.(session_id)
  end

  def response_body(body_template, _session_id), do: body_template

  defp decode_request_body(""), do: ""

  defp decode_request_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end

  defp decode_request_body(body), do: body

  def stream_events(behavior) do
    Map.get(behavior, :stream_events, @default_stream_events)
  end

  def create_status(behavior) do
    Map.get(behavior, :create_status, 201)
  end

  def create_body(behavior, session_id) do
    behavior
    |> Map.get(:create_body)
    |> response_body(session_id)
  end

  def snapshot_body(behavior, session_id) do
    behavior
    |> Map.get(:snapshot_body)
    |> case do
      nil -> %{"id" => session_id, "status" => "running"}
      body_template -> response_body(body_template, session_id)
    end
  end

  defp normalize_behavior(behavior) when is_map(behavior), do: Map.new(behavior)
  defp normalize_behavior(behavior) when is_list(behavior), do: Map.new(behavior)
  defp normalize_behavior(behavior), do: Map.new(behavior)

  defp maybe_add_event_line(lines, nil), do: lines
  defp maybe_add_event_line(lines, event), do: ["event: #{event}" | lines]

  defp format_data_lines("[DONE]"), do: ["data: [DONE]"]
  defp format_data_lines(data) when is_binary(data), do: Enum.map(String.split(data, "\n"), &"data: #{&1}")
  defp format_data_lines(data), do: ["data: #{Jason.encode!(data)}"]

  defmodule Plug do
    import Elixir.Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      server = Keyword.fetch!(opts, :server)
      behavior = Keyword.fetch!(opts, :behavior)

      case {conn.method, conn.path_info} do
        {"POST", ["v1", "sessions"]} ->
          {:ok, body, conn} = read_body(conn)
          session_id = "fake-omnigent-session-" <> Integer.to_string(System.unique_integer([:positive]))
          :ok = SymphonyElixir.FakeOmnigentServer.record_create_session_request(server, conn, body)
          body = SymphonyElixir.FakeOmnigentServer.create_body(behavior, session_id)

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(SymphonyElixir.FakeOmnigentServer.create_status(behavior), Jason.encode!(body))

        {"GET", ["v1", "sessions", session_id]} ->
          {:ok, _body, conn} = read_body(conn)
          :ok = SymphonyElixir.FakeOmnigentServer.record_get_session_request(server, conn, session_id)
          body = SymphonyElixir.FakeOmnigentServer.snapshot_body(behavior, session_id)

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(body))

        {"POST", ["v1", "sessions", session_id, "events"]} ->
          {:ok, body, conn} = read_body(conn)
          :ok = SymphonyElixir.FakeOmnigentServer.record_post_event_request(server, conn, session_id, body)
          send_resp(conn, 204, "")

        {"GET", ["v1", "sessions", session_id, "stream"]} ->
          {:ok, _body, conn} = read_body(conn)
          :ok = SymphonyElixir.FakeOmnigentServer.record_stream_request(server, conn, session_id)

          conn =
            conn
            |> put_resp_content_type("text/event-stream")
            |> put_resp_header("cache-control", "no-cache")
            |> put_resp_header("connection", "keep-alive")
            |> send_chunked(200)

          Enum.reduce(SymphonyElixir.FakeOmnigentServer.stream_events(behavior), conn, fn event, conn ->
            {:ok, conn} = chunk(conn, SymphonyElixir.FakeOmnigentServer.format_stream_event(event))
            conn
          end)

        _ ->
          send_resp(conn, 404, "not found")
      end
    end
  end
end
