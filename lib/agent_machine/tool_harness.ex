defmodule AgentMachine.ToolHarness do
  @moduledoc """
  Small adapter between AgentMachine tools and provider-native tool calling.
  """

  alias AgentMachine.{JSON, MCP.ToolFactory, ToolPolicy}

  @builtin_harnesses %{
    demo: [AgentMachine.Tools.Now],
    time: [AgentMachine.Tools.Now],
    code_edit: [
      AgentMachine.Tools.ApplyEdits,
      AgentMachine.Tools.ApplyPatch,
      AgentMachine.Tools.FileInfo,
      AgentMachine.Tools.ListFiles,
      AgentMachine.Tools.RollbackCheckpoint,
      AgentMachine.Tools.ReadFile,
      AgentMachine.Tools.SearchFiles
    ],
    local_files: [
      AgentMachine.Tools.AppendFile,
      AgentMachine.Tools.CreateDir,
      AgentMachine.Tools.FileInfo,
      AgentMachine.Tools.ListFiles,
      AgentMachine.Tools.ReadFile,
      AgentMachine.Tools.ReplaceInFile,
      AgentMachine.Tools.SearchFiles,
      AgentMachine.Tools.WriteFile
    ],
    skills: [
      AgentMachine.Tools.ListSkillResources,
      AgentMachine.Tools.ReadSkillResource
    ]
  }

  @builtin_policies %{
    demo: [:time_read],
    time: [:time_read],
    code_edit: [
      :code_edit_apply_edits,
      :code_edit_apply_patch,
      :code_edit_rollback_checkpoint,
      :local_files_info,
      :local_files_list,
      :local_files_read,
      :local_files_search
    ],
    local_files: [
      :local_files_append,
      :local_files_create_dir,
      :local_files_info,
      :local_files_list,
      :local_files_read,
      :local_files_replace,
      :local_files_search,
      :local_files_write
    ],
    skills: [
      :skills_resource_read
    ]
  }

  def builtin!(name, opts \\ [])

  def builtin!(nil, _opts), do: []

  def builtin!(name, opts) when is_atom(name) do
    case Map.fetch(@builtin_harnesses, name) do
      {:ok, tools} ->
        tools
        |> maybe_put_test_command_tool(name, opts)
        |> maybe_put_shell_tools(name, opts)
        |> maybe_put_skill_script_tool(name, opts)

      :error when name == :mcp ->
        ToolFactory.tools!(Keyword.fetch!(opts, :mcp_config))

      :error ->
        raise ArgumentError, "unknown tool harness: #{inspect(name)}"
    end
  end

  def builtin_many!(nil, _opts), do: []

  def builtin_many!(harnesses, opts) when is_list(harnesses) do
    harnesses
    |> Enum.flat_map(&builtin!(&1, opts))
    |> ensure_unique_definition_names!()
  end

  def builtin_many!(harnesses, _opts) do
    raise ArgumentError, "tool harnesses must be a list, got: #{inspect(harnesses)}"
  end

  def session_control_tools do
    [
      AgentMachine.Tools.SpawnSessionAgent,
      AgentMachine.Tools.SendSessionAgentMessage,
      AgentMachine.Tools.ReadSessionAgentOutput,
      AgentMachine.Tools.ListSessionAgents
    ]
  end

  def read_only_many!(harnesses, opts, intent) when is_list(harnesses) do
    tools =
      harnesses
      |> read_only_harnesses(intent)
      |> Enum.flat_map(&builtin!(&1, opts))
      |> maybe_force_time_tool(intent)
      |> Enum.filter(&(ToolPolicy.approval_risk!(&1) == :read))
      |> ensure_unique_definition_names!()

    if tools == [] do
      raise ArgumentError, "no read-only tools available for intent #{inspect(intent)}"
    end

    tools
  end

  def read_only_many!(harnesses, _opts, _intent) do
    raise ArgumentError, "tool harnesses must be a list, got: #{inspect(harnesses)}"
  end

  def read_only_policy_many!(harnesses, opts, intent) do
    permissions =
      harnesses
      |> read_only_many!(opts, intent)
      |> Enum.map(&ToolPolicy.tool_permission!/1)

    ToolPolicy.new!(
      harness: policy_harness_name(harnesses),
      permissions: Enum.uniq(permissions)
    )
  end

  def builtin_policy!(name, opts \\ [])

  def builtin_policy!(nil, _opts), do: nil

  def builtin_policy!(name, opts) when is_atom(name) do
    case Map.fetch(@builtin_policies, name) do
      {:ok, permissions} ->
        permissions = maybe_put_test_command_permission(name, permissions, opts)
        permissions = maybe_put_shell_permissions(name, permissions, opts)
        permissions = maybe_put_skill_script_permission(name, permissions, opts)
        ToolPolicy.new!(harness: name, permissions: permissions)

      :error when name == :mcp ->
        permissions =
          opts
          |> Keyword.fetch!(:mcp_config)
          |> Map.fetch!(:tools)
          |> Enum.map(& &1.permission)

        ToolPolicy.new!(harness: name, permissions: permissions)

      :error ->
        raise ArgumentError, "unknown tool harness policy: #{inspect(name)}"
    end
  end

  def builtin_policy_many!(nil, _opts), do: nil

  def builtin_policy_many!(harnesses, opts) when is_list(harnesses) do
    permissions =
      harnesses
      |> Enum.flat_map(fn harness ->
        harness
        |> builtin_policy!(opts)
        |> Map.fetch!(:permissions)
        |> MapSet.to_list()
      end)

    ToolPolicy.new!(harness: policy_harness_name(harnesses), permissions: Enum.uniq(permissions))
  end

  def builtin_policy_many!(harnesses, _opts) do
    raise ArgumentError, "tool harnesses must be a list, got: #{inspect(harnesses)}"
  end

  def definitions!(tools, opts \\ [])

  def definitions!(tools, opts) when is_list(tools) and is_list(opts) do
    Enum.map(tools, &definition!(&1, opts))
  end

  def req_llm_tools!(opts) when is_list(opts) do
    opts
    |> allowed_tools()
    |> definitions!(opts)
    |> Enum.map(&req_llm_tool!/1)
  end

  def req_llm_tool_groups!(opts) when is_list(opts) do
    opts
    |> allowed_tools()
    |> definitions!(opts)
    |> split_provider_tool_groups(&req_llm_tool_schema/1)
  end

  def req_llm_tool_calls!(calls, opts) when is_list(calls) do
    tools_by_name = tools_by_name(opts)

    Enum.map(calls, fn call ->
      id = fetch_tool_call_field!(call, :id)
      name = fetch_tool_call_field!(call, :name)
      arguments = fetch_tool_call_field!(call, :arguments)

      %{
        id: id,
        tool: tool_by_name!(tools_by_name, name),
        input: decode_arguments!(arguments)
      }
    end)
  end

  def req_llm_tool_calls!(calls, _opts) do
    raise ArgumentError, "ReqLLM tool calls must be a list, got: #{inspect(calls)}"
  end

  defp definition!(tool, opts) when is_atom(tool) do
    unless Code.ensure_loaded?(tool) and function_exported?(tool, :run, 2) do
      raise ArgumentError, "tool must be a loaded module exporting run/2, got: #{inspect(tool)}"
    end

    unless function_exported?(tool, :definition, 0) or function_exported?(tool, :definition, 1) do
      raise ArgumentError,
            "tool #{inspect(tool)} must export definition/0 or definition/1 for provider tool use"
    end

    tool_definition(tool, opts)
    |> require_definition!(tool)
    |> Map.put(:module, tool)
  end

  defp definition!(tool, _opts) do
    raise ArgumentError, "tool must be a module atom, got: #{inspect(tool)}"
  end

  defp tool_definition(tool, opts) do
    if function_exported?(tool, :definition, 1) do
      tool.definition(opts)
    else
      tool.definition()
    end
  end

  defp require_definition!(definition, tool) when is_map(definition) do
    name = Map.get(definition, :name)
    description = Map.get(definition, :description)
    input_schema = Map.get(definition, :input_schema)

    require_non_empty_binary!(name, "#{inspect(tool)} definition :name")
    require_non_empty_binary!(description, "#{inspect(tool)} definition :description")

    unless is_map(input_schema) do
      raise ArgumentError,
            "#{inspect(tool)} definition :input_schema must be a map, got: #{inspect(input_schema)}"
    end

    %{name: name, description: description, input_schema: input_schema}
  end

  defp require_definition!(definition, tool) do
    raise ArgumentError,
          "tool #{inspect(tool)} definition/0 must return a map, got: #{inspect(definition)}"
  end

  defp req_llm_tool!(definition) do
    ReqLLM.Tool.new!(
      name: definition.name,
      description: definition.description,
      parameter_schema: definition.input_schema,
      callback: fn _input -> {:error, "AgentMachine executes tools outside ReqLLM"} end
    )
  end

  defp req_llm_tool_schema(definition) do
    %{
      "name" => definition.name,
      "description" => definition.description,
      "parameters" => definition.input_schema
    }
  end

  defp split_provider_tool_groups(definitions, formatter) do
    {mcp, local} = Enum.split_with(definitions, &mcp_definition?/1)

    %{
      tools: Enum.map(local, formatter),
      mcp_tools: Enum.map(mcp, formatter)
    }
  end

  defp mcp_definition?(%{module: module}) when is_atom(module) do
    module
    |> Module.split()
    |> Enum.take(3)
    |> Kernel.==(["AgentMachine", "MCP", "DynamicTools"])
  end

  defp mcp_definition?(_definition), do: false

  defp fetch_tool_call_field!(call, field) when is_map(call) do
    string_field = Atom.to_string(field)

    cond do
      Map.has_key?(call, field) ->
        Map.fetch!(call, field)

      Map.has_key?(call, string_field) ->
        Map.fetch!(call, string_field)

      true ->
        raise ArgumentError,
              "invalid ReqLLM tool call missing #{inspect(field)}: #{inspect(call)}"
    end
  end

  defp fetch_tool_call_field!(call, _field) do
    raise ArgumentError, "invalid ReqLLM tool call: #{inspect(call)}"
  end

  defp decode_arguments!(arguments) when is_binary(arguments) do
    case JSON.decode!(arguments) do
      decoded when is_map(decoded) ->
        decoded

      decoded ->
        raise ArgumentError, "tool arguments must decode to a map, got: #{inspect(decoded)}"
    end
  end

  defp decode_arguments!(arguments) when is_map(arguments), do: arguments

  defp decode_arguments!(arguments) do
    raise ArgumentError,
          "tool arguments must be a JSON object string or map, got: #{inspect(arguments)}"
  end

  defp tools_by_name(opts) do
    opts
    |> allowed_tools()
    |> definitions!()
    |> ensure_unique_definitions!()
    |> Map.new(fn definition -> {definition.name, definition.module} end)
  end

  defp tool_by_name!(tools_by_name, name) do
    case Map.fetch(tools_by_name, name) do
      {:ok, tool} -> tool
      :error -> raise ArgumentError, "provider requested unknown tool: #{inspect(name)}"
    end
  end

  defp allowed_tools(opts), do: Keyword.get(opts, :allowed_tools, [])

  defp policy_harness_name([harness]), do: harness
  defp policy_harness_name(harnesses), do: harnesses

  defp read_only_harnesses(_harnesses, intent) when intent in [:time, "time"], do: [:time]

  defp read_only_harnesses(harnesses, intent) when intent in [:file_read, "file_read"] do
    Enum.filter(harnesses, &(&1 in [:local_files, :code_edit]))
  end

  defp read_only_harnesses(harnesses, intent) when intent in [:tool_use, "tool_use"],
    do: harnesses

  defp read_only_harnesses(_harnesses, intent) do
    raise ArgumentError, "unsupported read-only tool intent: #{inspect(intent)}"
  end

  defp maybe_force_time_tool(_tools, intent) when intent in [:time, "time"],
    do: [AgentMachine.Tools.Now]

  defp maybe_force_time_tool(tools, _intent), do: tools

  defp ensure_unique_definition_names!(tools) do
    tools
    |> definitions!()
    |> ensure_unique_definitions!()

    tools
  end

  defp ensure_unique_definitions!(definitions) do
    duplicates =
      definitions
      |> Enum.map(& &1.name)
      |> Enum.frequencies()
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    if duplicates != [] do
      raise ArgumentError, "duplicate provider-visible tool names: #{inspect(duplicates)}"
    end

    definitions
  end

  defp require_non_empty_binary!(value, _label) when is_binary(value) and byte_size(value) > 0,
    do: :ok

  defp require_non_empty_binary!(value, label) do
    raise ArgumentError, "#{label} must be a non-empty binary, got: #{inspect(value)}"
  end

  defp maybe_put_test_command_tool(tools, :code_edit, opts) do
    if test_commands_configured?(opts) do
      tools ++ [AgentMachine.Tools.RunTestCommand]
    else
      tools
    end
  end

  defp maybe_put_test_command_tool(tools, _name, _opts), do: tools

  defp maybe_put_shell_tools(tools, :code_edit, opts) do
    if shell_enabled?(opts) do
      tools ++
        [
          AgentMachine.Tools.RunShellCommand,
          AgentMachine.Tools.StartShellCommand,
          AgentMachine.Tools.ReadShellCommandOutput,
          AgentMachine.Tools.StopShellCommand,
          AgentMachine.Tools.ListShellCommands
        ]
    else
      tools
    end
  end

  defp maybe_put_shell_tools(tools, _name, _opts), do: tools

  defp maybe_put_skill_script_tool(tools, :skills, opts) do
    if Keyword.get(opts, :allow_skill_scripts, false) == true do
      tools ++ [AgentMachine.Tools.RunSkillScript]
    else
      tools
    end
  end

  defp maybe_put_skill_script_tool(tools, _name, _opts), do: tools

  defp maybe_put_test_command_permission(:code_edit, permissions, opts) do
    if test_commands_configured?(opts) do
      permissions ++ [:test_command_run]
    else
      permissions
    end
  end

  defp maybe_put_test_command_permission(_name, permissions, _opts), do: permissions

  defp maybe_put_shell_permissions(:code_edit, permissions, opts) do
    if shell_enabled?(opts) do
      permissions ++
        [
          :code_edit_shell_run,
          :code_edit_shell_background,
          :code_edit_shell_stop
        ]
    else
      permissions
    end
  end

  defp maybe_put_shell_permissions(_name, permissions, _opts), do: permissions

  defp maybe_put_skill_script_permission(:skills, permissions, opts) do
    if Keyword.get(opts, :allow_skill_scripts, false) == true do
      permissions ++ [:skills_script_run]
    else
      permissions
    end
  end

  defp maybe_put_skill_script_permission(_name, permissions, _opts), do: permissions

  defp test_commands_configured?(opts) do
    case Keyword.get(opts, :test_commands) do
      commands when is_list(commands) and commands != [] -> true
      _other -> false
    end
  end

  defp shell_enabled?(opts),
    do: Keyword.get(opts, :tool_approval_mode) in [:full_access, :ask_before_write]
end
