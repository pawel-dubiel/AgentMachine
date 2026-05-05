defmodule AgentMachine.RunContextPrompt do
  @moduledoc false

  alias AgentMachine.{JSON, ToolHarness, ToolPolicy}

  def text(opts) when is_list(opts) do
    opts
    |> budget_sections()
    |> Map.fetch!(:full_text)
  end

  def budget_sections(opts) when is_list(opts) do
    context = Keyword.fetch!(opts, :run_context)
    results = Map.fetch!(context, :results)
    artifacts = Map.fetch!(context, :artifacts)
    agent_graph = Map.get(context, :agent_graph, %{})
    tools = tool_context(opts)
    skills = skills_context(opts)
    runtime = runtime_context(opts)

    run_context =
      %{results: json_value(results), artifacts: json_value(artifacts)}
      |> maybe_put_agent_graph(agent_graph)
      |> maybe_put_runtime(runtime)
      |> maybe_put_tools(tools)

    full_context = maybe_put_skills(run_context, skills)

    %{
      full_text: context_text(full_context, skills),
      run_context: run_context_text(run_context),
      skills: skills_text(skills)
    }
  end

  def runtime_facts(opts \\ []) when is_list(opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    strategy = Keyword.get(opts, :execution_strategy) || Keyword.get(opts, :workflow_route)
    run_context = Keyword.get(opts, :run_context)

    %{
      current_utc: DateTime.to_iso8601(now),
      utc_date: Date.to_iso8601(DateTime.to_date(now)),
      local_timezone: local_timezone(),
      agent_machine: agent_machine_facts(),
      instruction: "Use these runtime facts when relevant. Do not invent dates or times."
    }
    |> maybe_put_execution_strategy(strategy)
    |> maybe_put_workflow_route(strategy)
    |> maybe_put_conversation_context(Keyword.get(opts, :conversation_context))
    |> maybe_put_run_context_facts(run_context)
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
          tool_timeout_ms: Keyword.fetch!(opts, :tool_timeout_ms),
          tool_max_rounds: Keyword.fetch!(opts, :tool_max_rounds),
          available_tools: tool_names!(tools),
          test_commands: Keyword.get(opts, :test_commands, []),
          instruction:
            "Use tools for external side effects. If a tool input has timeout_ms, set it to a positive value less than or equal to tool_timeout_ms exactly as shown here; never guess a larger timeout. For apply_edits, include every field required by the chosen operation: create_file needs path, content, overwrite; replace needs path, old_text, new_text, expected_replacements; insert_before/insert_after need path, anchor, text, expected_replacements; delete_file needs path, expected_sha256; rename_path needs from_path, to_path, overwrite. For filesystem tools, use paths relative to tool_root unless an absolute path is inside tool_root. When the user names a directory or file, inspect that exact relative path with list_files, file_info, or read_file before using search_files. Use search_files only for content search under a narrow path, not to locate file or directory names across the whole tool_root. Use MCP browser tools for web browsing: call mcp_playwright_browser_navigate with {\"arguments\":{\"url\":\"https://...\"}} using an absolute page or search URL, then call mcp_playwright_browser_snapshot with {\"arguments\":{}} before summarizing. If run_test_command is available, use only an exact command from test_commands. Do not claim file, directory, browser, or external changes unless tool_results confirm them."
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
  defp maybe_put_agent_graph(context, graph) when graph == %{}, do: context

  defp maybe_put_agent_graph(context, graph) when is_map(graph),
    do: Map.put(context, :agent_graph, json_value(graph))

  defp maybe_put_skills(context, []), do: context
  defp maybe_put_skills(context, skills), do: Map.put(context, :skills, json_value(skills))

  defp context_text(context, skills) do
    if empty_context?(context) and empty_skills?(skills), do: "", else: JSON.encode!(context)
  end

  defp run_context_text(context) do
    if empty_context?(context), do: "", else: JSON.encode!(context)
  end

  defp skills_text(skills) do
    if empty_skills?(skills), do: "", else: JSON.encode!(json_value(skills))
  end

  defp empty_context?(context) do
    map_size(context.results) == 0 and map_size(context.artifacts) == 0 and
      not Map.has_key?(context, :agent_graph) and not Map.has_key?(context, :tools) and
      not Map.has_key?(context, :runtime)
  end

  defp runtime_context(opts) do
    case Keyword.get(opts, :runtime_facts, :auto) do
      false ->
        nil

      nil ->
        nil

      facts when is_map(facts) ->
        facts

      :auto ->
        runtime_facts(
          execution_strategy: Keyword.get(opts, :execution_strategy),
          workflow_route: Keyword.get(opts, :workflow_route),
          run_context: Keyword.get(opts, :run_context),
          conversation_context: Keyword.get(opts, :conversation_context)
        )

      other ->
        raise ArgumentError,
              ":runtime_facts must be a map, false, nil, or :auto, got: #{inspect(other)}"
    end
  end

  defp maybe_put_execution_strategy(facts, nil), do: facts

  defp maybe_put_execution_strategy(facts, strategy) when is_map(strategy) do
    Map.put(facts, :execution_strategy, strategy_facts(strategy))
  end

  defp maybe_put_workflow_route(facts, nil), do: facts

  defp maybe_put_workflow_route(facts, route) when is_map(route) do
    Map.put(facts, :workflow_route, strategy_facts(route))
  end

  defp maybe_put_conversation_context(facts, nil), do: facts

  defp maybe_put_conversation_context(facts, context) when is_map(context) do
    conversation_context =
      %{
        recent_context: Map.get(context, :recent_context) || Map.get(context, "recent_context"),
        pending_action: Map.get(context, :pending_action) || Map.get(context, "pending_action"),
        instruction:
          "Current task is authoritative. Treat recent_context as reference material only. Treat pending_action as actionable only for affirmative follow-up requests. Do not redo prior completed work."
      }
      |> reject_nil_values()

    if map_size(conversation_context) == 1 do
      facts
    else
      Map.put(facts, :conversation_context, conversation_context)
    end
  end

  defp maybe_put_conversation_context(_facts, context) do
    raise ArgumentError, ":conversation_context must be a map, got: #{inspect(context)}"
  end

  defp strategy_facts(strategy) do
    Map.take(strategy, [
      :requested,
      :selected,
      :reason,
      :strategy,
      :tool_intent,
      :work_shape,
      :route_hint
    ])
  end

  defp maybe_put_run_context_facts(facts, nil), do: facts

  defp maybe_put_run_context_facts(facts, context) when is_map(context) do
    facts
    |> maybe_put_run_id(context)
    |> maybe_put_current_agent(context)
  end

  defp maybe_put_run_id(facts, %{run_id: run_id}) when is_binary(run_id),
    do: Map.put(facts, :run_id, run_id)

  defp maybe_put_run_id(facts, _context), do: facts

  defp maybe_put_current_agent(facts, context) do
    agent_facts =
      %{
        agent_id: Map.get(context, :agent_id),
        parent_agent_id: Map.get(context, :parent_agent_id)
      }
      |> Map.merge(safe_agent_metadata(Map.get(context, :agent)))
      |> reject_nil_values()

    if map_size(agent_facts) == 0 do
      facts
    else
      Map.put(facts, :current_agent, agent_facts)
    end
  end

  defp safe_agent_metadata(metadata) when is_map(metadata) do
    Map.take(metadata, [:agent_machine_role, :swarm_id, :variant_id, :workspace, :spawn_depth])
  end

  defp safe_agent_metadata(_metadata), do: %{}

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp agent_machine_facts do
    %{
      role: "assistant running inside AgentMachine",
      execution_model:
        "Models do not directly spawn OS processes. They return text, tool calls, or structured delegation; the Elixir runtime executes tools and starts delegated worker agents.",
      runtime: "one public agentic runtime selects an internal execution strategy",
      execution_strategies: %{
        direct: "one assistant, no tools, workers, or side effects",
        tool: "one assistant with a narrow read-only tool set",
        planned: "planner may return next_agents; Elixir runtime starts worker agents",
        swarm: "planner creates variants and the runtime evaluates them"
      },
      instruction:
        "Be precise about the selected execution strategy. Do not claim AgentMachine lacks agents. In direct strategy, explain that concrete 'use agents to do X' requests can use planned strategy, while this direct run has no workers or tools."
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
