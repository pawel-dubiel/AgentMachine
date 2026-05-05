defmodule AgentMachine.HTTPSSETest do
  use ExUnit.Case, async: true

  alias AgentMachine.HTTPSSE

  test "streams SSE events through Gun" do
    {:ok, server} =
      start_sse_server([
        "data: {\"one\":1}\n\n",
        "data: {\"two\":2}\n\n"
      ])

    parent = self()

    assert :ok =
             HTTPSSE.post(
               String.to_charlist("http://127.0.0.1:#{server.port}/stream"),
               [{~c"content-type", ~c"application/json"}],
               "{}",
               5_000,
               fn event -> send(parent, {:sse_event, event}) end
             )

    assert_receive {:sse_event, "{\"one\":1}"}
    assert_receive {:sse_event, "{\"two\":2}"}
  end

  test "halts a stream when the callback returns halt" do
    parent = self()

    {:ok, server} =
      start_hanging_sse_server(
        [
          "data: {\"one\":1}\n\n",
          "data: [DONE]\n\n"
        ],
        500,
        parent
      )

    assert :ok =
             HTTPSSE.post(
               String.to_charlist("http://127.0.0.1:#{server.port}/stream"),
               [{~c"content-type", ~c"application/json"}],
               "{}",
               1_000,
               fn event ->
                 send(parent, {:sse_event, event})
                 if event == "[DONE]", do: :halt, else: :ok
               end
             )

    assert_receive {:sse_event, "{\"one\":1}"}
    assert_receive {:sse_event, "[DONE]"}
    server_pid = server.pid
    assert_receive {:sse_server_holding, ^server_pid}
    refute_receive {:sse_server_closed, ^server_pid}, 50
  end

  test "returns response body for non-success status" do
    {:ok, server} = start_error_server(503, "temporarily unavailable")

    assert {:error, %{status: 503, body: "temporarily unavailable"}} =
             HTTPSSE.post(
               String.to_charlist("http://127.0.0.1:#{server.port}/stream"),
               [{~c"content-type", ~c"application/json"}],
               "{}",
               5_000,
               fn _event -> :ok end
             )
  end

  test "uses HTTP/2-preferred protocols by default for HTTPS streams" do
    assert HTTPSSE.https_protocols_for_test(nil) == [:http2, :http]
    assert HTTPSSE.https_protocols_for_test("") == [:http2, :http]
  end

  test "parses explicit HTTPS stream protocol modes" do
    assert HTTPSSE.https_protocols_for_test("http2") == [:http2, :http]
    assert HTTPSSE.https_protocols_for_test("auto") == [:http2, :http]
    assert HTTPSSE.https_protocols_for_test("http2-only") == [:http2]
    assert HTTPSSE.https_protocols_for_test("http1") == [:http]
    assert HTTPSSE.https_protocols_for_test("http") == [:http]
  end

  test "fails fast on invalid HTTPS stream protocol mode" do
    assert_raise ArgumentError, ~r/AGENT_MACHINE_HTTP_PROTOCOL/, fn ->
      HTTPSSE.https_protocols_for_test("spdy")
    end
  end

  test "builds tuned Gun options for HTTPS streams" do
    opts = HTTPSSE.gun_opts_for_test("https://example.com/stream", "http2")

    assert opts.transport == :tls
    assert opts.protocols == [:http2, :http]
    assert opts.connect_timeout == 5_000
    assert opts.domain_lookup_timeout == 2_000
    assert opts.tls_handshake_timeout == 5_000
    assert opts.retry == 0
    assert opts.tcp_opts[:nodelay]
    assert opts.tcp_opts[:keepalive]
    assert opts.tcp_opts[:send_timeout] == 15_000
    assert opts.tcp_opts[:send_timeout_close]
    assert opts.http_opts.keepalive == 30_000
    assert opts.http2_opts.keepalive == 30_000
    assert opts.http2_opts.keepalive_tolerance == 2
    assert Keyword.fetch!(opts.tls_opts, :server_name_indication) == ~c"example.com"
  end

  test "builds tuned Gun options for plain HTTP streams without TLS options" do
    opts = HTTPSSE.gun_opts_for_test("http://127.0.0.1:4000/stream")

    assert opts.transport == :tcp
    assert opts.protocols == [:http]
    assert opts.connect_timeout == 5_000
    assert opts.domain_lookup_timeout == 2_000
    assert opts.retry == 0
    assert opts.tcp_opts[:nodelay]
    refute Map.has_key?(opts, :tls_opts)
    refute Map.has_key?(opts, :tls_handshake_timeout)
  end

  defp start_sse_server(chunks) do
    with {:ok, listen} <- :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true]),
         {:ok, port} <- :inet.port(listen) do
      pid =
        spawn_link(fn ->
          {:ok, socket} = :gen_tcp.accept(listen)
          {:ok, _request} = :gen_tcp.recv(socket, 0, 1_000)

          :ok =
            :gen_tcp.send(
              socket,
              "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n"
            )

          send_chunks(socket, chunks)

          :gen_tcp.close(socket)
          :gen_tcp.close(listen)
        end)

      {:ok, %{port: port, pid: pid}}
    end
  end

  defp start_hanging_sse_server(chunks, hold_ms, parent) do
    with {:ok, listen} <- :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true]),
         {:ok, port} <- :inet.port(listen) do
      pid =
        spawn_link(fn ->
          {:ok, socket} = :gen_tcp.accept(listen)
          {:ok, _request} = :gen_tcp.recv(socket, 0, 1_000)

          :ok =
            :gen_tcp.send(
              socket,
              "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: keep-alive\r\n\r\n"
            )

          send_chunks(socket, chunks)
          send(parent, {:sse_server_holding, self()})
          Process.sleep(hold_ms)
          send(parent, {:sse_server_closed, self()})
          :gen_tcp.close(socket)
          :gen_tcp.close(listen)
        end)

      {:ok, %{port: port, pid: pid}}
    end
  end

  defp send_chunks(socket, chunks) do
    Enum.each(chunks, fn chunk ->
      :ok = :gen_tcp.send(socket, chunk)
      Process.sleep(10)
    end)
  end

  defp start_error_server(status, body) do
    with {:ok, listen} <- :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true]),
         {:ok, port} <- :inet.port(listen) do
      pid =
        spawn_link(fn ->
          {:ok, socket} = :gen_tcp.accept(listen)
          {:ok, _request} = :gen_tcp.recv(socket, 0, 1_000)

          :ok =
            :gen_tcp.send(
              socket,
              "HTTP/1.1 #{status} Error\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
            )

          :gen_tcp.close(socket)
          :gen_tcp.close(listen)
        end)

      {:ok, %{port: port, pid: pid}}
    end
  end
end
