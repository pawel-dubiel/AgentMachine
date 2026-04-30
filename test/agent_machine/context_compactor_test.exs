defmodule AgentMachine.ContextCompactorTest do
  use ExUnit.Case, async: false

  alias AgentMachine.{Agent, ContextCompactor}

  test "compacts validated conversation messages with strict JSON output" do
    result =
      ContextCompactor.compact_conversation!(
        [
          %{role: "user", text: "Research latest Poland news"},
          %{role: "assistant", text: "I need browser access"}
        ],
        provider: :echo,
        model: "echo",
        pricing: zero_pricing(),
        http_timeout_ms: 1_000
      )

    assert result.summary == "Echo compacted conversation context."
    assert result.covered_items == ["1", "2"]
    assert result.usage.input_tokens > 0
    assert result.usage_summary.provider == "Elixir.AgentMachine.Providers.Echo"
  end

  test "rejects empty conversation input" do
    assert_raise ArgumentError, ~r/conversation compaction requires messages/, fn ->
      ContextCompactor.compact_conversation!([],
        provider: :echo,
        model: "echo",
        pricing: zero_pricing(),
        http_timeout_ms: 1_000
      )
    end
  end

  test "rejects invalid conversation roles and empty text" do
    assert_raise ArgumentError, ~r/role must be user, assistant, or summary/, fn ->
      ContextCompactor.compact_conversation!([%{role: "system", text: "hidden"}],
        provider: :echo,
        model: "echo",
        pricing: zero_pricing(),
        http_timeout_ms: 1_000
      )
    end

    assert_raise ArgumentError, ~r/:text must be a non-empty binary/, fn ->
      ContextCompactor.compact_conversation!([%{role: "user", text: ""}],
        provider: :echo,
        model: "echo",
        pricing: zero_pricing(),
        http_timeout_ms: 1_000
      )
    end
  end

  test "rejects non-JSON provider output" do
    agent = source_agent(AgentMachine.TestProviders.NonJSONCompaction)

    assert_raise ArgumentError, ~r/invalid compaction output/, fn ->
      ContextCompactor.compact_run_context!(
        %{results: %{"planner" => %{output: "planned"}}, artifacts: %{}},
        agent,
        allowed_covered_items: ["planner"]
      )
    end
  end

  test "rejects empty compaction summaries" do
    agent = source_agent(AgentMachine.TestProviders.EmptySummaryCompaction)

    assert_raise ArgumentError, ~r/:summary must be a non-empty binary/, fn ->
      ContextCompactor.compact_run_context!(
        %{results: %{"planner" => %{output: "planned"}}, artifacts: %{}},
        agent,
        allowed_covered_items: ["planner"]
      )
    end
  end

  test "rejects covered items outside the allowed result set" do
    agent = source_agent(AgentMachine.TestProviders.UnknownCoveredItemCompaction)

    assert_raise ArgumentError, ~r/unknown item/, fn ->
      ContextCompactor.compact_run_context!(
        %{results: %{"planner" => %{output: "planned"}}, artifacts: %{}},
        agent,
        allowed_covered_items: ["planner"]
      )
    end
  end

  defp source_agent(provider) do
    Agent.new!(%{
      id: "planner",
      provider: provider,
      model: "test",
      input: "plan",
      pricing: zero_pricing()
    })
  end

  defp zero_pricing do
    %{input_per_million: 0.0, output_per_million: 0.0}
  end
end

defmodule AgentMachine.TestProviders.NonJSONCompaction do
  @behaviour AgentMachine.Provider

  @impl true
  def complete(agent, _opts) do
    {:ok, %{output: "not json", usage: usage(agent, "not json")}}
  end

  defp usage(agent, output) do
    %{input_tokens: token_count(agent.input), output_tokens: token_count(output), total_tokens: 3}
  end

  defp token_count(text), do: text |> String.split(~r/\s+/, trim: true) |> length()
end

defmodule AgentMachine.TestProviders.EmptySummaryCompaction do
  @behaviour AgentMachine.Provider

  @impl true
  def complete(agent, _opts) do
    output = AgentMachine.JSON.encode!(%{summary: "", covered_items: ["planner"]})
    {:ok, %{output: output, usage: usage(agent, output)}}
  end

  defp usage(agent, output) do
    input = token_count(agent.input)
    output = token_count(output)
    %{input_tokens: input, output_tokens: output, total_tokens: input + output}
  end

  defp token_count(text), do: text |> String.split(~r/\s+/, trim: true) |> length()
end

defmodule AgentMachine.TestProviders.UnknownCoveredItemCompaction do
  @behaviour AgentMachine.Provider

  @impl true
  def complete(agent, _opts) do
    output = AgentMachine.JSON.encode!(%{summary: "summary", covered_items: ["other"]})
    {:ok, %{output: output, usage: usage(agent, output)}}
  end

  defp usage(agent, output) do
    input = token_count(agent.input)
    output = token_count(output)
    %{input_tokens: input, output_tokens: output, total_tokens: input + output}
  end

  defp token_count(text), do: text |> String.split(~r/\s+/, trim: true) |> length()
end
