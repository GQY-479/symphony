defmodule SymphonyElixir.FakeAcpServer do
  @moduledoc false

  def write!(test_root, behavior) do
    executable = Path.join(test_root, "fake-acp-server")
    script = Path.join(test_root, "fake_acp_server.py")
    behavior_json = Jason.encode!(behavior)

    File.write!(script, """
    import json
    import os
    import sys

    behavior = json.loads(os.environ["FAKE_ACP_BEHAVIOR"])

    def send(message):
        print(json.dumps(message), flush=True)

    for line in sys.stdin:
        message = json.loads(line)
        method = message.get("method")
        request_id = message.get("id")
        session_id = behavior.get("sessionId", "fake-acp-session")

        if method == "initialize":
            send({"jsonrpc": "2.0", "id": request_id, "result": {"protocolVersion": 1, "agentCapabilities": {}, "authMethods": []}})
        elif method == "session/new":
            send({"jsonrpc": "2.0", "id": request_id, "result": {"sessionId": session_id}})
        elif method == "session/prompt":
            send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session_id, "update": {"kind": "text", "text": "working"}}})
            send({"jsonrpc": "2.0", "id": request_id, "result": {"stopReason": behavior.get("stopReason", "end_turn")}})
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
    {executable, [{"FAKE_ACP_BEHAVIOR", behavior_json}]}
  end
end
