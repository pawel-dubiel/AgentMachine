defmodule AgentMachine.MCP.Client do
  @moduledoc false

  alias AgentMachine.{JSON, MCP.Config}

  def call_tool(%Config.Server{} = server, tool_name, arguments, timeout_ms) do
    request_session(server, timeout_ms, fn request ->
      initialize =
        request.("initialize", %{"protocolVersion" => "2025-06-18", "capabilities" => %{}})

      tools = request.("tools/list", %{})
      validate_initialize!(initialize)
      validate_tool_list!(tools, tool_name)
      request.("tools/call", %{"name" => tool_name, "arguments" => arguments})
    end)
  end

  defp request_session(%Config.Server{transport: :stdio} = server, timeout_ms, callback) do
    executable = executable!(server.command)
    env = resolve_env!(server.env)
    port = Port.open({:spawn_executable, executable}, [:binary, args: server.args, env: env])

    try do
      {result, _state} =
        callback.(fn method, params ->
          stdio_request!(port, method, params, timeout_ms)
        end)
        |> then(&{&1, nil})

      result
    after
      Port.close(port)
    end
  end

  defp request_session(%Config.Server{transport: :streamable_http} = server, timeout_ms, callback) do
    key = {__MODULE__, make_ref()}
    Process.put(key, %{session_id: nil})

    try do
      callback.(fn method, params ->
        {response, next_state} =
          http_request!(server, method, params, timeout_ms, Process.get(key))

        Process.put(key, next_state)
        response
      end)
    after
      Process.delete(key)
    end
  end

  defp stdio_request!(port, method, params, timeout_ms) do
    id = System.unique_integer([:positive])
    Port.command(port, JSON.encode!(jsonrpc(id, method, params)) <> "\n")

    receive do
      {^port, {:data, data}} ->
        data
        |> first_json_line!()
        |> decode_response!(id)

      {^port, {:exit_status, status}} ->
        raise ArgumentError, "MCP stdio server exited before response with status #{status}"
    after
      timeout_ms ->
        raise ArgumentError, "MCP stdio request #{method} timed out after #{timeout_ms}ms"
    end
  end

  defp http_request!(server, method, params, timeout_ms, state) do
    id = System.unique_integer([:positive])
    body = JSON.encode!(jsonrpc(id, method, params))
    headers = [{"content-type", "application/json"}, {"accept", "application/json"}]
    headers = headers ++ resolved_headers!(server.headers)
    headers = maybe_put_session_header(headers, state.session_id)

    request = {to_charlist(server.url), charlist_headers(headers), ~c"application/json", body}
    options = [timeout: timeout_ms]

    case :httpc.request(:post, request, options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, response_headers, response_body}}
      when status in 200..299 ->
        session_id = response_session_id(response_headers) || state.session_id
        {decode_response!(response_body, id), %{state | session_id: session_id}}

      {:ok, {{_version, status, _reason}, _headers, response_body}} ->
        raise ArgumentError,
              "MCP HTTP request #{method} failed with status #{status}: #{response_body}"

      {:error, reason} ->
        raise ArgumentError, "MCP HTTP request #{method} failed: #{inspect(reason)}"
    end
  end

  defp validate_initialize!(%{"result" => _result}), do: :ok

  defp validate_initialize!(response) do
    raise ArgumentError, "MCP initialize returned malformed response: #{inspect(response)}"
  end

  defp validate_tool_list!(%{"result" => %{"tools" => tools}}, tool_name) when is_list(tools) do
    unless Enum.any?(tools, &(Map.get(&1, "name") == tool_name)) do
      raise ArgumentError, "MCP server did not list configured tool #{inspect(tool_name)}"
    end
  end

  defp validate_tool_list!(response, _tool_name) do
    raise ArgumentError, "MCP tools/list returned malformed response: #{inspect(response)}"
  end

  defp decode_response!(body, id) do
    response = JSON.decode!(body)

    cond do
      Map.get(response, "id") != id ->
        raise ArgumentError, "MCP JSON-RPC response id mismatch: #{inspect(response)}"

      Map.has_key?(response, "error") ->
        raise ArgumentError, "MCP JSON-RPC error: #{inspect(Map.fetch!(response, "error"))}"

      Map.has_key?(response, "result") ->
        response

      true ->
        raise ArgumentError, "MCP JSON-RPC response missing result: #{inspect(response)}"
    end
  end

  defp first_json_line!(data) do
    data
    |> String.split("\n", trim: true)
    |> List.first()
    |> case do
      nil -> raise ArgumentError, "MCP stdio server returned empty response"
      line -> line
    end
  end

  defp jsonrpc(id, method, params) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  defp executable!(command) do
    cond do
      Path.type(command) == :absolute and File.exists?(command) ->
        command

      Path.type(command) == :relative and String.contains?(command, "/") and File.exists?(command) ->
        Path.expand(command)

      found = System.find_executable(command) ->
        found

      true ->
        raise ArgumentError, "MCP stdio command not found: #{inspect(command)}"
    end
  end

  defp resolve_env!(env) do
    Enum.map(env, fn {key, env_name} ->
      {key, System.fetch_env!(env_name)}
    end)
  end

  defp resolved_headers!(headers) do
    Enum.map(headers, fn {key, env_name} ->
      {key, System.fetch_env!(env_name)}
    end)
  end

  defp maybe_put_session_header(headers, nil), do: headers

  defp maybe_put_session_header(headers, session_id),
    do: [{"mcp-session-id", session_id} | headers]

  defp charlist_headers(headers) do
    Enum.map(headers, fn {key, value} -> {to_charlist(key), to_charlist(value)} end)
  end

  defp response_session_id(headers) do
    Enum.find_value(headers, fn {key, value} ->
      if key |> to_string() |> String.downcase() == "mcp-session-id" do
        to_string(value)
      end
    end)
  end
end
