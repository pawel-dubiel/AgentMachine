defmodule AgentMachine.Tool do
  @moduledoc """
  Tool contract for explicit agent actions.
  """

  @callback run(map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback permission() :: atom()
  @callback approval_risk() :: :read | :write | :delete | :command | :network
  @callback definition() :: %{
              name: binary(),
              description: binary(),
              input_schema: map()
            }
  @callback definition(keyword()) :: %{
              name: binary(),
              description: binary(),
              input_schema: map()
            }

  @optional_callbacks definition: 0, definition: 1, permission: 0, approval_risk: 0
end
