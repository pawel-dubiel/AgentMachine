defmodule AgentMachine.ClientRunner do
  @moduledoc """
  High-level client runner used by CLI and TUI frontends.
  """

  alias AgentMachine.{EventLog, EventSummary, JSON, Orchestrator, RunSpec, WorkflowRouter}
  alias AgentMachine.Secrets.Redactor
  alias AgentMachine.Skills.{Manifest, Prompt, Selector}
  alias AgentMachine.Workflows.{Agentic, Basic, Chat}

  def run!(attrs, opts \\ []) when is_list(opts) do
    validate_opts!(opts)
    spec = RunSpec.new!(attrs)
    workflow_route = WorkflowRouter.route!(spec)
    spec = maybe_put_auto_time_harness(spec, workflow_route)
    write_workflow_route_event(spec, workflow_route)
    skill_selection = Selector.select!(spec)
    {agents, run_opts} = workflow_module(workflow_route).build!(spec)
    run_opts = put_skill_opts(run_opts, spec, skill_selection)
    run_opts = Keyword.put(run_opts, :workflow_route, workflow_route)
    run_opts = put_event_sink(run_opts, opts)

    case Orchestrator.run(agents, run_opts) do
      {:ok, run} -> summarize_and_log(run)
      {:error, {:failed, run}} -> summarize_and_log(run)
      {:error, {:timeout, run}} -> summarize_timeout_and_log(run)
      {:error, reason} -> raise RuntimeError, "run failed: #{inspect(reason)}"
    end
  end

  defp workflow_module(%{selected: "chat"}), do: Chat
  defp workflow_module(%{selected: "basic"}), do: Basic
  defp workflow_module(%{selected: "agentic"}), do: Agentic

  defp maybe_put_auto_time_harness(
         %RunSpec{tool_harnesses: harnesses} = spec,
         %{reason: "time_intent_with_auto_time_harness"}
       )
       when is_list(harnesses) do
    if Enum.any?(harnesses, &(&1 in [:time, :demo])) do
      spec
    else
      %{spec | tool_harnesses: harnesses ++ [:time]}
    end
  end

  defp maybe_put_auto_time_harness(spec, _workflow_route), do: spec

  defp write_workflow_route_event(spec, route) do
    EventLog.write_event(%{
      type: :workflow_routed,
      requested: route.requested,
      selected: route.selected,
      reason: route.reason,
      tool_intent: route.tool_intent,
      tools_exposed: route.tools_exposed,
      classifier: Map.get(route, :classifier),
      classified_intent: Map.get(route, :classified_intent),
      confidence: Map.get(route, :confidence),
      active_harnesses: Enum.map(spec.tool_harnesses || [], &Atom.to_string/1),
      at: DateTime.utc_now()
    })
  end

  def json!(summary) when is_map(summary) do
    summary |> Redactor.redact_output() |> Map.fetch!(:value) |> JSON.encode!()
  end

  def jsonl_event!(event) when is_map(event) do
    event = event |> summarize_event() |> Redactor.redact_output() |> Map.fetch!(:value)
    JSON.encode!(%{type: "event", event: event})
  end

  def jsonl_summary!(summary) when is_map(summary) do
    summary = summary |> Redactor.redact_output() |> Map.fetch!(:value)
    JSON.encode!(%{type: "summary", summary: summary})
  end

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
    allowed_keys = [:event_sink]
    unknown_keys = opts |> Keyword.keys() |> Enum.reject(&(&1 in allowed_keys))

    if unknown_keys != [] do
      raise ArgumentError, "unknown client runner option(s): #{inspect(unknown_keys)}"
    end

    case Keyword.fetch(opts, :event_sink) do
      :error ->
        :ok

      {:ok, sink} when is_function(sink, 1) ->
        :ok

      {:ok, sink} ->
        raise ArgumentError, ":event_sink must be a function of arity 1, got: #{inspect(sink)}"
    end
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

  defp summarize_run(run) do
    failed_results = failed_results(run.results)

    %{
      run_id: run.id,
      status: summary_status(run, failed_results),
      error: summary_error(run, failed_results),
      final_output: final_output(run),
      workflow_route: workflow_route(run),
      results: summarize_results(run.results),
      artifacts: stringify_map(run.artifacts),
      skills: summarize_skills(run),
      usage: run.usage || empty_usage(),
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

  defp final_output(run) do
    case Map.fetch(run.results, "finalizer") do
      {:ok, %{status: :ok, output: output}} -> output
      :error -> direct_planner_output(run.results) || chat_assistant_output(run)
      _other -> direct_planner_output(run.results) || chat_assistant_output(run)
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

  defp chat_assistant_output(%{
         opts: opts,
         results: %{"assistant" => %{status: :ok, output: output}}
       })
       when is_binary(output) do
    if workflow_route_selected?(opts, "chat"), do: output
  end

  defp chat_assistant_output(_run), do: nil

  defp workflow_route_selected?(opts, selected) when is_list(opts) do
    case Keyword.get(opts, :workflow_route) do
      %{selected: ^selected} -> true
      %{"selected" => ^selected} -> true
      _other -> false
    end
  end

  defp workflow_route_selected?(_opts, _selected), do: false

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
