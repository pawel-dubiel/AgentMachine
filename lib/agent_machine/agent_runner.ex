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
      {:ok, %{output: output, usage: provider_usage}} when is_binary(output) ->
        usage = Usage.from_provider!(agent, run_id, provider_usage)
        :ok = UsageLedger.record!(usage)

        %AgentResult{
          run_id: run_id,
          agent_id: agent.id,
          status: :ok,
          output: output,
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
end
