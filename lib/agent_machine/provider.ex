defmodule AgentMachine.Provider do
  @moduledoc """
  Provider contract for agent execution.
  """

  alias AgentMachine.Agent

  @callback complete(Agent.t(), keyword()) ::
              {:ok,
               %{
                 required(:output) => binary(),
                 required(:usage) => map(),
                 optional(:next_agents) => [map() | keyword() | Agent.t()],
                 optional(:artifacts) => map(),
                 optional(:tool_calls) => [map()],
                 optional(:tool_state) => term()
               }}
              | {:error, term()}

  @callback stream_complete(Agent.t(), keyword()) ::
              {:ok,
               %{
                 required(:output) => binary(),
                 required(:usage) => map(),
                 optional(:next_agents) => [map() | keyword() | Agent.t()],
                 optional(:artifacts) => map(),
                 optional(:tool_calls) => [map()],
                 optional(:tool_state) => term()
               }}
              | {:error, term()}

  @optional_callbacks stream_complete: 2
end
