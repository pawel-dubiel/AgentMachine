defmodule AgentMachine.MCP.Stdio do
  @moduledoc false

  @max_json_line_bytes 5_000_000

  def read_json_line!(port, method, timeout_ms)
      when is_port(port) and is_binary(method) and is_integer(timeout_ms) and timeout_ms > 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    read_json_line!(port, method, timeout_ms, deadline, <<>>)
  end

  defp read_json_line!(port, method, timeout_ms, deadline, buffer) do
    receive_timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        buffer = buffer <> data
        require_frame_size!(buffer, method)

        case :binary.match(buffer, "\n") do
          {0, 1} ->
            rest = binary_part(buffer, 1, byte_size(buffer) - 1)
            read_json_line!(port, method, timeout_ms, deadline, rest)

          {index, 1} ->
            binary_part(buffer, 0, index)

          :nomatch ->
            read_json_line!(port, method, timeout_ms, deadline, buffer)
        end

      {^port, {:exit_status, status}} ->
        raise ArgumentError, "MCP stdio server exited before response with status #{status}"
    after
      receive_timeout ->
        raise ArgumentError, "MCP stdio request #{method} timed out after #{timeout_ms}ms"
    end
  end

  defp require_frame_size!(buffer, method) do
    if byte_size(buffer) > @max_json_line_bytes do
      raise ArgumentError,
            "MCP stdio response for #{method} exceeded #{@max_json_line_bytes} bytes before newline"
    end
  end
end
