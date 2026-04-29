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
    task_supervisor = via_name(:task_supervisor, run_id)
    tool_session_supervisor = via_name(:tool_session_supervisor, run_id)

    run_opts =
      opts
      |> Keyword.put(:event_collector, event_collector)
      |> Keyword.put(:task_supervisor, task_supervisor)
      |> Keyword.put(:tool_session_supervisor, tool_session_supervisor)

    children = [
      {AgentMachine.RunEventCollector,
       {run_id, Keyword.get(opts, :event_sink), name: event_collector}},
      {Task.Supervisor, name: task_supervisor},
      {AgentMachine.ToolSessionSupervisor, name: tool_session_supervisor},
      {AgentMachine.RunServer, {run_id, agents, finalizer, run_opts}}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  defp via_name(type, run_id) do
    {:via, Registry, {AgentMachine.RunRegistry, {type, run_id}}}
  end
end
