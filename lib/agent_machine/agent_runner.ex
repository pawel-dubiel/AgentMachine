defmodule AgentMachine.AgentRunner do
  @moduledoc false

  alias AgentMachine.{Agent, AgentResult, DelegationResponse, ToolPolicy, Usage, UsageLedger}

  def run(%Agent{} = agent, opts) when is_list(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    attempt = Keyword.fetch!(opts, :attempt)
    _run_context = Keyword.fetch!(opts, :run_context)
    started_at = DateTime.utc_now()

    execute(agent, opts, run_id, attempt, started_at)
  end

  defp execute(agent, opts, run_id, attempt, started_at) do
    case complete_agent(agent, opts, run_id, attempt) do
      {:ok, %{payload: %{output: output} = payload, usage: provider_usage} = completion}
      when is_binary(output) ->
        payload = DelegationResponse.normalize_payload!(agent, payload)
        output = payload.output
        usage = Usage.from_provider!(agent, run_id, provider_usage)
        next_agents = next_agents_from_payload!(payload)
        artifacts = artifacts_from_payload!(payload)
        :ok = UsageLedger.record!(usage)

        %AgentResult{
          run_id: run_id,
          agent_id: agent.id,
          status: :ok,
          attempt: attempt,
          output: output,
          next_agents: next_agents,
          artifacts: artifacts,
          tool_results: completion.tool_results,
          events: completion.events,
          usage: usage,
          started_at: started_at,
          finished_at: DateTime.utc_now()
        }

      {:error, reason, events} ->
        %AgentResult{
          run_id: run_id,
          agent_id: agent.id,
          status: :error,
          attempt: attempt,
          error: reason,
          events: events,
          started_at: started_at,
          finished_at: DateTime.utc_now()
        }

      {:invalid, other} ->
        error(
          agent,
          run_id,
          attempt,
          started_at,
          "provider returned invalid success payload: #{inspect(other)}"
        )

      {:provider_error, reason} ->
        error(agent, run_id, attempt, started_at, inspect(reason))
    end
  rescue
    exception ->
      %AgentResult{
        run_id: run_id,
        agent_id: agent.id,
        status: :error,
        attempt: attempt,
        error: Exception.format(:error, exception, __STACKTRACE__),
        events: [],
        started_at: started_at,
        finished_at: DateTime.utc_now()
      }
  end

  defp error(agent, run_id, attempt, started_at, reason) do
    %AgentResult{
      run_id: run_id,
      agent_id: agent.id,
      status: :error,
      attempt: attempt,
      error: reason,
      events: [],
      started_at: started_at,
      finished_at: DateTime.utc_now()
    }
  end

  defp complete_agent(agent, opts, run_id, attempt) do
    context = %{run_id: run_id, attempt: attempt}

    state = %{
      round: 0,
      usage: empty_usage(),
      tool_results: %{},
      tool_call_ids: MapSet.new(),
      events: []
    }

    do_complete_agent(agent, opts, context, state)
  end

  defp do_complete_agent(agent, opts, context, state) do
    case agent.provider.complete(agent, opts) do
      {:ok, %{output: output, usage: provider_usage} = payload} when is_binary(output) ->
        state = %{state | usage: sum_usage!(state.usage, provider_usage)}
        tool_calls = tool_calls_from_payload!(payload)

        if tool_calls == [] do
          {:ok,
           %{
             payload: payload,
             usage: state.usage,
             tool_results: state.tool_results,
             events: state.events
           }}
        else
          continue_after_tool_calls(agent, opts, context, state, payload, tool_calls)
        end

      {:ok, other} ->
        {:invalid, other}

      {:error, reason} ->
        {:provider_error, reason}

      other ->
        {:invalid, other}
    end
  end

  defp continue_after_tool_calls(agent, opts, context, state, payload, tool_calls) do
    max_rounds = tool_max_rounds_from_opts!(opts)

    if state.round >= max_rounds do
      {:error, "provider exceeded :tool_max_rounds #{max_rounds}", state.events}
    else
      with {:ok, tool_state} <- tool_state_from_payload(payload),
           {:ok, tool_call_ids} <- validate_new_tool_call_ids(tool_calls, state.tool_call_ids),
           {:ok, round_results, round_events} <-
             run_tool_calls(
               tool_calls,
               opts,
               context.run_id,
               agent.id,
               context.attempt,
               state.round + 1
             ) do
        continuation = %{state: tool_state, results: round_results}
        opts = Keyword.put(opts, :tool_continuation, continuation)

        state = %{
          state
          | round: state.round + 1,
            tool_results: merge_tool_results!(state.tool_results, round_results),
            tool_call_ids: tool_call_ids,
            events: state.events ++ round_events
        }

        do_complete_agent(agent, opts, context, state)
      else
        {:error, reason} -> {:error, reason, state.events}
        {:error, reason, round_events} -> {:error, reason, state.events ++ round_events}
      end
    end
  end

  defp next_agents_from_payload!(payload) when is_map(payload) do
    case fetch_optional_payload_field(payload, :next_agents) do
      :error ->
        []

      {:ok, specs} when is_list(specs) ->
        Enum.map(specs, &Agent.new!/1)

      {:ok, specs} ->
        raise ArgumentError,
              "provider next_agents must be a list of agent specs, got: #{inspect(specs)}"
    end
  end

  defp artifacts_from_payload!(payload) when is_map(payload) do
    case fetch_optional_payload_field(payload, :artifacts) do
      :error ->
        %{}

      {:ok, artifacts} when is_map(artifacts) ->
        artifacts

      {:ok, artifacts} ->
        raise ArgumentError, "provider artifacts must be a map, got: #{inspect(artifacts)}"
    end
  end

  defp tool_calls_from_payload!(payload) when is_map(payload) do
    case fetch_optional_payload_field(payload, :tool_calls) do
      :error ->
        []

      {:ok, []} ->
        []

      {:ok, tool_calls} when is_list(tool_calls) ->
        tool_calls

      {:ok, tool_calls} ->
        raise ArgumentError, "provider tool_calls must be a list, got: #{inspect(tool_calls)}"
    end
  end

  defp tool_state_from_payload(payload) do
    case fetch_optional_payload_field(payload, :tool_state) do
      {:ok, state} -> {:ok, state}
      :error -> {:error, "provider tool_calls require provider tool_state"}
    end
  end

  defp allowed_tools_from_opts!(opts) do
    case Keyword.fetch(opts, :allowed_tools) do
      {:ok, allowed_tools} when is_list(allowed_tools) ->
        Enum.each(allowed_tools, &require_tool_module!/1)
        allowed_tools

      {:ok, allowed_tools} ->
        raise ArgumentError,
              ":allowed_tools must be a list of tool modules, got: #{inspect(allowed_tools)}"

      :error ->
        raise ArgumentError, "provider tool_calls require explicit :allowed_tools option"
    end
  end

  defp tool_timeout_ms_from_opts!(opts) do
    case Keyword.fetch(opts, :tool_timeout_ms) do
      {:ok, timeout_ms} when is_integer(timeout_ms) and timeout_ms > 0 ->
        timeout_ms

      {:ok, timeout_ms} ->
        raise ArgumentError,
              ":tool_timeout_ms must be a positive integer, got: #{inspect(timeout_ms)}"

      :error ->
        raise ArgumentError, "provider tool_calls require explicit :tool_timeout_ms option"
    end
  end

  defp tool_max_rounds_from_opts!(opts) do
    case Keyword.fetch(opts, :tool_max_rounds) do
      {:ok, max_rounds} when is_integer(max_rounds) and max_rounds > 0 ->
        max_rounds

      {:ok, max_rounds} ->
        raise ArgumentError,
              ":tool_max_rounds must be a positive integer, got: #{inspect(max_rounds)}"

      :error ->
        raise ArgumentError, "provider tool_calls require explicit :tool_max_rounds option"
    end
  end

  defp run_tool_calls(tool_calls, opts, run_id, agent_id, attempt, round) do
    allowed_tools = allowed_tools_from_opts!(opts)
    tool_policy = tool_policy_from_opts!(opts)
    tool_timeout_ms = tool_timeout_ms_from_opts!(opts)

    Enum.reduce_while(tool_calls, {:ok, [], []}, fn tool_call, {:ok, results, events} ->
      case run_tool_call(tool_call, opts, allowed_tools, tool_policy, tool_timeout_ms, %{
             run_id: run_id,
             agent_id: agent_id,
             attempt: attempt,
             round: round
           }) do
        {:ok, result, call_events} ->
          {:cont, {:ok, results ++ [result], events ++ call_events}}

        {:error, reason, call_events} ->
          {:halt, {:error, reason, events ++ call_events}}
      end
    end)
  end

  defp run_tool_call(tool_call, opts, allowed_tools, tool_policy, tool_timeout_ms, event_context)
       when is_map(tool_call) do
    started_at = DateTime.utc_now()
    id = safe_tool_call_id(tool_call)
    tool = safe_tool_call_tool(tool_call)

    with {:ok, id} <- validate_tool_call_id(id),
         {:ok, tool} <- validate_tool_module(tool),
         :ok <- validate_allowed_tool(tool, allowed_tools),
         :ok <- validate_tool_permission(tool_policy, tool),
         {:ok, input} <- validate_tool_input(safe_tool_call_input(tool_call)) do
      do_run_tool_call(tool, id, input, opts, tool_timeout_ms, event_context, started_at)
    else
      {:error, reason} ->
        failed_tool_call(opts, event_context, id, tool, started_at, reason)
    end
  end

  defp run_tool_call(
         tool_call,
         _opts,
         _allowed_tools,
         _tool_policy,
         _tool_timeout_ms,
         _event_context
       ) do
    raise ArgumentError, "tool call must be a map, got: #{inspect(tool_call)}"
  end

  defp do_run_tool_call(tool, id, input, opts, tool_timeout_ms, event_context, started_at) do
    started_event = tool_call_started_event(event_context, id, tool, started_at)
    emit_event!(opts, started_event)

    case run_tool_with_timeout(tool, input, opts, tool_timeout_ms) do
      {:ok, result} when is_map(result) ->
        finished_at = DateTime.utc_now()

        finished_event =
          tool_call_finished_event(event_context, id, tool, started_at, finished_at)

        emit_event!(opts, finished_event)
        {:ok, %{id: id, result: result}, [started_event, finished_event]}

      {:ok, result} ->
        reason = "tool #{inspect(tool)} returned invalid result: #{inspect(result)}"
        failed_tool_call(opts, event_context, id, tool, started_at, reason)

      {:error, reason} ->
        reason = "tool #{inspect(tool)} failed for call #{inspect(id)}: #{inspect(reason)}"
        failed_tool_call(opts, event_context, id, tool, started_at, reason)

      other ->
        reason = "tool #{inspect(tool)} returned invalid payload: #{inspect(other)}"
        failed_tool_call(opts, event_context, id, tool, started_at, reason)
    end
  end

  defp run_tool_call(tool_call, _opts, _allowed_tools, _tool_timeout_ms, _event_context) do
    raise ArgumentError, "tool call must be a map, got: #{inspect(tool_call)}"
  end

  defp run_tool_with_timeout(tool, input, opts, tool_timeout_ms) do
    task = Task.async(fn -> tool.run(input, opts) end)

    case Task.yield(task, tool_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        {:error, "timed out after #{tool_timeout_ms}ms"}
    end
  end

  defp failed_tool_call(opts, event_context, id, tool, started_at, reason) do
    finished_at = DateTime.utc_now()

    failed_event =
      tool_call_failed_event(event_context, id, tool, started_at, finished_at, reason)

    emit_event!(opts, failed_event)
    {:error, reason, [tool_call_started_event(event_context, id, tool, started_at), failed_event]}
  end

  defp validate_new_tool_call_ids(tool_calls, seen_ids) do
    ids =
      Enum.map(tool_calls, fn
        tool_call when is_map(tool_call) -> fetch_tool_call_field!(tool_call, :id)
        tool_call -> raise ArgumentError, "tool call must be a map, got: #{inspect(tool_call)}"
      end)

    duplicates =
      ids
      |> Enum.frequencies()
      |> Enum.filter(fn {_id, count} -> count > 1 end)
      |> Enum.map(fn {id, _count} -> id end)

    repeated =
      ids
      |> Enum.filter(&MapSet.member?(seen_ids, &1))
      |> Enum.uniq()

    cond do
      duplicates != [] ->
        {:error, "tool call ids must be unique, duplicates: #{inspect(duplicates)}"}

      repeated != [] ->
        {:error, "tool call ids must be globally unique, repeated: #{inspect(repeated)}"}

      true ->
        {:ok, Enum.reduce(ids, seen_ids, &MapSet.put(&2, &1))}
    end
  end

  defp fetch_tool_call_field!(tool_call, field) do
    case fetch_optional_payload_field(tool_call, field) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "tool call is missing required field: #{inspect(field)}"
    end
  end

  defp safe_tool_call_id(tool_call) do
    case fetch_optional_payload_field(tool_call, :id) do
      {:ok, id} -> id
      :error -> "missing-tool-call-id"
    end
  end

  defp safe_tool_call_tool(tool_call) do
    case fetch_optional_payload_field(tool_call, :tool) do
      {:ok, tool} -> tool
      :error -> nil
    end
  end

  defp safe_tool_call_input(tool_call) do
    case fetch_optional_payload_field(tool_call, :input) do
      {:ok, input} -> input
      :error -> nil
    end
  end

  defp validate_tool_call_id(value) when is_binary(value) and byte_size(value) > 0 do
    {:ok, value}
  end

  defp validate_tool_call_id(value) do
    {:error, "tool call id must be a non-empty binary, got: #{inspect(value)}"}
  end

  defp require_tool_module!(tool) do
    case validate_tool_module(tool) do
      {:ok, _tool} -> :ok
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  defp validate_tool_module(tool) when is_atom(tool) do
    if Code.ensure_loaded?(tool) and function_exported?(tool, :run, 2) do
      {:ok, tool}
    else
      {:error, "tool must be a loaded module exporting run/2, got: #{inspect(tool)}"}
    end
  end

  defp validate_tool_module(tool) do
    {:error, "tool must be a module atom, got: #{inspect(tool)}"}
  end

  defp validate_allowed_tool(tool, allowed_tools) do
    if tool in allowed_tools do
      :ok
    else
      {:error, "tool #{inspect(tool)} is not in :allowed_tools"}
    end
  end

  defp validate_tool_permission(tool_policy, tool) do
    case ToolPolicy.permit!(tool_policy, tool) do
      :ok -> :ok
    end
  rescue
    exception in ArgumentError -> {:error, Exception.message(exception)}
  end

  defp validate_tool_input(input) when is_map(input), do: {:ok, input}

  defp validate_tool_input(input) do
    {:error, "tool input must be a map, got: #{inspect(input)}"}
  end

  defp tool_policy_from_opts!(opts) do
    case Keyword.fetch(opts, :tool_policy) do
      {:ok, %ToolPolicy{} = policy} ->
        policy

      {:ok, policy} ->
        raise ArgumentError,
              ":tool_policy must be an AgentMachine.ToolPolicy, got: #{inspect(policy)}"

      :error ->
        raise ArgumentError, "provider tool_calls require explicit :tool_policy option"
    end
  end

  defp merge_tool_results!(tool_results, round_results) do
    Enum.reduce(round_results, tool_results, fn %{id: id, result: result}, acc ->
      Map.put(acc, id, result)
    end)
  end

  defp empty_usage do
    %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
  end

  defp sum_usage!(left, right) do
    %{
      input_tokens: usage_integer!(left, :input_tokens) + usage_integer!(right, :input_tokens),
      output_tokens: usage_integer!(left, :output_tokens) + usage_integer!(right, :output_tokens),
      total_tokens: usage_integer!(left, :total_tokens) + usage_integer!(right, :total_tokens)
    }
  end

  defp usage_integer!(usage, field) when is_map(usage) do
    value =
      cond do
        Map.has_key?(usage, field) -> Map.fetch!(usage, field)
        Map.has_key?(usage, Atom.to_string(field)) -> Map.fetch!(usage, Atom.to_string(field))
        true -> raise ArgumentError, "provider usage is missing required field: #{inspect(field)}"
      end

    if is_integer(value) and value >= 0 do
      value
    else
      raise ArgumentError,
            "provider usage #{inspect(field)} must be a non-negative integer, got: #{inspect(value)}"
    end
  end

  defp tool_call_started_event(context, id, tool, at) do
    %{
      type: :tool_call_started,
      run_id: context.run_id,
      agent_id: context.agent_id,
      attempt: context.attempt,
      round: context.round,
      tool_call_id: id,
      tool: tool_name(tool),
      status: :running,
      at: at
    }
  end

  defp tool_call_finished_event(context, id, tool, started_at, finished_at) do
    %{
      type: :tool_call_finished,
      run_id: context.run_id,
      agent_id: context.agent_id,
      attempt: context.attempt,
      round: context.round,
      tool_call_id: id,
      tool: tool_name(tool),
      status: :ok,
      duration_ms: duration_ms(started_at, finished_at),
      at: finished_at
    }
  end

  defp tool_call_failed_event(context, id, tool, started_at, finished_at, reason) do
    %{
      type: :tool_call_failed,
      run_id: context.run_id,
      agent_id: context.agent_id,
      attempt: context.attempt,
      round: context.round,
      tool_call_id: id,
      tool: tool_name(tool),
      status: :error,
      duration_ms: duration_ms(started_at, finished_at),
      reason: reason,
      at: finished_at
    }
  end

  defp emit_event!(opts, event) do
    case Keyword.fetch(opts, :event_sink) do
      :error -> :ok
      {:ok, sink} -> sink.(event)
    end
  end

  defp duration_ms(started_at, finished_at) do
    DateTime.diff(finished_at, started_at, :millisecond)
  end

  defp tool_name(tool) do
    if function_exported?(tool, :definition, 0) do
      tool.definition().name
    else
      inspect(tool)
    end
  end

  defp tool_name(tool), do: inspect(tool)

  defp fetch_optional_payload_field(payload, field) do
    string_field = Atom.to_string(field)

    cond do
      Map.has_key?(payload, field) -> {:ok, Map.fetch!(payload, field)}
      Map.has_key?(payload, string_field) -> {:ok, Map.fetch!(payload, string_field)}
      true -> :error
    end
  end
end
