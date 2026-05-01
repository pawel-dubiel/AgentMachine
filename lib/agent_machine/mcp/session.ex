defmodule AgentMachine.MCP.Session do
  @moduledoc false

  use GenServer

  alias AgentMachine.{JSON, MCP.Config, MCP.Stdio, Telemetry}

  def start_link(%Config{} = config) do
    GenServer.start_link(__MODULE__, {config, %{}})
  end

  def start_link({%Config{} = config, metadata}) when is_map(metadata) do
    GenServer.start_link(__MODULE__, {config, metadata})
  end

  def child_spec(arg) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [arg]},
      restart: :temporary,
      type: :worker
    }
  end

  def call_tool(pid, server_id, tool_name, arguments, timeout_ms)
      when is_pid(pid) and is_binary(server_id) and is_binary(tool_name) and is_map(arguments) and
             is_integer(timeout_ms) and timeout_ms > 0 do
    GenServer.call(
      pid,
      {:call_tool, server_id, tool_name, arguments, timeout_ms},
      timeout_ms + 1_000
    )
  end

  @impl true
  def init({%Config{} = config, metadata}) when is_map(metadata) do
    {:ok, %{config: config, telemetry_metadata: metadata, stdio: %{}, http: %{}}}
  end

  @impl true
  def handle_call({:call_tool, server_id, tool_name, arguments, timeout_ms}, _from, state) do
    server = Config.server_by_id!(state.config, server_id)

    started_at = Telemetry.start_time()
    metadata = mcp_telemetry_metadata(state, server_id, tool_name)

    Telemetry.execute(
      [:agent_machine, :mcp, :call, :start],
      %{system_time: Telemetry.system_time()},
      metadata
    )

    try do
      {response, state} =
        case server.transport do
          :stdio -> call_stdio_tool!(state, server, tool_name, arguments, timeout_ms)
          :streamable_http -> call_http_tool!(state, server, tool_name, arguments, timeout_ms)
        end

      Telemetry.execute(
        [:agent_machine, :mcp, :call, :stop],
        %{duration: Telemetry.duration_since(started_at)},
        metadata
      )

      {:reply, response, state}
    rescue
      exception in [ArgumentError, ErlangError, System.EnvError] ->
        Telemetry.execute(
          [:agent_machine, :mcp, :call, :exception],
          %{duration: Telemetry.duration_since(started_at)},
          Map.put(metadata, :error, Exception.message(exception))
        )

        {:reply, {:error, Exception.message(exception)}, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    state.stdio
    |> Map.values()
    |> Enum.each(fn %{port: port} -> Port.close(port) end)
  end

  defp call_stdio_tool!(state, server, tool_name, arguments, timeout_ms) do
    {session, state} = stdio_session!(state, server, timeout_ms)
    validate_tool_list!(session.tools, tool_name)

    response =
      stdio_request!(
        session.port,
        "tools/call",
        %{"name" => tool_name, "arguments" => arguments},
        timeout_ms
      )

    {response, state}
  end

  defp stdio_session!(state, server, timeout_ms) do
    case Map.fetch(state.stdio, server.id) do
      {:ok, session} ->
        {session, state}

      :error ->
        session = open_stdio_session!(server, timeout_ms)
        {session, %{state | stdio: Map.put(state.stdio, server.id, session)}}
    end
  end

  defp open_stdio_session!(server, timeout_ms) do
    executable = executable!(server.command)
    env = resolve_env!(server.env)

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        args: server.args,
        env: env
      ])

    initialize = stdio_request!(port, "initialize", initialize_params(), timeout_ms)

    validate_initialize!(initialize)

    tools = stdio_request!(port, "tools/list", %{}, timeout_ms)

    %{port: port, tools: tool_names!(tools)}
  end

  defp call_http_tool!(state, server, tool_name, arguments, timeout_ms) do
    {session, state} = http_session!(state, server, timeout_ms)
    validate_tool_list!(session.tools, tool_name)

    {response, session} =
      http_request!(
        server,
        "tools/call",
        %{"name" => tool_name, "arguments" => arguments},
        timeout_ms,
        session
      )

    {response, %{state | http: Map.put(state.http, server.id, session)}}
  end

  defp http_session!(state, server, timeout_ms) do
    case Map.fetch(state.http, server.id) do
      {:ok, session} ->
        {session, state}

      :error ->
        {initialize, session} =
          http_request!(server, "initialize", initialize_params(), timeout_ms, %{session_id: nil})

        validate_initialize!(initialize)
        {tools, session} = http_request!(server, "tools/list", %{}, timeout_ms, session)
        session = Map.put(session, :tools, tool_names!(tools))
        {session, %{state | http: Map.put(state.http, server.id, session)}}
    end
  end

  defp stdio_request!(port, method, params, timeout_ms) do
    id = System.unique_integer([:positive])
    Port.command(port, JSON.encode!(jsonrpc(id, method, params)) <> "\n")

    port
    |> Stdio.read_json_line!(method, timeout_ms)
    |> decode_response!(id)
  end

  defp http_request!(server, method, params, timeout_ms, session) do
    id = System.unique_integer([:positive])
    body = JSON.encode!(jsonrpc(id, method, params))
    headers = [{"content-type", "application/json"}, {"accept", "application/json"}]
    headers = headers ++ resolved_headers!(server.headers)
    headers = maybe_put_session_header(headers, session.session_id)

    request = {to_charlist(server.url), charlist_headers(headers), ~c"application/json", body}
    options = [timeout: timeout_ms]

    case :httpc.request(:post, request, options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, response_headers, response_body}}
      when status in 200..299 ->
        session_id = response_session_id(response_headers) || session.session_id
        {decode_response!(response_body, id), %{session | session_id: session_id}}

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

  defp tool_names!(%{"result" => %{"tools" => tools}}) when is_list(tools) do
    tools
    |> Enum.map(&Map.get(&1, "name"))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp tool_names!(response) do
    raise ArgumentError, "MCP tools/list returned malformed response: #{inspect(response)}"
  end

  defp validate_tool_list!(tools, tool_name) do
    unless MapSet.member?(tools, tool_name) do
      raise ArgumentError, "MCP server did not list configured tool #{inspect(tool_name)}"
    end
  end

  defp mcp_telemetry_metadata(state, server_id, tool_name) do
    state.telemetry_metadata
    |> Map.put(:mcp_server_id, server_id)
    |> Map.put(:mcp_tool, tool_name)
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

  defp jsonrpc(id, method, params) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  defp initialize_params do
    %{
      "protocolVersion" => "2025-06-18",
      "capabilities" => %{},
      "clientInfo" => %{"name" => "agent-machine", "version" => "0.1.0"}
    }
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
      {to_charlist(key), to_charlist(System.fetch_env!(env_name))}
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
