defmodule AgentMachine.HTTPSSE do
  @moduledoc false

  alias AgentMachine.SSE

  def post(url, headers, body, timeout_ms, on_data)
      when is_list(url) and is_list(headers) and is_binary(body) and is_integer(timeout_ms) and
             is_function(on_data, 1) do
    case :httpc.request(
           :post,
           {url, headers, ~c"application/json", body},
           [{:timeout, timeout_ms}],
           body_format: :binary,
           sync: false,
           stream: :self
         ) do
      {:ok, request_id} ->
        collect(request_id, SSE.new(), timeout_ms, on_data)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect(request_id, sse, timeout_ms, on_data) do
    receive do
      {:http, {^request_id, :stream_start, _headers}} ->
        collect(request_id, sse, timeout_ms, on_data)

      {:http, {^request_id, :stream, chunk}} ->
        {sse, events} = SSE.parse_chunk(sse, chunk)
        Enum.each(events, on_data)
        collect(request_id, sse, timeout_ms, on_data)

      {:http, {^request_id, :stream_end, _headers}} ->
        {_sse, events} = SSE.flush(sse)
        Enum.each(events, on_data)
        :ok

      {:http, {^request_id, {{_version, status, _reason}, _headers, response_body}}}
      when status in 200..299 ->
        {sse, events} = SSE.parse_chunk(sse, response_body)
        {_sse, flushed} = SSE.flush(sse)
        Enum.each(events ++ flushed, on_data)
        :ok

      {:http, {^request_id, {{_version, status, reason}, _headers, response_body}}} ->
        {:error, %{status: status, reason: reason, body: response_body}}

      {:http, {^request_id, {:error, reason}}} ->
        {:error, reason}

      {:http, {^request_id, other}} ->
        {:error, {:unexpected_http_stream_message, other}}
    after
      timeout_ms ->
        {:error, {:timeout, timeout_ms}}
    end
  end
end
