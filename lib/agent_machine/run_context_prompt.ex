defmodule AgentMachine.RunContextPrompt do
  @moduledoc false

  alias AgentMachine.JSON

  def text(opts) when is_list(opts) do
    context = Keyword.fetch!(opts, :run_context)
    results = Map.fetch!(context, :results)
    artifacts = Map.fetch!(context, :artifacts)

    if map_size(results) == 0 and map_size(artifacts) == 0 do
      ""
    else
      JSON.encode!(%{results: json_value(results), artifacts: json_value(artifacts)})
    end
  end

  defp json_value(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {json_key!(key), json_value(item)} end)
  end

  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)
  defp json_value(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp json_value(value) when is_binary(value), do: value
  defp json_value(value) when is_integer(value), do: value
  defp json_value(value) when is_float(value), do: value
  defp json_value(value) when is_boolean(value), do: value
  defp json_value(nil), do: nil

  defp json_value(value) do
    raise ArgumentError, "run context contains unsupported JSON value: #{inspect(value)}"
  end

  defp json_key!(key) when is_binary(key), do: key
  defp json_key!(key) when is_atom(key), do: Atom.to_string(key)

  defp json_key!(key) do
    raise ArgumentError, "run context contains unsupported JSON key: #{inspect(key)}"
  end
end
