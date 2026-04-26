defmodule AgentMachine.AgentResult do
  @moduledoc """
  Result returned by a spawned agent task.
  """

  @enforce_keys [:run_id, :agent_id, :status]
  defstruct [
    :run_id,
    :agent_id,
    :status,
    :attempt,
    :output,
    :decision,
    :next_agents,
    :artifacts,
    :tool_results,
    :events,
    :usage,
    :error,
    :started_at,
    :finished_at
  ]
end
