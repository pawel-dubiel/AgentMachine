defmodule AgentMachine.AgentRunner do
  @moduledoc false

  alias AgentMachine.{Agent, AgentResult, Usage, UsageLedger}

  def run(%Agent{} = agent, opts) when is_list(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    started_at = DateTime.utc_now()

    execute(agent, opts, run_id, started_at)
  end

  defp execute(agent, opts, run_id, started_at) do
    case agent.provider.complete(agent, opts) do
      {:ok, %{output: output, usage: provider_usage} = payload} when is_binary(output) ->
        usage = Usage.from_provider!(agent, run_id, provider_usage)
        next_agents = next_agents_from_payload!(payload)
        :ok = UsageLedger.record!(usage)

        %AgentResult{
          run_id: run_id,
          agent_id: agent.id,
          status: :ok,
          output: output,
          next_agents: next_agents,
          usage: usage,
          started_at: started_at,
          finished_at: DateTime.utc_now()
        }

      {:ok, other} ->
        error(
          agent,
          run_id,
          started_at,
          "provider returned invalid success payload: #{inspect(other)}"
        )

      {:error, reason} ->
        error(agent, run_id, started_at, inspect(reason))

      other ->
        error(agent, run_id, started_at, "provider returned invalid payload: #{inspect(other)}")
    end
  rescue
    exception ->
      %AgentResult{
        run_id: run_id,
        agent_id: agent.id,
        status: :error,
        error: Exception.format(:error, exception, __STACKTRACE__),
        started_at: started_at,
        finished_at: DateTime.utc_now()
      }
  end

  defp error(agent, run_id, started_at, reason) do
    %AgentResult{
      run_id: run_id,
      agent_id: agent.id,
      status: :error,
      error: reason,
      started_at: started_at,
      finished_at: DateTime.utc_now()
    }
  end

  defp next_agents_from_payload!(payload) when is_map(payload) do
    case fetch_optional_payload_field(payload, :next_agents) do
      :error ->
        []

      {:ok, specs} when is_list(specs) ->
        Enum.map(specs, &Agent.new!/1)

      {:ok, specs} ->
        raise ArgumentError,
              "provider next_agents must be a list of agent specs, got: #{inspect(specs)}"
    end
  end

  defp fetch_optional_payload_field(payload, field) do
    string_field = Atom.to_string(field)

    cond do
      Map.has_key?(payload, field) -> {:ok, Map.fetch!(payload, field)}
      Map.has_key?(payload, string_field) -> {:ok, Map.fetch!(payload, string_field)}
      true -> :error
    end
  end
end
