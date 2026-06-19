defmodule SymphonyElixir.FakeAcpServer do
  @moduledoc false

  def write!(test_root, behavior) do
    executable = Path.join(test_root, "fake-acp-server")
    script = Path.join(test_root, "fake_acp_server.py")
    behavior_json = Jason.encode!(behavior)
    python_behavior_json = String.replace(behavior_json, "'''", "\\'\\'\\'")

    File.write!(script, """
    import json
    import os
    import select
    import sys

    behavior = json.loads(r'''#{python_behavior_json}''')

    pid_file = behavior.get("pidFile")
    if pid_file:
        with open(pid_file, "w", encoding="utf-8") as handle:
            handle.write(str(os.getpid()))

    def send(message):
        print(json.dumps(message), flush=True)

    def send_split(message):
        encoded = json.dumps(message)
        split_at = max(1, len(encoded) // 2)
        sys.stdout.write(encoded[:split_at])
        sys.stdout.flush()
        import time
        time.sleep(0.05)
        sys.stdout.write(encoded[split_at:] + "\\n")
        sys.stdout.flush()

    def send_together(messages):
        sys.stdout.write("".join(json.dumps(message) + "\\n" for message in messages))
        sys.stdout.flush()

    def trace(method):
        trace_file = behavior.get("traceFile")
        if trace_file:
            with open(trace_file, "a", encoding="utf-8") as handle:
                handle.write(method + "\\n")

    def trace_message(message):
        trace_file = behavior.get("traceFile")
        if trace_file and behavior.get("traceMessages"):
            with open(trace_file, "a", encoding="utf-8") as handle:
                handle.write("JSON:" + json.dumps(message, sort_keys=True) + "\\n")

    def trace_prompt_text(message):
        trace_file = behavior.get("traceFile")
        if trace_file and behavior.get("tracePromptText"):
            prompt = message.get("params", {}).get("prompt", [])
            text = "\\n".join(part.get("text", "") for part in prompt if isinstance(part, dict))
            with open(trace_file, "a", encoding="utf-8") as handle:
                handle.write("PROMPT:" + text.replace("\\n", "\\\\n") + "\\n")

    for line in sys.stdin:
        message = json.loads(line)
        method = message.get("method")
        request_id = message.get("id")
        session_id = behavior.get("sessionId", "fake-acp-session")
        trace(method or "")
        trace_message(message)

        if method == "initialize":
            if behavior.get("initializeError"):
                send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32000, "message": "initialize failed"}})
            else:
                agent_capabilities = {}
                if behavior.get("closeCapability"):
                    agent_capabilities["sessionCapabilities"] = {"close": {}}
                send({"jsonrpc": "2.0", "id": request_id, "result": {"protocolVersion": 1, "agentCapabilities": agent_capabilities, "authMethods": []}})
        elif method == "session/new":
            if behavior.get("sessionNewError"):
                send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32000, "message": "session new failed"}})
            elif behavior.get("sessionNewRequiresMcpServers") and not isinstance(message.get("params", {}).get("mcpServers"), list):
                send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32602, "message": "Invalid params", "data": {"mcpServers": {"_errors": ["Invalid input: expected array, received undefined"]}}}})
            elif behavior.get("sessionNewHangAndTraceNext"):
                ready, _, _ = select.select([sys.stdin], [], [], 0.5)
                if ready:
                    followup_line = sys.stdin.readline()
                    if followup_line:
                        followup = json.loads(followup_line)
                        trace(followup.get("method") or "")
            else:
                send({"jsonrpc": "2.0", "id": request_id, "result": {"sessionId": session_id}})
        elif method == "session/set_config_option":
            expected_config_options = behavior.get("expectedConfigOptions", {})
            params = message.get("params", {})
            config_id = params.get("configId")
            expected_value = expected_config_options.get(config_id)

            if config_id in expected_config_options and params.get("value") == expected_value:
                send({"jsonrpc": "2.0", "id": request_id, "result": {"configOptions": [{"id": config_id, "currentValue": expected_value}]}})
            elif config_id in expected_config_options:
                send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32000, "message": "unexpected config option value", "data": {"expected": expected_value, "actual": params.get("value")}}})
            else:
                send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32000, "message": "unexpected config option", "data": params}})
        elif method == "session/prompt":
            trace_prompt_text(message)
            if behavior.get("permission"):
                send({"jsonrpc": "2.0", "id": 9001, "method": "session/request_permission", "params": {"sessionId": session_id, "toolCall": {"title": "write"}, "options": behavior.get("permissionOptions", [{"optionId": "once", "kind": "allow_once", "name": "Allow once"}, {"optionId": "reject", "kind": "reject_once", "name": "Reject"}])}})
                permission_reply = json.loads(sys.stdin.readline())
                expected_option_id = behavior.get("expectedPermissionOptionId")
                if expected_option_id:
                    actual_option_id = permission_reply.get("result", {}).get("outcome", {}).get("optionId")
                    if actual_option_id != expected_option_id:
                        send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32000, "message": "unexpected permission option", "data": {"expected": expected_option_id, "actual": actual_option_id}}})
                        continue
                client_request = behavior.get("clientRequestAfterPermission")
                if client_request:
                    client_request_id = client_request.get("id", 9002)
                    send({"jsonrpc": "2.0", "id": client_request_id, "method": client_request.get("method", "client/unsupported"), "params": client_request.get("params", {})})
                    client_response = json.loads(sys.stdin.readline())
                    if client_response.get("id") != client_request_id or "error" not in client_response:
                        send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32000, "message": "unexpected client request response", "data": client_response}})
                        continue
            if behavior.get("malformed"):
                print("not-json", flush=True)
            write_file = behavior.get("writeFileOnPrompt")
            if write_file:
                path = write_file.get("path")
                contents = write_file.get("contents", "")
                if path:
                    os.makedirs(os.path.dirname(path), exist_ok=True)
                    with open(path, "w", encoding="utf-8") as handle:
                        handle.write(contents)
            append_jsonl = behavior.get("appendJsonlOnPrompt")
            if append_jsonl:
                path = append_jsonl.get("path")
                entry = append_jsonl.get("entry", {})
                if path:
                    os.makedirs(os.path.dirname(path), exist_ok=True)
                    with open(path, "a", encoding="utf-8") as handle:
                        handle.write(json.dumps(entry, ensure_ascii=False) + "\\n")
            if behavior.get("delayPromptMs"):
                import time
                time.sleep(behavior.get("delayPromptMs") / 1000.0)
            if behavior.get("streamUpdatesBeforePromptResponseMs"):
                import time
                duration = behavior.get("streamUpdatesBeforePromptResponseMs") / 1000.0
                interval = behavior.get("streamUpdateIntervalMs", 10) / 1000.0
                deadline = time.monotonic() + duration
                while time.monotonic() < deadline:
                    send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session_id, "update": {"kind": "text", "text": "still working"}}})
                    time.sleep(interval)
            prompt_update = behavior.get("promptUpdate", {"kind": "text", "text": "working"})
            send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session_id, "update": prompt_update}})
            prompt_result = {"stopReason": behavior.get("stopReason", "end_turn")}
            if behavior.get("usage"):
                prompt_result["usage"] = behavior.get("usage")
            prompt_response = {"jsonrpc": "2.0", "id": request_id, "result": prompt_result}
            if behavior.get("splitPromptResponse"):
                send_split(prompt_response)
            elif behavior.get("trailingNotificationAfterPromptResponse"):
                send_together([
                    prompt_response,
                    {"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session_id, "update": {"kind": "text", "text": "post-response"}}}
                ])
            else:
                send(prompt_response)
        elif method == "session/cancel":
            pass
        elif method == "session/close":
            if behavior.get("delayCloseMs"):
                import time
                time.sleep(behavior.get("delayCloseMs") / 1000.0)
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
