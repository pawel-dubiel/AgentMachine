defmodule AgentMachine.OrchestratorTest do
  use ExUnit.Case, async: false

  alias AgentMachine.{Orchestrator, UsageLedger}

  setup do
    UsageLedger.reset!()
    :ok
  end

  test "application starts run registry and run supervisor" do
    assert Process.whereis(AgentMachine.RunRegistry)
    assert Process.whereis(AgentMachine.RunSupervisor)
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

  test "registers each run and its per-run supervisors" do
    run_id = "run-registry-#{System.unique_integer([:positive])}"

    agents = [
      %{
        id: "assistant",
        provider: AgentMachine.Providers.Echo,
        model: "echo",
        input: "hello",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:ok, ^run_id} = Orchestrator.start_run(agents, run_id: run_id)
    assert %{id: ^run_id} = Orchestrator.get_run(run_id)
    assert [{run_pid, _}] = Registry.lookup(AgentMachine.RunRegistry, {:run, run_id})
    assert Process.alive?(run_pid)

    assert [{task_supervisor, _}] =
             Registry.lookup(AgentMachine.RunRegistry, {:task_supervisor, run_id})

    assert Process.alive?(task_supervisor)

    assert [{tool_session_supervisor, _}] =
             Registry.lookup(AgentMachine.RunRegistry, {:tool_session_supervisor, run_id})

    assert Process.alive?(tool_session_supervisor)

    assert [{event_collector, _}] =
             Registry.lookup(AgentMachine.RunRegistry, {:event_collector, run_id})

    assert Process.alive?(event_collector)
  end

  test "agent tasks run under the per-run task supervisor" do
    agents = [
      %{
        id: "inspector",
        provider: AgentMachine.TestProviders.TaskSupervisorInspecting,
        model: "test",
        input: "inspect",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:ok, run} = Orchestrator.run(agents, timeout: 1_000)
    assert run.results["inspector"].output == "per-run-task-supervisor"
  end

  test "terminating a run subtree cleans up its registered processes and tasks" do
    run_id = "run-cleanup-#{System.unique_integer([:positive])}"

    agents = [
      %{
        id: "slow",
        provider: AgentMachine.TestProviders.LongRunning,
        model: "test",
        input: "sleep",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:ok, ^run_id} = Orchestrator.start_run(agents, run_id: run_id)
    assert [{run_pid, _}] = Registry.lookup(AgentMachine.RunRegistry, {:run, run_id})

    assert [{task_supervisor, _}] =
             Registry.lookup(AgentMachine.RunRegistry, {:task_supervisor, run_id})

    assert {:ok, [task_pid]} = wait_for_task_child(task_supervisor, 50)
    assert tree_pid = run_tree_pid_for(run_pid)

    assert :ok = DynamicSupervisor.terminate_child(AgentMachine.RunSupervisor, tree_pid)
    Process.sleep(20)

    refute Process.alive?(run_pid)
    refute Process.alive?(task_supervisor)
    refute Process.alive?(task_pid)
    assert Registry.lookup(AgentMachine.RunRegistry, {:run, run_id}) == []
  end

  test "leased await cancels a run when the idle lease expires" do
    run_id = "run-idle-timeout-#{System.unique_integer([:positive])}"

    agents = [
      %{
        id: "slow",
        provider: AgentMachine.TestProviders.LongRunning,
        model: "test",
        input: "sleep",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:error, {:timeout, run}} =
             Orchestrator.run(agents,
               run_id: run_id,
               timeout: 40,
               idle_timeout_ms: 40,
               hard_timeout_ms: 200,
               heartbeat_interval_ms: false
             )

    assert run.status == :timeout
    assert run.error =~ "idle lease expired"
    assert Enum.any?(run.events, &(&1.type == :run_timed_out))
    assert run.tasks == %{}

    assert [{task_supervisor, _}] =
             Registry.lookup(AgentMachine.RunRegistry, {:task_supervisor, run_id})

    assert Task.Supervisor.children(task_supervisor) == []
  end

  test "leased await completes past the idle lease when heartbeats show progress" do
    agents = [
      %{
        id: "slow-but-healthy",
        provider: AgentMachine.TestProviders.ShortSleeping,
        model: "test",
        input: "sleep",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:ok, run} =
             Orchestrator.run(agents,
               timeout: 30,
               idle_timeout_ms: 30,
               hard_timeout_ms: 300,
               heartbeat_interval_ms: 10
             )

    assert run.status == :completed
    assert run.results["slow-but-healthy"].output == "finished"
    assert Enum.any?(run.events, &(&1.type == :agent_heartbeat))
    assert Enum.any?(run.events, &(&1.type == :run_lease_extended))
  end

  test "leased await cancels a healthy run at the hard cap" do
    agents = [
      %{
        id: "slow",
        provider: AgentMachine.TestProviders.LongRunning,
        model: "test",
        input: "sleep",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:error, {:timeout, run}} =
             Orchestrator.run(agents,
               timeout: 30,
               idle_timeout_ms: 30,
               hard_timeout_ms: 100,
               heartbeat_interval_ms: 10
             )

    assert run.status == :timeout
    assert run.error =~ "hard timeout reached"
    assert Enum.any?(run.events, &(&1.type == :agent_heartbeat))
    assert Enum.any?(run.events, &(&1.type == :run_timed_out))
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
    assert run.results["planner"].decision.mode == "delegate"
    assert run.results["planner"].decision.delegated_agent_ids == ["worker-a", "worker-b"]
    assert run.results["planner"].next_agents |> Enum.map(& &1.id) == ["worker-a", "worker-b"]
    assert run.results["worker-a"].output == "finished worker-a"
    assert run.results["worker-b"].output == "finished worker-b"
  end

  test "parses fenced structured delegation output" do
    agents = [
      %{
        id: "planner",
        provider: AgentMachine.TestProviders.FencedStructuredDelegating,
        model: "test",
        input: "split the work",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0},
        metadata: %{agent_machine_response: "delegation"}
      }
    ]

    assert {:ok, run} = Orchestrator.run(agents, timeout: 1_000, max_steps: 2)
    assert run.status == :completed
    assert run.results["planner"].output == "Created worker."
    assert run.results["planner"].decision.mode == "delegate"
    assert run.results["worker"].output == "finished worker"
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

  test "skips finalizer after a direct planner decision" do
    agents = [
      %{
        id: "planner",
        provider: AgentMachine.TestProviders.StructuredDirectPlanner,
        model: "test",
        input: "answer directly",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0},
        metadata: %{agent_machine_response: "delegation"}
      }
    ]

    finalizer = %{
      id: "finalizer",
      provider: AgentMachine.TestProviders.Finalizing,
      model: "test",
      input: "combine outputs",
      pricing: %{input_per_million: 0.0, output_per_million: 0.0}
    }

    assert {:ok, run} =
             Orchestrator.run(agents, timeout: 1_000, max_steps: 2, finalizer: finalizer)

    assert run.status == :completed
    assert run.agent_order == ["planner"]
    refute Map.has_key?(run.results, "finalizer")
    assert run.results["planner"].output == "Direct answer."
    assert run.results["planner"].decision.mode == "direct"
    assert run.usage.agents == 1
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
               tool_max_rounds: 2,
               tool_approval_mode: :auto_approved_safe
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

  test "agent metadata can disable tools for that agent" do
    agents = [
      %{
        id: "no-tools",
        provider: AgentMachine.TestProviders.ToolOptionsInspecting,
        model: "test",
        input: "inspect opts",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0},
        metadata: %{agent_machine_disable_tools: true}
      }
    ]

    assert {:ok, run} =
             Orchestrator.run(agents,
               timeout: 1_000,
               allowed_tools: [AgentMachine.TestTools.Uppercase],
               tool_policy: AgentMachine.ToolPolicy.new!(permissions: [:test_uppercase]),
               tool_timeout_ms: 100,
               tool_max_rounds: 2,
               tool_approval_mode: :auto_approved_safe
             )

    assert run.results["no-tools"].status == :ok
    assert run.results["no-tools"].output == "tools disabled"
  end

  test "agent metadata can disable tool schemas while preserving tool context" do
    agents = [
      %{
        id: "no-tools",
        provider: AgentMachine.TestProviders.ToolContextInspecting,
        model: "test",
        input: "inspect opts",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0},
        metadata: %{agent_machine_disable_tools: true}
      }
    ]

    assert {:ok, run} =
             Orchestrator.run(agents,
               timeout: 1_000,
               allowed_tools: [AgentMachine.Tools.CreateDir],
               tool_policy: AgentMachine.ToolHarness.builtin_policy!(:local_files),
               tool_root: "/tmp/agent-machine-home",
               tool_timeout_ms: 100,
               tool_max_rounds: 2,
               tool_approval_mode: :auto_approved_safe
             )

    assert run.results["no-tools"].status == :ok
    assert run.results["no-tools"].output =~ "worker agents only"
    assert run.results["no-tools"].output =~ "create_dir"
    assert run.results["no-tools"].output =~ "/tmp/agent-machine-home"
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
               tool_max_rounds: 2,
               tool_approval_mode: :auto_approved_safe
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
               tool_max_rounds: 1,
               tool_approval_mode: :auto_approved_safe
             )

    assert run.results["tool-user"].status == :error
    assert run.results["tool-user"].error =~ "exceeded :tool_max_rounds 1"

    assert run.results["tool-user"].tool_results == %{
             "uppercase-1" => %{value: "HELLO", attempt: 1}
           }
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
               tool_max_rounds: 1,
               tool_approval_mode: :auto_approved_safe
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
               tool_max_rounds: 2,
               tool_approval_mode: :auto_approved_safe
             )

    assert run.results["tool-user"].status == :error
    assert run.results["tool-user"].error =~ "globally unique"
  end

  test "returns recoverable tool execution errors to the provider" do
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
               tool_max_rounds: 1,
               tool_approval_mode: :auto_approved_safe
             )

    assert run.results["tool-user"].status == :ok
    assert run.results["tool-user"].output == "recovered from tool error: :planned_tool_failure"

    assert run.results["tool-user"].tool_results == %{
             "failing" => %{
               status: "error",
               error: ":planned_tool_failure",
               tool: "AgentMachine.TestTools.Failing"
             }
           }

    assert Enum.any?(run.events, &(&1.type == :tool_call_failed))

    assert run.events
           |> Enum.filter(&(&1.type in [:tool_call_started, :tool_call_failed]))
           |> Enum.map(& &1.type) == [:tool_call_started, :tool_call_failed]
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
               tool_max_rounds: 1,
               tool_approval_mode: :auto_approved_safe
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
               tool_max_rounds: 1,
               tool_approval_mode: :auto_approved_safe
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
               tool_max_rounds: 1,
               tool_approval_mode: :auto_approved_safe
             )

    assert run.results["tool-user"].status == :error
    assert run.results["tool-user"].error =~ "requires permission :test_uppercase"
    assert Enum.any?(run.events, &(&1.type == :tool_call_failed))
  end

  test "requires explicit tool approval mode when a provider requests tools" do
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
               tool_max_rounds: 1
             )

    assert run.results["tool-user"].status == :error
    assert run.results["tool-user"].error =~ "explicit :tool_approval_mode"
  end

  test "read-only approval mode allows read tools" do
    agents = [
      %{
        id: "tool-user",
        provider: AgentMachine.TestProviders.NowUsing,
        model: "test",
        input: "what time is it?",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:ok, run} =
             Orchestrator.run(agents,
               timeout: 1_000,
               allowed_tools: [AgentMachine.Tools.Now],
               tool_policy: AgentMachine.ToolPolicy.new!(permissions: [:time_read]),
               tool_timeout_ms: 100,
               tool_max_rounds: 1,
               tool_approval_mode: :read_only
             )

    assert run.results["tool-user"].status == :ok
    assert run.results["tool-user"].output =~ "final answer:"
    assert %{"now" => %{utc: _utc}} = run.results["tool-user"].tool_results
  end

  test "read-only approval mode rejects write tools before execution" do
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
               tool_max_rounds: 1,
               tool_approval_mode: :read_only
             )

    assert run.results["tool-user"].status == :error
    assert run.results["tool-user"].error =~ "approval risk :write"
    assert run.results["tool-user"].tool_results in [nil, %{}]
    assert Enum.any?(run.events, &(&1.type == :tool_call_failed))
  end

  test "ask-before-write approval mode rejects writes without callback" do
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
               tool_max_rounds: 1,
               tool_approval_mode: :ask_before_write
             )

    assert run.results["tool-user"].status == :error
    assert run.results["tool-user"].error =~ "requires approval"
  end

  test "ask-before-write approval mode allows writes with approval callback" do
    agents = [
      %{
        id: "tool-user",
        provider: AgentMachine.TestProviders.ToolUsing,
        model: "test",
        input: "hello",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    callback = fn context ->
      assert context.tool_call_id == "uppercase"
      assert context.risk == :write
      :approved
    end

    assert {:ok, run} =
             Orchestrator.run(agents,
               timeout: 1_000,
               allowed_tools: [AgentMachine.TestTools.Uppercase],
               tool_policy: AgentMachine.ToolPolicy.new!(permissions: [:test_uppercase]),
               tool_timeout_ms: 100,
               tool_max_rounds: 1,
               tool_approval_mode: :ask_before_write,
               tool_approval_callback: callback
             )

    assert run.results["tool-user"].status == :ok
    assert run.results["tool-user"].tool_results["uppercase"].value == "HELLO"
  end

  test "command approval mode requires full access" do
    agents = [
      %{
        id: "tool-user",
        provider: AgentMachine.TestProviders.TestCommandUsing,
        model: "test",
        input: "verify",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    root = tmp_root("agent-machine-command-approval")

    assert {:ok, run} =
             Orchestrator.run(agents,
               timeout: 1_000,
               allowed_tools: [AgentMachine.Tools.RunTestCommand],
               tool_policy: AgentMachine.ToolPolicy.new!(permissions: [:test_command_run]),
               tool_root: root,
               test_commands: ["elixir -e IO.puts(1)"],
               tool_timeout_ms: 100,
               tool_max_rounds: 1,
               tool_approval_mode: :auto_approved_safe
             )

    assert run.results["tool-user"].status == :error
    assert run.results["tool-user"].error =~ "approval risk :command"
  end

  test "command tool fails without matching policy permission" do
    agents = [
      %{
        id: "tool-user",
        provider: AgentMachine.TestProviders.TestCommandUsing,
        model: "test",
        input: "verify",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    root = tmp_root("agent-machine-command-policy")

    assert {:ok, run} =
             Orchestrator.run(agents,
               timeout: 1_000,
               allowed_tools: [AgentMachine.Tools.RunTestCommand],
               tool_policy: AgentMachine.ToolPolicy.new!(permissions: [:local_files_read]),
               tool_root: root,
               test_commands: ["elixir -e IO.puts(1)"],
               tool_timeout_ms: 100,
               tool_max_rounds: 1,
               tool_approval_mode: :full_access
             )

    assert run.results["tool-user"].status == :error
    assert run.results["tool-user"].error =~ "requires permission :test_command_run"
  end

  test "returns recoverable tool timeout errors to the provider" do
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
               tool_max_rounds: 1,
               tool_approval_mode: :auto_approved_safe
             )

    assert run.results["tool-user"].status == :ok
    assert run.results["tool-user"].output == "recovered from tool error: timed out after 1ms"
    assert run.results["tool-user"].tool_results["sleeping"].status == "error"
    assert run.results["tool-user"].tool_results["sleeping"].error == "timed out after 1ms"
    assert Enum.any?(run.events, &(&1.type == :tool_call_failed))
  end

  test "emits telemetry for run, agent, and tool events" do
    parent = self()
    handler_id = {:orchestrator_test, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:agent_machine, :run, :start],
          [:agent_machine, :run, :stop],
          [:agent_machine, :agent, :start],
          [:agent_machine, :agent, :stop],
          [:agent_machine, :tool, :start],
          [:agent_machine, :tool, :stop]
        ],
        &AgentMachine.TestTelemetryForwarder.handle/4,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

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
               tool_max_rounds: 2,
               tool_approval_mode: :auto_approved_safe
             )

    events = flush_telemetry([])
    assert Enum.any?(events, &match?({[:agent_machine, :run, :start], _, %{run_id: _}}, &1))

    assert Enum.any?(
             events,
             &match?({[:agent_machine, :run, :stop], %{duration: _}, %{run_id: _}}, &1)
           )

    assert Enum.any?(
             events,
             &match?({[:agent_machine, :agent, :start], _, %{agent_id: "tool-user"}}, &1)
           )

    assert Enum.any?(
             events,
             &match?(
               {[:agent_machine, :agent, :stop], %{duration: _}, %{agent_id: "tool-user"}},
               &1
             )
           )

    assert Enum.any?(
             events,
             &match?(
               {[:agent_machine, :tool, :start], _, %{tool: "AgentMachine.TestTools.Uppercase"}},
               &1
             )
           )

    assert Enum.any?(
             events,
             &match?(
               {[:agent_machine, :tool, :stop], %{duration: _},
                %{tool: "AgentMachine.TestTools.Uppercase"}},
               &1
             )
           )

    assert run.results["tool-user"].status == :ok
  end

  test "emits telemetry for run timeouts" do
    parent = self()
    handler_id = {:orchestrator_timeout_test, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach_many(
        handler_id,
        [[:agent_machine, :run, :exception]],
        &AgentMachine.TestTelemetryForwarder.handle/4,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    agents = [
      %{
        id: "slow",
        provider: AgentMachine.TestProviders.LongRunning,
        model: "test",
        input: "sleep",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:error, {:timeout, _run}} =
             Orchestrator.run(agents,
               timeout: 30,
               idle_timeout_ms: 30,
               hard_timeout_ms: 120,
               heartbeat_interval_ms: false
             )

    events = flush_telemetry([])

    assert Enum.any?(
             events,
             &match?(
               {[:agent_machine, :run, :exception], %{duration: _},
                %{reason: "idle lease expired after 30ms without runtime activity"}},
               &1
             )
           )
  end

  defp tmp_root(prefix) do
    root = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp wait_for_task_child(_task_supervisor, 0), do: {:error, :timeout}

  defp wait_for_task_child(task_supervisor, attempts_left) do
    case Task.Supervisor.children(task_supervisor) do
      [] ->
        Process.sleep(10)
        wait_for_task_child(task_supervisor, attempts_left - 1)

      pids ->
        {:ok, pids}
    end
  end

  defp run_tree_pid_for(run_pid) do
    AgentMachine.RunSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.find_value(fn {_id, pid, _type, _modules} ->
      if run_tree_has_child?(pid, run_pid), do: pid
    end)
  end

  defp run_tree_has_child?(tree_pid, child_pid) do
    tree_pid
    |> Supervisor.which_children()
    |> Enum.any?(fn {_id, pid, _type, _modules} -> pid == child_pid end)
  end

  defp flush_telemetry(acc) do
    receive do
      {:telemetry, event, measurements, metadata} ->
        flush_telemetry([{event, measurements, metadata} | acc])
    after
      50 -> Enum.reverse(acc)
    end
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
        decision: %{
          mode: "delegate",
          reason: "The work should be split across two workers."
        },
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

defmodule AgentMachine.TestProviders.StructuredDirectPlanner do
  @behaviour AgentMachine.Provider

  alias AgentMachine.{Agent, JSON}

  @impl true
  def complete(%Agent{} = agent, _opts) do
    output =
      JSON.encode!(%{
        decision: %{
          mode: "direct",
          reason: "No worker is needed."
        },
        output: "Direct answer.",
        next_agents: []
      })

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

defmodule AgentMachine.TestProviders.FencedStructuredDelegating do
  @behaviour AgentMachine.Provider

  alias AgentMachine.{Agent, JSON}

  @impl true
  def complete(%Agent{id: "planner"} = agent, _opts) do
    json =
      JSON.encode!(%{
        decision: %{
          mode: "delegate",
          reason: "A worker should handle the task."
        },
        output: "Created worker.",
        next_agents: [
          %{
            id: "worker",
            input: "do work"
          }
        ]
      })

    output = "```json\n" <> json <> "\n```"
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

defmodule AgentMachine.TestProviders.ToolOptionsInspecting do
  @behaviour AgentMachine.Provider

  alias AgentMachine.Agent

  @impl true
  def complete(%Agent{} = agent, opts) do
    output =
      if Keyword.has_key?(opts, :allowed_tools) do
        "tools enabled"
      else
        "tools disabled"
      end

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

defmodule AgentMachine.TestProviders.ToolContextInspecting do
  @behaviour AgentMachine.Provider

  alias AgentMachine.{Agent, RunContextPrompt}

  @impl true
  def complete(%Agent{} = agent, opts) do
    output = RunContextPrompt.text(opts)
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

defmodule AgentMachine.TestProviders.TaskSupervisorInspecting do
  @behaviour AgentMachine.Provider

  alias AgentMachine.Agent

  @impl true
  def complete(%Agent{} = _agent, opts) do
    task_supervisor = Keyword.fetch!(opts, :task_supervisor)
    run_children = Task.Supervisor.children(task_supervisor)
    global_children = Task.Supervisor.children(AgentMachine.AgentSupervisor)

    output =
      if self() in run_children and self() not in global_children do
        "per-run-task-supervisor"
      else
        "wrong-task-supervisor"
      end

    {:ok,
     %{
       output: output,
       usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}
     }}
  end
end

defmodule AgentMachine.TestProviders.LongRunning do
  @behaviour AgentMachine.Provider

  alias AgentMachine.Agent

  @impl true
  def complete(%Agent{} = _agent, _opts) do
    Process.sleep(5_000)

    {:ok,
     %{
       output: "finished",
       usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}
     }}
  end
end

defmodule AgentMachine.TestProviders.ShortSleeping do
  @behaviour AgentMachine.Provider

  alias AgentMachine.Agent

  @impl true
  def complete(%Agent{} = _agent, _opts) do
    Process.sleep(80)

    {:ok,
     %{
       output: "finished",
       usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}
     }}
  end
end

defmodule AgentMachine.TestProviders.NowUsing do
  @behaviour AgentMachine.Provider

  alias AgentMachine.Agent

  @impl true
  def complete(%Agent{} = agent, opts) do
    case Keyword.get(opts, :tool_continuation) do
      %{results: [%{result: %{utc: utc}}]} -> final_response(utc)
      nil -> tool_request(agent)
    end
  end

  defp final_response(utc) do
    output = "final answer: #{utc}"

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
    output = "called now tool"

    {:ok,
     %{
       output: output,
       tool_calls: [
         %{
           id: "now",
           tool: AgentMachine.Tools.Now,
           input: %{}
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

defmodule AgentMachine.TestProviders.TestCommandUsing do
  @behaviour AgentMachine.Provider

  alias AgentMachine.Agent

  @impl true
  def complete(%Agent{} = agent, opts) do
    case Keyword.get(opts, :tool_continuation) do
      %{results: [%{result: %{exit_status: status}}]} -> final_response(status)
      nil -> tool_request(agent)
    end
  end

  defp final_response(status) do
    output = "test command finished with #{inspect(status)}"

    {:ok,
     %{
       output: output,
       usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}
     }}
  end

  defp tool_request(agent) do
    output = "called test command"

    {:ok,
     %{
       output: output,
       tool_calls: [
         %{
           id: "run-tests",
           tool: AgentMachine.Tools.RunTestCommand,
           input: %{command: "elixir -e IO.puts(1)", cwd: "."}
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
  def complete(%Agent{} = agent, opts) do
    case Keyword.get(opts, :tool_continuation) do
      %{results: [%{result: %{status: "error", error: error}}]} -> final_response(error)
      nil -> tool_request(agent)
    end
  end

  defp final_response(error) do
    output = "recovered from tool error: #{error}"

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
  def complete(%Agent{} = agent, opts) do
    case Keyword.get(opts, :tool_continuation) do
      %{results: [%{result: %{status: "error", error: error}}]} -> final_response(error)
      nil -> tool_request(agent)
    end
  end

  defp final_response(error) do
    output = "recovered from tool error: #{error}"

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
