defmodule AgentMachine.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: AgentMachine.RunRegistry},
      AgentMachine.RunSupervisor,
      {Task.Supervisor, name: AgentMachine.AgentSupervisor},
      AgentMachine.SessionSupervisor,
      {Task.Supervisor, name: AgentMachine.LLMRouter.TaskSupervisor},
      AgentMachine.LLMRouter,
      AgentMachine.ShellCommandRegistry,
      AgentMachine.UsageLedger,
      AgentMachine.EventLog,
      AgentMachine.Orchestrator
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: AgentMachine.Supervisor)
  end
end
