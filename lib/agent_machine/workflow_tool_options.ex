defmodule AgentMachine.WorkflowToolOptions do
  @moduledoc false

  alias AgentMachine.{RunSpec, ToolHarness}

  @tool_intents %{
    "time" => :time,
    "file_read" => :file_read,
    "web_browse" => :web_browse,
    "tool_use" => :tool_use,
    "file_mutation" => :file_mutation,
    "code_mutation" => :code_mutation,
    "test_command" => :test_command,
    "delegation" => :delegation,
    "none" => :none
  }

  def put_full_tool_opts(opts, %RunSpec{tool_harnesses: nil}) when is_list(opts), do: opts

  def put_full_tool_opts(
        opts,
        %RunSpec{
          tool_harnesses: harnesses,
          tool_timeout_ms: tool_timeout_ms,
          tool_max_rounds: tool_max_rounds,
          tool_approval_mode: tool_approval_mode
        } = spec
      )
      when is_list(opts) and is_list(harnesses) do
    opts
    |> Keyword.put(:allowed_tools, ToolHarness.builtin_many!(harnesses, full_harness_opts(spec)))
    |> Keyword.put(
      :tool_policy,
      ToolHarness.builtin_policy_many!(harnesses, full_harness_opts(spec))
    )
    |> Keyword.put(:tool_timeout_ms, tool_timeout_ms)
    |> Keyword.put(:tool_max_rounds, tool_max_rounds)
    |> Keyword.put(:tool_approval_mode, tool_approval_mode)
    |> maybe_put_tool_root(harnesses, spec)
    |> maybe_put_test_commands(spec)
    |> maybe_put_mcp_config(spec)
  end

  def put_full_tool_opts(opts, spec) do
    raise ArgumentError,
          "workflow tool options require keyword opts and a RunSpec, got: #{inspect({opts, spec})}"
  end

  def put_agentic_tool_opts(opts, %RunSpec{tool_harnesses: nil}, _route) when is_list(opts),
    do: opts

  def put_agentic_tool_opts(opts, %RunSpec{} = spec, route)
      when is_list(opts) and is_map(route) do
    case tool_intent(route) do
      intent when intent in [:time, :file_read] ->
        put_read_only_tool_opts(opts, spec, intent)

      :web_browse ->
        put_scoped_full_tool_opts(opts, spec, [:mcp], :web_browse)

      _intent ->
        put_full_tool_opts(opts, spec)
    end
  end

  def put_agentic_tool_opts(opts, spec, route) do
    raise ArgumentError,
          "workflow tool options require keyword opts, a RunSpec, and a route map, got: #{inspect({opts, spec, route})}"
  end

  def put_read_only_tool_opts(
        opts,
        %RunSpec{
          tool_harnesses: harnesses,
          tool_timeout_ms: tool_timeout_ms,
          tool_max_rounds: tool_max_rounds,
          tool_approval_mode: tool_approval_mode
        } = spec,
        intent
      )
      when is_list(opts) and is_list(harnesses) do
    harness_opts = read_only_harness_opts(spec)

    opts
    |> Keyword.put(:allowed_tools, ToolHarness.read_only_many!(harnesses, harness_opts, intent))
    |> Keyword.put(
      :tool_policy,
      ToolHarness.read_only_policy_many!(harnesses, harness_opts, intent)
    )
    |> Keyword.put(:tool_timeout_ms, tool_timeout_ms)
    |> Keyword.put(:tool_max_rounds, tool_max_rounds)
    |> Keyword.put(:tool_approval_mode, tool_approval_mode)
    |> maybe_put_tool_root(harnesses, spec)
    |> maybe_put_mcp_config(spec)
  end

  def put_read_only_tool_opts(_opts, %RunSpec{} = spec, _intent) do
    raise ArgumentError,
          "tool workflow requires tool harnesses, got: #{inspect(spec.tool_harnesses)}"
  end

  def put_read_only_tool_opts(opts, spec, intent) do
    raise ArgumentError,
          "workflow tool options require keyword opts, a RunSpec, and an intent, got: #{inspect({opts, spec, intent})}"
  end

  defp put_scoped_full_tool_opts(
         opts,
         %RunSpec{tool_harnesses: harnesses} = spec,
         expected,
         intent
       ) do
    scoped_harnesses = Enum.filter(harnesses, &(&1 in expected))

    if scoped_harnesses == [] do
      raise ArgumentError,
            "agentic #{intent} strategy requires configured tool harness #{inspect(expected)}, got: #{inspect(harnesses)}"
    end

    put_full_tool_opts(opts, %{
      spec
      | tool_harnesses: scoped_harnesses,
        tool_harness: hd(scoped_harnesses)
    })
  end

  defp tool_intent(%{tool_intent: intent}), do: normalize_tool_intent(intent)
  defp tool_intent(%{"tool_intent" => intent}), do: normalize_tool_intent(intent)
  defp tool_intent(_route), do: nil

  defp normalize_tool_intent(intent) when is_atom(intent), do: intent

  defp normalize_tool_intent(intent) when is_binary(intent), do: Map.get(@tool_intents, intent)

  defp normalize_tool_intent(_intent), do: nil

  defp full_harness_opts(%RunSpec{
         test_commands: test_commands,
         mcp_config: mcp_config,
         allow_skill_scripts: allow_skill_scripts,
         tool_approval_mode: tool_approval_mode
       }),
       do: [
         test_commands: test_commands,
         mcp_config: mcp_config,
         allow_skill_scripts: allow_skill_scripts,
         tool_approval_mode: tool_approval_mode
       ]

  defp read_only_harness_opts(%RunSpec{
         mcp_config: mcp_config,
         allow_skill_scripts: allow_skill_scripts,
         tool_approval_mode: tool_approval_mode
       }),
       do: [
         mcp_config: mcp_config,
         allow_skill_scripts: allow_skill_scripts,
         tool_approval_mode: tool_approval_mode
       ]

  defp maybe_put_tool_root(opts, harnesses, %RunSpec{tool_root: root}) when is_list(harnesses) do
    if Enum.any?(harnesses, &(&1 in [:local_files, :code_edit])) do
      Keyword.put(opts, :tool_root, root)
    else
      opts
    end
  end

  defp maybe_put_tool_root(opts, _harnesses, _spec), do: opts

  defp maybe_put_test_commands(opts, %RunSpec{test_commands: nil}), do: opts

  defp maybe_put_test_commands(opts, %RunSpec{test_commands: commands}),
    do: Keyword.put(opts, :test_commands, commands)

  defp maybe_put_mcp_config(opts, %RunSpec{mcp_config: nil}), do: opts

  defp maybe_put_mcp_config(opts, %RunSpec{mcp_config: config}),
    do: Keyword.put(opts, :mcp_config, config)
end
