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

  test "lets an agent delegate follow-up agents with an explicit step limit" do
    agents = [
      %{
        id: "planner",
        provider: AgentMachine.TestProviders.Delegating,
        model: "test",
        input: "split the work",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:ok, run} = Orchestrator.run(agents, timeout: 1_000, max_steps: 3)
    assert run.status == :completed
    assert run.agent_order == ["planner", "worker-a", "worker-b"]
    assert Map.keys(run.results) |> Enum.sort() == ["planner", "worker-a", "worker-b"]
    assert run.results["planner"].next_agents |> Enum.map(& &1.id) == ["worker-a", "worker-b"]
    assert run.results["worker-a"].output == "finished worker-a"
    assert run.results["worker-b"].output == "finished worker-b"
    assert run.usage.agents == 3
  end

  test "fails a dynamic run when max_steps is missing" do
    agents = [
      %{
        id: "planner",
        provider: AgentMachine.TestProviders.Delegating,
        model: "test",
        input: "split the work",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:error, {:failed, run}} = Orchestrator.run(agents, timeout: 1_000)
    assert run.status == :failed
    assert run.error =~ "dynamic agent delegation requires explicit :max_steps option"
    assert Map.keys(run.results) == ["planner"]
  end

  test "fails a dynamic run when delegated agents exceed max_steps" do
    agents = [
      %{
        id: "planner",
        provider: AgentMachine.TestProviders.Delegating,
        model: "test",
        input: "split the work",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:error, {:failed, run}} = Orchestrator.run(agents, timeout: 1_000, max_steps: 2)
    assert run.status == :failed
    assert run.error =~ "exceed max_steps 2"
    assert Map.keys(run.results) == ["planner"]
  end

  test "passes run artifacts and previous results to delegated agents" do
    agents = [
      %{
        id: "planner",
        provider: AgentMachine.TestProviders.ContextAwareDelegating,
        model: "test",
        input: "create shared context",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:ok, run} = Orchestrator.run(agents, timeout: 1_000, max_steps: 2)
    assert run.status == :completed

    assert run.artifacts == %{
             plan: "shared plan",
             worker_summary: "worker used shared plan"
           }

    assert run.results["worker"].output ==
             "worker saw parent planner, plan shared plan, and planner output planned with context"
  end

  test "fails when an agent overwrites an existing artifact key" do
    agents = [
      %{
        id: "planner",
        provider: AgentMachine.TestProviders.ConflictingArtifacts,
        model: "test",
        input: "create conflicting artifacts",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:error, {:failed, run}} = Orchestrator.run(agents, timeout: 1_000, max_steps: 2)
    assert run.status == :failed
    assert run.error =~ "agent artifacts must not overwrite existing keys"
    assert run.artifacts == %{plan: "original plan"}
  end
end

defmodule AgentMachine.TestProviders.Delegating do
  @behaviour AgentMachine.Provider

  alias AgentMachine.Agent

  @impl true
  def complete(%Agent{id: "planner"} = agent, _opts) do
    {:ok,
     %{
       output: "planned follow-up work",
       usage: usage(agent, "planned follow-up work"),
       next_agents: [
         child("worker-a", "do part a", agent.pricing),
         child("worker-b", "do part b", agent.pricing)
       ]
     }}
  end

  def complete(%Agent{} = agent, _opts) do
    output = "finished #{agent.id}"

    {:ok,
     %{
       output: output,
       usage: usage(agent, output)
     }}
  end

  defp child(id, input, pricing) do
    %{
      id: id,
      provider: __MODULE__,
      model: "test",
      input: input,
      pricing: pricing
    }
  end

  defp usage(agent, output) do
    input_tokens = token_count(agent.input)
    output_tokens = token_count(output)

    %{
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      total_tokens: input_tokens + output_tokens
    }
  end

  defp token_count(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end
end

defmodule AgentMachine.TestProviders.ContextAwareDelegating do
  @behaviour AgentMachine.Provider

  alias AgentMachine.Agent

  @impl true
  def complete(%Agent{id: "planner"} = agent, _opts) do
    output = "planned with context"

    {:ok,
     %{
       output: output,
       artifacts: %{plan: "shared plan"},
       usage: usage(agent, output),
       next_agents: [
         %{
           id: "worker",
           provider: __MODULE__,
           model: "test",
           input: "use shared context",
           pricing: agent.pricing
         }
       ]
     }}
  end

  def complete(%Agent{id: "worker"} = agent, opts) do
    context = Keyword.fetch!(opts, :run_context)
    plan = Map.fetch!(context.artifacts, :plan)
    planner_result = Map.fetch!(context.results, "planner")
    planner_output = Map.fetch!(planner_result, :output)
    parent_agent_id = Map.fetch!(context, :parent_agent_id)

    output =
      "worker saw parent #{parent_agent_id}, plan #{plan}, and planner output #{planner_output}"

    {:ok,
     %{
       output: output,
       artifacts: %{worker_summary: "worker used #{plan}"},
       usage: usage(agent, output)
     }}
  end

  defp usage(agent, output) do
    input_tokens = token_count(agent.input)
    output_tokens = token_count(output)

    %{
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      total_tokens: input_tokens + output_tokens
    }
  end

  defp token_count(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end
end

defmodule AgentMachine.TestProviders.ConflictingArtifacts do
  @behaviour AgentMachine.Provider

  alias AgentMachine.Agent

  @impl true
  def complete(%Agent{id: "planner"} = agent, _opts) do
    output = "planned with an artifact"

    {:ok,
     %{
       output: output,
       artifacts: %{plan: "original plan"},
       usage: usage(agent, output),
       next_agents: [
         %{
           id: "worker",
           provider: __MODULE__,
           model: "test",
           input: "overwrite shared context",
           pricing: agent.pricing
         }
       ]
     }}
  end

  def complete(%Agent{id: "worker"} = agent, _opts) do
    output = "conflicting artifact"

    {:ok,
     %{
       output: output,
       artifacts: %{plan: "overwritten plan"},
       usage: usage(agent, output)
     }}
  end

  defp usage(agent, output) do
    input_tokens = token_count(agent.input)
    output_tokens = token_count(output)

    %{
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      total_tokens: input_tokens + output_tokens
    }
  end

  defp token_count(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end
end
