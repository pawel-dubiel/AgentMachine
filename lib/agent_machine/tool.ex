defmodule AgentMachine.Tool do
  @moduledoc """
  Tool contract for explicit agent actions.
  """

  @callback run(map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback permission() :: atom()
  @callback definition() :: %{
              name: binary(),
              description: binary(),
              input_schema: map()
            }

  @optional_callbacks definition: 0, permission: 0
end
