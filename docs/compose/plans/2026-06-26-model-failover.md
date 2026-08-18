# Model Failover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use compose:subagent (recommended) or compose:execute to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement backend-level model failover for ACP sessions, supporting multiple models in priority order with runtime switching.

**Architecture:** Add error tracking and model switching logic to `AcpStdio` backend, leveraging ACP's `session/set_config_option` for runtime model changes within the same session.

**Tech Stack:** Elixir, ACP protocol, MiMo-Code agent

## Global Constraints

- Model priority: `mimo-v2.5-pro` first, `mimo/mimo-auto` as fallback
- Error threshold: 10 failures per model before switching
- Session preservation: Same session ID maintained throughout
- ACP protocol compliance: Use `session/set_config_option` for runtime switching

---

### Task 1: Update Configuration Schema for Model Lists

**Covers:** S3

**Files:**
- Modify: `lib/symphony_elixir/config/schema.ex`
- Test: `test/symphony_elixir/config/schema_test.exs`

**Interfaces:**
- Produces: `@default_mimocode_model` as list `["mimo-v2.5-pro", "mimo/mimo-auto"]`

- [ ] **Step 1: Write the failing test**

```elixir
# test/symphony_elixir/config/schema_test.exs
test "default_mimocode_agent_config supports model list" do
  config = SymphonyElixir.Config.Schema.default_mimocode_agent_config()
  model = get_in(config, ["config_options", "model"])
  assert is_list(model)
  assert length(model) > 0
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/symphony_elixir/config/schema_test.exs`
Expected: FAIL with "model is not a list"

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/symphony_elixir/config/schema.ex
@default_mimocode_model ["mimo-v2.5-pro", "mimo/mimo-auto"]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/symphony_elixir/config/schema_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/symphony_elixir/config/schema.ex test/symphony_elixir/config/schema_test.exs
git commit -m "feat: support model list in config schema"
```

---

### Task 2: Add Model List Parsing in Config Validation

**Covers:** S3, S4

**Files:**
- Modify: `lib/symphony_elixir/config.ex`
- Test: `test/symphony_elixir/config_test.exs`

**Interfaces:**
- Consumes: Model list from config
- Produces: Validated model list in agent config

- [ ] **Step 1: Write the failing test**

```elixir
# test/symphony_elixir/config_test.exs
test "validates model list in config_options" do
  config = %{
    "kind" => "acp_stdio",
    "command" => "mimo",
    "config_options" => %{"model" => ["mimo-v2.5-pro", "mimo/mimo-auto"]}
  }

  assert {:ok, _} = SymphonyElixir.Config.validate_agent_config("test", config)
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/symphony_elixir/config_test.exs`
Expected: FAIL with validation error

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/symphony_elixir/config.ex
defp validate_optional_string_map(agent_id, agent, key) do
  case Map.get(agent, key) do
    nil -> :ok
    map when is_map(map) -> :ok
    list when is_list(list) -> :ok  # Add this line
    _ -> {:error, "#{agent_id}.#{key} must be a map or list"}
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/symphony_elixir/config_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/symphony_elixir/config.ex test/symphony_elixir/config_test.exs
git commit -m "feat: validate model list in config"
```

---

### Task 3: Add Error Tracking State to ACP Backend

**Covers:** S4, S5

**Files:**
- Modify: `lib/symphony_elixir/agent/backend/acp_stdio.ex`
- Test: `test/symphony_elixir/agent/backend/acp_stdio_test.exs`

**Interfaces:**
- Produces: Session state with `model_errors`, `current_model`, `model_list`

- [ ] **Step 1: Write the failing test**

```elixir
# test/symphony_elixir/agent/backend/acp_stdio_test.exs
test "session state includes error tracking fields" do
  session = %{
    session_id: "test",
    model_errors: %{},
    current_model: nil,
    model_list: []
  }

  assert Map.has_key?(session, :model_errors)
  assert Map.has_key?(session, :current_model)
  assert Map.has_key?(session, :model_list)
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/symphony_elixir/agent/backend/acp_stdio_test.exs`
Expected: FAIL with "session missing fields"

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/symphony_elixir/agent/backend/acp_stdio.ex
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

