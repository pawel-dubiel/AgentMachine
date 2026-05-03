defmodule AgentMachine.RunTree do
  @moduledoc false

  use Supervisor

  def start_link({run_id, agents, finalizer, opts})
      when is_binary(run_id) and is_list(agents) and is_list(opts) do
    Supervisor.start_link(__MODULE__, {run_id, agents, finalizer, opts})
  end

  @impl true
  def init({run_id, agents, finalizer, opts}) do
    event_collector = via_name(:event_collector, run_id)
    progress_observer = via_name(:progress_observer, run_id)
    task_supervisor = via_name(:task_supervisor, run_id)
    tool_session_supervisor = via_name(:tool_session_supervisor, run_id)

    run_opts =
      opts
      |> Keyword.put(:event_collector, event_collector)
      |> Keyword.put(:task_supervisor, task_supervisor)
      |> Keyword.put(:tool_session_supervisor, tool_session_supervisor)

    children =
      progress_observer_children(run_id, opts, progress_observer) ++
        [
          {AgentMachine.RunEventCollector,
           {run_id, Keyword.get(opts, :event_sink),
            progress_observer: progress_observer_name(opts, progress_observer),
            name: event_collector}},
          {Task.Supervisor, name: task_supervisor},
          {AgentMachine.ToolSessionSupervisor, name: tool_session_supervisor},
          {AgentMachine.RunServer, {run_id, agents, finalizer, run_opts}}
        ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  defp progress_observer_children(run_id, opts, name) do
    case Keyword.fetch(opts, :progress_observer) do
      {:ok, config} ->
        event_sink = progress_observer_event_sink!(opts)

        [
          Supervisor.child_spec(
            {AgentMachine.ProgressObserver, {run_id, config, event_sink, name: name}},
            restart: :temporary
          )
        ]

      :error ->
        []
    end
  end

  defp progress_observer_event_sink!(opts) do
    case Keyword.fetch(opts, :event_sink) do
      {:ok, sink} when is_function(sink, 1) ->
        sink

      _other ->
        raise ArgumentError, "progress observer requires an explicit :event_sink"
    end
  end

  defp progress_observer_name(opts, name) do
    if Keyword.has_key?(opts, :progress_observer), do: name
  end

  defp via_name(type, run_id) do
    {:via, Registry, {AgentMachine.RunRegistry, {type, run_id}}}
  end
end
