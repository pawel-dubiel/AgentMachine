defmodule AgentMachine.AgentRunner do
  @moduledoc false

  alias AgentMachine.{
    Agent,
    AgenticReviewResponse,
    AgentResult,
    ContextBudget,
    DelegationResponse,
    ToolHarness,
    ToolPolicy,
    ToolSessionSupervisor,
    Usage,
    UsageLedger
  }

  alias AgentMachine.MCP.{Session, ToolFactory}
  alias AgentMachine.Tools.{PathGuard, RequestCapability}

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
        payload = normalize_structured_payload!(agent, payload)
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

      {:error, reason, events, tool_results} ->
        %AgentResult{
          run_id: run_id,
          agent_id: agent.id,
          status: :error,
          attempt: attempt,
          error: reason,
          tool_results: tool_results,
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

      {:provider_error, %{reason: reason, events: events, tool_results: tool_results}} ->
        %AgentResult{
          run_id: run_id,
          agent_id: agent.id,
          status: :error,
          attempt: attempt,
          error: inspect(reason),
          tool_results: tool_results,
          events: events,
          started_at: started_at,
          finished_at: DateTime.utc_now()
        }

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

  defp normalize_structured_payload!(agent, payload) do
    if AgenticReviewResponse.applies?(agent) do
      AgenticReviewResponse.normalize_payload!(agent, payload)
    else
      DelegationResponse.normalize_payload!(agent, payload)
    end
  end

  defp complete_agent(agent, opts, run_id, attempt) do
    context = %{run_id: run_id, attempt: attempt}

    state = %{
      round: 0,
      usage: empty_usage(),
      tool_results: %{},
      tool_call_ids: MapSet.new(),
      denied_approval_fingerprints: MapSet.new(),
      failed_tool_fingerprints: MapSet.new(),
      events: []
    }

    with_mcp_session(agent, opts, fn opts ->
      do_complete_agent(agent, opts, context, state)
    end)
  end

  defp with_mcp_session(agent, opts, callback) do
    if mcp_session_required?(agent, opts) do
      {:ok, session} = start_mcp_session(agent, opts)

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

  defp start_mcp_session(agent, opts) do
    config = Keyword.fetch!(opts, :mcp_config)
    run_id = Keyword.fetch!(opts, :run_id)
    attempt = Keyword.fetch!(opts, :attempt)

    case Keyword.fetch(opts, :tool_session_supervisor) do
      {:ok, supervisor} ->
        ToolSessionSupervisor.start_mcp_session(supervisor, run_id, agent.id, attempt, config)

      :error ->
        Session.start_link({config, %{run_id: run_id, agent_id: agent.id, attempt: attempt}})
    end
  end

  defp mcp_session_required?(%Agent{} = agent, opts) do
    Keyword.has_key?(opts, :mcp_config) and Keyword.has_key?(opts, :allowed_tools) and
      not tools_disabled?(agent)
  end

  defp do_complete_agent(agent, opts, context, state) do
    opts = maybe_disable_tools(agent, opts)

    case safe_complete_provider(agent, opts, context) do
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
        {:provider_error,
         %{
           reason: reason,
           events: state.events ++ provider_events,
           tool_results: state.tool_results
         }}

      {:provider_exception, reason} ->
        error_completion(reason, state)

      other ->
        {:invalid, other}
    end
  end

  defp safe_complete_provider(agent, opts, context) do
    complete_provider(agent, opts, context)
  rescue
    exception -> {:provider_exception, Exception.format(:error, exception, __STACKTRACE__)}
  end

  defp complete_provider(agent, opts, context) do
    started_at = DateTime.utc_now()
    started_event = provider_request_started_event(context, agent, started_at)
    emit_event!(opts, started_event)
    budget_event = ContextBudget.event(agent, context, opts)
    emit_event!(opts, budget_event)

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

        {:ok,
         %{
           payload: payload,
           events: [started_event, budget_event] ++ stream_events ++ [finished_event]
         }}

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

        {:ok,
         %{
           payload: other,
           events: [started_event, budget_event] ++ stream_events ++ [failed_event]
         }}

      {:error, reason} ->
        finished_at = DateTime.utc_now()

        failed_event =
          provider_request_failed_event(context, agent, started_at, finished_at, inspect(reason))

        emit_event!(opts, failed_event)
        {:error, reason, [started_event, budget_event] ++ stream_events ++ [failed_event]}
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
        "Tools are available to worker agents only. You cannot call tools in this agent. If the task needs filesystem, MCP browser, command, or other external side effects, delegate the exact action to a worker and require the worker to use tools. Do not claim file, directory, browser, command, or external changes unless worker tool_results confirm them."
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
      error_completion("provider exceeded :tool_max_rounds #{max_rounds}", state)
    else
      with {:ok, tool_state} <- tool_state_from_payload(payload),
           {:ok, tool_call_ids} <- validate_new_tool_call_ids(tool_calls, state.tool_call_ids),
           {:ok, round_results, round_events, opts, denied_approval_fingerprints,
            failed_tool_fingerprints} <-
             run_tool_calls(
               tool_calls,
               opts,
               context.run_id,
               agent.id,
               context.attempt,
               state.round + 1,
               state.denied_approval_fingerprints,
               state.failed_tool_fingerprints
             ) do
        continuation = %{state: tool_state, results: round_results}
        opts = Keyword.put(opts, :tool_continuation, continuation)

        state = %{
          state
          | round: state.round + 1,
            tool_results: merge_tool_results!(state.tool_results, round_results),
            tool_call_ids: tool_call_ids,
            denied_approval_fingerprints: denied_approval_fingerprints,
            failed_tool_fingerprints: failed_tool_fingerprints,
            events: state.events ++ round_events
        }

        do_complete_agent(agent, opts, context, state)
      else
        {:error, reason} -> error_completion(reason, state)
        {:error, reason, round_events} -> error_completion(reason, state, round_events)
      end
    end
  end

  defp error_completion(reason, state, extra_events \\ []) do
    {:error, reason, state.events ++ extra_events, state.tool_results}
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

  defp run_tool_calls(
         tool_calls,
         opts,
         run_id,
         agent_id,
         attempt,
         round,
         denied_fingerprints,
         failed_fingerprints
       ) do
    allowed_tools = allowed_tools_from_opts!(opts)
    tool_policy = tool_policy_from_opts!(opts)
    tool_approval_mode = tool_approval_mode_from_opts!(opts)
    tool_timeout_ms = tool_timeout_ms_from_opts!(opts)

    event_context =
      %{
        run_id: run_id,
        agent_id: agent_id,
        attempt: attempt,
        round: round
      }
      |> Map.merge(agent_event_metadata(opts))

    tool_context = %{
      allowed_tools: allowed_tools,
      tool_policy: tool_policy,
      tool_approval_mode: tool_approval_mode,
      tool_timeout_ms: tool_timeout_ms,
      event_context: event_context
    }

    if capability_request_round?(tool_calls) do
      run_capability_request_round(
        tool_calls,
        opts,
        allowed_tools,
        tool_policy,
        tool_timeout_ms,
        event_context,
        denied_fingerprints,
        failed_fingerprints
      )
    else
      run_regular_tool_call_round(
        tool_calls,
        opts,
        tool_context,
        denied_fingerprints,
        failed_fingerprints
      )
    end
  end

  defp run_regular_tool_call_round(
         tool_calls,
         opts,
         tool_context,
         denied_fingerprints,
         failed_fingerprints
       ) do
    Enum.reduce_while(
      tool_calls,
      {:ok, [], [], opts, denied_fingerprints, failed_fingerprints},
      fn tool_call, {:ok, results, events, opts, denied_fingerprints, failed_fingerprints} ->
        tool_call_result =
          run_tool_call(
            tool_call,
            opts,
            tool_context,
            denied_fingerprints,
            failed_fingerprints
          )

        handle_tool_call_result(tool_call_result, results, events, opts)
      end
    )
  end

  defp handle_tool_call_result(
         {:ok, result, call_events, denied_fingerprints, failed_fingerprints},
         results,
         events,
         opts
       ) do
    {:cont,
     {:ok, results ++ [result], events ++ call_events, opts, denied_fingerprints,
      failed_fingerprints}}
  end

  defp handle_tool_call_result({:error, reason, call_events}, _results, events, _opts) do
    {:halt, {:error, reason, events ++ call_events}}
  end

  defp capability_request_round?(tool_calls) do
    Enum.any?(tool_calls, fn
      tool_call when is_map(tool_call) -> safe_tool_call_tool(tool_call) == RequestCapability
      _other -> false
    end)
  end

  defp run_capability_request_round(
         [tool_call],
         opts,
         allowed_tools,
         tool_policy,
         _tool_timeout_ms,
         event_context,
         denied_fingerprints,
         failed_fingerprints
       ) do
    started_at = DateTime.utc_now()
    id = safe_tool_call_id(tool_call)
    tool = safe_tool_call_tool(tool_call)

    with {:ok, id} <- validate_tool_call_id(id),
         {:ok, ^tool} <- validate_tool_module(tool),
         :ok <- validate_request_capability_tool(tool),
         :ok <- validate_allowed_tool(tool, allowed_tools),
         :ok <- validate_tool_permission(tool_policy, tool),
         {:ok, input} <- validate_tool_input(safe_tool_call_input(tool_call)) do
      started_event = tool_call_started_event(event_context, id, tool, started_at, opts, input)
      emit_event!(opts, started_event)

      case request_capability_grant(opts, id, input, event_context) do
        {:ok, updated_opts, result, permission_events} ->
          finished_at = DateTime.utc_now()

          finished_event =
            tool_call_finished_event(
              event_context,
              id,
              tool,
              started_at,
              finished_at,
              opts,
              result
            )

          emit_event!(opts, finished_event)

          {:ok, [%{id: id, result: result}],
           [started_event] ++ permission_events ++ [finished_event], updated_opts,
           denied_fingerprints, failed_fingerprints}

        {:denied, reason, permission_events} ->
          {:ok, result, denied_events} =
            denied_tool_call(opts, event_context, id, tool, started_at, reason)

          {:ok, [result], [started_event] ++ permission_events ++ denied_events, opts,
           denied_fingerprints, failed_fingerprints}

        {:error, reason, permission_events} ->
          {:error, reason, failed_events} =
            failed_tool_call(opts, event_context, id, tool, started_at, reason, false)

          {:error, reason, [started_event] ++ permission_events ++ failed_events}
      end
    else
      {:error, reason} ->
        failed_tool_call(opts, event_context, id, tool, started_at, reason)
    end
  end

  defp run_capability_request_round(
         tool_calls,
         _opts,
         _allowed_tools,
         _tool_policy,
         _tool_timeout_ms,
         _event_context,
         _denied_fingerprints,
         _failed_fingerprints
       ) do
    {:error,
     "request_capability must be the only tool call in its provider round, got #{length(tool_calls)} call(s)",
     []}
  end

  defp validate_request_capability_tool(RequestCapability), do: :ok

  defp validate_request_capability_tool(tool) do
    {:error,
     "request_capability round must call #{inspect(RequestCapability)}, got: #{inspect(tool)}"}
  end

  defp request_capability_grant(opts, tool_call_id, input, event_context) do
    request_id = permission_request_id(event_context.run_id, event_context.agent_id, tool_call_id)
    capability = input_value(input, "capability")
    reason = input_value(input, "reason")

    request_event =
      permission_requested_event(
        event_context,
        %{
          request_id: request_id,
          kind: :capability_grant,
          tool_call_id: tool_call_id,
          tool: tool_name(RequestCapability),
          permission: RequestCapability.permission(),
          approval_risk: RequestCapability.approval_risk(),
          approval_mode: Keyword.get(opts, :tool_approval_mode),
          capability: capability,
          requested_root: input_value(input, "root"),
          requested_tool: input_value(input, "tool"),
          requested_command: input_value(input, "command"),
          reason: reason,
          input_summary: summarize_tool_input(input)
        }
      )

    approval_context =
      Map.merge(event_context, %{
        request_id: request_id,
        kind: :capability_grant,
        tool_call_id: tool_call_id,
        tool: RequestCapability,
        input: input,
        risk: :read,
        capability: capability
      })

    case request_permission(opts, request_event, approval_context) do
      {:approved, approval_reason, events} ->
        case apply_capability_grant(opts, input) do
          {:ok, updated_opts, result} ->
            {:ok, updated_opts, Map.put(result, :approval_reason, approval_reason), events}

          {:error, reason} ->
            {:error, reason, events}
        end

      {:denied, denied_reason, events} ->
        {:denied, permission_denied_reason(denied_reason), events}

      {:cancelled, cancel_reason, events} ->
        {:denied, permission_denied_reason(cancel_reason), events}

      {:error, reason, events} ->
        {:error, reason, events}
    end
  end

  defp apply_capability_grant(opts, input) do
    case input_value(input, "capability") do
      "local_files" ->
        root = input_value(input, "root")
        add_harness_capability(opts, :local_files, root)

      "code_edit" ->
        root = input_value(input, "root")
        add_harness_capability(opts, :code_edit, root)

      "mcp_tool" ->
        add_mcp_tool_capability(opts, input_value(input, "tool"))

      "test_command" ->
        add_test_command_capability(opts, input_value(input, "command"))

      capability ->
        {:error, "unsupported capability request: #{inspect(capability)}"}
    end
  end

  defp add_harness_capability(opts, harness, root) when harness in [:local_files, :code_edit] do
    with {:ok, root} <- validate_capability_root(root),
         {:ok, opts} <- put_capability_root(opts, root) do
      tools = ToolHarness.builtin_many!([harness], tool_harness_opts(opts))
      updated_opts = add_capability_tools(opts, harness, tools)

      {:ok, updated_opts,
       %{
         status: "ok",
         capability: Atom.to_string(harness),
         root: Keyword.fetch!(updated_opts, :tool_root),
         tools: provider_tool_names(tools)
       }}
    end
  end

  defp add_mcp_tool_capability(opts, provider_name) do
    with {:ok, provider_name} <- validate_non_empty_binary(provider_name, "tool"),
         {:ok, config} <- fetch_required_opt(opts, :mcp_config, "MCP config"),
         {:ok, tool} <- configured_mcp_tool(config, provider_name) do
      updated_opts = add_capability_tools(opts, :mcp, [tool])

      {:ok, updated_opts,
       %{
         status: "ok",
         capability: "mcp_tool",
         tool: provider_name,
         tools: [provider_name]
       }}
    end
  end

  defp add_test_command_capability(opts, command) do
    with {:ok, command} <- validate_non_empty_binary(command, "command"),
         {:ok, commands} <- fetch_required_opt(opts, :test_commands, "test commands"),
         :ok <- validate_exact_test_command(command, commands) do
      tools = [AgentMachine.Tools.RunTestCommand]
      updated_opts = add_capability_tools(opts, :code_edit, tools)

      {:ok, updated_opts,
       %{
         status: "ok",
         capability: "test_command",
         command: command,
         tools: provider_tool_names(tools)
       }}
    end
  end

  defp validate_capability_root(root) do
    with {:ok, root} <- validate_non_empty_binary(root, "root") do
      {:ok, Path.expand(root)}
    end
  end

  defp put_capability_root(opts, root) do
    case Keyword.fetch(opts, :tool_root) do
      {:ok, active_root} when is_binary(active_root) and active_root != "" ->
        active_root = PathGuard.root!(opts)
        requested_root = PathGuard.existing_target!(active_root, root)

        case File.stat!(requested_root) do
          %{type: :directory} ->
            {:ok, Keyword.put(opts, :tool_root, requested_root)}

          %{type: type} ->
            {:error, "requested root must be a directory, got: #{inspect(type)}"}
        end

      _other ->
        case File.stat(root) do
          {:ok, %{type: :directory}} ->
            {:ok, Keyword.put(opts, :tool_root, root)}

          {:ok, %{type: type}} ->
            {:error, "requested root must be a directory, got: #{inspect(type)}"}

          {:error, reason} ->
            {:error, "requested root does not exist: #{inspect(root)} (#{inspect(reason)})"}
        end
    end
  rescue
    exception in ArgumentError -> {:error, Exception.message(exception)}
  end

  defp configured_mcp_tool(config, provider_name) do
    tools = ToolFactory.tools!(config)

    case Enum.find(tools, &(tool_name(&1) == provider_name)) do
      nil -> {:error, "MCP tool #{inspect(provider_name)} is not configured"}
      tool -> {:ok, tool}
    end
  rescue
    exception in ArgumentError -> {:error, Exception.message(exception)}
  end

  defp validate_exact_test_command(command, commands) when is_list(commands) do
    if command in commands do
      :ok
    else
      {:error, "test command must exactly match a configured allowlist entry"}
    end
  end

  defp validate_exact_test_command(_command, commands) do
    {:error, "test commands must be a list, got: #{inspect(commands)}"}
  end

  defp add_capability_tools(opts, harness, tools) when is_list(tools) do
    allowed_tools =
      opts
      |> Keyword.get(:allowed_tools, [])
      |> Kernel.++(tools)
      |> Enum.uniq()

    permissions = Enum.map(allowed_tools, &ToolPolicy.tool_permission!/1)
    harnesses = merge_policy_harness(Keyword.get(opts, :tool_policy), harness)

    opts
    |> Keyword.put(:allowed_tools, allowed_tools)
    |> Keyword.put(:tool_policy, ToolPolicy.new!(harness: harnesses, permissions: permissions))
  end

  defp merge_policy_harness(%ToolPolicy{harness: existing}, harness) when is_list(existing),
    do: Enum.uniq(existing ++ [harness])

  defp merge_policy_harness(%ToolPolicy{harness: existing}, harness) when is_atom(existing),
    do: Enum.uniq([existing, harness])

  defp merge_policy_harness(_policy, harness), do: [harness]

  defp tool_harness_opts(opts) do
    [
      test_commands: Keyword.get(opts, :test_commands),
      mcp_config: Keyword.get(opts, :mcp_config),
      allow_skill_scripts: Keyword.get(opts, :allow_skill_scripts, false),
      tool_approval_mode: Keyword.get(opts, :tool_approval_mode)
    ]
  end

  defp provider_tool_names(tools) do
    tools
    |> ToolHarness.definitions!()
    |> Enum.map(& &1.name)
  end

  defp fetch_required_opt(opts, key, label) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when not is_nil(value) -> {:ok, value}
      _other -> {:error, "#{label} is not configured for this run"}
    end
  end

  defp validate_non_empty_binary(value, _field) when is_binary(value) and byte_size(value) > 0,
    do: {:ok, value}

  defp validate_non_empty_binary(value, field) do
    {:error, "capability request #{field} must be a non-empty string, got: #{inspect(value)}"}
  end

  defp run_tool_call(
         tool_call,
         opts,
         tool_context,
         denied_fingerprints,
         failed_fingerprints
       )
       when is_map(tool_call) do
    started_at = DateTime.utc_now()
    id = safe_tool_call_id(tool_call)
    tool = safe_tool_call_tool(tool_call)

    with {:ok, id} <- validate_tool_call_id(id),
         {:ok, tool} <- validate_tool_module(tool),
         :ok <- validate_allowed_tool(tool, tool_context.allowed_tools),
         :ok <- validate_tool_permission(tool_context.tool_policy, tool),
         {:ok, input} <- validate_tool_input(safe_tool_call_input(tool_call)) do
      approval_fingerprint = approval_fingerprint(tool, input)

      cond do
        MapSet.member?(failed_fingerprints, approval_fingerprint) ->
          repeat_failed_tool_call(opts, tool_context.event_context, id, tool, started_at)

        MapSet.member?(denied_fingerprints, approval_fingerprint) ->
          repeat_denied_tool_call(
            opts,
            tool_context.event_context,
            id,
            tool,
            started_at,
            denied_fingerprints,
            failed_fingerprints
          )

        true ->
          run_tool_call_after_approval(%{
            opts: opts,
            tool_approval_mode: tool_context.tool_approval_mode,
            tool_timeout_ms: tool_context.tool_timeout_ms,
            event_context: tool_context.event_context,
            id: id,
            tool: tool,
            input: input,
            started_at: started_at,
            approval_fingerprint: approval_fingerprint,
            denied_fingerprints: denied_fingerprints,
            failed_fingerprints: failed_fingerprints
          })
      end
    else
      {:error, reason} ->
        failed_tool_call(opts, tool_context.event_context, id, tool, started_at, reason)
    end
  end

  defp run_tool_call(
         tool_call,
         _opts,
         _tool_context,
         _denied_fingerprints,
         _failed_fingerprints
       ) do
    raise ArgumentError, "tool call must be a map, got: #{inspect(tool_call)}"
  end

  defp repeat_failed_tool_call(opts, event_context, id, tool, started_at) do
    reason = "provider repeated failed tool call #{tool_name(tool)} with identical input"
    failed_tool_call(opts, event_context, id, tool, started_at, reason)
  end

  defp repeat_denied_tool_call(
         opts,
         event_context,
         id,
         tool,
         started_at,
         denied_fingerprints,
         failed_fingerprints
       ) do
    {:ok, result, events} =
      denied_tool_call(
        opts,
        event_context,
        id,
        tool,
        started_at,
        "tool approval denied previously for the same request"
      )

    {:ok, result, events, denied_fingerprints, failed_fingerprints}
  end

  defp run_tool_call_after_approval(context) do
    case validate_tool_approval(
           context.opts,
           context.tool_approval_mode,
           context.tool,
           context.id,
           context.input,
           context.event_context
         ) do
      {:approved, approval_events} ->
        run_approved_tool_call(context, approval_events)

      {:denied, reason, approval_events} ->
        run_denied_tool_call(context, reason, approval_events)

      {:error, reason, approval_events} ->
        {:error, reason, events} =
          failed_tool_call(
            context.opts,
            context.event_context,
            context.id,
            context.tool,
            context.started_at,
            reason
          )

        {:error, reason, approval_events ++ events}
    end
  end

  defp run_approved_tool_call(context, approval_events) do
    execution_started_at = DateTime.utc_now()

    {:ok, result, events} =
      do_run_tool_call(
        context.tool,
        context.id,
        context.input,
        context.opts,
        context.tool_timeout_ms,
        context.event_context,
        execution_started_at
      )

    failed_fingerprints =
      maybe_cache_failed_tool_fingerprint(
        result,
        context.approval_fingerprint,
        context.failed_fingerprints
      )

    {:ok, result, approval_events ++ events, context.denied_fingerprints, failed_fingerprints}
  end

  defp run_denied_tool_call(context, reason, approval_events) do
    denied_at = DateTime.utc_now()

    {:ok, result, events} =
      denied_tool_call(
        context.opts,
        context.event_context,
        context.id,
        context.tool,
        denied_at,
        reason
      )

    {:ok, result, approval_events ++ events,
     MapSet.put(context.denied_fingerprints, context.approval_fingerprint),
     context.failed_fingerprints}
  end

  defp maybe_cache_failed_tool_fingerprint(
         %{result: result},
         approval_fingerprint,
         failed_fingerprints
       )
       when is_map(result) do
    status = Map.get(result, :status, Map.get(result, "status"))
    error = Map.get(result, :error, Map.get(result, "error"))

    if status == "error" and cacheable_tool_failure?(error) do
      MapSet.put(failed_fingerprints, approval_fingerprint)
    else
      failed_fingerprints
    end
  end

  defp maybe_cache_failed_tool_fingerprint(_result, _approval_fingerprint, failed_fingerprints),
    do: failed_fingerprints

  defp cacheable_tool_failure?(error) when is_binary(error) do
    String.starts_with?(error, [
      "MCP tool input requires an arguments object",
      "MCP tool arguments invalid:"
    ])
  end

  defp cacheable_tool_failure?(_error), do: false

  defp do_run_tool_call(tool, id, input, opts, tool_timeout_ms, event_context, started_at) do
    started_event = tool_call_started_event(event_context, id, tool, started_at, opts, input)
    emit_event!(opts, started_event)
    opts = Keyword.put(opts, :tool_event_context, event_context)

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
          input,
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
         input,
         reason
       ) do
    finished_at = DateTime.utc_now()
    error = tool_error_text(reason)

    event_reason = "tool #{inspect(tool)} failed for call #{inspect(id)}: #{error}"

    failed_event =
      tool_call_failed_event(event_context, id, tool, started_at, finished_at, opts, event_reason)

    emit_event!(opts, failed_event)

    if terminal_tool_failure?(error, input) do
      {:error, event_reason, [started_event, failed_event]}
    else
      result = %{
        status: "error",
        error: error,
        tool: tool_name(tool)
      }

      {:ok, %{id: id, result: result}, [started_event, failed_event]}
    end
  end

  defp terminal_tool_failure?(error, input) when is_binary(error) do
    String.contains?(error, "outside tool root") and absolute_tool_path?(input)
  end

  defp terminal_tool_failure?(_error, _input), do: false

  defp absolute_tool_path?(input) when is_map(input) do
    path = Map.get(input, :path) || Map.get(input, "path")
    is_binary(path) and Path.type(path) == :absolute
  end

  defp absolute_tool_path?(_input), do: false

  defp tool_error_text(reason) when is_binary(reason), do: reason
  defp tool_error_text(reason), do: inspect(reason)

  defp denied_tool_call(opts, event_context, id, tool, started_at, reason) do
    finished_at = DateTime.utc_now()
    error = tool_error_text(reason)

    failed_event =
      tool_call_failed_event(event_context, id, tool, started_at, finished_at, opts, error)

    emit_event!(opts, failed_event)

    result = %{
      status: "denied",
      error: error,
      tool: tool_name(tool)
    }

    {:ok, %{id: id, result: result}, [failed_event]}
  end

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

  defp approval_fingerprint(tool, input) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary({tool, input}))
    |> Base.encode16(case: :lower)
  end

  defp validate_tool_approval(opts, mode, tool, id, input, event_context) do
    risk = ToolPolicy.approval_risk!(tool)

    cond do
      approval_allowed?(mode, risk) ->
        {:approved, []}

      mode == :ask_before_write and risk in [:write, :delete, :command, :network] ->
        request_tool_approval(opts, tool, id, input, event_context, risk)

      true ->
        {:error,
         "tool #{inspect(tool)} with approval risk #{inspect(risk)} is not allowed by tool approval mode #{inspect(mode)}",
         []}
    end
  rescue
    exception in ArgumentError -> {:error, Exception.message(exception), []}
  end

  defp approval_allowed?(:read_only, :read), do: true
  defp approval_allowed?(:ask_before_write, :read), do: true
  defp approval_allowed?(:auto_approved_safe, risk) when risk in [:read, :write], do: true

  defp approval_allowed?(:full_access, risk)
       when risk in [:read, :write, :delete, :command, :network], do: true

  defp approval_allowed?(_mode, _risk), do: false

  defp request_tool_approval(opts, tool, id, input, event_context, risk) do
    case Keyword.fetch(opts, :tool_approval_callback) do
      {:ok, callback} when is_function(callback, 1) ->
        request_id = permission_request_id(event_context.run_id, event_context.agent_id, id)

        request_event =
          permission_requested_event(
            event_context,
            %{
              request_id: request_id,
              kind: :tool_execution,
              tool_call_id: id,
              tool: tool_name(tool),
              permission: safe_tool_permission(tool),
              approval_risk: risk,
              approval_mode: Keyword.get(opts, :tool_approval_mode),
              requested_root: input_value(input, "root") || input_value(input, "cwd"),
              requested_command: input_value(input, "command"),
              input_summary: summarize_tool_input(input)
            }
          )

        approval_context =
          Map.merge(event_context, %{
            request_id: request_id,
            kind: :tool_execution,
            tool_call_id: id,
            tool: tool,
            input: input,
            risk: risk
          })

        case request_permission(opts, request_event, approval_context) do
          {:approved, _reason, events} -> {:approved, events}
          {:denied, reason, events} -> {:denied, permission_denied_reason(reason), events}
          {:cancelled, reason, events} -> {:denied, permission_denied_reason(reason), events}
          {:error, reason, events} -> {:error, reason, events}
        end

      {:ok, callback} ->
        {:error,
         ":tool_approval_callback must be a function of arity 1, got: #{inspect(callback)}", []}

      :error ->
        {:error,
         "tool #{inspect(tool)} with approval risk #{inspect(risk)} requires approval for tool approval mode :ask_before_write",
         []}
    end
  end

  defp request_permission(opts, request_event, approval_context) do
    emit_event!(opts, request_event)
    callback = Keyword.fetch!(opts, :tool_approval_callback)

    decision = approval_callback_result(callback.(approval_context))
    decision_event = permission_decision_event(request_event, decision)
    emit_event!(opts, decision_event)

    append_decision_events(decision, [request_event, decision_event])
  rescue
    exception ->
      reason = Exception.message(exception)
      cancel_event = permission_cancelled_event(request_event, reason)
      emit_event!(opts, cancel_event)
      {:error, reason, [request_event, cancel_event]}
  end

  defp approval_callback_result(:approved), do: {:approved, ""}
  defp approval_callback_result(true), do: {:approved, ""}
  defp approval_callback_result({:approved, reason}), do: {:approved, stringify_reason(reason)}
  defp approval_callback_result({:cancelled, reason}), do: {:cancelled, stringify_reason(reason)}

  defp approval_callback_result({:denied, reason}),
    do: {:denied, stringify_reason(reason)}

  defp approval_callback_result(false), do: {:denied, ""}

  defp approval_callback_result(result) do
    {:error, "tool approval callback returned invalid result: #{inspect(result)}"}
  end

  defp append_decision_events({:approved, reason}, events), do: {:approved, reason, events}
  defp append_decision_events({:denied, reason}, events), do: {:denied, reason, events}
  defp append_decision_events({:cancelled, reason}, events), do: {:cancelled, reason, events}
  defp append_decision_events({:error, reason}, events), do: {:error, reason, events}

  defp permission_denied_reason(""), do: "tool approval denied"
  defp permission_denied_reason(reason), do: "tool approval denied: #{reason}"

  defp stringify_reason(reason) when is_binary(reason), do: reason
  defp stringify_reason(reason), do: inspect(reason)

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

  defp permission_requested_event(context, attrs) do
    %{
      type: :permission_requested,
      run_id: context.run_id,
      agent_id: context.agent_id,
      attempt: context.attempt,
      round: context.round,
      request_id: Map.fetch!(attrs, :request_id),
      kind: Map.fetch!(attrs, :kind),
      tool_call_id: Map.fetch!(attrs, :tool_call_id),
      tool: Map.fetch!(attrs, :tool),
      permission: Map.fetch!(attrs, :permission),
      approval_risk: Map.fetch!(attrs, :approval_risk),
      approval_mode: Map.fetch!(attrs, :approval_mode),
      capability: Map.get(attrs, :capability),
      requested_root: Map.get(attrs, :requested_root),
      requested_tool: Map.get(attrs, :requested_tool),
      requested_command: Map.get(attrs, :requested_command),
      input_summary: Map.get(attrs, :input_summary),
      reason: Map.get(attrs, :reason),
      at: DateTime.utc_now()
    }
    |> Map.merge(tool_event_metadata(context))
    |> reject_nil_values()
  end

  defp permission_decision_event(request_event, {decision, reason})
       when decision in [:approved, :denied] do
    request_event
    |> Map.take([
      :run_id,
      :agent_id,
      :parent_agent_id,
      :attempt,
      :round,
      :request_id,
      :kind,
      :tool_call_id,
      :tool,
      :permission,
      :approval_risk,
      :approval_mode,
      :capability,
      :requested_root,
      :requested_tool,
      :requested_command,
      :agent_machine_role,
      :swarm_id,
      :variant_id,
      :workspace,
      :spawn_depth
    ])
    |> Map.merge(%{
      type: :permission_decided,
      decision: decision,
      reason: reason,
      at: DateTime.utc_now()
    })
    |> reject_nil_values()
  end

  defp permission_decision_event(request_event, {:error, reason}),
    do: permission_cancelled_event(request_event, reason)

  defp permission_decision_event(request_event, {:cancelled, reason}),
    do: permission_cancelled_event(request_event, reason)

  defp permission_cancelled_event(request_event, reason) do
    request_event
    |> Map.take([
      :run_id,
      :agent_id,
      :parent_agent_id,
      :attempt,
      :round,
      :request_id,
      :kind,
      :tool_call_id,
      :tool,
      :permission,
      :approval_risk,
      :approval_mode,
      :capability,
      :requested_root,
      :requested_tool,
      :requested_command,
      :agent_machine_role,
      :swarm_id,
      :variant_id,
      :workspace,
      :spawn_depth
    ])
    |> Map.merge(%{type: :permission_cancelled, reason: reason, at: DateTime.utc_now()})
    |> reject_nil_values()
  end

  defp permission_request_id(run_id, agent_id, tool_call_id) do
    entropy = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    Enum.join(["perm", run_id, agent_id, tool_call_id, entropy], "-")
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
    |> Map.merge(tool_event_metadata(context))
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
    |> Map.merge(tool_event_metadata(context))
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
    |> Map.merge(tool_event_metadata(context))
  end

  defp agent_event_metadata(opts) do
    case Keyword.get(opts, :agent_event_metadata, %{}) do
      metadata when is_map(metadata) -> metadata
      _other -> %{}
    end
  end

  defp tool_event_metadata(context) when is_map(context) do
    Map.take(context, [
      :agent_machine_role,
      :swarm_id,
      :variant_id,
      :workspace,
      :spawn_depth
    ])
  end

  defp tool_event_metadata(_context), do: %{}

  defp emit_event!(opts, event) do
    case Keyword.fetch(opts, :event_collector) do
      {:ok, collector} ->
        AgentMachine.RunEventCollector.emit(collector, event)

      :error ->
        case Keyword.fetch(opts, :event_sink) do
          :error -> :ok
          {:ok, sink} -> sink.(event)
        end
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
    input
    |> safe_tool_input_fields()
    |> Map.merge(%{
      keys: input |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort(),
      bytes: input |> AgentMachine.JSON.encode!() |> byte_size()
    })
  end

  defp summarize_tool_input(_input), do: nil

  defp summarize_tool_result(result) when is_map(result) do
    (Map.get(result, :summary) || Map.get(result, "summary") || changed_summary(result))
    |> merge_result_display_metadata(result)
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

  defp input_value(input, key) when is_map(input) and is_binary(key) do
    atom_key = String.to_existing_atom(key)

    Map.get(input, key) || Map.get(input, atom_key)
  rescue
    ArgumentError -> Map.get(input, key)
  end

  defp merge_result_display_metadata(nil, _result), do: nil

  defp merge_result_display_metadata(summary, result) when is_map(summary) do
    summary
    |> maybe_put_result_path(result)
    |> maybe_put_changed_paths(result)
  end

  defp merge_result_display_metadata(summary, _result), do: summary

  defp reject_nil_values(map) when is_map(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp maybe_put_result_path(summary, result) do
    case Map.get(result, :path) || Map.get(result, "path") do
      path when is_binary(path) and byte_size(path) <= 500 -> Map.put_new(summary, :path, path)
      _other -> summary
    end
  end

  defp maybe_put_changed_paths(summary, result) do
    changed_paths =
      result
      |> changed_path_entries()
      |> Enum.take(20)

    if changed_paths == [] do
      summary
    else
      Map.put_new(summary, :changed_paths, changed_paths)
    end
  end

  defp changed_path_entries(result) do
    (Map.get(result, :changed_paths) || Map.get(result, "changed_paths") || [])
    |> Enum.concat(Map.get(result, :changed_files) || Map.get(result, "changed_files") || [])
    |> Enum.flat_map(&changed_path_entry/1)
  end

  defp changed_path_entry(%{path: path} = entry) when is_binary(path) do
    [%{path: path, action: Map.get(entry, :action)}]
  end

  defp changed_path_entry(%{"path" => path} = entry) when is_binary(path) do
    [%{path: path, action: Map.get(entry, "action")}]
  end

  defp changed_path_entry(_entry), do: []

  defp safe_tool_input_fields(input) do
    [
      {"path", :path, :path},
      {"cwd", :cwd, :cwd},
      {"query", :query, :query},
      {"pattern", :pattern, :pattern},
      {"command", :command, :command},
      {"max_entries", :max_entries, :max_entries},
      {"max_results", :max_results, :max_results}
    ]
    |> Enum.reduce(%{}, fn {string_key, atom_key, output_key}, acc ->
      value = Map.get(input, string_key, Map.get(input, atom_key))

      if safe_tool_input_value?(value) do
        Map.put(acc, output_key, value)
      else
        acc
      end
    end)
  end

  defp safe_tool_input_value?(value) when is_binary(value), do: byte_size(value) <= 500
  defp safe_tool_input_value?(value) when is_integer(value), do: true
  defp safe_tool_input_value?(_value), do: false
end
