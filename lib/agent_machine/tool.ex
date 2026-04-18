defmodule AgentMachine.Tool do
  @moduledoc """
  Tool contract for explicit agent actions.
  """

  @callback run(map(), keyword()) :: {:ok, map()} | {:error, term()}
end