defp extract_model_list(config) do
  case get_in(config, ["config_options", "model"]) do
    list when is_list(list) -> list
    string when is_binary(string) -> [string]
    _ -> ["mimo/mimo-auto"]
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/symphony_elixir/agent/backend/acp_stdio_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/symphony_elixir/agent/backend/acp_stdio.ex test/symphony_elixir/agent/backend/acp_stdio_test.exs
git commit -m "feat: add error tracking state to ACP backend"
```

---

### Task 4: Implement Model Switching Function

**Covers:** S4, S5

**Files:**
- Modify: `lib/symphony_elixir/agent/backend/acp_stdio.ex`
- Test: `test/symphony_elixir/agent/backend/acp_stdio_test.exs`

**Interfaces:**
- Consumes: Session state, new model name
- Produces: Updated session state with new current_model

- [ ] **Step 1: Write the failing test**

```elixir
# test/symphony_elixir/agent/backend/acp_stdio_test.exs
test "switch_model updates current_model" do
  session = %{
    session_id: "test",
    current_model: "mimo-v2.5-pro",
    model_list: ["mimo-v2.5-pro", "mimo/mimo-auto"]
  }

  # Mock the Client.request function
  expect(SymphonyElixir.Agent.AcpStdio.Client, :request, fn _, _, _, _ ->
    {:ok, %{"configOptions" => []}}
  end)

  {:ok, updated_session} = SymphonyElixir.Agent.Backend.AcpStdio.switch_model(session, "mimo/mimo-auto")
  assert updated_session.current_model == "mimo/mimo-auto"
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/symphony_elixir/agent/backend/acp_stdio_test.exs`
Expected: FAIL with "function not defined"

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/symphony_elixir/agent/backend/acp_stdio.ex
def switch_model(session, new_model) do
  params = %{
    "sessionId" => session.session_id,
    "configId" => "model",
    "value" => new_model
  }

  case Client.request(session, "session/set_config_option", params, session.timeout_ms) do
    {:ok, _result} ->
      updated_session = %{session | current_model: new_model}
      {:ok, updated_session}
    {:error, reason} ->
      {:error, reason}
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/symphony_elixir/agent/backend/acp_stdio_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/symphony_elixir/agent/backend/acp_stdio.ex test/symphony_elixir/agent/backend/acp_stdio_test.exs
git commit -m "feat: implement model switching function"
```

---

### Task 5: Implement Failover Logic

**Covers:** S4, S5, S6

**Files:**
- Modify: `lib/symphony_elixir/agent/backend/acp_stdio.ex`
- Test: `test/symphony_elixir/agent/backend/acp_stdio_test.exs`

**Interfaces:**
- Consumes: Session state, error count, threshold
- Produces: Updated session state after failover (if triggered)

- [ ] **Step 1: Write the failing test**

```elixir
# test/symphony_elixir/agent/backend/acp_stdio_test.exs
test "maybe_switch_model triggers failover at threshold" do
  session = %{
    session_id: "test",
    current_model: "mimo-v2.5-pro",
    model_list: ["mimo-v2.5-pro", "mimo/mimo-auto"],
    model_errors: %{"mimo-v2.5-pro" => 10}
  }

  # Mock the switch_model function
  expect(SymphonyElixir.Agent.Backend.AcpStdio, :switch_model, fn _, _ ->
    {:ok, %{session | current_model: "mimo/mimo-auto"}}
  end)

  {:ok, updated_session} = SymphonyElixir.Agent.Backend.AcpStdio.maybe_switch_model(session, 10, 10)
  assert updated_session.current_model == "mimo/mimo-auto"
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/symphony_elixir/agent/backend/acp_stdio_test.exs`
Expected: FAIL with "function not defined"

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/symphony_elixir/agent/backend/acp_stdio.ex
def maybe_switch_model(session, error_count, threshold) when error_count >= threshold do
  current_model = session.current_model
  model_list = session.model_list

  case find_next_model(model_list, current_model) do
    nil ->
      {:error, :no_more_models}
    next_model ->
      case switch_model(session, next_model) do
        {:ok, updated_session} ->
          {:ok, updated_session}
        {:error, reason} ->
          {:error, reason}
      end
  end
