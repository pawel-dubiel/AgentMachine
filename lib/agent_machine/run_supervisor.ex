defmodule AgentMachine.RunSupervisor do
  @moduledoc false

  use DynamicSupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def start_run(run_id, agents, finalizer, opts)
      when is_binary(run_id) and is_list(agents) and is_list(opts) do
    child = {AgentMachine.RunTree, {run_id, agents, finalizer, opts}}
    DynamicSupervisor.start_child(__MODULE__, child)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
