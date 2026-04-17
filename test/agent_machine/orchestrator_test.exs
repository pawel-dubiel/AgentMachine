defmodule AgentMachine.OrchestratorTest do
  use ExUnit.Case, async: false

  alias AgentMachine.{Orchestrator, UsageLedger}

  setup do
    UsageLedger.reset!()
    :ok
  end

  test "spawns agents and collects results with usage" do
    agents = [
      %{
        id: "planner",
        provider: AgentMachine.Providers.Echo,
        model: "echo",
        input: "make a plan",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      },
      %{
        id: "reviewer",
        provider: AgentMachine.Providers.Echo,
        model: "echo",
        input: "review the plan",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:ok, run} = Orchestrator.run(agents, timeout: 1_000)
    assert run.status == :completed
    assert Map.keys(run.results) |> Enum.sort() == ["planner", "reviewer"]
    assert run.results["planner"].status == :ok
    assert run.results["reviewer"].status == :ok
    assert run.usage.agents == 2
    assert run.usage.total_tokens > 0

    assert %{agents: 2, total_tokens: total_tokens, cost_usd: cost_usd} = UsageLedger.totals()
    assert total_tokens > 0
    assert cost_usd == 0.0
  end

  test "fails fast when required fields are missing" do
    agents = [
      %{
        id: "planner",
        provider: AgentMachine.Providers.Echo,
        model: "echo",
        input: "make a plan"
      }
    ]

    assert_raise ArgumentError, ~r/missing required field/, fn ->
      Orchestrator.run(agents, timeout: 1_000)
    end
  end

  test "calculates cost from explicit pricing" do
    usage = %{input_tokens: 1_000_000, output_tokens: 500_000, total_tokens: 1_500_000}

    agent =
      AgentMachine.Agent.new!(%{
        id: "costed",
        provider: AgentMachine.Providers.Echo,
        model: "priced",
        input: "hello",
        pricing: %{input_per_million: 1.0, output_per_million: 2.0}
      })

    normalized = AgentMachine.Usage.from_provider!(agent, "run-cost", usage)
    assert normalized.cost_usd == 2.0
  end
end
