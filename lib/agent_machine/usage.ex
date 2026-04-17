defmodule AgentMachine.Usage do
  @moduledoc """
  Normalized usage and cost entry for one agent execution.
  """

  alias AgentMachine.{Agent, Pricing}

  @enforce_keys [
    :run_id,
    :agent_id,
    :provider,
    :model,
    :input_tokens,
    :output_tokens,
    :total_tokens,
    :cost_usd,
    :recorded_at
  ]
  defstruct [
    :run_id,
    :agent_id,
    :provider,
    :model,
    :input_tokens,
    :output_tokens,
    :total_tokens,
    :cost_usd,
    :recorded_at
  ]

  def from_provider!(%Agent{} = agent, run_id, provider_usage) when is_binary(run_id) do
    input_tokens = fetch_usage_integer!(provider_usage, :input_tokens)
    output_tokens = fetch_usage_integer!(provider_usage, :output_tokens)
    total_tokens = fetch_usage_integer!(provider_usage, :total_tokens)
    cost_usd = Pricing.cost_usd!(agent.pricing, input_tokens, output_tokens)

    %__MODULE__{
      run_id: run_id,
      agent_id: agent.id,
      provider: agent.provider,
      model: agent.model,
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      total_tokens: total_tokens,
      cost_usd: cost_usd,
      recorded_at: DateTime.utc_now()
    }
  end

  defp fetch_usage_integer!(usage, field) when is_map(usage) do
    value =
      cond do
        Map.has_key?(usage, field) -> Map.fetch!(usage, field)
        Map.has_key?(usage, Atom.to_string(field)) -> Map.fetch!(usage, Atom.to_string(field))
        true -> raise ArgumentError, "provider usage is missing required field: #{inspect(field)}"
      end

    if is_integer(value) and value >= 0 do
      value
    else
      raise ArgumentError,
            "provider usage #{inspect(field)} must be a non-negative integer, got: #{inspect(value)}"
    end
  end

  defp fetch_usage_integer!(usage, _field) do
    raise ArgumentError, "provider usage must be a map, got: #{inspect(usage)}"
  end
end
