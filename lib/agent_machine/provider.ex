defmodule AgentMachine.Provider do
  @moduledoc """
  Provider contract for agent execution.
  """

  alias AgentMachine.Agent

  @callback complete(Agent.t(), keyword()) ::
              {:ok,
               %{
                 required(:output) => binary(),
                 required(:usage) => map()
               }}
              | {:error, term()}
end
