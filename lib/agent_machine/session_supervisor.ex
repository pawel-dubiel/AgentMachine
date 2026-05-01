defmodule AgentMachine.SessionSupervisor do
  @moduledoc """
  Supervises long-lived interactive sessions and their background agent tasks.
  """

  use Supervisor

  def start_link(opts) when is_list(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def start_session(opts) when is_list(opts) do
    DynamicSupervisor.start_child(
      AgentMachine.SessionDynamicSupervisor,
      {AgentMachine.SessionServer, opts}
    )
  end

  @impl true
  def init(_opts) do
    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: AgentMachine.SessionDynamicSupervisor},
      {Task.Supervisor, name: AgentMachine.SessionTaskSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
