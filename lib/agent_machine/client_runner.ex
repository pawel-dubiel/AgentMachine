defmodule AgentMachine.ClientRunner do
  @moduledoc """
  High-level client runner used by CLI and TUI frontends.
  """

  alias AgentMachine.{
    CapabilityRequired,
    EventLog,
    EventSummary,
    ExecutionPlanner,
    JSON,
    Orchestrator,
    ProgressObserver,
    RunChecklist,
    RunSpec,
    Telemetry,
    ToolPolicy,
    Tools.RequestCapability
  }

  alias AgentMachine.Secrets.Redactor
  alias AgentMachine.Skills.{Manifest, Prompt, Selector}
  alias AgentMachine.Workflows.{Agentic, Chat, Tool}

  @minimum_code_edit_shell_timeout_ms 120_000
  @minimum_code_edit_shell_max_rounds 16
  @minimum_mcp_browser_timeout_ms 60_000
  @code_edit_shell_tools [
    AgentMachine.Tools.RunShellCommand,
    AgentMachine.Tools.StartShellCommand,
    AgentMachine.Tools.ReadShellCommandOutput,
    AgentMachine.Tools.StopShellCommand,
    AgentMachine.Tools.ListShellCommands
  ]

  def run!(attrs, opts \\ []) when is_list(opts) do
    validate_opts!(opts)
    spec = RunSpec.new!(attrs)

    case plan_execution(spec, opts) do
      {:ok, execution_strategy} ->
        try do
          spec = maybe_put_auto_time_harness(spec, execution_strategy)
          write_execution_strategy_event(spec, execution_strategy, opts)
          skill_selection = Selector.select!(spec)
          {agents, run_opts} = build_strategy(spec, execution_strategy)
          run_opts = put_permission_control(run_opts, opts)
          validate_runtime_opts!(run_opts, opts)
          run_opts = put_skill_opts(run_opts, spec, skill_selection)
          run_opts = put_timeout_lease_opts(run_opts, spec)
          run_opts = Keyword.put(run_opts, :execution_strategy, execution_strategy)
          run_opts = Keyword.put(run_opts, :workflow_route, execution_strategy)
          run_opts = put_event_sink(run_opts, opts)
          run_opts = put_progress_observer_opts(run_opts, spec)
          run_opts = put_tool_approval_callback(run_opts, opts)
          run_opts = put_planner_review_callback(run_opts, opts)

          case Orchestrator.run(agents, run_opts) do
            {:ok, run} -> summarize_and_log(run)
            {:error, {:failed, run}} -> summarize_and_log(run)
            {:error, {:timeout, run}} -> summarize_timeout_and_log(run)
            {:error, reason} -> raise RuntimeError, "run failed: #{inspect(reason)}"
          end
        rescue
          exception in CapabilityRequired ->
            summarize_capability_required(spec, opts, exception)
        end

      {:capability_required, summary} ->
        summary
    end
  end

  defp plan_execution(spec, opts) do
    {:ok, ExecutionPlanner.plan!(spec)}
  rescue
    exception in CapabilityRequired ->
      {:capability_required, summarize_capability_required(spec, opts, exception)}
  end

  defp build_strategy(spec, %{strategy: "direct"}), do: Chat.build!(spec)
  defp build_strategy(spec, %{strategy: "tool"} = route), do: Tool.build!(spec, route)

  defp build_strategy(spec, %{strategy: strategy} = route) when strategy in ["planned", "swarm"],
    do: Agentic.build!(spec, route)

  defp maybe_put_auto_time_harness(
         %RunSpec{tool_harnesses: harnesses} = spec,
         %{strategy: "tool", tool_intent: "time"}
       )
       when is_list(harnesses) do
    if Enum.any?(harnesses, &(&1 in [:time, :demo])) do
      spec
    else
      %{spec | tool_harnesses: harnesses ++ [:time]}
    end
  end

  defp maybe_put_auto_time_harness(spec, _execution_strategy), do: spec

  defp write_execution_strategy_event(spec, strategy, opts) do
    Telemetry.execute(
      [:agent_machine, :execution_strategy, :selected],
      %{system_time: Telemetry.system_time()},
      %{execution_strategy: strategy}
    )

    event = %{
      type: :execution_strategy_selected,
      requested: strategy.requested,
      selected: strategy.selected,
      strategy: strategy.strategy,
      reason: strategy.reason,
      tool_intent: strategy.tool_intent,
      tools_exposed: strategy.tools_exposed,
      classifier: Map.get(strategy, :classifier),
      classifier_model: Map.get(strategy, :classifier_model),
      classified_intent: Map.get(strategy, :classified_intent),
      work_shape: Map.get(strategy, :work_shape),
      route_hint: Map.get(strategy, :route_hint),
      confidence: Map.get(strategy, :confidence),
      active_harnesses: Enum.map(spec.tool_harnesses || [], &Atom.to_string/1),
      at: DateTime.utc_now()
    }

    emit_execution_strategy_event(opts, event)
    EventLog.write_event(event)
  end

  defp emit_execution_strategy_event(opts, event) do
    case Keyword.fetch(opts, :event_sink) do
      {:ok, sink} -> sink.(event)
      :error -> :ok
    end
  end

  def json!(summary) when is_map(summary) do
    summary |> Redactor.redact_output() |> Map.fetch!(:value) |> JSON.encode!()
  end

  def jsonl_event!(event) when is_map(event) do
    event =
      event
      |> ProgressObserver.strip_private_evidence()
      |> summarize_event()
      |> Redactor.redact_output()
      |> Map.fetch!(:value)

    JSON.encode!(%{type: "event", event: event})
  end

  def jsonl_summary!(summary) when is_map(summary) do
    summary = summary |> Redactor.redact_output() |> Map.fetch!(:value)
    JSON.encode!(%{type: "summary", summary: summary})
  end

  def summarize_run!(run) when is_map(run), do: summarize_run(run)

  if Mix.env() == :test do
    def summarize_for_test!(run), do: summarize_run(run)
  end

  defp summarize_timeout(run) do
    run
    |> summarize_run()
    |> Map.put(:status, "timeout")
  end

  defp summarize_and_log(run) do
    run
    |> summarize_run()
    |> tap(&EventLog.write_summary/1)
  end

  defp summarize_timeout_and_log(run) do
    run
    |> summarize_timeout()
    |> tap(&EventLog.write_summary/1)
  end

  defp validate_opts!(opts) do
    allowed_keys = [
      :event_sink,
      :permission_control,
      :tool_approval_callback,
      :planner_review_callback
    ]

    unknown_keys = opts |> Keyword.keys() |> Enum.reject(&(&1 in allowed_keys))

    if unknown_keys != [] do
      raise ArgumentError, "unknown client runner option(s): #{inspect(unknown_keys)}"
    end

    validate_optional_callback!(opts, :event_sink)
    validate_optional_callback!(opts, :tool_approval_callback)
    validate_optional_callback!(opts, :planner_review_callback)
  end

  defp put_permission_control(run_opts, opts) do
    case Keyword.fetch(opts, :permission_control) do
      :error ->
        run_opts

      {:ok, control} ->
        run_opts
        |> Keyword.put(:permission_control, control)
        |> maybe_put_request_capability_tool()
    end
  end

  defp maybe_put_request_capability_tool(run_opts) do
    case {Keyword.fetch(run_opts, :allowed_tools), Keyword.fetch(run_opts, :tool_policy)} do
      {{:ok, tools}, {:ok, %ToolPolicy{} = policy}} ->
        tools = Enum.uniq(tools ++ [RequestCapability])
        permissions = tools |> Enum.map(&ToolPolicy.tool_permission!/1) |> Enum.uniq()

        run_opts
        |> Keyword.put(:allowed_tools, tools)
        |> Keyword.put(
          :tool_policy,
          ToolPolicy.new!(harness: policy.harness, permissions: permissions)
        )

      _other ->
        run_opts
    end
  end

  defp validate_optional_callback!(opts, key) do
    case Keyword.fetch(opts, key) do
      :error ->
        :ok

      {:ok, callback} when is_function(callback, 1) ->
        :ok

      {:ok, callback} ->
        raise ArgumentError,
              "#{inspect(key)} must be a function of arity 1, got: #{inspect(callback)}"
    end
  end

  defp validate_runtime_opts!(run_opts, opts) do
    validate_code_edit_shell_budget!(run_opts)
    validate_mcp_browser_budget!(run_opts)

    if Keyword.get(run_opts, :tool_approval_mode) == :ask_before_write and
         approval_callback_required?(run_opts) and
         not Keyword.has_key?(opts, :tool_approval_callback) do
      raise ArgumentError,
            ":tool_approval_callback is required when :tool_approval_mode :ask_before_write exposes write, delete, command, or network tools"
    end

    if Keyword.has_key?(run_opts, :planner_review_mode) and
         not Keyword.has_key?(opts, :planner_review_callback) do
      raise ArgumentError,
            ":planner_review_callback is required when planner review is enabled"
    end
  end

  defp validate_code_edit_shell_budget!(run_opts) do
    if code_edit_shell_exposed?(run_opts) do
      require_minimum_integer!(
        Keyword.get(run_opts, :tool_timeout_ms),
        :tool_timeout_ms,
        @minimum_code_edit_shell_timeout_ms,
        "code-edit shell access",
        reason: :insufficient_tool_timeout,
        intent: :code_mutation,
        required_harness: :code_edit,
        requested_root: Keyword.get(run_opts, :tool_root)
      )

      require_minimum_integer!(
        Keyword.get(run_opts, :tool_max_rounds),
        :tool_max_rounds,
        @minimum_code_edit_shell_max_rounds,
        "code-edit shell access",
        reason: :insufficient_tool_max_rounds,
        intent: :code_mutation,
        required_harness: :code_edit,
        requested_root: Keyword.get(run_opts, :tool_root)
      )
    end
  end

  defp code_edit_shell_exposed?(run_opts) do
    allowed_tools = Keyword.get(run_opts, :allowed_tools, [])
    Enum.any?(@code_edit_shell_tools, &(&1 in allowed_tools))
  end

  defp validate_mcp_browser_budget!(run_opts) do
    if mcp_browser_exposed?(run_opts) do
      require_minimum_integer!(
        Keyword.get(run_opts, :tool_timeout_ms),
        :tool_timeout_ms,
        @minimum_mcp_browser_timeout_ms,
        "MCP browser access",
        reason: :insufficient_tool_timeout,
        intent: :web_browse,
        required_harness: :mcp,
        required_mcp_tool: "browser_navigate"
      )
    end
  end

  defp mcp_browser_exposed?(run_opts) do
    run_opts
    |> Keyword.get(:allowed_tools, [])
    |> Enum.any?(&mcp_browser_tool?/1)
  end

  defp mcp_browser_tool?(tool) when is_atom(tool) do
    Code.ensure_loaded?(tool) and function_exported?(tool, :permission, 0) and
      tool.permission() |> Atom.to_string() |> String.contains?("browser")
  end

  defp mcp_browser_tool?(_tool), do: false

  defp require_minimum_integer!(value, _key, minimum, _label, _capability)
       when is_integer(value) and value >= minimum,
       do: :ok

  defp require_minimum_integer!(value, key, minimum, label, capability) do
    message = "#{label} requires #{inspect(key)} >= #{minimum}, got: #{inspect(value)}"

    raise CapabilityRequired,
          Keyword.merge(capability,
            detail: message,
            message: message
          )
  end

  defp approval_callback_required?(run_opts) do
    run_opts
    |> Keyword.get(:allowed_tools, [])
    |> Enum.any?(&(ToolPolicy.approval_risk!(&1) in [:write, :delete, :command, :network]))
  end

  defp put_tool_approval_callback(run_opts, opts) do
    case Keyword.fetch(opts, :tool_approval_callback) do
      :error -> run_opts
      {:ok, callback} -> Keyword.put(run_opts, :tool_approval_callback, callback)
    end
  end

  defp put_planner_review_callback(run_opts, opts) do
    if Keyword.has_key?(run_opts, :planner_review_mode) do
      case Keyword.fetch(opts, :planner_review_callback) do
        :error -> run_opts
        {:ok, callback} -> Keyword.put(run_opts, :planner_review_callback, callback)
      end
    else
      run_opts
    end
  end

  defp put_progress_observer_opts(run_opts, %{progress_observer: false}), do: run_opts

  defp put_progress_observer_opts(run_opts, %{progress_observer: true} = spec) do
    unless Keyword.has_key?(run_opts, :event_sink) do
      raise ArgumentError, "progress observer requires an explicit event sink"
    end

    Keyword.put(run_opts, :progress_observer, ProgressObserver.from_run_spec!(spec))
  end

  defp put_event_sink(run_opts, opts) do
    case Keyword.fetch(opts, :event_sink) do
      :error ->
        if EventLog.configured?() do
          Keyword.put(run_opts, :event_sink, &EventLog.write_event/1)
        else
          run_opts
        end

      {:ok, sink} ->
        Keyword.put(run_opts, :event_sink, fn event ->
          EventLog.write_event(event)
          sink.(event)
        end)
    end
  end

  defp put_skill_opts(run_opts, spec, selection) do
    selected = Enum.map(selection.selected, & &1.skill)

    run_opts
    |> Keyword.put(:skills_mode, selection.mode)
    |> Keyword.put(:skills_dir, spec.skills_dir)
    |> Keyword.put(:skills_loaded, Enum.map(selection.loaded, &Manifest.catalog_entry/1))
    |> Keyword.put(
      :skills_selected,
      Enum.map(selection.selected, fn %{skill: skill, reason: reason} ->
        %{name: skill.name, description: skill.description, reason: reason}
      end)
    )
    |> Keyword.put(:selected_skills, selected)
    |> Keyword.put(:skills_context, Prompt.context(selection.selected))
    |> Keyword.put(:allow_skill_scripts, spec.allow_skill_scripts)
  end

  defp put_timeout_lease_opts(run_opts, %RunSpec{timeout_ms: timeout_ms}) do
    run_opts
    |> Keyword.put(:idle_timeout_ms, timeout_ms)
    |> Keyword.put(:hard_timeout_ms, timeout_ms * 3)
  end

  defp summarize_capability_required(spec, opts, %CapabilityRequired{} = exception) do
    event = CapabilityRequired.event(exception)
    emit_capability_required_event(opts, event)
    EventLog.write_event(event)

    %{
      run_id: nil,
      status: "failed",
      error: Exception.message(exception),
      final_output: nil,
      execution_strategy: nil,
      workflow_route: nil,
      results: %{},
      artifacts: %{},
      skills: [],
      checklist: [],
      usage: empty_usage(),
      events: [summarize_event(event)],
      agentic_persistence: disabled_agentic_persistence_summary(),
      capability_required: CapabilityRequired.to_map(exception),
      task: spec.task
    }
    |> Redactor.redact_output()
    |> Map.fetch!(:value)
  end

  defp emit_capability_required_event(opts, event) do
    case Keyword.fetch(opts, :event_sink) do
      {:ok, sink} -> sink.(event)
      :error -> :ok
    end
  end

  defp summarize_run(run) do
    failed_results = failed_results(run.results)
    unresolved_failed_results = unresolved_failed_results(run, failed_results)

    %{
      run_id: run.id,
      status: summary_status(run, unresolved_failed_results),
      error: summary_error(run, unresolved_failed_results),
      final_output: final_output(run, unresolved_failed_results),
      execution_strategy: execution_strategy(run),
      workflow_route: workflow_route(run),
      results: summarize_results(run.results),
      artifacts: stringify_map(run.artifacts),
      skills: summarize_skills(run),
      checklist: RunChecklist.from_events(run.events),
      usage: run.usage || empty_usage(),
      agentic_persistence: agentic_persistence_summary(run),
      events: Enum.map(run.events, &summarize_event/1)
    }
    |> Redactor.redact_output()
    |> Map.fetch!(:value)
  end

  defp summary_status(%{status: :completed}, failed_results) when failed_results != [],
    do: "failed"

  defp summary_status(run, _failed_results), do: Atom.to_string(run.status)

  defp summary_error(%{error: error}, _failed_results) when not is_nil(error), do: error

  defp summary_error(_run, failed_results) do
    case failed_results do
      [] ->
        nil

      results ->
        Enum.map_join(results, "\n", fn result ->
          "#{result.agent_id}: #{result.error || "unknown error"}"
        end)
    end
  end

  defp failed_results(results) do
    results
    |> Map.values()
    |> Enum.filter(&(&1.status == :error))
  end

  defp unresolved_failed_results(run, failed_results) do
    if agentic_persistence_completed?(run) do
      Enum.filter(failed_results, &terminal_failed_result?(run, &1))
    else
      failed_results
    end
  end

  defp terminal_failed_result?(_run, %{agent_id: agent_id})
       when agent_id in ["planner", "finalizer"],
       do: true

  defp terminal_failed_result?(run, %{agent_id: agent_id}) do
    run.agent_graph
    |> Map.get(agent_id, %{})
    |> Map.get(:agent_machine_role)
    |> Kernel.==("goal_reviewer")
  end

  defp agentic_persistence_completed?(run) do
    agentic_persistence_summary(run).completed
  end

  defp agentic_persistence_summary(run) do
    rounds = run |> Map.get(:opts, []) |> Keyword.get(:agentic_persistence_rounds)

    %{
      enabled: not is_nil(rounds),
      rounds: rounds,
      continue_count: Map.get(run, :goal_review_continue_count, 0),
      completed: Map.get(run, :goal_review_completed, false)
    }
  end

  defp disabled_agentic_persistence_summary do
    %{enabled: false, rounds: nil, continue_count: 0, completed: false}
  end

  defp final_output(_run, [_failed_result | _rest]), do: nil

  defp final_output(run, []) do
    case Map.fetch(run.results, "finalizer") do
      {:ok, %{status: :ok, output: output}} ->
        output

      :error ->
        direct_planner_output(run.results) || single_assistant_output(run) ||
          single_coordinator_output(run)

      _other ->
        direct_planner_output(run.results) || single_assistant_output(run) ||
          single_coordinator_output(run)
    end
  end

  defp direct_planner_output(%{"planner" => %{status: :ok, decision: decision, output: output}})
       when is_binary(output) do
    if direct_decision?(decision), do: output
  end

  defp direct_planner_output(_results), do: nil

  defp direct_decision?(%{mode: "direct"}), do: true
  defp direct_decision?(%{"mode" => "direct"}), do: true
  defp direct_decision?(_decision), do: false

  defp single_assistant_output(%{
         opts: opts,
         results: %{"assistant" => %{status: :ok, output: output}}
       })
       when is_binary(output) do
    if execution_strategy_selected?(opts, ["direct", "tool"]), do: output
  end

  defp single_assistant_output(_run), do: nil

  defp single_coordinator_output(%{
         opts: opts,
         results: %{"coordinator" => %{status: :ok, output: output}}
       })
       when is_binary(output) do
    if execution_strategy_selected?(opts, ["session"]), do: output
  end

  defp single_coordinator_output(_run), do: nil

  defp execution_strategy_selected?(opts, selected) when is_list(opts) do
    selected = List.wrap(selected)

    case Keyword.get(opts, :execution_strategy) || Keyword.get(opts, :workflow_route) do
      %{selected: route_selected} -> route_selected in selected
      %{"selected" => route_selected} -> route_selected in selected
      _other -> false
    end
  end

  defp execution_strategy_selected?(_opts, _selected), do: false

  defp summarize_results(results) do
    Map.new(results, fn {agent_id, result} ->
      {agent_id,
       %{
         status: Atom.to_string(result.status),
         output: result.output,
         decision: result.decision,
         error: result.error,
         attempt: result.attempt,
         artifacts: result.artifacts || %{},
         tool_results: result.tool_results || %{}
       }}
    end)
  end

  defp summarize_event(event) do
    event
    |> ProgressObserver.strip_private_evidence()
    |> EventSummary.enrich()
    |> Map.new(fn
      {:type, type} -> {:type, Atom.to_string(type)}
      {:at, %DateTime{} = at} -> {:at, DateTime.to_iso8601(at)}
      {key, value} -> {key, summarize_event_value(value)}
    end)
  end

  defp summarize_event_value(%DateTime{} = at), do: DateTime.to_iso8601(at)

  defp summarize_event_value(value) when is_boolean(value), do: value

  defp summarize_event_value(value) when is_atom(value) and not is_nil(value) do
    Atom.to_string(value)
  end

  defp summarize_event_value(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {key, summarize_event_value(nested)} end)
  end

  defp summarize_event_value(value) when is_list(value),
    do: Enum.map(value, &summarize_event_value/1)

  defp summarize_event_value(value), do: value

  defp stringify_map(map) when is_map(map), do: map

  defp workflow_route(run) do
    run
    |> Map.get(:opts, [])
    |> Keyword.get(:workflow_route)
  end

  defp execution_strategy(run) do
    run
    |> Map.get(:opts, [])
    |> Keyword.get(:execution_strategy)
  end

  defp summarize_skills(run) do
    run
    |> Map.get(:opts, [])
    |> Keyword.get(:skills_selected, [])
    |> Enum.map(fn skill ->
      %{
        name: Map.fetch!(skill, :name),
        description: Map.fetch!(skill, :description),
        reason: Map.fetch!(skill, :reason)
      }
    end)
  end

  defp empty_usage do
    %{
      agents: 0,
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      cost_usd: 0.0
    }
  end
end
