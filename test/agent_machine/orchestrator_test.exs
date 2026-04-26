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

  test "parses opt-in structured delegation output into follow-up agents" do
    agents = [
      %{
        id: "planner",
        provider: AgentMachine.TestProviders.StructuredDelegating,
        model: "test",
        input: "split the work",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0},
        metadata: %{agent_machine_response: "delegation"}
      }
    ]

    assert {:ok, run} = Orchestrator.run(agents, timeout: 1_000, max_steps: 3)
    assert run.status == :completed
    assert run.agent_order == ["planner", "worker-a", "worker-b"]
    assert run.results["planner"].output == "Created two workers."
    assert run.results["planner"].next_agents |> Enum.map(& &1.id) == ["worker-a", "worker-b"]
    assert run.results["worker-a"].output == "finished worker-a"
    assert run.results["worker-b"].output == "finished worker-b"
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

  test "runs a finalizer after delegated agents finish" do
    agents = [
      %{
        id: "planner",
        provider: AgentMachine.TestProviders.Finalizing,
        model: "test",
        input: "plan final output",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    finalizer = %{
      id: "finalizer",
      provider: AgentMachine.TestProviders.Finalizing,
      model: "test",
      input: "combine worker outputs",
      pricing: %{input_per_million: 0.0, output_per_million: 0.0}
    }

    assert {:ok, run} =
             Orchestrator.run(agents, timeout: 1_000, max_steps: 4, finalizer: finalizer)

    assert run.status == :completed
    assert run.agent_order == ["planner", "worker-a", "worker-b", "finalizer"]
    assert run.results["finalizer"].output == "finalized worker-a output + worker-b output"
    assert run.artifacts.final_output == "finalized worker-a output + worker-b output"
    assert run.usage.agents == 4
  end

  test "fails fast when finalizer id duplicates an agent id" do
    agents = [
      %{
        id: "planner",
        provider: AgentMachine.Providers.Echo,
        model: "echo",
        input: "make a plan",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    finalizer = %{
      id: "planner",
      provider: AgentMachine.Providers.Echo,
      model: "echo",
      input: "combine",
      pricing: %{input_per_million: 0.0, output_per_million: 0.0}
    }

    assert_raise ArgumentError, ~r/agent ids must be unique/, fn ->
      Orchestrator.run(agents, timeout: 1_000, finalizer: finalizer)
    end
  end

  test "counts finalizer against max_steps" do
    agents = [
      %{
        id: "planner",
        provider: AgentMachine.TestProviders.Finalizing,
        model: "test",
        input: "plan final output",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    finalizer = %{
      id: "finalizer",
      provider: AgentMachine.TestProviders.Finalizing,
      model: "test",
      input: "combine worker outputs",
      pricing: %{input_per_million: 0.0, output_per_million: 0.0}
    }

    assert {:error, {:failed, run}} =
             Orchestrator.run(agents, timeout: 1_000, max_steps: 3, finalizer: finalizer)

    assert run.status == :failed
    assert run.error =~ "exceed max_steps 3"
    refute Map.has_key?(run.results, "finalizer")
  end

  test "records structured events for a finalized run" do
    agents = [
      %{
        id: "planner",
        provider: AgentMachine.TestProviders.Finalizing,
        model: "test",
        input: "plan final output",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    finalizer = %{
      id: "finalizer",
      provider: AgentMachine.TestProviders.Finalizing,
      model: "test",
      input: "combine worker outputs",
      pricing: %{input_per_million: 0.0, output_per_million: 0.0}
    }

    assert {:ok, run} =
             Orchestrator.run(agents, timeout: 1_000, max_steps: 4, finalizer: finalizer)

    assert hd(run.events).type == :run_started
    assert List.last(run.events).type == :run_completed

    assert run.events
           |> Enum.filter(&(&1.type == :agent_started))
           |> Enum.map(& &1.agent_id)
           |> Enum.sort() == ["finalizer", "planner", "worker-a", "worker-b"]

    assert run.events
           |> Enum.filter(&(&1.type == :agent_finished))
           |> Enum.map(& &1.agent_id)
           |> Enum.sort() == ["finalizer", "planner", "worker-a", "worker-b"]

    worker_parent_ids =
      run.events
      |> Enum.filter(&(&1.type == :agent_started and &1.agent_id in ["worker-a", "worker-b"]))
      |> Enum.map(& &1.parent_agent_id)

    assert worker_parent_ids == ["planner", "planner"]
    assert Enum.all?(run.events, &match?(%DateTime{}, &1.at))
  end

  test "records a run_failed event" do
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

    assert List.last(run.events).type == :run_failed
    assert List.last(run.events).reason =~ "agent artifacts must not overwrite existing keys"
  end

  test "retries a failed agent until it succeeds" do
    agents = [
      %{
        id: "flaky",
        provider: AgentMachine.TestProviders.Flaky,
        model: "test",
        input: "eventually succeed",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:ok, run} = Orchestrator.run(agents, timeout: 1_000, max_attempts: 2)

    assert run.status == :completed
    assert run.results["flaky"].status == :ok
    assert run.results["flaky"].attempt == 2
    assert run.results["flaky"].output == "succeeded on attempt 2"

    assert run.events
           |> Enum.filter(&(&1.type == :agent_retry_scheduled))
           |> Enum.map(& &1.next_attempt) == [2]
  end

  test "stores the final error when retry attempts are exhausted" do
    agents = [
      %{
        id: "always-fails",
        provider: AgentMachine.TestProviders.AlwaysFails,
        model: "test",
        input: "never succeeds",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:ok, run} = Orchestrator.run(agents, timeout: 1_000, max_attempts: 2)

    assert run.status == :completed
    assert run.results["always-fails"].status == :error
    assert run.results["always-fails"].attempt == 2
    assert run.results["always-fails"].error == ":planned_failure"

    assert run.events
           |> Enum.filter(&(&1.type == :agent_finished and &1.agent_id == "always-fails"))
           |> Enum.map(& &1.attempt) == [1, 2]
  end

  test "runs initial agents after their dependencies finish" do
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
        depends_on: ["planner"],
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      },
      %{
        id: "publisher",
        provider: AgentMachine.Providers.Echo,
        model: "echo",
        input: "publish the result",
        depends_on: ["reviewer"],
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:ok, run} = Orchestrator.run(agents, timeout: 1_000)

    assert run.status == :completed
    assert run.agent_order == ["planner", "reviewer", "publisher"]
    assert Map.keys(run.results) |> Enum.sort() == ["planner", "publisher", "reviewer"]
  end

  test "fails fast when an agent dependency is missing" do
    agents = [
      %{
        id: "reviewer",
        provider: AgentMachine.Providers.Echo,
        model: "echo",
        input: "review the plan",
        depends_on: ["planner"],
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert_raise ArgumentError, ~r/depends on missing agent id/, fn ->
      Orchestrator.run(agents, timeout: 1_000)
    end
  end

  test "fails fast when agent dependencies contain a cycle" do
    agents = [
      %{
        id: "a",
        provider: AgentMachine.Providers.Echo,
        model: "echo",
        input: "a",
        depends_on: ["b"],
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      },
      %{
        id: "b",
        provider: AgentMachine.Providers.Echo,
        model: "echo",
        input: "b",
        depends_on: ["a"],
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert_raise ArgumentError, ~r/dependency graph contains a cycle/, fn ->
      Orchestrator.run(agents, timeout: 1_000)
    end
  end

  test "executes provider tool calls and stores tool results" do
    agents = [
      %{
        id: "tool-user",
        provider: AgentMachine.TestProviders.ToolUsing,
        model: "test",
        input: "hello",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:ok, run} =
             Orchestrator.run(agents,
               timeout: 1_000,
               allowed_tools: [AgentMachine.TestTools.Uppercase],
               tool_policy: AgentMachine.ToolPolicy.new!(permissions: [:test_uppercase]),
               tool_timeout_ms: 100,
               tool_max_rounds: 2
             )

    assert run.results["tool-user"].status == :ok
    assert run.results["tool-user"].output == "final answer: HELLO"

    assert run.results["tool-user"].tool_results == %{
             "uppercase" => %{value: "HELLO", attempt: 1}
           }

    assert run.usage.input_tokens == 2
    assert run.usage.output_tokens == 6

    assert run.events
           |> Enum.filter(&(&1.type in [:tool_call_started, :tool_call_finished]))
           |> Enum.map(& &1.tool_call_id) == ["uppercase", "uppercase"]
  end

  test "runs multiple provider tool rounds up to the explicit limit" do
    agents = [
      %{
        id: "tool-user",
        provider: AgentMachine.TestProviders.MultiRoundToolUsing,
        model: "test",
        input: "hello",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:ok, run} =
             Orchestrator.run(agents,
               timeout: 1_000,
               allowed_tools: [AgentMachine.TestTools.Uppercase],
               tool_policy: AgentMachine.ToolPolicy.new!(permissions: [:test_uppercase]),
               tool_timeout_ms: 100,
               tool_max_rounds: 2
             )

    assert run.results["tool-user"].status == :ok
    assert run.results["tool-user"].output == "final answer: HELLO AGAIN"

    assert Map.keys(run.results["tool-user"].tool_results) |> Enum.sort() == [
             "uppercase-1",
             "uppercase-2"
           ]
  end

  test "fails when provider exceeds tool max rounds" do
    agents = [
      %{
        id: "tool-user",
        provider: AgentMachine.TestProviders.MultiRoundToolUsing,
        model: "test",
        input: "hello",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:ok, run} =
             Orchestrator.run(agents,
               timeout: 1_000,
               allowed_tools: [AgentMachine.TestTools.Uppercase],
               tool_policy: AgentMachine.ToolPolicy.new!(permissions: [:test_uppercase]),
               tool_timeout_ms: 100,
               tool_max_rounds: 1
             )

    assert run.results["tool-user"].status == :error
    assert run.results["tool-user"].error =~ "exceeded :tool_max_rounds 1"
  end

  test "fails when provider tool calls omit tool_state" do
    agents = [
      %{
        id: "tool-user",
        provider: AgentMachine.TestProviders.ToolMissingState,
        model: "test",
        input: "hello",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:ok, run} =
             Orchestrator.run(agents,
               timeout: 1_000,
               allowed_tools: [AgentMachine.TestTools.Uppercase],
               tool_policy: AgentMachine.ToolPolicy.new!(permissions: [:test_uppercase]),
               tool_timeout_ms: 100,
               tool_max_rounds: 1
             )

    assert run.results["tool-user"].status == :error
    assert run.results["tool-user"].error =~ "tool_state"
  end

  test "fails when provider repeats a tool call id across rounds" do
    agents = [
      %{
        id: "tool-user",
        provider: AgentMachine.TestProviders.RepeatedToolID,
        model: "test",
        input: "hello",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:ok, run} =
             Orchestrator.run(agents,
               timeout: 1_000,
               allowed_tools: [AgentMachine.TestTools.Uppercase],
               tool_policy: AgentMachine.ToolPolicy.new!(permissions: [:test_uppercase]),
               tool_timeout_ms: 100,
               tool_max_rounds: 2
             )

    assert run.results["tool-user"].status == :error
    assert run.results["tool-user"].error =~ "globally unique"
  end

  test "returns an agent error when a tool call fails" do
    agents = [
      %{
        id: "tool-user",
        provider: AgentMachine.TestProviders.ToolFailing,
        model: "test",
        input: "hello",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:ok, run} =
             Orchestrator.run(agents,
               timeout: 1_000,
               allowed_tools: [AgentMachine.TestTools.Failing],
               tool_policy: AgentMachine.ToolPolicy.new!(permissions: [:test_failing]),
               tool_timeout_ms: 100,
               tool_max_rounds: 1
             )

    assert run.results["tool-user"].status == :error
    assert run.results["tool-user"].error =~ "tool AgentMachine.TestTools.Failing failed"
    assert Enum.any?(run.events, &(&1.type == :tool_call_failed))
  end

  test "rejects a tool call outside allowed_tools" do
    agents = [
      %{
        id: "tool-user",
        provider: AgentMachine.TestProviders.ToolUsing,
        model: "test",
        input: "hello",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:ok, run} =
             Orchestrator.run(agents,
               timeout: 1_000,
               allowed_tools: [AgentMachine.TestTools.Failing],
               tool_policy: AgentMachine.ToolPolicy.new!(permissions: [:test_failing]),
               tool_timeout_ms: 100,
               tool_max_rounds: 1
             )

    assert run.results["tool-user"].status == :error
    assert run.results["tool-user"].error =~ "not in :allowed_tools"
    assert Enum.any?(run.events, &(&1.type == :tool_call_failed))
  end

  test "requires explicit tool policy when a provider requests tools" do
    agents = [
      %{
        id: "tool-user",
        provider: AgentMachine.TestProviders.ToolUsing,
        model: "test",
        input: "hello",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:ok, run} =
             Orchestrator.run(agents,
               timeout: 1_000,
               allowed_tools: [AgentMachine.TestTools.Uppercase],
               tool_timeout_ms: 100,
               tool_max_rounds: 1
             )

    assert run.results["tool-user"].status == :error
    assert run.results["tool-user"].error =~ "explicit :tool_policy"
  end

  test "rejects a tool call outside the explicit tool policy" do
    agents = [
      %{
        id: "tool-user",
        provider: AgentMachine.TestProviders.ToolUsing,
        model: "test",
        input: "hello",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:ok, run} =
             Orchestrator.run(agents,
               timeout: 1_000,
               allowed_tools: [AgentMachine.TestTools.Uppercase],
               tool_policy: AgentMachine.ToolPolicy.new!(permissions: [:test_failing]),
               tool_timeout_ms: 100,
               tool_max_rounds: 1
             )

    assert run.results["tool-user"].status == :error
    assert run.results["tool-user"].error =~ "requires permission :test_uppercase"
    assert Enum.any?(run.events, &(&1.type == :tool_call_failed))
  end

  test "returns an agent error when a tool call times out" do
    agents = [
      %{
        id: "tool-user",
        provider: AgentMachine.TestProviders.ToolSleeping,
        model: "test",
        input: "hello",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:ok, run} =
             Orchestrator.run(agents,
               timeout: 1_000,
               allowed_tools: [AgentMachine.TestTools.Sleeping],
               tool_policy: AgentMachine.ToolPolicy.new!(permissions: [:test_sleeping]),
               tool_timeout_ms: 1,
               tool_max_rounds: 1
             )

    assert run.results["tool-user"].status == :error
    assert run.results["tool-user"].error =~ "timed out after 1ms"
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

defmodule AgentMachine.TestProviders.StructuredDelegating do
  @behaviour AgentMachine.Provider

  alias AgentMachine.{Agent, JSON}

  @impl true
  def complete(%Agent{id: "planner"} = agent, _opts) do
    output =
      JSON.encode!(%{
        output: "Created two workers.",
        next_agents: [
          %{
            id: "worker-a",
            input: "do part a",
            instructions: "handle only part a"
          },
          %{
            id: "worker-b",
            input: "do part b"
          }
        ]
      })

    {:ok, %{output: output, usage: usage(agent, output)}}
  end

  def complete(%Agent{} = agent, _opts) do
    output = "finished #{agent.id}"
    {:ok, %{output: output, usage: usage(agent, output)}}
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

defmodule AgentMachine.TestProviders.Finalizing do
  @behaviour AgentMachine.Provider

  alias AgentMachine.Agent

  @impl true
  def complete(%Agent{id: "planner"} = agent, _opts) do
    output = "planned final output"

    {:ok,
     %{
       output: output,
       artifacts: %{plan: "final plan"},
       usage: usage(agent, output),
       next_agents: [
         worker("worker-a", "do final part a", agent.pricing),
         worker("worker-b", "do final part b", agent.pricing)
       ]
     }}
  end

  def complete(%Agent{id: "finalizer"} = agent, opts) do
    context = Keyword.fetch!(opts, :run_context)
    worker_a = context.results |> Map.fetch!("worker-a") |> Map.fetch!(:output)
    worker_b = context.results |> Map.fetch!("worker-b") |> Map.fetch!(:output)
    output = "finalized #{worker_a} + #{worker_b}"

    {:ok,
     %{
       output: output,
       artifacts: %{final_output: output},
       usage: usage(agent, output)
     }}
  end

  def complete(%Agent{} = agent, _opts) do
    output = "#{agent.id} output"

    {:ok,
     %{
       output: output,
       usage: usage(agent, output)
     }}
  end

  defp worker(id, input, pricing) do
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

defmodule AgentMachine.TestProviders.Flaky do
  @behaviour AgentMachine.Provider

  alias AgentMachine.Agent

  @impl true
  def complete(%Agent{} = agent, opts) do
    case Keyword.fetch!(opts, :attempt) do
      1 ->
        {:error, :planned_failure}

      attempt ->
        output = "succeeded on attempt #{attempt}"

        {:ok,
         %{
           output: output,
           usage: usage(agent, output)
         }}
    end
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

defmodule AgentMachine.TestProviders.AlwaysFails do
  @behaviour AgentMachine.Provider

  alias AgentMachine.Agent

  @impl true
  def complete(%Agent{} = _agent, _opts), do: {:error, :planned_failure}
end

defmodule AgentMachine.TestProviders.ToolUsing do
  @behaviour AgentMachine.Provider

  alias AgentMachine.Agent

  @impl true
  def complete(%Agent{} = agent, opts) do
    case Keyword.get(opts, :tool_continuation) do
      %{results: [%{result: %{value: value}}]} -> final_response(value)
      nil -> tool_request(agent)
    end
  end

  defp final_response(value) do
    output = "final answer: #{value}"

    {:ok,
     %{
       output: output,
       usage: %{
         input_tokens: 1,
         output_tokens: token_count(output),
         total_tokens: 1 + token_count(output)
       }
     }}
  end

  defp tool_request(agent) do
    output = "called uppercase tool"

    {:ok,
     %{
       output: output,
       tool_calls: [
         %{
           id: "uppercase",
           tool: AgentMachine.TestTools.Uppercase,
           input: %{value: agent.input}
         }
       ],
       tool_state: %{round: 1},
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

defmodule AgentMachine.TestProviders.MultiRoundToolUsing do
  @behaviour AgentMachine.Provider

  alias AgentMachine.Agent

  @impl true
  def complete(%Agent{} = agent, opts) do
    case Keyword.get(opts, :tool_continuation) do
      %{state: %{round: 1}} -> second_tool_request()
      %{state: %{round: 2}, results: results} -> final_response(results)
      nil -> first_tool_request(agent)
    end
  end

  defp second_tool_request do
    output = "called second uppercase tool"

    {:ok,
     %{
       output: output,
       tool_calls: [
         %{
           id: "uppercase-2",
           tool: AgentMachine.TestTools.Uppercase,
           input: %{value: "hello again"}
         }
       ],
       tool_state: %{round: 2},
       usage: %{
         input_tokens: 1,
         output_tokens: token_count(output),
         total_tokens: 1 + token_count(output)
       }
     }}
  end

  defp final_response(results) do
    value = results |> List.first() |> Map.fetch!(:result) |> Map.fetch!(:value)
    output = "final answer: #{value}"

    {:ok,
     %{
       output: output,
       usage: %{
         input_tokens: 1,
         output_tokens: token_count(output),
         total_tokens: 1 + token_count(output)
       }
     }}
  end

  defp first_tool_request(agent) do
    output = "called first uppercase tool"

    {:ok,
     %{
       output: output,
       tool_calls: [
         %{
           id: "uppercase-1",
           tool: AgentMachine.TestTools.Uppercase,
           input: %{value: agent.input}
         }
       ],
       tool_state: %{round: 1},
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

defmodule AgentMachine.TestProviders.ToolMissingState do
  @behaviour AgentMachine.Provider

  alias AgentMachine.Agent

  @impl true
  def complete(%Agent{} = agent, _opts) do
    output = "called uppercase tool"

    {:ok,
     %{
       output: output,
       tool_calls: [
         %{
           id: "uppercase",
           tool: AgentMachine.TestTools.Uppercase,
           input: %{value: agent.input}
         }
       ],
       usage: %{input_tokens: 1, output_tokens: 3, total_tokens: 4}
     }}
  end
end

defmodule AgentMachine.TestProviders.RepeatedToolID do
  @behaviour AgentMachine.Provider

  alias AgentMachine.Agent

  @impl true
  def complete(%Agent{} = agent, opts) do
    case Keyword.get(opts, :tool_continuation) do
      %{state: %{round: 1}} -> repeated_tool_request()
      nil -> first_tool_request(agent)
    end
  end

  defp repeated_tool_request do
    output = "called duplicate uppercase tool"

    {:ok,
     %{
       output: output,
       tool_calls: [
         %{
           id: "duplicate",
           tool: AgentMachine.TestTools.Uppercase,
           input: %{value: "again"}
         }
       ],
       tool_state: %{round: 2},
       usage: %{
         input_tokens: 1,
         output_tokens: token_count(output),
         total_tokens: 1 + token_count(output)
       }
     }}
  end

  defp first_tool_request(agent) do
    output = "called uppercase tool"

    {:ok,
     %{
       output: output,
       tool_calls: [
         %{
           id: "duplicate",
           tool: AgentMachine.TestTools.Uppercase,
           input: %{value: agent.input}
         }
       ],
       tool_state: %{round: 1},
       usage: %{
         input_tokens: 1,
         output_tokens: token_count(output),
         total_tokens: 1 + token_count(output)
       }
     }}
  end

  defp token_count(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end
end

defmodule AgentMachine.TestProviders.ToolFailing do
  @behaviour AgentMachine.Provider

  alias AgentMachine.Agent

  @impl true
  def complete(%Agent{} = agent, _opts) do
    output = "called failing tool"

    {:ok,
     %{
       output: output,
       tool_calls: [
         %{
           id: "failing",
           tool: AgentMachine.TestTools.Failing,
           input: %{value: agent.input}
         }
       ],
       tool_state: %{round: 1},
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

defmodule AgentMachine.TestProviders.ToolSleeping do
  @behaviour AgentMachine.Provider

  alias AgentMachine.Agent

  @impl true
  def complete(%Agent{} = agent, _opts) do
    output = "called sleeping tool"

    {:ok,
     %{
       output: output,
       tool_calls: [
         %{
           id: "sleeping",
           tool: AgentMachine.TestTools.Sleeping,
           input: %{sleep_ms: 20}
         }
       ],
       tool_state: %{round: 1},
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

defmodule AgentMachine.TestTools.Uppercase do
  @behaviour AgentMachine.Tool

  @impl true
  def permission, do: :test_uppercase

  @impl true
  def approval_risk, do: :write

  @impl true
  def run(input, opts) do
    value = Map.fetch!(input, :value)
    attempt = Keyword.fetch!(opts, :attempt)

    {:ok, %{value: String.upcase(value), attempt: attempt}}
  end
end

defmodule AgentMachine.TestTools.Failing do
  @behaviour AgentMachine.Tool

  @impl true
  def permission, do: :test_failing

  @impl true
  def approval_risk, do: :write

  @impl true
  def run(_input, _opts), do: {:error, :planned_tool_failure}
end

defmodule AgentMachine.TestTools.Sleeping do
  @behaviour AgentMachine.Tool

  @impl true
  def permission, do: :test_sleeping

  @impl true
  def approval_risk, do: :write

  @impl true
  def run(input, _opts) do
    input |> Map.fetch!(:sleep_ms) |> Process.sleep()
    {:ok, %{slept: true}}
  end
end
