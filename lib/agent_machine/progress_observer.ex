defmodule AgentMachine.ProgressObserver do
  @moduledoc false

  use GenServer

  alias AgentMachine.{Agent, JSON, RunSpec, Secrets.Redactor, WorkflowProvider}

  @default_debounce_ms 1_500
  @default_cooldown_ms 25_000
  @default_max_evidence 24
  @max_excerpt_bytes 2_000
  @max_commentary_bytes 1_200

  @private_evidence_key :progress_observer_evidence
  @forbidden_provider_opts [
    :allowed_tools,
    :tool_policy,
    :tool_context,
    :tool_continuation,
    :tool_approval_mode,
    :tool_approval_callback,
    :stream_event_sink,
    :stream_context,
    :event_sink,
    :event_collector,
    :task_supervisor,
    :tool_session_supervisor,
    :permission_control,
    :mcp_session,
    :mcp_config
  ]

  def start_link({run_id, config, event_sink, opts})
      when is_binary(run_id) and is_function(event_sink, 1) and is_list(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, {run_id, config, event_sink}, name: name)
  end

  def observe(observer, event) when is_map(event) do
    GenServer.cast(observer, {:observe, event})
  end

  def from_run_spec!(%RunSpec{provider: :echo}) do
    raise ArgumentError,
          "progress observer requires an OpenAI/OpenRouter provider and model; echo provider cannot run observer commentary"
  end

  def from_run_spec!(%RunSpec{} = spec) do
    provider_opts =
      []
      |> WorkflowProvider.put_http_opts(spec)

    %{
      provider: WorkflowProvider.provider_module(spec),
      model: WorkflowProvider.model(spec),
      pricing: WorkflowProvider.pricing(spec),
      provider_opts: provider_opts,
      task: spec.task
    }
  end

  def from_run_spec!(spec) do
    raise ArgumentError, "progress observer requires a RunSpec, got: #{inspect(spec)}"
  end

  def strip_private_evidence(event) when is_map(event) do
    event
    |> Map.delete(@private_evidence_key)
    |> Map.delete(Atom.to_string(@private_evidence_key))
  end

  def tool_result_evidence(tool, result) when is_binary(tool) and is_map(result) do
    result = Redactor.redact_output(result) |> Map.fetch!(:value)
    summary = map_value(result, :summary) || %{}

    %{
      kind: "tool_result",
      tool: tool,
      result: tool_evidence_result(tool, result, summary)
    }
  end

  def tool_result_evidence(tool, result) do
    raise ArgumentError,
          "tool result evidence requires binary tool and map result, got: #{inspect({tool, result})}"
  end

  @impl true
  def init({run_id, config, event_sink}) do
    config = validate_config!(config)

    {:ok,
     %{
       run_id: run_id,
       event_sink: event_sink,
       provider: Map.fetch!(config, :provider),
       model: Map.fetch!(config, :model),
       pricing: Map.fetch!(config, :pricing),
       provider_opts: Map.fetch!(config, :provider_opts),
       task: Map.fetch!(config, :task),
       debounce_ms: Map.fetch!(config, :debounce_ms),
       cooldown_ms: Map.fetch!(config, :cooldown_ms),
       max_evidence: Map.fetch!(config, :max_evidence),
       buffer: [],
       timer_ref: nil,
       in_flight?: false,
       pending_flush?: false,
       final_flush?: false,
       last_commentary_at_ms: nil
     }}
  end

  @impl true
  def handle_cast({:observe, event}, state) do
    case event_evidence(event) do
      nil ->
        {:noreply, state}

      evidence ->
        state =
          state
          |> append_evidence(evidence)
          |> maybe_schedule_flush(event)

        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:flush, state) do
    state = %{state | timer_ref: nil}

    cond do
      state.buffer == [] ->
        {:noreply, state}

      state.in_flight? ->
        {:noreply, %{state | pending_flush?: true}}

      true ->
        {:noreply, start_commentary_task(state)}
    end
  end

  def handle_info({:commentary_finished, {:ok, event}}, state) do
    safe_emit(state.event_sink, event)

    state =
      %{state | in_flight?: false, last_commentary_at_ms: now_ms()}
      |> maybe_schedule_pending_flush()

    {:noreply, state}
  end

  def handle_info({:commentary_finished, {:skip, _reason}}, state) do
    state =
      %{state | in_flight?: false, last_commentary_at_ms: now_ms()}
      |> maybe_schedule_pending_flush()

    {:noreply, state}
  end

  def handle_info({:commentary_finished, {:error, _reason}}, state) do
    state =
      %{state | in_flight?: false, last_commentary_at_ms: now_ms()}
      |> maybe_schedule_pending_flush()

    {:noreply, state}
  end

  defp validate_config!(config) when is_map(config) do
    config =
      config
      |> normalize_config_key!(:provider)
      |> normalize_config_key!(:model)
      |> normalize_config_key!(:pricing)
      |> normalize_config_key!(:provider_opts)
      |> normalize_config_key!(:task)
      |> put_default_config(:debounce_ms, @default_debounce_ms)
      |> put_default_config(:cooldown_ms, @default_cooldown_ms)
      |> put_default_config(:max_evidence, @default_max_evidence)

    require_provider!(Map.fetch!(config, :provider))
    require_non_empty_binary!(Map.fetch!(config, :model), :model)
    AgentMachine.Pricing.validate!(Map.fetch!(config, :pricing))
    require_non_empty_binary!(Map.fetch!(config, :task), :task)
    validate_provider_opts!(Map.fetch!(config, :provider_opts))
    require_non_negative_integer!(Map.fetch!(config, :debounce_ms), :debounce_ms)
    require_non_negative_integer!(Map.fetch!(config, :cooldown_ms), :cooldown_ms)
    require_positive_integer!(Map.fetch!(config, :max_evidence), :max_evidence)

    config
  end

  defp validate_config!(config) do
    raise ArgumentError, "progress observer config must be a map, got: #{inspect(config)}"
  end

  defp tool_evidence_result("read_file", result, summary) do
    %{
      path: map_value(summary, :path) || map_value(result, :path),
      line_count: map_value(summary, :line_count),
      bytes: map_value(summary, :bytes) || map_value(result, :bytes),
      truncated: map_value(summary, :truncated) || map_value(result, :truncated),
      content_excerpt: text_excerpt(map_value(result, :content))
    }
    |> reject_empty_values()
  end

  defp tool_evidence_result("search_files", result, summary) do
    %{
      path: map_value(summary, :path),
      pattern: map_value(summary, :pattern),
      match_count: map_value(summary, :match_count),
      truncated: map_value(summary, :truncated) || map_value(result, :truncated),
      matches:
        result
        |> map_value(:matches)
        |> list_items(10)
        |> Enum.map(&search_match_evidence/1)
    }
    |> reject_empty_values()
  end

  defp tool_evidence_result("list_files", result, summary) do
    %{
      path: map_value(summary, :path),
      entry_count: map_value(summary, :entry_count),
      truncated: map_value(summary, :truncated) || map_value(result, :truncated),
      entries:
        result
        |> map_value(:entries)
        |> list_items(50)
        |> Enum.map(&list_entry_evidence/1)
    }
    |> reject_empty_values()
  end

  defp tool_evidence_result("run_test_command", result, _summary) do
    result
    |> command_result_evidence()
    |> reject_empty_values()
  end

  defp tool_evidence_result("run_shell_command", result, _summary) do
    result
    |> command_result_evidence()
    |> reject_empty_values()
  end

  defp tool_evidence_result(_tool, result, summary) do
    summary
    |> changed_result_evidence(result)
    |> reject_empty_values()
  end

  defp normalize_config_key!(config, key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(config, key) ->
        config

      Map.has_key?(config, string_key) ->
        Map.put(config, key, Map.fetch!(config, string_key))

      true ->
        raise ArgumentError, "progress observer config missing required key #{inspect(key)}"
    end
  end

  defp put_default_config(config, key, value) do
    Map.put_new(config, key, value)
  end

  defp require_provider!(provider) when is_atom(provider) do
    if provider == AgentMachine.Providers.Echo do
      raise ArgumentError,
            "progress observer requires an OpenAI/OpenRouter provider and model; echo provider cannot run observer commentary"
    end

    if Code.ensure_loaded?(provider) and function_exported?(provider, :complete, 2) do
      :ok
    else
      raise ArgumentError,
            "progress observer provider must export complete/2, got: #{inspect(provider)}"
    end
  end

  defp require_provider!(provider) do
    raise ArgumentError,
          "progress observer provider must be a module atom, got: #{inspect(provider)}"
  end

  defp require_non_empty_binary!(value, _field) when is_binary(value) and byte_size(value) > 0,
    do: :ok

  defp require_non_empty_binary!(value, field) do
    raise ArgumentError,
          "progress observer #{inspect(field)} must be a non-empty binary, got: #{inspect(value)}"
  end

  defp require_non_negative_integer!(value, _field) when is_integer(value) and value >= 0,
    do: :ok

  defp require_non_negative_integer!(value, field) do
    raise ArgumentError,
          "progress observer #{inspect(field)} must be a non-negative integer, got: #{inspect(value)}"
  end

  defp require_positive_integer!(value, _field) when is_integer(value) and value > 0, do: :ok

  defp require_positive_integer!(value, field) do
    raise ArgumentError,
          "progress observer #{inspect(field)} must be a positive integer, got: #{inspect(value)}"
  end

  defp validate_provider_opts!(opts) when is_list(opts) do
    forbidden = opts |> Keyword.keys() |> Enum.filter(&(&1 in @forbidden_provider_opts))

    if forbidden != [] do
      raise ArgumentError,
            "progress observer provider_opts must not contain runtime/tool key(s): #{inspect(forbidden)}"
    end
  end

  defp validate_provider_opts!(opts) do
    raise ArgumentError,
          "progress observer provider_opts must be a keyword list, got: #{inspect(opts)}"
  end

  defp append_evidence(state, evidence) do
    evidence = Map.put_new(evidence, :at, DateTime.utc_now())
    buffer = Enum.take(state.buffer ++ [evidence], -state.max_evidence)
    %{state | buffer: buffer}
  end

  defp maybe_schedule_flush(state, event) do
    cond do
      final_flush_trigger?(event) ->
        state
        |> Map.put(:final_flush?, true)
        |> schedule_immediate_flush()

      flush_trigger?(event) ->
        schedule_flush(state)

      true ->
        state
    end
  end

  defp final_flush_trigger?(%{type: type})
       when type in [:run_completed, :run_failed, :run_timed_out],
       do: true

  defp final_flush_trigger?(_event), do: false

  defp flush_trigger?(%{type: type})
       when type in [
              :tool_call_finished,
              :tool_call_failed,
              :agent_finished,
              :agent_delegation_scheduled,
              :run_completed,
              :run_failed,
              :run_timed_out
            ],
       do: true

  defp flush_trigger?(_event), do: false

  defp schedule_flush(%{timer_ref: ref} = state) when not is_nil(ref), do: state

  defp schedule_flush(state) do
    delay = flush_delay(state)
    ref = Process.send_after(self(), :flush, delay)
    %{state | timer_ref: ref}
  end

  defp schedule_immediate_flush(%{timer_ref: ref} = state) when not is_nil(ref) do
    Process.cancel_timer(ref)
    ref = Process.send_after(self(), :flush, 0)
    %{state | timer_ref: ref}
  end

  defp schedule_immediate_flush(state) do
    ref = Process.send_after(self(), :flush, 0)
    %{state | timer_ref: ref}
  end

  defp flush_delay(%{final_flush?: true}), do: 0
  defp flush_delay(state), do: next_flush_delay(state)

  defp next_flush_delay(%{last_commentary_at_ms: nil, debounce_ms: debounce_ms}), do: debounce_ms

  defp next_flush_delay(state) do
    elapsed_ms = now_ms() - state.last_commentary_at_ms
    max(state.debounce_ms, max(state.cooldown_ms - elapsed_ms, 0))
  end

  defp maybe_schedule_pending_flush(%{pending_flush?: true, buffer: buffer} = state)
       when buffer != [] do
    %{state | pending_flush?: false}
    |> schedule_flush()
  end

  defp maybe_schedule_pending_flush(state), do: %{state | pending_flush?: false}

  defp start_commentary_task(state) do
    evidence = state.buffer
    owner = self()

    task_state = Map.take(state, [:run_id, :provider, :model, :pricing, :provider_opts, :task])

    {:ok, _pid} =
      Task.start(fn ->
        send(owner, {:commentary_finished, generate_commentary(task_state, evidence)})
      end)

    %{state | buffer: [], in_flight?: true, pending_flush?: false, final_flush?: false}
  end

  defp generate_commentary(state, evidence) when is_list(evidence) and evidence != [] do
    agent = observer_agent(state, evidence)

    opts =
      state.provider_opts
      |> Keyword.put(:run_context, empty_run_context(state.run_id))
      |> Keyword.put(:runtime_facts, false)

    case state.provider.complete(agent, opts) do
      {:ok, %{output: output}} when is_binary(output) ->
        case compact_commentary(output) do
          "" -> {:skip, :empty_commentary}
          commentary -> {:ok, commentary_event(state.run_id, commentary, evidence)}
        end

      {:ok, other} ->
        {:error, "progress observer provider returned invalid payload: #{inspect(other)}"}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    exception ->
      {:error, Exception.format(:error, exception, __STACKTRACE__)}
  end

  defp generate_commentary(_state, _evidence), do: {:skip, :empty_evidence}

  defp observer_agent(state, evidence) do
    Agent.new!(%{
      id: "progress-observer",
      provider: state.provider,
      model: state.model,
      pricing: state.pricing,
      instructions: observer_instructions(),
      input:
        JSON.encode!(%{
          task: state.task,
          evidence: Enum.map(evidence, &json_safe/1)
        }),
      metadata: %{agent_machine_role: "progress_observer"}
    })
  end

  defp observer_instructions do
    """
    You are a progress observer for AgentMachine.
    Write one or two short user-facing sentences about what just happened.
    Use only the provided evidence. Do not claim work that is not evidenced.
    Mention concrete findings when the evidence supports them.
    Do not write as the main assistant or take credit for work you only observed.
    Do not reveal secrets. Do not address the main task's final answer.
    Do not include markdown tables, headings, JSON, or bullet lists.
    """
    |> String.trim()
  end

  defp empty_run_context(run_id) do
    %{run_id: run_id, results: %{}, artifacts: %{}, agent_graph: %{}}
  end

  defp commentary_event(run_id, commentary, evidence) do
    %{
      type: :progress_commentary,
      run_id: run_id,
      source: :observer,
      commentary: commentary,
      summary: commentary,
      evidence_count: length(evidence),
      agent_ids:
        evidence |> Enum.map(&Map.get(&1, :agent_id)) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      tool_call_ids:
        evidence |> Enum.map(&Map.get(&1, :tool_call_id)) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      at: DateTime.utc_now()
    }
  end

  defp compact_commentary(output) do
    output
    |> String.trim()
    |> String.split("\n", trim: true)
    |> Enum.take(2)
    |> Enum.join(" ")
    |> text_excerpt(@max_commentary_bytes)
  end

  defp safe_emit(sink, event) do
    sink.(event)
  rescue
    _exception -> :ok
  end

  defp event_evidence(%{type: :agent_delegation_scheduled} = event) do
    base_event_evidence(event)
    |> Map.put(:delegated_agent_ids, Map.get(event, :delegated_agent_ids, []))
  end

  defp event_evidence(%{type: type} = event)
       when type in [
              :agent_started,
              :agent_finished,
              :agent_retry_scheduled,
              :provider_request_failed,
              :tool_call_started,
              :tool_call_finished,
              :tool_call_failed,
              :run_failed,
              :run_timed_out,
              :run_completed
            ] do
    event
    |> base_event_evidence()
    |> maybe_put(:status, Map.get(event, :status))
    |> maybe_put(:reason, Map.get(event, :reason))
    |> maybe_put(:tool, Map.get(event, :tool))
    |> maybe_put(:tool_call_id, Map.get(event, :tool_call_id))
    |> maybe_put(:input_summary, safe_summary(Map.get(event, :input_summary)))
    |> maybe_put(:result_summary, safe_summary(Map.get(event, :result_summary)))
    |> maybe_put(:result, Map.get(event, @private_evidence_key))
  end

  defp event_evidence(_event), do: nil

  defp base_event_evidence(event) do
    %{
      kind: "runtime_event",
      type: event |> Map.fetch!(:type) |> type_text()
    }
    |> maybe_put(:agent_id, Map.get(event, :agent_id))
    |> maybe_put(:parent_agent_id, Map.get(event, :parent_agent_id))
    |> maybe_put(:attempt, Map.get(event, :attempt))
    |> maybe_put(:round, Map.get(event, :round))
    |> maybe_put(:at, Map.get(event, :at))
  end

  defp safe_summary(summary) when is_map(summary) do
    summary
    |> Map.take([
      :tool,
      "tool",
      :status,
      "status",
      :path,
      "path",
      :pattern,
      "pattern",
      :match_count,
      "match_count",
      :entry_count,
      "entry_count",
      :changed_count,
      "changed_count",
      :changed_paths,
      "changed_paths",
      :command,
      "command",
      :exit_status,
      "exit_status",
      :truncated,
      "truncated"
    ])
    |> reject_empty_values()
  end

  defp safe_summary(_summary), do: nil

  defp changed_result_evidence(summary, result) do
    %{
      summary: safe_summary(summary),
      changed_paths:
        result
        |> changed_path_entries()
        |> Enum.take(20)
    }
  end

  defp command_result_evidence(result) do
    %{
      command: map_value(result, :command),
      cwd: map_value(result, :cwd),
      status: map_value(result, :status),
      exit_status: map_value(result, :exit_status),
      timed_out: map_value(result, :timed_out),
      stopped: map_value(result, :stopped),
      output_truncated: map_value(result, :output_truncated),
      output_excerpt: text_excerpt(map_value(result, :output))
    }
  end

  defp search_match_evidence(match) when is_map(match) do
    %{
      path: map_value(match, :path),
      line: map_value(match, :line),
      text: text_excerpt(map_value(match, :text), 500)
    }
    |> reject_empty_values()
  end

  defp search_match_evidence(_match), do: %{}

  defp list_entry_evidence(entry) when is_map(entry) do
    %{
      name: map_value(entry, :name),
      type: map_value(entry, :type),
      size: map_value(entry, :size)
    }
    |> reject_empty_values()
  end

  defp list_entry_evidence(_entry), do: %{}

  defp changed_path_entries(result) do
    (map_value(result, :changed_paths) || [])
    |> Enum.concat(map_value(result, :changed_files) || [])
    |> Enum.flat_map(fn
      %{path: path} = entry when is_binary(path) ->
        [%{path: path, action: Map.get(entry, :action)} |> reject_empty_values()]

      %{"path" => path} = entry when is_binary(path) ->
        [%{path: path, action: Map.get(entry, "action")} |> reject_empty_values()]

      _entry ->
        []
    end)
  end

  defp list_items(items, limit) when is_list(items), do: Enum.take(items, limit)
  defp list_items(_items, _limit), do: []

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_value(_map, _key), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, _key, %{}), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp reject_empty_values(map) do
    Map.reject(map, fn
      {_key, nil} -> true
      {_key, ""} -> true
      {_key, []} -> true
      {_key, %{}} -> true
      _other -> false
    end)
  end

  defp text_excerpt(text), do: text_excerpt(text, @max_excerpt_bytes)

  defp text_excerpt(text, limit) when is_binary(text) and byte_size(text) > limit do
    binary_part(text, 0, limit)
  end

  defp text_excerpt(text, _limit) when is_binary(text), do: text
  defp text_excerpt(_text, _limit), do: nil

  defp json_safe(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp json_safe(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)

  defp json_safe(value) when is_map(value),
    do: Map.new(value, fn {key, val} -> {key, json_safe(val)} end)

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value), do: value

  defp type_text(type) when is_atom(type), do: Atom.to_string(type)
  defp type_text(type) when is_binary(type), do: type
  defp type_text(type), do: inspect(type)

  defp now_ms, do: System.monotonic_time(:millisecond)
end
