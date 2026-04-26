defmodule AgentMachine.ClientRunner do
  @moduledoc """
  High-level client runner used by CLI and TUI frontends.
  """

  alias AgentMachine.{JSON, Orchestrator, RunSpec}
  alias AgentMachine.Secrets.Redactor
  alias AgentMachine.Workflows.{Agentic, Basic}

  def run!(attrs, opts \\ []) when is_list(opts) do
    validate_opts!(opts)
    spec = RunSpec.new!(attrs)
    {agents, run_opts} = workflow_module(spec).build!(spec)
    run_opts = put_event_sink(run_opts, opts)

    case Orchestrator.run(agents, run_opts) do
      {:ok, run} -> summarize_run(run)
      {:error, {:failed, run}} -> summarize_run(run)
      {:error, {:timeout, run}} -> summarize_timeout(run)
      {:error, reason} -> raise RuntimeError, "run failed: #{inspect(reason)}"
    end
  end

  defp workflow_module(%RunSpec{workflow: :basic}), do: Basic
  defp workflow_module(%RunSpec{workflow: :agentic}), do: Agentic

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
      :error -> run_opts
      {:ok, sink} -> Keyword.put(run_opts, :event_sink, sink)
    end
  end

  defp summarize_run(run) do
    failed_results = failed_results(run.results)

    %{
      run_id: run.id,
      status: summary_status(run, failed_results),
      error: summary_error(run, failed_results),
      final_output: final_output(run),
      results: summarize_results(run.results),
      artifacts: stringify_map(run.artifacts),
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
      :error -> nil
      _other -> nil
    end
  end

  defp summarize_results(results) do
    Map.new(results, fn {agent_id, result} ->
      {agent_id,
       %{
         status: Atom.to_string(result.status),
         output: result.output,
         error: result.error,
         attempt: result.attempt,
         artifacts: result.artifacts || %{},
         tool_results: result.tool_results || %{}
       }}
    end)
  end

  defp summarize_event(event) do
    Map.new(event, fn
      {:type, type} -> {:type, Atom.to_string(type)}
      {key, value} when is_atom(value) and not is_nil(value) -> {key, Atom.to_string(value)}
      {:at, %DateTime{} = at} -> {:at, DateTime.to_iso8601(at)}
      {key, value} -> {key, value}
    end)
  end

  defp stringify_map(map) when is_map(map), do: map

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
