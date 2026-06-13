defmodule SymphonyElixir.FakeAcpServer do
  @moduledoc false

  def write!(test_root, behavior) do
    executable = Path.join(test_root, "fake-acp-server")
    script = Path.join(test_root, "fake_acp_server.py")
    behavior_json = Jason.encode!(behavior)
    python_behavior_json = String.replace(behavior_json, "'''", "\\'\\'\\'")

    File.write!(script, """
    import json
    import sys

    behavior = json.loads('''#{python_behavior_json}''')

    def send(message):
        print(json.dumps(message), flush=True)

    def trace(method):
        trace_file = behavior.get("traceFile")
        if trace_file:
            with open(trace_file, "a", encoding="utf-8") as handle:
                handle.write(method + "\\n")

    for line in sys.stdin:
        message = json.loads(line)
        method = message.get("method")
        request_id = message.get("id")
        session_id = behavior.get("sessionId", "fake-acp-session")
        trace(method or "")

        if method == "initialize":
            send({"jsonrpc": "2.0", "id": request_id, "result": {"protocolVersion": 1, "agentCapabilities": {}, "authMethods": []}})
        elif method == "session/new":
            send({"jsonrpc": "2.0", "id": request_id, "result": {"sessionId": session_id}})
        elif method == "session/prompt":
            if behavior.get("permission"):
                send({"jsonrpc": "2.0", "id": 9001, "method": "session/request_permission", "params": {"sessionId": session_id, "toolCall": {"title": "write"}, "options": [{"id": "allow_once"}, {"id": "reject"}]}})
                json.loads(sys.stdin.readline())
            if behavior.get("malformed"):
                print("not-json", flush=True)
            if behavior.get("delayPromptMs"):
                import time
                time.sleep(behavior.get("delayPromptMs") / 1000.0)
            send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session_id, "update": {"kind": "text", "text": "working"}}})
            send({"jsonrpc": "2.0", "id": request_id, "result": {"stopReason": behavior.get("stopReason", "end_turn")}})
        elif method == "session/cancel":
            pass
        elif method == "session/close":
            send({"jsonrpc": "2.0", "id": request_id, "result": {}})
        else:
            send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": "method not found"}})
    """)

    File.write!(executable, """
    #!/bin/sh
    exec python3 -u "#{script}"
    """)

    File.chmod!(executable, 0o755)
    {executable, []}
  end
end
