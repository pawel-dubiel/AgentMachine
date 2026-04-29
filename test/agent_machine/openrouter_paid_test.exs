defmodule AgentMachine.OpenRouterPaidTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AgentMachine.{Agent, ClientRunner, JSON, Providers.OpenRouterChat, SSE}
  alias Mix.Tasks.AgentMachine.Run

  @moduletag :paid_openrouter
  @moduletag timeout: 180_000
  @default_model "stepfun/step-3.5-flash"
  @pricing %{input_per_million: 0.0, output_per_million: 0.0}

  setup_all do
    model = paid_model()

    case System.fetch_env("OPENROUTER_API_KEY") do
      {:ok, key} when byte_size(key) > 0 ->
        IO.puts("Running paid OpenRouter tests with model=#{model}")
        :ok

      _missing ->
        flunk("OPENROUTER_API_KEY is required for paid OpenRouter integration tests")
    end
  end

  test "OpenRouter paid model returns a provider response" do
    model = paid_model()

    agent =
      Agent.new!(%{
        id: "openrouter-paid-provider",
        provider: OpenRouterChat,
        model: model,
        pricing: @pricing,
        instructions:
          "Reply with one short sentence. Do not call tools. Include the word AgentMachine.",
        input: "Say that this paid OpenRouter integration test is working."
      })

    assert {:ok, payload} =
             OpenRouterChat.complete(agent,
               http_timeout_ms: 120_000,
               run_context: empty_run_context()
             )

    assert is_binary(payload.output)
    assert String.trim(payload.output) != ""
    assert payload.usage.total_tokens > 0
    assert payload.usage.input_tokens > 0
  end

  @tag :openrouter_stream_probe
  test "OpenRouter paid model streams directly without workflow runtime" do
    model = paid_model()
    parent = self()

    agent =
      Agent.new!(%{
        id: "openrouter-paid-direct-stream",
        provider: OpenRouterChat,
        model: model,
        pricing: @pricing,
        instructions:
          "Reply with one short sentence. Do not call tools. Include the word AgentMachine.",
        input: "Say that this direct OpenRouter streaming probe is working."
      })

    started_ms = System.monotonic_time(:millisecond)

    result =
      OpenRouterChat.stream_complete(agent,
        http_timeout_ms: 120_000,
        run_context: empty_run_context(agent.id),
        stream_context: %{
          run_id: "paid-openrouter-direct-stream",
          agent_id: agent.id,
          attempt: 1
        },
        stream_event_sink: fn event ->
          send(parent, {:openrouter_stream_event, event, System.monotonic_time(:millisecond)})
        end
      )

    finished_ms = System.monotonic_time(:millisecond)
    events = drain_openrouter_stream_events([])
    delta_events = Enum.filter(events, fn {event, _ms} -> event.type == :assistant_delta end)
    first_delta_ms = first_delta_elapsed_ms(delta_events, started_ms)

    IO.puts(
      "OpenRouter direct stream probe model=#{model} " <>
        "status=#{stream_status(result)} " <>
        "time_to_first_delta_ms=#{inspect(first_delta_ms)} " <>
        "duration_ms=#{finished_ms - started_ms} " <>
        "delta_count=#{length(delta_events)}"
    )

    assert {:ok, payload} = result
    assert is_integer(first_delta_ms)
    assert first_delta_ms >= 0
    assert delta_events != []
    assert is_binary(payload.output)
    assert String.trim(payload.output) != ""
    assert payload.usage.total_tokens > 0
  end

  @tag :openrouter_gun_stream_probe
  test "OpenRouter paid model streams directly through Gun without workflow runtime" do
    model = paid_model()

    agent =
      Agent.new!(%{
        id: "openrouter-paid-gun-direct-stream",
        provider: OpenRouterChat,
        model: model,
        pricing: @pricing,
        instructions:
          "Reply with one short sentence. Do not call tools. Include the word AgentMachine.",
        input:
          "Say that this direct OpenRouter Gun streaming probe is working. Probe id: #{unique_probe_id("gun")}."
      })

    result = gun_openrouter_stream!(agent, 120_000)

    IO.puts(
      "OpenRouter Gun direct stream probe model=#{model} " <>
        "status=ok " <>
        "protocol=#{result.protocol} " <>
        "headers_ms=#{result.headers_ms} " <>
        "first_raw_chunk_ms=#{inspect(result.first_raw_chunk_ms)} " <>
        "first_sse_event_ms=#{inspect(result.first_sse_event_ms)} " <>
        "first_content_delta_ms=#{inspect(result.first_content_delta_ms)} " <>
        "duration_ms=#{result.duration_ms} " <>
        "delta_count=#{result.delta_count}"
    )

    assert is_integer(result.headers_ms)
    assert is_integer(result.first_raw_chunk_ms)
    assert is_integer(result.first_sse_event_ms)
    assert is_integer(result.first_content_delta_ms)
    assert result.delta_count > 0
    assert result.delta_chars > 0
    assert is_map(result.usage)
  end

  test "ClientRunner completes a basic run through the OpenRouter paid model" do
    summary =
      ClientRunner.run!(%{
        task: "Reply with one concise sentence that includes AgentMachine.",
        workflow: :basic,
        provider: :openrouter,
        model: paid_model(),
        timeout_ms: 120_000,
        max_steps: 2,
        max_attempts: 1,
        http_timeout_ms: 120_000,
        pricing: @pricing
      })

    assert summary.status == "completed"
    assert is_binary(summary.final_output)
    assert String.trim(summary.final_output) != ""
    assert summary.usage.total_tokens > 0
    assert Enum.any?(summary.events, &(&1.type == "run_completed"))
  end

  test "mix agent_machine.run streams a completed OpenRouter JSONL run" do
    Mix.Task.reenable("agent_machine.run")
    model = paid_model()

    output =
      capture_io(fn ->
        Run.run([
          "--workflow",
          "basic",
          "--provider",
          "openrouter",
          "--model",
          model,
          "--timeout-ms",
          "120000",
          "--http-timeout-ms",
          "120000",
          "--max-steps",
          "2",
          "--max-attempts",
          "1",
          "--input-price-per-million",
          "0",
          "--output-price-per-million",
          "0",
          "--jsonl",
          "Reply with one concise sentence that includes AgentMachine and Mix."
        ])
      end)

    envelopes =
      output
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "{"))
      |> Enum.map(&JSON.decode!/1)

    assert Enum.any?(envelopes, &(Map.get(&1, "type") == "event"))
    assert %{"type" => "summary", "summary" => summary} = List.last(envelopes)
    assert summary["status"] == "completed"
    assert is_binary(summary["final_output"])
    assert String.trim(summary["final_output"]) != ""
    assert get_in(summary, ["usage", "total_tokens"]) > 0

    event_types = Enum.map(summary["events"], & &1["type"])
    assert "run_started" in event_types
    assert "run_completed" in event_types
  end

  test "ClientRunner lets OpenRouter call an allowlisted MCP stdio tool" do
    marker = "MCP_PAID_TOOL_RESULT_42"
    script = fake_mcp_stdio_server!(marker)
    config_path = mcp_config_file!(script)

    summary =
      ClientRunner.run!(%{
        task:
          "You have access to an MCP tool named mcp_paid_lookup. Call that tool once with arguments {\"query\":\"agent-machine\"}. Then answer with the exact marker returned by the tool. Do not answer without using the tool.",
        workflow: :basic,
        provider: :openrouter,
        model: paid_model(),
        timeout_ms: 120_000,
        max_steps: 2,
        max_attempts: 1,
        http_timeout_ms: 120_000,
        pricing: @pricing,
        tool_harnesses: [:mcp],
        tool_timeout_ms: 30_000,
        tool_max_rounds: 4,
        tool_approval_mode: :read_only,
        mcp_config_path: config_path
      })

    assert summary.status == "completed"
    assert summary.final_output =~ marker
    assert summary.usage.total_tokens > 0
    assert Enum.any?(summary.events, &(&1.type == "tool_call_finished"))
    assert event_with?(summary.events, :tool, "mcp_paid_lookup")

    assistant = Map.fetch!(summary.results, "assistant")
    assert assistant.status == "ok"
    assert assistant.tool_results != %{}
  end

  @tag :playwright_mcp
  @tag timeout: 300_000
  test "ClientRunner lets OpenRouter drive Playwright MCP against a local page" do
    if System.get_env("AGENT_MACHINE_PAID_PLAYWRIGHT_MCP") == "1" do
      if is_nil(System.find_executable("npx")) do
        flunk("npx is required for the Playwright MCP paid integration test")
      end

      marker = "PLAYWRIGHT_MCP_PAID_MARKER_42"
      url = marker_page_url!(marker)
      config_path = playwright_mcp_config_file!()

      summary =
        ClientRunner.run!(%{
          task:
            "Use the MCP tools mcp_playwright_browser_navigate and mcp_playwright_browser_snapshot. First call mcp_playwright_browser_navigate with arguments {\"arguments\":{\"url\":\"#{url}\"}}. Then call mcp_playwright_browser_snapshot with arguments {\"arguments\":{}}. Reply with the exact marker text from the page and nothing else.",
          workflow: :basic,
          provider: :openrouter,
          model: paid_model(),
          timeout_ms: 240_000,
          max_steps: 2,
          max_attempts: 1,
          http_timeout_ms: 120_000,
          pricing: @pricing,
          tool_harnesses: [:mcp],
          tool_timeout_ms: 120_000,
          tool_max_rounds: 6,
          tool_approval_mode: :full_access,
          mcp_config_path: config_path
        })

      assert summary.status == "completed"
      assert summary.final_output =~ marker
      assert event_with?(summary.events, :tool, "mcp_playwright_browser_navigate")
      assert event_with?(summary.events, :tool, "mcp_playwright_browser_snapshot")
    else
      IO.puts(
        "Skipping Playwright MCP paid integration test; set AGENT_MACHINE_PAID_PLAYWRIGHT_MCP=1"
      )
    end
  end

  defp paid_model do
    case System.get_env("AGENT_MACHINE_PAID_OPENROUTER_MODEL") do
      nil ->
        @default_model

      model ->
        model = String.trim(model)

        if model == "" do
          flunk("AGENT_MACHINE_PAID_OPENROUTER_MODEL must be non-empty when set")
        end

        model
    end
  end

  defp empty_run_context do
    empty_run_context("openrouter-paid-provider")
  end

  defp empty_run_context(agent_id) do
    %{
      run_id: "paid-openrouter-test",
      agent_id: agent_id,
      parent_agent_id: nil,
      attempt: 1,
      results: %{},
      artifacts: %{}
    }
  end

  defp drain_openrouter_stream_events(acc) do
    receive do
      {:openrouter_stream_event, event, received_ms} ->
        drain_openrouter_stream_events([{event, received_ms} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp first_delta_elapsed_ms([], _started_ms), do: nil

  defp first_delta_elapsed_ms([{_event, received_ms} | _events], started_ms) do
    received_ms - started_ms
  end

  defp stream_status({:ok, _payload}), do: "ok"
  defp stream_status({:error, reason}), do: "error:#{inspect(reason)}"

  defp unique_probe_id(prefix) do
    "#{prefix}-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
  end

  defp gun_openrouter_stream!(%Agent{} = agent, timeout_ms) do
    api_key = System.fetch_env!("OPENROUTER_API_KEY")
    started_ms = System.monotonic_time(:millisecond)

    body =
      agent
      |> OpenRouterChat.request_body_for_test!(run_context: empty_run_context(agent.id))
      |> Map.put("stream", true)
      |> Map.put("stream_options", %{"include_usage" => true})
      |> JSON.encode!()

    Application.ensure_all_started(:gun)

    {:ok, conn} =
      :gun.open(~c"openrouter.ai", 443, %{
        transport: :tls,
        protocols:
          AgentMachine.HTTPSSE.https_protocols_for_test(
            System.get_env("AGENT_MACHINE_HTTP_PROTOCOL")
          ),
        tls_opts: [
          server_name_indication: ~c"openrouter.ai",
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]
      })

    try do
      {:ok, protocol} = :gun.await_up(conn, timeout_ms)

      stream_ref =
        :gun.post(
          conn,
          "/api/v1/chat/completions",
          [
            {"authorization", "Bearer #{api_key}"},
            {"content-type", "application/json"},
            {"x-openrouter-title", "AgentMachine Gun Probe"}
          ],
          body
        )

      conn
      |> collect_gun_stream!(stream_ref, timeout_ms, started_ms)
      |> Map.put(:protocol, protocol)
    after
      :gun.close(conn)
    end
  end

  defp collect_gun_stream!(conn, stream_ref, timeout_ms, started_ms) do
    state = %{
      sse: SSE.new(),
      started_ms: started_ms,
      headers_ms: nil,
      first_raw_chunk_ms: nil,
      first_sse_event_ms: nil,
      first_content_delta_ms: nil,
      delta_count: 0,
      delta_chars: 0,
      usage: nil
    }

    state = collect_gun_stream_loop!(conn, stream_ref, timeout_ms, state)

    %{
      headers_ms: require_metric!(state.headers_ms, :headers_ms),
      first_raw_chunk_ms: require_metric!(state.first_raw_chunk_ms, :first_raw_chunk_ms),
      first_sse_event_ms: require_metric!(state.first_sse_event_ms, :first_sse_event_ms),
      first_content_delta_ms:
        require_metric!(state.first_content_delta_ms, :first_content_delta_ms),
      duration_ms: System.monotonic_time(:millisecond) - started_ms,
      delta_count: state.delta_count,
      delta_chars: state.delta_chars,
      usage: state.usage
    }
  end

  defp collect_gun_stream_loop!(conn, stream_ref, timeout_ms, state) do
    receive do
      {:gun_response, ^conn, ^stream_ref, fin, status, _headers} when status in 200..299 ->
        state = put_metric(state, :headers_ms)

        case fin do
          :fin -> flush_gun_sse_state!(state)
          :nofin -> collect_gun_stream_loop!(conn, stream_ref, timeout_ms, state)
        end

      {:gun_response, ^conn, ^stream_ref, _fin, status, _headers} ->
        raise "Gun OpenRouter request failed with status #{status}"

      {:gun_data, ^conn, ^stream_ref, fin, chunk} ->
        state =
          state
          |> put_metric(:first_raw_chunk_ms)
          |> parse_gun_sse_chunk!(chunk)

        case fin do
          :fin -> flush_gun_sse_state!(state)
          :nofin -> collect_gun_stream_loop!(conn, stream_ref, timeout_ms, state)
        end

      {:gun_error, ^conn, ^stream_ref, reason} ->
        raise "Gun OpenRouter stream failed: #{inspect(reason)}"

      {:gun_error, ^conn, reason} ->
        raise "Gun OpenRouter connection failed: #{inspect(reason)}"
    after
      timeout_ms ->
        raise "Gun OpenRouter stream timed out after #{timeout_ms}ms"
    end
  end

  defp parse_gun_sse_chunk!(state, chunk) do
    {sse, events} = SSE.parse_chunk(state.sse, chunk)

    state
    |> Map.put(:sse, sse)
    |> handle_gun_sse_events!(events)
  end

  defp flush_gun_sse_state!(state) do
    {_sse, events} = SSE.flush(state.sse)
    handle_gun_sse_events!(state, events)
  end

  defp handle_gun_sse_events!(state, events) do
    Enum.reduce(events, state, fn
      "[DONE]", acc ->
        acc

      event, acc ->
        acc
        |> put_metric(:first_sse_event_ms)
        |> handle_gun_sse_event!(event)
    end)
  end

  defp handle_gun_sse_event!(state, event) do
    decoded = JSON.decode!(event)

    if is_map(decoded["usage"]) do
      %{state | usage: decoded["usage"]}
    else
      decoded
      |> Map.get("choices", [])
      |> Enum.reduce(state, &handle_gun_choice!/2)
    end
  end

  defp handle_gun_choice!(%{"delta" => %{"content" => content}}, state)
       when is_binary(content) and content != "" do
    state
    |> put_metric(:first_content_delta_ms)
    |> Map.update!(:delta_count, &(&1 + 1))
    |> Map.update!(:delta_chars, &(&1 + String.length(content)))
  end

  defp handle_gun_choice!(_choice, state), do: state

  defp put_metric(state, key) do
    case Map.fetch!(state, key) do
      nil -> Map.put(state, key, System.monotonic_time(:millisecond) - state.started_ms)
      _value -> state
    end
  end

  defp require_metric!(value, _field) when is_integer(value), do: value

  defp require_metric!(_value, field) do
    raise "Gun OpenRouter stream did not produce required #{field}"
  end

  defp event_with?(events, key, value) do
    Enum.any?(events, &(Map.get(&1, key) == value))
  end

  defp mcp_config_file!(script) do
    path =
      Path.join(
        System.tmp_dir!(),
        "agent-machine-paid-openrouter-#{System.unique_integer([:positive])}.mcp.json"
      )

    File.write!(
      path,
      JSON.encode!(%{
        "servers" => [
          %{
            "id" => "paid",
            "transport" => "stdio",
            "command" => script,
            "args" => [],
            "env" => %{},
            "tools" => [
              %{"name" => "lookup", "permission" => "mcp_paid_lookup", "risk" => "read"}
            ]
          }
        ]
      })
    )

    path
  end

  defp playwright_mcp_config_file! do
    path =
      Path.join(
        System.tmp_dir!(),
        "agent-machine-paid-playwright-mcp-#{System.unique_integer([:positive])}.json"
      )

    cache_dir =
      Path.join(
        System.tmp_dir!(),
        "agent-machine-playwright-npm-cache-#{System.unique_integer([:positive])}"
      )

    File.write!(
      path,
      JSON.encode!(%{
        "servers" => [
          %{
            "id" => "playwright",
            "transport" => "stdio",
            "command" => "npx",
            "args" => ["--yes", "--cache", cache_dir, "@playwright/mcp@latest", "--headless"],
            "env" => %{},
            "tools" => [
              %{
                "name" => "browser_navigate",
                "permission" => "mcp_playwright_browser_navigate",
                "risk" => "network"
              },
              %{
                "name" => "browser_snapshot",
                "permission" => "mcp_playwright_browser_snapshot",
                "risk" => "read"
              }
            ]
          }
        ]
      })
    )

    path
  end

  defp marker_page_url!(marker) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)

    task =
      Task.async(fn ->
        serve_marker_page(listener, marker)
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      Task.shutdown(task, :brutal_kill)
    end)

    "http://127.0.0.1:#{port}/"
  end

  defp serve_marker_page(listener, marker) do
    case :gen_tcp.accept(listener, 240_000) do
      {:ok, socket} ->
        _request = :gen_tcp.recv(socket, 0, 1_000)

        body =
          "<!doctype html><html><head><title>AgentMachine MCP</title></head><body><main><h1>#{marker}</h1></main></body></html>"

        response =
          "HTTP/1.1 200 OK\r\ncontent-type: text/html\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"

        :ok = :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        serve_marker_page(listener, marker)

      {:error, _reason} ->
        :ok
    end
  end

  defp fake_mcp_stdio_server!(marker) do
    path =
      Path.join(
        System.tmp_dir!(),
        "agent-machine-paid-mcp-#{System.unique_integer([:positive])}.sh"
      )

    script = """
    #!/bin/sh
    while IFS= read -r line; do
      id=$(printf '%s\\n' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      case "$line" in
        *'"method":"initialize"'*)
          printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-06-18"}}\\n' "$id"
          ;;
        *'"method":"tools/list"'*)
          printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"lookup","inputSchema":{"type":"object"}}]}}\\n' "$id"
          ;;
        *'"method":"tools/call"'*)
          printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"%s"}],"structuredContent":{"marker":"%s"}}}\\n' "$id" "#{marker}" "#{marker}"
          ;;
      esac
    done
    """

    File.write!(path, script)
    File.chmod!(path, 0o700)
    path
  end
end
