defmodule AgentMachine.ContextBudget do
  @moduledoc false

  alias AgentMachine.Agent

  def event(%Agent{} = agent, context, usage, opts) when is_map(context) and is_list(opts) do
    input_tokens = usage_integer!(usage, :input_tokens)
    output_tokens = usage_integer!(usage, :output_tokens)
    total_tokens = usage_integer!(usage, :total_tokens)

    base = %{
      type: :context_budget,
      run_id: Map.fetch!(context, :run_id),
      agent_id: agent.id,
      attempt: Map.fetch!(context, :attempt),
      model: agent.model,
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      total_tokens: total_tokens,
      at: DateTime.utc_now()
    }

    case Keyword.get(opts, :context_window_tokens) do
      tokens when is_integer(tokens) and tokens > 0 ->
        used_percent = percent(total_tokens, tokens)
        warning_percent = Keyword.get(opts, :context_warning_percent)

        base
        |> Map.merge(%{
          status: status(used_percent, warning_percent),
          context_window_tokens: tokens,
          used_percent: used_percent,
          remaining_percent: max(0, 100 - used_percent)
        })
        |> maybe_put_warning_percent(warning_percent)

      nil ->
        Map.merge(base, %{
          status: "unknown",
          reason: "missing_context_window_tokens"
        })

      other ->
        raise ArgumentError,
              ":context_window_tokens must be a positive integer, got: #{inspect(other)}"
    end
  end

  def threshold_reached?(usage, context_window_tokens, percent)
      when is_integer(context_window_tokens) and context_window_tokens > 0 and is_integer(percent) and
             percent >= 1 and percent <= 100 do
    used_percent = usage |> usage_integer!(:total_tokens) |> percent(context_window_tokens)
    used_percent >= percent
  end

  def threshold_reached?(_usage, context_window_tokens, percent) do
    raise ArgumentError,
          "context threshold requires positive :context_window_tokens and percent 1..100, got: #{inspect({context_window_tokens, percent})}"
  end

  defp status(_used_percent, nil), do: "ok"

  defp status(used_percent, warning_percent) when is_integer(warning_percent) do
    if used_percent >= warning_percent, do: "warning", else: "ok"
  end

  defp status(_used_percent, warning_percent) do
    raise ArgumentError,
          ":context_warning_percent must be an integer between 1 and 100, got: #{inspect(warning_percent)}"
  end

  defp maybe_put_warning_percent(event, nil), do: event

  defp maybe_put_warning_percent(event, warning_percent) when is_integer(warning_percent),
    do: Map.put(event, :warning_percent, warning_percent)

  defp percent(tokens, context_window_tokens) do
    tokens
    |> Kernel.*(100)
    |> Kernel./(context_window_tokens)
    |> Float.round(1)
  end

  defp usage_integer!(usage, field) when is_map(usage) do
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

  defp usage_integer!(usage, _field) do
    raise ArgumentError, "provider usage must be a map, got: #{inspect(usage)}"
  end
end
