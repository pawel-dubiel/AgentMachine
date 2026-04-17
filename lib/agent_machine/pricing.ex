defmodule AgentMachine.Pricing do
  @moduledoc """
  Cost calculation from token usage and explicit per-million-token pricing.
  """

  @required_fields [:input_per_million, :output_per_million]

  def validate!(pricing) when is_map(pricing) do
    missing = Enum.reject(@required_fields, &Map.has_key?(pricing, &1))

    case missing do
      [] ->
        require_number!(pricing.input_per_million, :input_per_million)
        require_number!(pricing.output_per_million, :output_per_million)
        pricing

      fields ->
        raise ArgumentError, "pricing is missing required field(s): #{inspect(fields)}"
    end
  end

  def validate!(pricing) do
    raise ArgumentError, "pricing must be a map, got: #{inspect(pricing)}"
  end

  def cost_usd!(pricing, input_tokens, output_tokens) do
    validate!(pricing)
    require_non_negative_integer!(input_tokens, :input_tokens)
    require_non_negative_integer!(output_tokens, :output_tokens)

    input_cost = input_tokens / 1_000_000 * pricing.input_per_million
    output_cost = output_tokens / 1_000_000 * pricing.output_per_million

    input_cost + output_cost
  end

  defp require_number!(value, _field) when is_number(value) and value >= 0 do
    :ok
  end

  defp require_number!(value, field) do
    raise ArgumentError,
          "pricing #{inspect(field)} must be a non-negative number, got: #{inspect(value)}"
  end

  defp require_non_negative_integer!(value, _field) when is_integer(value) and value >= 0 do
    :ok
  end

  defp require_non_negative_integer!(value, field) do
    raise ArgumentError,
          "#{inspect(field)} must be a non-negative integer, got: #{inspect(value)}"
  end
end