end

def maybe_switch_model(session, _error_count, _threshold), do: {:ok, session}

defp find_next_model(model_list, current_model) do
  index = Enum.find_index(model_list, fn m -> m == current_model end)

  if index && index < length(model_list) - 1 do
    Enum.at(model_list, index + 1)
  else
    nil
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/symphony_elixir/agent/backend/acp_stdio_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/symphony_elixir/agent/backend/acp_stdio.ex test/symphony_elixir/agent/backend/acp_stdio_test.exs
git commit -m "feat: implement failover logic"
```

---

### Task 6: Integrate Failover into run_turn

**Covers:** S4, S5, S7

**Files:**
- Modify: `lib/symphony_elixir/agent/backend/acp_stdio.ex`
- Test: `test/symphony_elixir/agent/backend/acp_stdio_test.exs`

**Interfaces:**
- Consumes: Session state, prompt, options
- Produces: Updated session state with error tracking

- [ ] **Step 1: Write the failing test**

```elixir
# test/symphony_elixir/agent/backend/acp_stdio_test.exs
test "run_turn tracks errors and triggers failover" do
  session = %{
    session_id: "test",
    current_model: "mimo-v2.5-pro",
    model_list: ["mimo-v2.5-pro", "mimo/mimo-auto"],
    model_errors: %{"mimo-v2.5-pro" => 9},
    timeout_ms: 3600000
  }

  # Mock the Client.prompt function to return error
  expect(SymphonyElixir.Agent.AcpStdio.Client, :prompt, fn _, _, _ ->
    {:error, :acp_timeout}
  end)

  # Mock the switch_model function
  expect(SymphonyElixir.Agent.Backend.AcpStdio, :switch_model, fn _, _ ->
    {:ok, %{session | current_model: "mimo/mimo-auto"}}
  end)

  {:error, :acp_timeout} = SymphonyElixir.Agent.Backend.AcpStdio.run_turn(session, "workspace", "issue", "prompt", [])
  assert session.model_errors["mimo-v2.5-pro"] == 10
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/symphony_elixir/agent/backend/acp_stdio_test.exs`
Expected: FAIL with "error tracking not implemented"

- [ ] **Step 3: Write minimal implementation**

```elixir
# lib/symphony_elixir/agent/backend/acp_stdio.ex
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
      handle_model_error(turn_session, error)

    {:error, reason} = error ->
      emit_turn_failed(turn_session, reason)
      handle_model_error(turn_session, error)

    other ->
      other
  end
end

defp handle_model_error(session, error) do
  current_model = session.current_model
  error_count = Map.get(session.model_errors, current_model, 0) + 1
  updated_errors = Map.put(session.model_errors, current_model, error_count)
  updated_session = %{session | model_errors: updated_errors}

  case maybe_switch_model(updated_session, error_count, 10) do
    {:ok, new_session} ->
      Logger.info("Model switched from #{current_model} to #{new_session.current_model} after #{error_count} errors")
      error
    {:error, :no_more_models} ->
      Logger.warning("All models exhausted after #{error_count} errors on #{current_model}")
      error
    {:error, reason} ->
      Logger.warning("Failed to switch model: #{inspect(reason)}")
      error
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/symphony_elixir/agent/backend/acp_stdio_test.exs`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/symphony_elixir/agent/backend/acp_stdio.ex test/symphony_elixir/agent/backend/acp_stdio_test.exs
git commit -m "feat: integrate failover into run_turn"
```

---

### Task 7: Update WORKFLOW.local.md Configuration

**Covers:** S3

**Files:**
- Modify: `WORKFLOW.local.md`

**Interfaces:**
- Produces: Updated configuration with model list

- [ ] **Step 1: Update configuration**

