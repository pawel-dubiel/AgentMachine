defmodule AgentMachine.OpenRouterPaidTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AgentMachine.{Agent, ClientRunner, JSON, Providers.OpenRouterChat}
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
    %{
      run_id: "paid-openrouter-test",
      agent_id: "openrouter-paid-provider",
      parent_agent_id: nil,
      attempt: 1,
      results: %{},
      artifacts: %{}
    }
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
