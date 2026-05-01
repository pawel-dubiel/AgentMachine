defmodule AgentMachine.ContextBudgetTest do
  use ExUnit.Case, async: true

  alias AgentMachine.{Agent, ContextBudget}

  defp tokenizer_path do
    Path.expand("../fixtures/context_tokenizer.json", __DIR__)
  end

  defp agent do
    Agent.new!(%{
      id: "assistant",
      provider: AgentMachine.Providers.Echo,
      model: "echo",
      instructions: "Be brief.",
      input: "hello world",
      pricing: %{input_per_million: 0.0, output_per_million: 0.0}
    })
  end

  defp opts(extra) do
    Keyword.merge(
      [
        run_context: %{
          run_id: "run-budget",
          agent_id: "assistant",
          results: %{},
          artifacts: %{}
        }
      ],
      extra
    )
  end

  test "reports unknown without tokenizer path" do
    measurement = ContextBudget.measure(agent(), opts(context_window_tokens: 128_000))

    assert measurement.measurement == "unknown"
    assert measurement.status == "unknown"
    assert measurement.reason == "missing_context_tokenizer_path"
    assert measurement.context_window_tokens == 128_000
  end

  test "fails fast for invalid tokenizer path" do
    assert_raise ArgumentError, ~r/context tokenizer file does not exist/, fn ->
      ContextBudget.measure(agent(), opts(context_tokenizer_path: "missing-tokenizer.json"))
    end
  end

  test "returns tokenizer estimate with request breakdown and provider overhead" do
    measurement =
      ContextBudget.measure(
        agent(),
        opts(
          context_tokenizer_path: tokenizer_path(),
          context_window_tokens: 128_000,
          reserved_output_tokens: 2048
        )
      )

    assert measurement.measurement == "tokenizer_estimate"
    assert measurement.status == "ok"
    assert measurement.used_tokens > 0
    assert measurement.context_window_tokens == 128_000
    assert measurement.reserved_output_tokens == 2048
    assert measurement.available_tokens == 128_000 - measurement.used_tokens - 2048
    assert measurement.breakdown.instructions > 0
    assert measurement.breakdown.task_input > 0
    assert measurement.breakdown.provider_overhead_estimate >= 0
  end

  test "reserved output omission leaves availability unknown" do
    measurement =
      ContextBudget.measure(
        agent(),
        opts(context_tokenizer_path: tokenizer_path(), context_window_tokens: 128_000)
      )

    refute Map.has_key?(measurement, :available_tokens)
    refute Map.has_key?(measurement, :reserved_output_tokens)
    assert measurement.reason == "missing_reserved_output_tokens"
  end

  test "warning threshold uses request tokens, not provider response usage" do
    measurement =
      ContextBudget.measure(
        agent(),
        opts(
          context_tokenizer_path: tokenizer_path(),
          context_window_tokens: 1,
          context_warning_percent: 1
        )
      )

    assert measurement.status == "warning"
    assert ContextBudget.threshold_reached?(measurement, 1)
  end
end
