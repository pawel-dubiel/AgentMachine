defmodule AgentMachine.RunContextPrompt do
  @moduledoc false

  alias AgentMachine.{JSON, ToolHarness, ToolPolicy}

  def text(opts) when is_list(opts) do
    context = Keyword.fetch!(opts, :run_context)
    results = Map.fetch!(context, :results)
    artifacts = Map.fetch!(context, :artifacts)
    tools = tool_context(opts)
    skills = skills_context(opts)
    runtime = runtime_context(opts)

    if map_size(results) == 0 and map_size(artifacts) == 0 and is_nil(tools) and is_nil(runtime) and
         empty_skills?(skills) do
      ""
    else
      %{results: json_value(results), artifacts: json_value(artifacts)}
      |> maybe_put_runtime(runtime)
      |> maybe_put_tools(tools)
      |> maybe_put_skills(skills)
      |> JSON.encode!()
    end
  end

  def runtime_facts(opts \\ []) when is_list(opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    route = Keyword.get(opts, :workflow_route)

    %{
      current_utc: DateTime.to_iso8601(now),
      utc_date: Date.to_iso8601(DateTime.to_date(now)),
      local_timezone: local_timezone(),
      agent_machine: agent_machine_facts(),
      instruction: "Use these runtime facts when relevant. Do not invent dates or times."
    }
    |> maybe_put_workflow_route(route)
  end

  defp skills_context(opts) do
    case Keyword.fetch(opts, :skills_context) do
      {:ok, skills} when is_list(skills) ->
        skills

      {:ok, skills} ->
        raise ArgumentError, ":skills_context must be a list, got: #{inspect(skills)}"

      :error ->
        []
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
            "Use tools for external side effects. For filesystem tools, use paths relative to tool_root unless an absolute path is inside tool_root. When the user names a directory or file, inspect that exact relative path with list_files, file_info, or read_file before using search_files. Use search_files only for content search under a narrow path, not to locate file or directory names across the whole tool_root. If run_test_command is available, use only an exact command from test_commands. Do not claim file or directory changes unless tool_results confirm them."
        }

      {:ok, []} ->
        nil

      :error ->
        nil
    end
  end

  defp maybe_put_tools(context, nil), do: context
  defp maybe_put_tools(context, tools), do: Map.put(context, :tools, json_value(tools))
  defp maybe_put_runtime(context, nil), do: context
  defp maybe_put_runtime(context, runtime), do: Map.put(context, :runtime, json_value(runtime))
  defp maybe_put_skills(context, []), do: context
  defp maybe_put_skills(context, skills), do: Map.put(context, :skills, json_value(skills))

  defp runtime_context(opts) do
    case Keyword.get(opts, :runtime_facts, :auto) do
      false ->
        nil

      nil ->
        nil

      facts when is_map(facts) ->
        facts

      :auto ->
        runtime_facts(workflow_route: Keyword.get(opts, :workflow_route))

      other ->
        raise ArgumentError,
              ":runtime_facts must be a map, false, nil, or :auto, got: #{inspect(other)}"
    end
  end

  defp maybe_put_workflow_route(facts, nil), do: facts

  defp maybe_put_workflow_route(facts, route) when is_map(route) do
    Map.put(
      facts,
      :workflow_route,
      Map.take(route, [:requested, :selected, :reason, :tool_intent])
    )
  end

  defp agent_machine_facts do
    %{
      role: "assistant running inside AgentMachine",
      execution_model:
        "Models do not directly spawn OS processes. They return text, tool calls, or structured delegation; the Elixir runtime executes tools and starts delegated worker agents.",
      workflows: %{
        chat: "no tools, workers, or side effects",
        tool: "read-only tool calls when selected by auto routing",
        agentic: "planner may return next_agents; Elixir runtime starts worker agents"
      },
      instruction:
        "Be precise about the selected route. Do not claim AgentMachine lacks agents. In chat route, explain that concrete 'use agents to do X' requests can be routed through agentic workflow, but this chat run has no workers or tools."
    }
  end

  defp local_timezone do
    System.get_env("TZ") || "UTC"
  end

  defp empty_skills?([]), do: true
  defp empty_skills?(_skills), do: false

  defp harness_name!(%ToolPolicy{harness: harness}) when is_atom(harness),
    do: Atom.to_string(harness)

  defp harness_name!(%ToolPolicy{harness: harnesses}) when is_list(harnesses) do
    Enum.map(harnesses, &Atom.to_string/1)
  end

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
