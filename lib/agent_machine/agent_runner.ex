defmodule AgentMachine.AgentRunner do
  @moduledoc false

  alias AgentMachine.{
    Agent,
    AgentResult,
    DelegationResponse,
    MCP.Session,
    ToolHarness,
    ToolPolicy,
    Usage,
    UsageLedger
  }

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
        decision = decision_from_payload!(payload)
        next_agents = next_agents_from_payload!(payload)
        artifacts = artifacts_from_payload!(payload)
        :ok = UsageLedger.record!(usage)

        %AgentResult{
          run_id: run_id,
          agent_id: agent.id,
          status: :ok,
          attempt: attempt,
          output: output,
          decision: decision,
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

      {:provider_error, %{reason: reason, events: events}} ->
        %AgentResult{
          run_id: run_id,
          agent_id: agent.id,
          status: :error,
          attempt: attempt,
          error: inspect(reason),
          events: events,
          started_at: started_at,
          finished_at: DateTime.utc_now()
        }

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

    with_mcp_session(agent, opts, fn opts ->
      do_complete_agent(agent, opts, context, state)
    end)
  end

  defp with_mcp_session(agent, opts, callback) do
    if mcp_session_required?(agent, opts) do
      {:ok, session} = Session.start_link(Keyword.fetch!(opts, :mcp_config))

      try do
        callback.(Keyword.put(opts, :mcp_session, session))
      after
        if Process.alive?(session) do
          GenServer.stop(session)
        end
      end
    else
      callback.(opts)
    end
  end

  defp mcp_session_required?(%Agent{} = agent, opts) do
    Keyword.has_key?(opts, :mcp_config) and Keyword.has_key?(opts, :allowed_tools) and
      not tools_disabled?(agent)
  end

  defp do_complete_agent(agent, opts, context, state) do
    opts = maybe_disable_tools(agent, opts)

    case complete_provider(agent, opts, context) do
      {:ok,
       %{payload: %{output: output, usage: provider_usage} = payload, events: provider_events}}
      when is_binary(output) ->
        state = %{state | usage: sum_usage!(state.usage, provider_usage)}
        state = %{state | events: state.events ++ provider_events}
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

      {:ok, %{payload: other, events: provider_events}} ->
        {:invalid, %{payload: other, events: provider_events}}

      {:error, reason, provider_events} ->
        {:provider_error, %{reason: reason, events: provider_events}}

      other ->
        {:invalid, other}
    end
  end

  defp complete_provider(agent, opts, context) do
    started_at = DateTime.utc_now()
    started_event = provider_request_started_event(context, agent, started_at)
    emit_event!(opts, started_event)

    ref = make_ref()
    owner = self()

    stream_sink = fn event ->
      emit_event!(opts, event)
      send(owner, {ref, event})
    end

    provider_opts =
      opts
      |> Keyword.put(:stream_event_sink, stream_sink)
      |> Keyword.put(:stream_context, Map.merge(context, %{agent_id: agent.id}))

    result =
      if Keyword.get(opts, :stream_response, false) do
        stream_complete_provider(agent, provider_opts)
      else
        agent.provider.complete(agent, opts)
      end

    stream_events = drain_stream_events(ref, [])

    case result do
      {:ok, %{output: output, usage: _provider_usage} = payload} when is_binary(output) ->
        finished_at = DateTime.utc_now()
        finished_event = provider_request_finished_event(context, agent, started_at, finished_at)
        emit_event!(opts, finished_event)
        {:ok, %{payload: payload, events: [started_event] ++ stream_events ++ [finished_event]}}

      {:ok, other} ->
        finished_at = DateTime.utc_now()

        failed_event =
          provider_request_failed_event(
            context,
            agent,
            started_at,
            finished_at,
            "invalid provider payload"
          )

        emit_event!(opts, failed_event)
        {:ok, %{payload: other, events: [started_event] ++ stream_events ++ [failed_event]}}

      {:error, reason} ->
        finished_at = DateTime.utc_now()

        failed_event =
          provider_request_failed_event(context, agent, started_at, finished_at, inspect(reason))

        emit_event!(opts, failed_event)
        {:error, reason, [started_event] ++ stream_events ++ [failed_event]}
    end
  end

  defp stream_complete_provider(%Agent{provider: provider} = agent, opts) do
    if function_exported?(provider, :stream_complete, 2) do
      provider.stream_complete(agent, opts)
    else
      {:error, "provider #{inspect(provider)} does not support streaming responses"}
    end
  end

  defp drain_stream_events(ref, acc) do
    receive do
      {^ref, event} -> drain_stream_events(ref, [event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp maybe_disable_tools(%Agent{metadata: metadata}, opts) when is_map(metadata) do
    if tools_disabled?(metadata) do
      opts
      |> put_disabled_tool_context()
      |> Keyword.delete(:allowed_tools)
      |> Keyword.delete(:tool_policy)
      |> Keyword.delete(:tool_timeout_ms)
      |> Keyword.delete(:tool_max_rounds)
      |> Keyword.delete(:tool_approval_mode)
    else
      opts
    end
  end

  defp maybe_disable_tools(_agent, opts), do: opts

  defp tools_disabled?(%Agent{metadata: metadata}) when is_map(metadata),
    do: tools_disabled?(metadata)

  defp tools_disabled?(%Agent{}), do: false

  defp tools_disabled?(metadata) when is_map(metadata) do
    Map.get(metadata, :agent_machine_disable_tools) == true ||
      Map.get(metadata, "agent_machine_disable_tools") == true
  end

  defp put_disabled_tool_context(opts) do
    case Keyword.fetch(opts, :allowed_tools) do
      {:ok, tools} when is_list(tools) and tools != [] ->
        put_disabled_tool_context!(opts, tools)

      _other ->
        opts
    end
  rescue
    ArgumentError -> opts
  end

  defp put_disabled_tool_context!(opts, tools) do
    policy = Keyword.fetch!(opts, :tool_policy)

    Keyword.put(opts, :tool_context, %{
      harness: disabled_tool_harness!(policy),
      root: Keyword.get(opts, :tool_root),
      approval_mode: Keyword.fetch!(opts, :tool_approval_mode),
      available_tools: disabled_tool_names!(tools),
      test_commands: Keyword.get(opts, :test_commands, []),
      instruction:
        "Tools are available to worker agents only. You cannot call tools in this agent. If the task needs filesystem side effects, delegate the exact action to a worker and require the worker to use tools. Do not claim file or directory changes unless worker tool_results confirm them."
    })
  end

  defp disabled_tool_harness!(%ToolPolicy{harness: harness}) when is_atom(harness),
    do: Atom.to_string(harness)

  defp disabled_tool_harness!(%ToolPolicy{harness: harnesses}) when is_list(harnesses) do
    Enum.map(harnesses, &Atom.to_string/1)
  end

  defp disabled_tool_harness!(policy) do
    raise ArgumentError, ":tool_policy must include a harness, got: #{inspect(policy)}"
  end

  defp disabled_tool_names!(tools) do
    tools
    |> ToolHarness.definitions!()
    |> Enum.map(& &1.name)
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

  defp decision_from_payload!(payload) when is_map(payload) do
    case fetch_optional_payload_field(payload, :decision) do
      :error ->
        nil

      {:ok, decision} when is_map(decision) ->
        decision

      {:ok, decision} ->
        raise ArgumentError, "provider decision must be a map, got: #{inspect(decision)}"
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
    tool_approval_mode = tool_approval_mode_from_opts!(opts)
    tool_timeout_ms = tool_timeout_ms_from_opts!(opts)

    Enum.reduce_while(tool_calls, {:ok, [], []}, fn tool_call, {:ok, results, events} ->
      case run_tool_call(
             tool_call,
             opts,
             allowed_tools,
             tool_policy,
             tool_approval_mode,
             tool_timeout_ms,
             %{
               run_id: run_id,
               agent_id: agent_id,
               attempt: attempt,
               round: round
             }
           ) do
        {:ok, result, call_events} ->
          {:cont, {:ok, results ++ [result], events ++ call_events}}

        {:error, reason, call_events} ->
          {:halt, {:error, reason, events ++ call_events}}
      end
    end)
  end

  defp run_tool_call(
         tool_call,
         opts,
         allowed_tools,
         tool_policy,
         tool_approval_mode,
         tool_timeout_ms,
         event_context
       )
       when is_map(tool_call) do
    started_at = DateTime.utc_now()
    id = safe_tool_call_id(tool_call)
    tool = safe_tool_call_tool(tool_call)

    with {:ok, id} <- validate_tool_call_id(id),
         {:ok, tool} <- validate_tool_module(tool),
         :ok <- validate_allowed_tool(tool, allowed_tools),
         :ok <- validate_tool_permission(tool_policy, tool),
         {:ok, input} <- validate_tool_input(safe_tool_call_input(tool_call)),
         :ok <- validate_tool_approval(opts, tool_approval_mode, tool, id, input, event_context) do
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
         _tool_approval_mode,
         _tool_timeout_ms,
         _event_context
       ) do
    raise ArgumentError, "tool call must be a map, got: #{inspect(tool_call)}"
  end

  defp do_run_tool_call(tool, id, input, opts, tool_timeout_ms, event_context, started_at) do
    started_event = tool_call_started_event(event_context, id, tool, started_at, opts, input)
    emit_event!(opts, started_event)

    case run_tool_with_timeout(tool, input, opts, tool_timeout_ms) do
      {:ok, result} when is_map(result) ->
        finished_at = DateTime.utc_now()

        finished_event =
          tool_call_finished_event(event_context, id, tool, started_at, finished_at, opts, result)

        emit_event!(opts, finished_event)
        {:ok, %{id: id, result: result}, [started_event, finished_event]}

      {:ok, result} ->
        reason = "tool #{inspect(tool)} returned invalid result: #{inspect(result)}"
        failed_tool_call(opts, event_context, id, tool, started_at, reason, false)

      {:error, reason} ->
        recoverable_tool_call_failure(
          opts,
          event_context,
          id,
          tool,
          started_at,
          started_event,
          reason
        )

      other ->
        reason = "tool #{inspect(tool)} returned invalid payload: #{inspect(other)}"
        failed_tool_call(opts, event_context, id, tool, started_at, reason, false)
    end
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

  defp recoverable_tool_call_failure(
         opts,
         event_context,
         id,
         tool,
         started_at,
         started_event,
         reason
       ) do
    finished_at = DateTime.utc_now()
    error = tool_error_text(reason)

    event_reason = "tool #{inspect(tool)} failed for call #{inspect(id)}: #{error}"

    failed_event =
      tool_call_failed_event(event_context, id, tool, started_at, finished_at, opts, event_reason)

    emit_event!(opts, failed_event)

    result = %{
      status: "error",
      error: error,
      tool: tool_name(tool)
    }

    {:ok, %{id: id, result: result}, [started_event, failed_event]}
  end

  defp tool_error_text(reason) when is_binary(reason), do: reason
  defp tool_error_text(reason), do: inspect(reason)

  defp failed_tool_call(opts, event_context, id, tool, started_at, reason, emit_started? \\ true) do
    finished_at = DateTime.utc_now()
    started_event = tool_call_started_event(event_context, id, tool, started_at, opts, nil)

    failed_event =
      tool_call_failed_event(event_context, id, tool, started_at, finished_at, opts, reason)

    if emit_started? do
      emit_event!(opts, started_event)
    end

    emit_event!(opts, failed_event)

    {:error, reason, [started_event, failed_event]}
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

  defp validate_tool_approval(opts, mode, tool, id, input, event_context) do
    risk = ToolPolicy.approval_risk!(tool)

    cond do
      approval_allowed?(mode, risk) ->
        :ok

      mode == :ask_before_write and risk in [:write, :delete, :command, :network] ->
        request_tool_approval(opts, tool, id, input, event_context, risk)

      true ->
        {:error,
         "tool #{inspect(tool)} with approval risk #{inspect(risk)} is not allowed by tool approval mode #{inspect(mode)}"}
    end
  rescue
    exception in ArgumentError -> {:error, Exception.message(exception)}
  end

  defp approval_allowed?(:read_only, :read), do: true
  defp approval_allowed?(:auto_approved_safe, risk) when risk in [:read, :write], do: true

  defp approval_allowed?(:full_access, risk)
       when risk in [:read, :write, :delete, :command, :network], do: true

  defp approval_allowed?(_mode, _risk), do: false

  defp request_tool_approval(opts, tool, id, input, event_context, risk) do
    case Keyword.fetch(opts, :tool_approval_callback) do
      {:ok, callback} when is_function(callback, 1) ->
        approval_context =
          Map.merge(event_context, %{tool_call_id: id, tool: tool, input: input, risk: risk})

        callback.(approval_context)
        |> approval_callback_result()

      {:ok, callback} ->
        {:error,
         ":tool_approval_callback must be a function of arity 1, got: #{inspect(callback)}"}

      :error ->
        {:error,
         "tool #{inspect(tool)} with approval risk #{inspect(risk)} requires approval for tool approval mode :ask_before_write"}
    end
  end

  defp approval_callback_result(:approved), do: :ok
  defp approval_callback_result(true), do: :ok
  defp approval_callback_result({:approved, _reason}), do: :ok

  defp approval_callback_result({:denied, reason}),
    do: {:error, "tool approval denied: #{inspect(reason)}"}

  defp approval_callback_result(false), do: {:error, "tool approval denied"}

  defp approval_callback_result(result) do
    {:error, "tool approval callback returned invalid result: #{inspect(result)}"}
  end

  defp tool_approval_mode_from_opts!(opts) do
    case Keyword.fetch(opts, :tool_approval_mode) do
      {:ok, mode}
      when mode in [:read_only, :ask_before_write, :auto_approved_safe, :full_access] ->
        mode

      {:ok, mode} ->
        raise ArgumentError,
              ":tool_approval_mode must be :read_only, :ask_before_write, :auto_approved_safe, or :full_access, got: #{inspect(mode)}"

      :error ->
        raise ArgumentError, "provider tool_calls require explicit :tool_approval_mode option"
    end
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

  defp provider_request_started_event(context, agent, at) do
    %{
      type: :provider_request_started,
      run_id: context.run_id,
      agent_id: agent.id,
      attempt: context.attempt,
      provider: provider_name(agent.provider),
      at: at
    }
  end

  defp provider_request_finished_event(context, agent, started_at, finished_at) do
    %{
      type: :provider_request_finished,
      run_id: context.run_id,
      agent_id: agent.id,
      attempt: context.attempt,
      provider: provider_name(agent.provider),
      duration_ms: duration_ms(started_at, finished_at),
      at: finished_at
    }
  end

  defp provider_request_failed_event(context, agent, started_at, finished_at, reason) do
    %{
      type: :provider_request_failed,
      run_id: context.run_id,
      agent_id: agent.id,
      attempt: context.attempt,
      provider: provider_name(agent.provider),
      duration_ms: duration_ms(started_at, finished_at),
      reason: reason,
      at: finished_at
    }
  end

  defp tool_call_started_event(context, id, tool, at, opts, input) do
    %{
      type: :tool_call_started,
      run_id: context.run_id,
      agent_id: context.agent_id,
      attempt: context.attempt,
      round: context.round,
      tool_call_id: id,
      tool: tool_name(tool),
      status: :running,
      permission: safe_tool_permission(tool),
      approval_risk: safe_tool_approval_risk(tool),
      approval_mode: Keyword.get(opts, :tool_approval_mode),
      input_summary: summarize_tool_input(input),
      at: at
    }
  end

  defp tool_call_finished_event(context, id, tool, started_at, finished_at, opts, result) do
    %{
      type: :tool_call_finished,
      run_id: context.run_id,
      agent_id: context.agent_id,
      attempt: context.attempt,
      round: context.round,
      tool_call_id: id,
      tool: tool_name(tool),
      status: :ok,
      permission: safe_tool_permission(tool),
      approval_risk: safe_tool_approval_risk(tool),
      approval_mode: Keyword.get(opts, :tool_approval_mode),
      result_summary: summarize_tool_result(result),
      duration_ms: duration_ms(started_at, finished_at),
      at: finished_at
    }
  end

  defp tool_call_failed_event(context, id, tool, started_at, finished_at, opts, reason) do
    %{
      type: :tool_call_failed,
      run_id: context.run_id,
      agent_id: context.agent_id,
      attempt: context.attempt,
      round: context.round,
      tool_call_id: id,
      tool: tool_name(tool),
      status: :error,
      permission: safe_tool_permission(tool),
      approval_risk: safe_tool_approval_risk(tool),
      approval_mode: Keyword.get(opts, :tool_approval_mode),
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

  defp tool_name(tool) when is_atom(tool) do
    if function_exported?(tool, :definition, 0) do
      tool.definition().name
    else
      inspect(tool)
    end
  end

  defp tool_name(tool), do: inspect(tool)

  defp provider_name(provider), do: provider |> Module.split() |> List.last()

  defp safe_tool_permission(tool) when is_atom(tool) do
    ToolPolicy.tool_permission!(tool)
  rescue
    ArgumentError -> nil
  end

  defp safe_tool_permission(_tool), do: nil

  defp safe_tool_approval_risk(tool) when is_atom(tool) do
    ToolPolicy.approval_risk!(tool)
  rescue
    ArgumentError -> nil
  end

  defp safe_tool_approval_risk(_tool), do: nil

  defp summarize_tool_input(input) when is_map(input) do
    %{
      keys: input |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort(),
      bytes: input |> AgentMachine.JSON.encode!() |> byte_size()
    }
  end

  defp summarize_tool_input(_input), do: nil

  defp summarize_tool_result(result) when is_map(result) do
    Map.get(result, :summary) || Map.get(result, "summary") || changed_summary(result)
  end

  defp summarize_tool_result(_result), do: nil

  defp changed_summary(result) do
    changed = Map.get(result, :changed_files) || Map.get(result, "changed_files") || []

    if is_list(changed) do
      %{changed_count: length(changed)}
    end
  end

  defp fetch_optional_payload_field(payload, field) do
    string_field = Atom.to_string(field)

    cond do
      Map.has_key?(payload, field) -> {:ok, Map.fetch!(payload, field)}
      Map.has_key?(payload, string_field) -> {:ok, Map.fetch!(payload, string_field)}
      true -> :error
    end
  end
end
