defmodule AgentMachine.WorkflowOptions do
  @moduledoc false

  alias AgentMachine.RunSpec

  def put_context_opts(opts, %RunSpec{} = spec) when is_list(opts) do
    opts
    |> maybe_put(:context_window_tokens, spec.context_window_tokens)
    |> maybe_put(:context_warning_percent, spec.context_warning_percent)
    |> maybe_put(:context_tokenizer_path, spec.context_tokenizer_path)
    |> maybe_put(:reserved_output_tokens, spec.reserved_output_tokens)
    |> maybe_put(:run_context_compaction, enabled_compaction(spec.run_context_compaction))
    |> maybe_put(:run_context_compact_percent, spec.run_context_compact_percent)
    |> maybe_put(:max_context_compactions, spec.max_context_compactions)
    |> maybe_put(:conversation_context, conversation_context(spec))
  end

  defp conversation_context(%RunSpec{} = spec) do
    %{}
    |> maybe_put_context(:recent_context, spec.recent_context)
    |> maybe_put_context(:pending_action, spec.pending_action)
    |> then(fn
      context when map_size(context) == 0 -> nil
      context -> context
    end)
  end

  defp maybe_put_context(context, _key, nil), do: context
  defp maybe_put_context(context, key, value), do: Map.put(context, key, value)

  defp enabled_compaction(:on), do: :on
  defp enabled_compaction(_other), do: nil

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
