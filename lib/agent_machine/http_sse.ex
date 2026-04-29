defmodule AgentMachine.HTTPSSE do
  @moduledoc false

  alias AgentMachine.SSE

  @http_protocol_env "AGENT_MACHINE_HTTP_PROTOCOL"
  @connect_timeout_ms 5_000
  @domain_lookup_timeout_ms 2_000
  @tls_handshake_timeout_ms 5_000
  @tcp_send_timeout_ms 15_000
  @keepalive_ms 30_000
  @http2_keepalive_tolerance 2

  if Mix.env() == :test do
    def https_protocols_for_test(value), do: https_protocols_from_env!(value)

    def gun_opts_for_test(url, protocol_value \\ nil) do
      url
      |> parse_url!()
      |> gun_opts(https_protocols_from_env!(protocol_value))
    end
  end

  def post(url, headers, body, timeout_ms, on_data)
      when is_list(url) and is_list(headers) and is_binary(body) and is_integer(timeout_ms) and
             is_function(on_data, 1) do
    owner = self()
    ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        result =
          do_post(url, headers, body, timeout_ms, fn data ->
            on_data.(data)
            send(owner, {:httpsse_progress, ref})
          end)

        send(owner, {:httpsse_result, ref, result})
      end)

    await_result(ref, pid, monitor_ref, timeout_ms)
  end

  defp do_post(url, headers, body, timeout_ms, on_data) do
    uri = parse_url!(url)
    ensure_started!(:gun)

    with {:ok, conn} <- :gun.open(String.to_charlist(uri.host), uri.port, gun_opts(uri)),
         {:ok, _protocol} <- :gun.await_up(conn, timeout_ms) do
      try do
        stream_ref = :gun.post(conn, request_path(uri), gun_headers(headers, body), body)
        collect(conn, stream_ref, SSE.new(), timeout_ms, on_data)
      after
        :gun.close(conn)
      end
    end
  end

  defp await_result(ref, pid, monitor_ref, timeout_ms) do
    receive do
      {:httpsse_result, ^ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:httpsse_progress, ^ref} ->
        await_result(ref, pid, monitor_ref, timeout_ms)

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        {:error, reason}
    after
      timeout_ms ->
        Process.exit(pid, :kill)
        {:error, {:timeout, timeout_ms}}
    end
  end

  defp parse_url!(url) do
    url
    |> to_string()
    |> URI.parse()
    |> normalize_uri!()
  end

  defp normalize_uri!(%URI{scheme: scheme, host: host} = uri)
       when scheme in ["http", "https"] and is_binary(host) and host != "" do
    port = uri.port || default_port!(scheme)
    %{uri | port: port}
  end

  defp normalize_uri!(uri) do
    raise ArgumentError, "HTTPSSE.post requires an http or https URL, got: #{inspect(uri)}"
  end

  defp default_port!("http"), do: 80
  defp default_port!("https"), do: 443

  defp gun_opts(uri), do: gun_opts(uri, https_protocols())

  defp gun_opts(%URI{scheme: "http"}, _https_protocols) do
    base_gun_opts(:tcp, [:http])
  end

  defp gun_opts(%URI{scheme: "https", host: host}, protocols) do
    hostname = String.to_charlist(host)

    :tls
    |> base_gun_opts(protocols)
    |> Map.put(:tls_handshake_timeout, @tls_handshake_timeout_ms)
    |> Map.put(
      :tls_opts,
      server_name_indication: hostname,
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    )
  end

  defp base_gun_opts(transport, protocols) do
    %{
      connect_timeout: @connect_timeout_ms,
      domain_lookup_timeout: @domain_lookup_timeout_ms,
      retry: 0,
      transport: transport,
      protocols: protocols,
      tcp_opts: [
        nodelay: true,
        keepalive: true,
        send_timeout: @tcp_send_timeout_ms,
        send_timeout_close: true
      ],
      http_opts: %{
        keepalive: @keepalive_ms
      },
      http2_opts: %{
        keepalive: @keepalive_ms,
        keepalive_tolerance: @http2_keepalive_tolerance
      }
    }
  end

  defp https_protocols do
    @http_protocol_env
    |> System.get_env()
    |> https_protocols_from_env!()
  end

  defp https_protocols_from_env!(nil), do: [:http2, :http]
  defp https_protocols_from_env!(""), do: [:http2, :http]
  defp https_protocols_from_env!("auto"), do: [:http2, :http]
  defp https_protocols_from_env!("http2"), do: [:http2, :http]
  defp https_protocols_from_env!("http2-only"), do: [:http2]
  defp https_protocols_from_env!("http1"), do: [:http]
  defp https_protocols_from_env!("http"), do: [:http]

  defp https_protocols_from_env!(value) do
    raise ArgumentError,
          "#{@http_protocol_env} must be one of: http2, http2-only, auto, http1, or http; got: #{inspect(value)}"
  end

  defp request_path(%URI{path: nil, query: nil}), do: "/"
  defp request_path(%URI{path: "", query: nil}), do: "/"
  defp request_path(%URI{path: nil, query: query}), do: "/?" <> query
  defp request_path(%URI{path: "", query: query}), do: "/?" <> query
  defp request_path(%URI{path: path, query: nil}), do: path
  defp request_path(%URI{path: path, query: query}), do: path <> "?" <> query

  defp gun_headers(headers, body) do
    normalized = Enum.map(headers, fn {key, value} -> {to_string(key), to_string(value)} end)

    if Enum.any?(normalized, fn {key, _value} -> String.downcase(key) == "content-length" end) do
      normalized
    else
      [{"content-length", Integer.to_string(byte_size(body))} | normalized]
    end
  end

  defp ensure_started!(app) do
    case Application.ensure_all_started(app) do
      {:ok, _apps} -> :ok
      {:error, reason} -> raise "failed to start #{inspect(app)}: #{inspect(reason)}"
    end
  end

  defp collect(conn, stream_ref, sse, timeout_ms, on_data) do
    receive do
      {:gun_response, ^conn, ^stream_ref, fin, status, _headers} when status in 200..299 ->
        case fin do
          :fin -> flush_sse(sse, on_data)
          :nofin -> collect(conn, stream_ref, sse, timeout_ms, on_data)
        end

      {:gun_response, ^conn, ^stream_ref, fin, status, _headers} ->
        body = collect_response_body(conn, stream_ref, fin, "", timeout_ms)
        {:error, %{status: status, reason: "", body: body}}

      {:gun_data, ^conn, ^stream_ref, fin, chunk} ->
        {sse, events} = SSE.parse_chunk(sse, chunk)
        Enum.each(events, on_data)

        case fin do
          :fin -> flush_sse(sse, on_data)
          :nofin -> collect(conn, stream_ref, sse, timeout_ms, on_data)
        end

      {:gun_inform, ^conn, ^stream_ref, _status, _headers} ->
        collect(conn, stream_ref, sse, timeout_ms, on_data)

      {:gun_error, ^conn, ^stream_ref, reason} ->
        {:error, reason}

      {:gun_error, ^conn, reason} ->
        {:error, reason}

      {:gun_down, ^conn, _protocol, reason, _killed_streams, _unprocessed_streams} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_gun_stream_message, other}}
    after
      timeout_ms ->
        {:error, {:timeout, timeout_ms}}
    end
  end

  defp flush_sse(sse, on_data) do
    {_sse, events} = SSE.flush(sse)
    Enum.each(events, on_data)
    :ok
  end

  defp collect_response_body(_conn, _stream_ref, :fin, body, _timeout_ms), do: body

  defp collect_response_body(conn, stream_ref, :nofin, body, timeout_ms) do
    receive do
      {:gun_data, ^conn, ^stream_ref, fin, chunk} ->
        collect_response_body(conn, stream_ref, fin, body <> chunk, timeout_ms)

      {:gun_error, ^conn, ^stream_ref, reason} ->
        inspect(reason)

      {:gun_error, ^conn, reason} ->
        inspect(reason)
    after
      timeout_ms -> body
    end
  end
end
