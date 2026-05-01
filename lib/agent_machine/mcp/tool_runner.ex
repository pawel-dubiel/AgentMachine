defmodule AgentMachine.MCP.ToolRunner do
  @moduledoc false

  alias AgentMachine.{JSON, MCP.Client, MCP.Config, MCP.Session, Secrets.Redactor}

  @max_result_bytes 50_000

  def run(server_id, tool_name, input, opts) when is_map(input) do
    config = Keyword.fetch!(opts, :mcp_config)

    with {:ok, arguments} <- arguments(input),
         %Config.Tool{input_schema: input_schema} <-
           Config.tool_by_name!(config, server_id, tool_name),
         :ok <- validate_arguments(input_schema, arguments) do
      timeout_ms = Keyword.fetch!(opts, :tool_timeout_ms)
      Config.server_by_id!(config, server_id)
      response = call_tool(server_id, tool_name, arguments, timeout_ms, opts)
      {:ok, result(server_id, tool_name, response)}
    end
  rescue
    exception in [ArgumentError, KeyError, ErlangError, System.EnvError] ->
      {:error, Exception.message(exception)}
  end

  def run(_server_id, _tool_name, input, _opts), do: {:error, {:invalid_input, input}}

  defp call_tool(server_id, tool_name, arguments, timeout_ms, opts) do
    case Keyword.fetch(opts, :mcp_session) do
      {:ok, session} when is_pid(session) ->
        case Session.call_tool(session, server_id, tool_name, arguments, timeout_ms) do
          {:error, reason} -> raise ArgumentError, reason
          response -> response
        end

      :error ->
        config = Keyword.fetch!(opts, :mcp_config)
        server = Config.server_by_id!(config, server_id)
        Client.call_tool(server, tool_name, arguments, timeout_ms)
    end
  end

  defp arguments(input) do
    cond do
      Map.has_key?(input, "arguments") and is_map(input["arguments"]) ->
        {:ok, input["arguments"]}

      Map.has_key?(input, :arguments) and is_map(input[:arguments]) ->
        {:ok, input[:arguments]}

      true ->
        {:error, "MCP tool input requires an arguments object"}
    end
  end

  defp validate_arguments(schema, arguments) when schema in [nil, %{}] and is_map(arguments),
    do: :ok

  defp validate_arguments(schema, arguments) when is_map(schema) and is_map(arguments) do
    case validate_schema(schema, arguments, ["arguments"]) do
      [] -> :ok
      errors -> {:error, "MCP tool arguments invalid: #{Enum.join(errors, "; ")}"}
    end
  end

  defp validate_schema(schema, value, path) do
    type_errors = validate_schema_type(schema_value(schema, "type"), value, path)

    if type_errors == [] and object_schema?(schema, value) do
      type_errors ++ validate_object_schema(schema, value, path)
    else
      type_errors
    end
  end

  defp validate_schema_type(nil, _value, _path), do: []

  defp validate_schema_type(types, value, path) when is_list(types) do
    if Enum.any?(types, &(validate_schema_type(&1, value, path) == [])) do
      []
    else
      ["expected #{format_path(path)} to match one of #{inspect(types)}"]
    end
  end

  defp validate_schema_type("object", value, path) when not is_map(value),
    do: ["expected #{format_path(path)} to be object"]

  defp validate_schema_type("string", value, path) when not is_binary(value),
    do: ["expected #{format_path(path)} to be string"]

  defp validate_schema_type("integer", value, path) when not is_integer(value),
    do: ["expected #{format_path(path)} to be integer"]

  defp validate_schema_type("number", value, path) when not is_number(value),
    do: ["expected #{format_path(path)} to be number"]

  defp validate_schema_type("boolean", value, path) when not is_boolean(value),
    do: ["expected #{format_path(path)} to be boolean"]

  defp validate_schema_type("array", value, path) when not is_list(value),
    do: ["expected #{format_path(path)} to be array"]

  defp validate_schema_type("null", value, path) when not is_nil(value),
    do: ["expected #{format_path(path)} to be null"]

  defp validate_schema_type(type, _value, _path)
       when type in ["object", "string", "integer", "number", "boolean", "array", "null"],
       do: []

  defp validate_schema_type(type, _value, _path),
    do: ["unsupported JSON schema type #{inspect(type)}"]

  defp object_schema?(schema, value) do
    is_map(value) and
      (schema_value(schema, "type") in [nil, "object"] or
         is_map(schema_value(schema, "properties")))
  end

  defp validate_object_schema(schema, value, path) do
    properties = schema_value(schema, "properties") || %{}

    schema
    |> required_fields()
    |> Enum.flat_map(&validate_required_field(value, &1, path))
    |> Kernel.++(validate_present_properties(properties, value, path))
    |> Kernel.++(validate_additional_properties(schema, properties, value, path))
  end

  defp required_fields(schema) do
    case schema_value(schema, "required") do
      fields when is_list(fields) -> Enum.filter(fields, &is_binary/1)
      _other -> []
    end
  end

  defp validate_required_field(value, field, path) do
    if map_has_key?(value, field) do
      []
    else
      ["missing required field #{format_path(path ++ [field])}"]
    end
  end

  defp validate_present_properties(properties, value, path) when is_map(properties) do
    Enum.flat_map(properties, fn {field, field_schema} ->
      case fetch_key(value, field) do
        {:ok, field_value} when is_map(field_schema) ->
          validate_schema(field_schema, field_value, path ++ [field])

        _other ->
          []
      end
    end)
  end

  defp validate_present_properties(_properties, _value, _path), do: []

  defp validate_additional_properties(%{"additionalProperties" => false}, properties, value, path)
       when is_map(properties) do
    known = Map.keys(properties) |> MapSet.new(&to_string/1)

    value
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&MapSet.member?(known, &1))
    |> Enum.map(&"unexpected field #{format_path(path ++ [&1])}")
  end

  defp validate_additional_properties(%{additionalProperties: false}, properties, value, path)
       when is_map(properties) do
    validate_additional_properties(%{"additionalProperties" => false}, properties, value, path)
  end

  defp validate_additional_properties(_schema, _properties, _value, _path), do: []

  defp result(server_id, tool_name, %{"result" => result}) do
    redacted = Redactor.redact_value(result)
    {bounded, truncated} = bound_json_value(redacted.value)

    %{
      server_id: server_id,
      tool: tool_name,
      result: bounded,
      result_truncated: truncated,
      redacted: redacted.redacted,
      redaction_count: redacted.count,
      redaction_reasons: redacted.reasons,
      summary: %{
        tool: "mcp",
        status: "ok",
        server_id: server_id,
        mcp_tool: tool_name,
        result_truncated: truncated
      }
    }
  end

  defp bound_json_value(value) do
    encoded = JSON.encode!(value)

    if byte_size(encoded) <= @max_result_bytes do
      {value, false}
    else
      {binary_part(encoded, 0, @max_result_bytes), true}
    end
  end

  defp schema_value(schema, key),
    do: Map.get(schema, key, Map.get(schema, existing_atom_key(key)))

  defp map_has_key?(map, key),
    do: Map.has_key?(map, key) or Map.has_key?(map, existing_atom_key(key))

  defp fetch_key(map, key) do
    atom_key = existing_atom_key(key)

    cond do
      Map.has_key?(map, key) -> {:ok, Map.fetch!(map, key)}
      Map.has_key?(map, atom_key) -> {:ok, Map.fetch!(map, atom_key)}
      true -> :error
    end
  end

  defp existing_atom_key(key) when is_atom(key), do: key

  defp existing_atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> :__agent_machine_missing_atom_key__
  end

  defp format_path(path), do: Enum.join(path, ".")
end
