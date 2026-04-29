defmodule AgentMachine.MCP.ToolRunner do
  @moduledoc false

  alias AgentMachine.{JSON, MCP.Client, MCP.Config, MCP.Session, Secrets.Redactor}

  @max_result_bytes 50_000

  def run(server_id, tool_name, input, opts) when is_map(input) do
    with {:ok, arguments} <- arguments(input) do
      config = Keyword.fetch!(opts, :mcp_config)
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
      redaction_reasons: redacted.reasons
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
end
