defmodule AgentMachine.RouterAdvice do
  @moduledoc false

  @work_shapes [
    :conversation,
    :narrow_read,
    :broad_project_analysis,
    :mutation,
    :test_execution,
    :web_research,
    :explicit_delegation,
    :generic_tool_use
  ]

  @route_hints [:chat, :tool, :agentic]

  @work_shape_lookup Map.new(@work_shapes, &{Atom.to_string(&1), &1})
  @route_hint_lookup Map.new(@route_hints, &{Atom.to_string(&1), &1})

  def work_shapes, do: @work_shapes
  def route_hints, do: @route_hints

  def normalize_work_shape!(value, label \\ "invalid work_shape"),
    do: normalize!(value, @work_shapes, @work_shape_lookup, label)

  def normalize_route_hint!(value, label \\ "invalid route_hint"),
    do: normalize!(value, @route_hints, @route_hint_lookup, label)

  defp normalize!(value, valid_values, lookup, label) when is_atom(value) do
    if value in valid_values do
      value
    else
      raise_invalid!(value, lookup, label)
    end
  end

  defp normalize!(value, _valid_values, lookup, label) when is_binary(value) do
    case Map.fetch(lookup, value) do
      {:ok, normalized} -> normalized
      :error -> raise_invalid!(value, lookup, label)
    end
  end

  defp normalize!(value, _valid_values, lookup, label), do: raise_invalid!(value, lookup, label)

  defp raise_invalid!(value, lookup, label) do
    valid_values = lookup |> Map.keys() |> Enum.sort() |> Enum.join(", ")
    raise ArgumentError, "#{label}: #{inspect(value)}; valid values: #{valid_values}"
  end
end