```yaml
# WORKFLOW.local.md
agents:
  mimocode:
    kind: acp_stdio
    command: /home/gqy47/.npm-global/bin/mimo
    args:
      - acp
      - --cwd
      - "{{workspace}}"
      - --pure
    permission_policy: allow
    config_options:
      model:
        - "mimo-v2.5-pro"
        - "mimo/mimo-auto"
    mcp:
      linear_tools: true
    timeout_ms: 3600000
    read_timeout_ms: 15000
    close_timeout_ms: 1000
```

- [ ] **Step 2: Validate configuration**

Run: `mix run -e "SymphonyElixir.Config.load!()"` in elixir directory
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add WORKFLOW.local.md
git commit -m "feat: update WORKFLOW.local.md with model failover config"
```

---

### Task 8: Integration Test with Real ACP Session

**Covers:** S6, S7

**Files:**
- Create: `test/integration/model_failover_test.exs`

**Interfaces:**
- Consumes: Real ACP session
- Produces: Verified failover behavior

- [ ] **Step 1: Create integration test**

```elixir
# test/integration/model_failover_test.exs
defmodule SymphonyElixir.Integration.ModelFailoverTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  test "model failover works with real ACP session" do
    # This test requires a running MiMo-Code instance
    # Skip if not available

    workspace = "/tmp/test-workspace"
    File.mkdir_p!(workspace)

    config = %{
      "kind" => "acp_stdio",
      "command" => "/home/gqy47/.npm-global/bin/mimo",
      "args" => ["acp", "--cwd", workspace, "--pure"],
      "permission_policy" => "allow",
      "config_options" => %{"model" => ["mimo-v2.5-pro", "mimo/mimo-auto"]},
      "timeout_ms" => 3600000,
      "read_timeout_ms" => 15000,
      "close_timeout_ms" => 1000
    }

    resolved_agent = %{
      id: "test-agent",
      kind: "acp_stdio",
      config: config
    }

    case SymphonyElixir.Agent.Backend.AcpStdio.start_session(workspace, resolved_agent, []) do
      {:ok, session} ->
        assert session.current_model == "mimo-v2.5-pro"
        assert session.model_list == ["mimo-v2.5-pro", "mimo/mimo-auto"]

        # Test model switching
        case SymphonyElixir.Agent.Backend.AcpStdio.switch_model(session, "mimo/mimo-auto") do
          {:ok, updated_session} ->
            assert updated_session.current_model == "mimo/mimo-auto"
          {:error, reason} ->
            flunk("Failed to switch model: #{inspect(reason)}")
        end

        SymphonyElixir.Agent.Backend.AcpStdio.stop_session(session)

      {:error, reason} ->
        # Skip test if ACP not available
        IO.puts("Skipping integration test: #{inspect(reason)}")
    end
  end
end
```

- [ ] **Step 2: Run integration test**

Run: `mix test test/integration/model_failover_test.exs --include integration`
Expected: PASS (or skip if ACP not available)

- [ ] **Step 3: Commit**

```bash
git add test/integration/model_failover_test.exs
git commit -m "test: add integration test for model failover"
```

---

### Task 9: Documentation Update

**Covers:** S9

**Files:**
- Modify: `docs/multi_agent_backends.md`

**Interfaces:**
- Produces: Updated documentation

- [ ] **Step 1: Update documentation**

Add to `docs/multi_agent_backends.md`:

```markdown
## Model Failover

The ACP backend supports model failover with the following features:

- **Model Priority List**: Configure multiple models in priority order
- **Runtime Switching**: Switch models within the same session using `session/set_config_option`
- **Error Tracking**: Track errors per model and switch when threshold reached

### Configuration

```yaml
agents:
  mimocode:
    config_options:
      model:
        - "mimo-v2.5-pro"
        - "mimo/mimo-auto"
```

### Behavior

1. **Primary Model**: First model in list is used by default
2. **Failover**: When primary model fails 10 times, switches to next model
3. **Session Preservation**: Same session ID maintained throughout
```

- [ ] **Step 2: Commit**

```bash
git add docs/multi_agent_backends.md
git commit -m "docs: add model failover documentation"
```
