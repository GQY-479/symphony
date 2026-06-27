# [S1] Model Failover Feature Design

## Problem Statement

Current Symphony ACP backend uses a single model configuration (`mimo/mimo-auto`) that cannot failover when the model is unavailable or fails during execution. Users need:

1. **Model priority list**: Use `mimo-v2.5-pro` as primary, `mimo/mimo-auto` as fallback
2. **Runtime failover**: Switch models when errors occur during session execution
3. **Session preservation**: Maintain the same ACP session when switching models

## [S2] Solution Overview

Implement backend-level model failover in `SymphonyElixir.Agent.Backend.AcpStdio` that:

- Supports multiple models in priority order
- Monitors error counts per model
- Switches models within the same ACP session using `session/set_config_option`
- Preserves session context during model switches

## [S3] Architecture

### Configuration Format

```yaml
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

### Error Tracking

Track errors per model in the session state:

```elixir
%{
  session_id: "sess_abc123",
  model_errors: %{
    "mimo-v2.5-pro" => 0,
    "mimo/mimo-auto" => 0
  },
  current_model: "mimo-v2.5-pro",
  model_list: ["mimo-v2.5-pro", "mimo/mimo-auto"]
}
```

### Failover Logic

1. **Configuration Error**: If `session/set_config_option` fails for a model, immediately try the next model
2. **Runtime Error**: Increment error count for current model; when count reaches threshold (10), switch to next model
3. **Model Switch**: Call `session/set_config_option` with new model value within the same session

## [S4] Implementation Details

### Modified Files

1. **`lib/symphony_elixir/config/schema.ex`**
   - Update `@default_mimocode_model` to support list format
   - Add validation for model list

2. **`lib/symphony_elixir/agent/backend/acp_stdio.ex`**
   - Add error tracking state
   - Implement `maybe_switch_model/3` function
   - Modify `run_turn/5` to track errors and trigger failover

3. **`lib/symphony_elixir/agent/acp_stdio/client.ex`**
   - Modify `apply_config_options/3` to handle model list
   - Add `switch_model/3` function for runtime switching

### Key Functions

#### `maybe_switch_model(session, error_count, threshold)`

```elixir
defp maybe_switch_model(session, error_count, threshold) when error_count >= threshold do
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

defp maybe_switch_model(session, _error_count, _threshold), do: {:ok, session}
```

#### `switch_model(session, new_model)`

```elixir
defp switch_model(session, new_model) do
  params = %{
    "sessionId" => session.session_id,
    "configId" => "model",
    "value" => new_model
  }

  case request(session, "session/set_config_option", params, timeout_ms) do
    {:ok, _result} ->
      updated_session = %{session | current_model: new_model}
      {:ok, updated_session}
    {:error, reason} ->
      {:error, reason}
  end
end
```

## [S5] Error Handling

### Configuration Errors

- If all models fail during configuration, return error to caller
- Log which models failed and why

### Runtime Errors

- Track errors per model (not per session)
- Reset error count when model switches successfully
- If all models exhausted, return error to caller

### Session Errors

- If `session/set_config_option` fails during runtime switch, continue with current model
- Log the failure for debugging

## [S6] Testing Strategy

### Unit Tests

1. Test model list parsing from config
2. Test `find_next_model/2` logic
3. Test error counting and threshold logic
4. Test `switch_model/3` with mock ACP client

### Integration Tests

1. Test failover with real ACP session (if available)
2. Test session preservation during model switch
3. Test error recovery after successful switch

### Smoke Tests

1. Create test issue with model failover config
2. Verify primary model is used first
3. Simulate model failure and verify failover
4. Verify session context is preserved

## [S7] Success Criteria

1. **Configuration**: Model list is properly parsed and validated
2. **Failover**: When primary model fails, automatically switches to fallback
3. **Session Preservation**: Same session ID maintained throughout
4. **Error Tracking**: Accurate error counting per model
5. **Logging**: Clear logs showing model switches and reasons

## [S8] Risks and Mitigations

### Risk 1: ACP Protocol Compatibility

**Risk**: MiMo-Code may not support runtime model switching

**Mitigation**:
- Test with real ACP session first
- Fall back to session recreation if runtime switch fails

### Risk 2: Session State Loss

**Risk**: Model switch may affect session context

**Mitigation**:
- ACP protocol explicitly supports runtime config changes
- Test thoroughly before deployment

### Risk 3: Error Threshold Tuning

**Risk**: Threshold of 10 may be too high/low

**Mitigation**:
- Make threshold configurable
- Start with 10, adjust based on real-world usage

## [S9] Future Enhancements

1. **Configurable Model Lists**: Allow users to define custom model priority lists
2. **Performance-Based Switching**: Switch based on response time, not just errors
3. **Model Health Checks**: Proactively check model availability before use
4. **Metrics Collection**: Track model performance and failover frequency

## [S10] References

- ACP Protocol Documentation: https://agentclientprotocol.com/protocol/v1/session-config-options.md
- Symphony ACP Backend: `lib/symphony_elixir/agent/backend/acp_stdio.ex`
- ACP Client: `lib/symphony_elixir/agent/acp_stdio/client.ex`
