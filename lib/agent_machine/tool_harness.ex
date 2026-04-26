defmodule AgentMachine.ToolHarness do
  @moduledoc """
  Small adapter between AgentMachine tools and provider-native tool calling.
  """

  alias AgentMachine.{JSON, ToolPolicy}

  @builtin_harnesses %{
    demo: [AgentMachine.Tools.Now],
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
    ]
  }

  @builtin_policies %{
    demo: [:demo_time],
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
    ]
  }

  def builtin!(name, opts \\ [])

  def builtin!(nil, _opts), do: []

  def builtin!(name, opts) when is_atom(name) do
    case Map.fetch(@builtin_harnesses, name) do
      {:ok, tools} -> maybe_put_test_command_tool(name, tools, opts)
      :error -> raise ArgumentError, "unknown tool harness: #{inspect(name)}"
    end
  end

  def builtin_policy!(name, opts \\ [])

  def builtin_policy!(nil, _opts), do: nil

  def builtin_policy!(name, opts) when is_atom(name) do
    case Map.fetch(@builtin_policies, name) do
      {:ok, permissions} ->
        permissions = maybe_put_test_command_permission(name, permissions, opts)
        ToolPolicy.new!(harness: name, permissions: permissions)

      :error ->
        raise ArgumentError, "unknown tool harness policy: #{inspect(name)}"
    end
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
    |> Map.new(fn definition -> {definition.name, definition.module} end)
  end

  defp tool_by_name!(tools_by_name, name) do
    case Map.fetch(tools_by_name, name) do
      {:ok, tool} -> tool
      :error -> raise ArgumentError, "provider requested unknown tool: #{inspect(name)}"
    end
  end

  defp allowed_tools(opts), do: Keyword.get(opts, :allowed_tools, [])

  defp require_non_empty_binary!(value, _label) when is_binary(value) and byte_size(value) > 0,
    do: :ok

  defp require_non_empty_binary!(value, label) do
    raise ArgumentError, "#{label} must be a non-empty binary, got: #{inspect(value)}"
  end

  defp maybe_put_test_command_tool(:code_edit, tools, opts) do
    if test_commands_configured?(opts) do
      tools ++ [AgentMachine.Tools.RunTestCommand]
    else
      tools
    end
  end

  defp maybe_put_test_command_tool(_name, tools, _opts), do: tools

  defp maybe_put_test_command_permission(:code_edit, permissions, opts) do
    if test_commands_configured?(opts) do
      permissions ++ [:test_command_run]
    else
      permissions
    end
  end

  defp maybe_put_test_command_permission(_name, permissions, _opts), do: permissions

  defp test_commands_configured?(opts) do
    case Keyword.get(opts, :test_commands) do
      commands when is_list(commands) and commands != [] -> true
      _other -> false
    end
  end
end
