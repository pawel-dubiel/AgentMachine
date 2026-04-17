defmodule AgentMachine.Providers.Echo do
  @moduledoc """
  Local provider for development and tests.

  It does not call an LLM. It echoes the input and emits deterministic fake usage
  so the rest of the orchestration path can be tested without network access.
  """

  @behaviour AgentMachine.Provider

  alias AgentMachine.Agent

  @impl true
  def complete(%Agent{} = agent, _opts) do
    input_tokens = token_count(agent.input) + token_count(agent.instructions)
    output = "agent #{agent.id}: #{agent.input}"
    output_tokens = token_count(output)

    {:ok,
     %{
       output: output,
       usage: %{
         input_tokens: input_tokens,
         output_tokens: output_tokens,
         total_tokens: input_tokens + output_tokens
       }
     }}
  end

  defp token_count(nil), do: 0

  defp token_count(text) when is_binary(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end
end
