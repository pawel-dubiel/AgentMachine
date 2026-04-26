defmodule AgentMachine.Providers.Echo do
  @moduledoc """
  Local provider for development and tests.

  It does not call an LLM. It echoes the input and emits deterministic fake usage
  so the rest of the orchestration path can be tested without network access.
  """

  @behaviour AgentMachine.Provider

  alias AgentMachine.{Agent, JSON}

  @impl true
  def complete(%Agent{} = agent, _opts) do
    input_tokens = token_count(agent.input) + token_count(agent.instructions)
    output = output(agent)
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

  @impl true
  def stream_complete(%Agent{} = agent, opts) do
    output = output(agent)
    emit_delta(opts, output)
    emit_done(opts)

    input_tokens = token_count(agent.input) + token_count(agent.instructions)
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

  defp emit_delta(opts, delta) do
    context = Keyword.fetch!(opts, :stream_context)
    sink = Keyword.fetch!(opts, :stream_event_sink)

    sink.(%{
      type: :assistant_delta,
      run_id: context.run_id,
      agent_id: context.agent_id,
      attempt: context.attempt,
      delta: delta,
      at: DateTime.utc_now()
    })
  end

  defp emit_done(opts) do
    context = Keyword.fetch!(opts, :stream_context)
    sink = Keyword.fetch!(opts, :stream_event_sink)

    sink.(%{
      type: :assistant_done,
      run_id: context.run_id,
      agent_id: context.agent_id,
      attempt: context.attempt,
      at: DateTime.utc_now()
    })
  end

  defp output(%Agent{} = agent) do
    if structured_delegation_response?(agent) do
      JSON.encode!(%{
        "decision" => %{
          "mode" => "direct",
          "reason" => "Echo provider completes structured planner requests directly."
        },
        "output" => "agent #{agent.id}: #{agent.input}",
        "next_agents" => []
      })
    else
      "agent #{agent.id}: #{agent.input}"
    end
  end

  defp structured_delegation_response?(%Agent{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, :agent_machine_response) == "delegation" ||
      Map.get(metadata, "agent_machine_response") == "delegation"
  end

  defp structured_delegation_response?(_agent), do: false

  defp token_count(nil), do: 0

  defp token_count(text) when is_binary(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end
end
