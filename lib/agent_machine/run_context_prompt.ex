defmodule AgentMachine.RunContextPrompt do
  @moduledoc false

  alias AgentMachine.{JSON, ToolHarness, ToolPolicy}

  def text(opts) when is_list(opts) do
    context = Keyword.fetch!(opts, :run_context)
    results = Map.fetch!(context, :results)
    artifacts = Map.fetch!(context, :artifacts)
    tools = tool_context(opts)

    if map_size(results) == 0 and map_size(artifacts) == 0 and is_nil(tools) do
      ""
    else
      %{results: json_value(results), artifacts: json_value(artifacts)}
      |> maybe_put_tools(tools)
      |> JSON.encode!()
    end
  end

  defp tool_context(opts) do
    case Keyword.fetch(opts, :tool_context) do
      {:ok, context} when is_map(context) ->
        context

      {:ok, context} ->
        raise ArgumentError, ":tool_context must be a map, got: #{inspect(context)}"

      :error ->
        allowed_tool_context(opts)
    end
  end

  defp allowed_tool_context(opts) do
    case Keyword.fetch(opts, :allowed_tools) do
      {:ok, tools} when is_list(tools) and tools != [] ->
        policy = Keyword.fetch!(opts, :tool_policy)

        %{
          harness: harness_name!(policy),
          root: Keyword.get(opts, :tool_root),
          approval_mode: Keyword.fetch!(opts, :tool_approval_mode),
          available_tools: tool_names!(tools),
          test_commands: Keyword.get(opts, :test_commands, []),
          instruction:
            "Use tools for external side effects. For filesystem tools, use paths relative to tool_root unless an absolute path is inside tool_root. If run_test_command is available, use only an exact command from test_commands. Do not claim file or directory changes unless tool_results confirm them."
        }

      {:ok, []} ->
        nil

      :error ->
        nil
    end
  end

  defp maybe_put_tools(context, nil), do: context
  defp maybe_put_tools(context, tools), do: Map.put(context, :tools, json_value(tools))

  defp harness_name!(%ToolPolicy{harness: harness}) when is_atom(harness),
    do: Atom.to_string(harness)

  defp harness_name!(policy) do
    raise ArgumentError, ":tool_policy must include a harness, got: #{inspect(policy)}"
  end

  defp tool_names!(tools) do
    tools
    |> ToolHarness.definitions!()
    |> Enum.map(& &1.name)
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
