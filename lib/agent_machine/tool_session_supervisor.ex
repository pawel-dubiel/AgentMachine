defmodule AgentMachine.ToolSessionSupervisor do
  @moduledoc false

  use DynamicSupervisor

  alias AgentMachine.MCP.{Config, Session}

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    DynamicSupervisor.start_link(__MODULE__, :ok, name: name)
  end

  def start_mcp_session(supervisor, run_id, agent_id, attempt, %Config{} = config)
      when is_binary(run_id) and is_binary(agent_id) and is_integer(attempt) do
    metadata = %{run_id: run_id, agent_id: agent_id, attempt: attempt}
    DynamicSupervisor.start_child(supervisor, {Session, {config, metadata}})
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
