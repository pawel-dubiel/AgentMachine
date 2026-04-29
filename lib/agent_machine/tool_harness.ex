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

  def definitions!(tools) when is_list(tools) do
    Enum.map(tools, &definition!/1)
  end

  def put_openai_tools!(body, opts) when is_map(body) do
    case allowed_tools(opts) do
      [] -> body
      tools -> Map.put(body, "tools", Enum.map(definitions!(tools), &openai_tool/1))
    end
  end

  def put_openrouter_tools!(body, opts) when is_map(body) do
    case allowed_tools(opts) do
      [] -> body
      tools -> Map.put(body, "tools", Enum.map(definitions!(tools), &openrouter_tool/1))
    end
  end

  def openai_tool_calls!(response, opts) do
    tools_by_name = tools_by_name(opts)

    response
    |> Map.get("output", [])
    |> Enum.flat_map(fn
      %{"type" => "function_call"} = call -> [provider_tool_call!(call, tools_by_name)]
      _other -> []
    end)
  end

  def openrouter_tool_calls!(message, opts) when is_map(message) do
    tools_by_name = tools_by_name(opts)

    message
    |> Map.get("tool_calls", [])
    |> Enum.map(fn
      %{"id" => id, "function" => %{"name" => name, "arguments" => arguments}} ->
        %{
          id: id,
          tool: tool_by_name!(tools_by_name, name),
          input: decode_arguments!(arguments)
        }

      call ->
        raise ArgumentError, "invalid OpenRouter tool call: #{inspect(call)}"
    end)
  end

  def openrouter_tool_calls!(_message, _opts), do: []

  defp definition!(tool) when is_atom(tool) do
    unless Code.ensure_loaded?(tool) and function_exported?(tool, :run, 2) do
      raise ArgumentError, "tool must be a loaded module exporting run/2, got: #{inspect(tool)}"
    end

    unless function_exported?(tool, :definition, 0) do
      raise ArgumentError, "tool #{inspect(tool)} must export definition/0 for provider tool use"
    end

    tool.definition()
    |> require_definition!(tool)
    |> Map.put(:module, tool)
  end

  defp definition!(tool) do
    raise ArgumentError, "tool must be a module atom, got: #{inspect(tool)}"
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

  defp openai_tool(definition) do
    %{
      "type" => "function",
      "name" => definition.name,
      "description" => definition.description,
      "parameters" => definition.input_schema
    }
  end

  defp openrouter_tool(definition) do
    %{
      "type" => "function",
      "function" => %{
        "name" => definition.name,
        "description" => definition.description,
        "parameters" => definition.input_schema
      }
    }
  end

  defp provider_tool_call!(call, tools_by_name) do
    name = Map.fetch!(call, "name")
    id = Map.get(call, "call_id") || Map.fetch!(call, "id")

    %{
      id: id,
      tool: tool_by_name!(tools_by_name, name),
      input: call |> Map.fetch!("arguments") |> decode_arguments!()
    }
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
end
