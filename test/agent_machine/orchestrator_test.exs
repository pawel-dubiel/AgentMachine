defmodule AgentMachine.OrchestratorTest do
  use ExUnit.Case, async: false

  alias AgentMachine.{Orchestrator, UsageLedger}

  setup do
    UsageLedger.reset!()
    :ok
  end

  defp context_tokenizer_path do
    Path.expand("../fixtures/context_tokenizer.json", __DIR__)
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
    assert {:ok, %{status: :completed}} = Orchestrator.await_run(run_id, 1_000)
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

  test "emits unknown context budget events when tokenizer path is missing" do
    agents = [
      %{
        id: "assistant",
        provider: AgentMachine.Providers.Echo,
        model: "echo",
        input: "hello",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:ok, run} = Orchestrator.run(agents, timeout: 1_000)

    assert Enum.any?(run.events, fn event ->
             event.type == :context_budget and event.agent_id == "assistant" and
               event.status == "unknown" and event.reason == "missing_context_tokenizer_path"
           end)
  end

  test "emits unknown context budget events when context window is missing" do
    agents = [
      %{
        id: "assistant",
        provider: AgentMachine.Providers.Echo,
        model: "echo",
        input: "hello",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:ok, run} =
             Orchestrator.run(agents,
               timeout: 1_000,
               context_tokenizer_path: context_tokenizer_path()
             )

    assert Enum.any?(run.events, fn event ->
             event.type == :context_budget and event.agent_id == "assistant" and
               event.status == "unknown" and event.reason == "missing_context_window_tokens" and
               event.measurement == "tokenizer_estimate" and event.used_tokens > 0
           end)
  end

  test "emits warning context budget events when usage reaches configured threshold" do
    agents = [
      %{
        id: "assistant",
        provider: AgentMachine.Providers.Echo,
        model: "echo",
        input: "hello",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:ok, run} =
             Orchestrator.run(agents,
               timeout: 1_000,
               context_window_tokens: 1,
               context_warning_percent: 1,
               context_tokenizer_path: context_tokenizer_path()
             )

    assert Enum.any?(run.events, fn event ->
             event.type == :context_budget and event.agent_id == "assistant" and
               event.status == "warning" and event.context_window_tokens == 1 and
               event.warning_percent == 1 and event.used_percent >= 1
           end)
  end

  test "run-context compaction hides covered raw results from later agents but preserves final raw results" do
    agents = [
      %{
        id: "planner",
        provider: AgentMachine.TestProviders.RunContextCompacting,
        model: "test",
        input: "plan with large context",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:ok, run} =
             Orchestrator.run(agents,
               timeout: 1_000,
               max_steps: 2,
               context_window_tokens: 1,
               context_tokenizer_path: context_tokenizer_path(),
               run_context_compaction: :on,
               run_context_compact_percent: 1,
               max_context_compactions: 1
             )

    assert run.status == :completed
    assert run.results["planner"].output == "raw planner output that should stay in summary"

    assert run.results["worker"].output ==
             "saw_raw=false saw_plan=false compacted=compacted planner context"

    assert run.usage.agents == 2

    assert run.usage.total_tokens >
             run.results["planner"].usage.total_tokens + run.results["worker"].usage.total_tokens

    assert Enum.any?(run.events, &(&1.type == :run_context_compaction_started))

    assert Enum.any?(
             run.events,
             &(&1.type == :run_context_compaction_finished and &1.covered_items == ["planner"])
           )
  end

  test "run-context compaction skips when request budget measurement is unknown" do
    agents = [
      %{
        id: "planner",
        provider: AgentMachine.TestProviders.RunContextCompacting,
        model: "test",
        input: "plan with large context",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:ok, run} =
             Orchestrator.run(agents,
               timeout: 1_000,
               max_steps: 2,
               context_window_tokens: 1,
               run_context_compaction: :on,
               run_context_compact_percent: 1,
               max_context_compactions: 1
             )

    assert run.status == :completed

    assert run.results["worker"].output ==
             "saw_raw=true saw_plan=true compacted=none"

    assert Enum.any?(
             run.events,
             &(&1.type == :run_context_compaction_skipped and
                 &1.reason == "missing_context_tokenizer_path")
           )

    refute Enum.any?(run.events, &(&1.type == :run_context_compaction_started))
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

  test "schedules delegated agents as a dependency DAG" do
    agents = [
      %{
        id: "planner",
        provider: AgentMachine.TestProviders.SwarmGraph,
        model: "test",
        input: "plan swarm graph",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:ok, run} = Orchestrator.run(agents, timeout: 1_000, max_steps: 4)
    assert run.status == :completed
    assert run.agent_order == ["planner", "variant-minimal", "variant-robust", "evaluator"]
    assert run.results["evaluator"].output == "evaluated minimal output + robust output"

    assert Enum.any?(run.events, fn event ->
             event.type == :agent_started and event.agent_id == "variant-minimal" and
               event.agent_machine_role == "swarm_variant" and event.variant_id == "minimal" and
               event.workspace == ".agent-machine/swarm/run-graph/minimal" and
               event.spawn_depth == 1
           end)
  end

  test "isolates swarm variant filesystem tools to their workspaces" do
    run_id = "run-swarm-workspace-#{System.unique_integer([:positive])}"
    root = tmp_root("agent-machine-swarm-workspace")

    agents = [
      %{
        id: "planner",
        provider: AgentMachine.TestProviders.SwarmWorkspace,
        model: "test",
        input: "plan isolated workspaces",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:ok, run} =
             Orchestrator.run(agents,
               run_id: run_id,
               timeout: 1_000,
               max_steps: 4,
               allowed_tools: [AgentMachine.Tools.WriteFile],
               tool_policy: AgentMachine.ToolHarness.builtin_policy!(:local_files),
               tool_root: root,
               tool_timeout_ms: 100,
               tool_max_rounds: 1,
               tool_approval_mode: :auto_approved_safe
             )

    minimal_workspace = Path.join(root, ".agent-machine/swarm/#{run_id}/minimal")
    robust_workspace = Path.join(root, ".agent-machine/swarm/#{run_id}/robust")

    assert File.dir?(minimal_workspace)
    assert File.dir?(robust_workspace)
    refute File.exists?(Path.join(root, "outside.txt"))

    assert run.results["variant-minimal"].output =~ minimal_workspace
    assert run.results["variant-minimal"].output =~ "outside tool root"
    assert run.results["variant-robust"].output =~ robust_workspace
    assert run.results["evaluator"].output =~ "variant-minimal"
  end

  test "swarm variants can write and run approved code checks inside isolated workspaces" do
    run_id = "run-swarm-code-edit-#{System.unique_integer([:positive])}"
    root = tmp_root("agent-machine-swarm-code-edit")
    parent = self()
    test_commands = ["elixir sort_check.exs"]

    agents = [
      %{
        id: "planner",
        provider: AgentMachine.TestProviders.SwarmCodeEdit,
        model: "test",
        input: "plan code-edit swarm",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    callback = fn context ->
      send(parent, {:approval_context, context})
      :approved
    end

    assert {:ok, run} =
             Orchestrator.run(agents,
               run_id: run_id,
               timeout: 5_000,
               max_steps: 5,
               allowed_tools:
                 AgentMachine.ToolHarness.builtin_many!([:code_edit],
                   test_commands: test_commands
                 ),
               tool_policy:
                 AgentMachine.ToolHarness.builtin_policy_many!([:code_edit],
                   test_commands: test_commands
                 ),
               tool_root: root,
               test_commands: test_commands,
               tool_timeout_ms: 1_000,
               tool_max_rounds: 3,
               tool_approval_mode: :ask_before_write,
               tool_approval_callback: callback
             )

    approval_contexts = drain_approval_contexts([])

    assert run.status == :completed
    assert run.results["variant-minimal"].status == :ok
    assert run.results["variant-robust"].status == :ok
    assert run.results["variant-experimental"].status == :ok
    assert run.results["variant-minimal"].output =~ "exit_status=0"
    assert run.results["variant-robust"].output =~ "exit_status=0"
    assert run.results["variant-experimental"].output =~ "exit_status=0"
    assert run.results["evaluator"].output =~ "recommended=robust"

    assert Enum.count(approval_contexts, &(&1.tool == AgentMachine.Tools.ApplyPatch)) == 3
    assert Enum.count(approval_contexts, &(&1.tool == AgentMachine.Tools.RunTestCommand)) == 3

    assert Enum.all?(approval_contexts, fn context ->
             context.agent_machine_role == "swarm_variant" and
               context.variant_id in ["minimal", "robust", "experimental"] and
               context.workspace == ".agent-machine/swarm/#{run_id}/#{context.variant_id}" and
               context.spawn_depth == 1
           end)

    Enum.each(["minimal", "robust", "experimental"], fn variant_id ->
      assert File.exists?(
               Path.join(root, ".agent-machine/swarm/#{run_id}/#{variant_id}/sort_check.exs")
             )
    end)

    refute File.exists?(Path.join(root, "sort_check.exs"))

    assert Enum.count(run.events, fn event ->
             event.type == :tool_call_finished and event.tool == "run_test_command" and
               event.agent_machine_role == "swarm_variant"
           end) == 3
  end

  test "swarm code writes fail when runtime approval denies them" do
    run_id = "run-swarm-code-denied-#{System.unique_integer([:positive])}"
    root = tmp_root("agent-machine-swarm-code-denied")
    parent = self()
    test_commands = ["elixir sort_check.exs"]

    agents = [
      %{
        id: "planner",
        provider: AgentMachine.TestProviders.SwarmCodeEdit,
        model: "test",
        input: "plan denied code-edit swarm",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    callback = fn context ->
      send(parent, {:approval_context, context})
      {:denied, "test denial"}
    end

    assert {:ok, run} =
             Orchestrator.run(agents,
               run_id: run_id,
               timeout: 5_000,
               max_steps: 5,
               allowed_tools:
                 AgentMachine.ToolHarness.builtin_many!([:code_edit],
                   test_commands: test_commands
                 ),
               tool_policy:
                 AgentMachine.ToolHarness.builtin_policy_many!([:code_edit],
                   test_commands: test_commands
                 ),
               tool_root: root,
               test_commands: test_commands,
               tool_timeout_ms: 1_000,
               tool_max_rounds: 3,
               tool_approval_mode: :ask_before_write,
               tool_approval_callback: callback
             )

    approval_contexts = drain_approval_contexts([])

    assert approval_contexts != []
    assert Enum.all?(approval_contexts, &(&1.agent_machine_role == "swarm_variant"))
    assert run.results["variant-minimal"].status == :error
    assert run.results["variant-robust"].status == :error
    assert run.results["variant-experimental"].status == :error
    assert Path.wildcard(Path.join(root, ".agent-machine/swarm/**/sort_check.exs")) == []

    assert Enum.count(run.events, fn event ->
             event.type == :tool_call_failed and event.agent_machine_role == "swarm_variant" and
               String.contains?(event.reason || "", "tool approval denied")
           end) == 6
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

  test "fails a dynamic run when delegated dependencies contain a cycle" do
    agents = [
      %{
        id: "planner",
        provider: AgentMachine.TestProviders.InvalidDynamicGraph,
        model: "test",
        input: "cycle",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:error, {:failed, run}} = Orchestrator.run(agents, timeout: 1_000, max_steps: 4)
    assert run.status == :failed
    assert run.error =~ "dependency graph contains a cycle"
    assert Map.keys(run.results) == ["planner"]
  end

  test "fails a dynamic run when one agent proposes too many children" do
    agents = [
      %{
        id: "planner",
        provider: AgentMachine.TestProviders.InvalidDynamicGraph,
        model: "test",
        input: "too many children",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:error, {:failed, run}} = Orchestrator.run(agents, timeout: 1_000, max_steps: 20)
    assert run.status == :failed
    assert run.error =~ "max children per agent"
    assert Map.keys(run.results) == ["planner"]
  end

  test "fails a dynamic run when spawn depth exceeds the runtime limit" do
    agents = [
      %{
        id: "planner",
        provider: AgentMachine.TestProviders.RecursiveDelegating,
        model: "test",
        input: "recurse",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:error, {:failed, run}} = Orchestrator.run(agents, timeout: 1_000, max_steps: 10)
    assert run.status == :failed
    assert run.error =~ "max depth"
    assert Map.has_key?(run.results, "depth-3")
    refute Map.has_key?(run.results, "depth-4")
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

  test "agentic persistence runs a reviewer before the finalizer" do
    agents = [agentic_persistence_planner()]

    assert {:ok, run} =
             Orchestrator.run(agents,
               timeout: 1_000,
               max_steps: 4,
               finalizer: agentic_persistence_finalizer(),
               goal_reviewer: agentic_persistence_reviewer("complete"),
               agentic_persistence_rounds: 1
             )

    assert run.status == :completed
    assert run.agent_order == ["planner", "worker-a", "goal-reviewer-1", "finalizer"]
    assert run.results["goal-reviewer-1"].decision.mode == "complete"

    assert run.results["goal-reviewer-1"].decision.completion_evidence == [
             %{
               source_agent_id: "worker-a",
               kind: "agent_output",
               summary: "worker-a confirms initial worker completed the task"
             }
           ]

    assert run.goal_review_continue_count == 0
    assert run.goal_review_completed == true
    assert run.results["finalizer"].output =~ "reviewed=goal-reviewer-1 complete"

    assert Enum.any?(run.events, fn event ->
             event.type == :agentic_review_decided and event.reviewer_id == "goal-reviewer-1" and
               event.mode == "complete" and event.round == 1 and event.continue_count == 0 and
               event.delegated_agent_ids == [] and event.completion_evidence_count == 1 and
               event.completion_evidence ==
                 run.results["goal-reviewer-1"].decision.completion_evidence
           end)
  end

  test "agentic persistence can continue once before completing and finalizing" do
    agents = [agentic_persistence_planner()]

    assert {:ok, run} =
             Orchestrator.run(agents,
               timeout: 1_000,
               max_steps: 6,
               finalizer: agentic_persistence_finalizer(),
               goal_reviewer: agentic_persistence_reviewer("continue-once"),
               agentic_persistence_rounds: 1
             )

    assert run.status == :completed

    assert run.agent_order == [
             "planner",
             "worker-a",
             "goal-reviewer-1",
             "follow-up",
             "goal-reviewer-2",
             "finalizer"
           ]

    assert run.results["goal-reviewer-1"].decision.mode == "continue"
    assert run.results["goal-reviewer-1"].decision.delegated_agent_ids == ["follow-up"]
    assert run.results["follow-up"].output == "follow-up output"
    assert run.results["goal-reviewer-2"].decision.mode == "complete"

    assert run.results["goal-reviewer-2"].decision.completion_evidence == [
             %{
               source_agent_id: "follow-up",
               kind: "agent_output",
               summary: "follow-up confirms follow-up completed missing work"
             }
           ]

    assert run.goal_review_continue_count == 1
    assert run.goal_review_completed == true
    assert run.results["finalizer"].output =~ "follow_up=true"
  end

  test "agentic persistence accepts reviewer artifact completion evidence" do
    agents = [agentic_persistence_planner()]

    assert {:ok, run} =
             Orchestrator.run(agents,
               timeout: 1_000,
               max_steps: 4,
               finalizer: agentic_persistence_finalizer(),
               goal_reviewer: agentic_persistence_reviewer("complete-artifact"),
               agentic_persistence_rounds: 1
             )

    assert run.status == :completed

    assert run.results["goal-reviewer-1"].decision.completion_evidence == [
             %{
               source_agent_id: "worker-a",
               kind: "artifact",
               summary: "worker-a produced the worker_marker artifact",
               artifact_key: "worker_marker"
             }
           ]
  end

  test "agentic persistence fails when reviewer completion evidence references missing work" do
    agents = [agentic_persistence_planner()]

    assert {:error, {:failed, run}} =
             Orchestrator.run(agents,
               timeout: 1_000,
               max_steps: 4,
               finalizer: agentic_persistence_finalizer(),
               goal_reviewer: agentic_persistence_reviewer("complete-unknown-evidence"),
               agentic_persistence_rounds: 1
             )

    assert run.status == :failed

    assert run.error =~
             ~s(completion_evidence references unknown source_agent_id "missing-worker")

    assert run.goal_review_completed == false
    refute Map.has_key?(run.results, "finalizer")
    refute Enum.any?(run.events, &(&1.type == :agentic_review_decided))
  end

  test "agentic persistence fails when continue decisions exhaust configured rounds" do
    agents = [agentic_persistence_planner()]

    assert {:error, {:failed, run}} =
             Orchestrator.run(agents,
               timeout: 1_000,
               max_steps: 8,
               finalizer: agentic_persistence_finalizer(),
               goal_reviewer: agentic_persistence_reviewer("always-continue"),
               agentic_persistence_rounds: 1
             )

    assert run.status == :failed
    assert run.error =~ "agentic persistence exhausted after 1 continue round(s)"
    assert run.goal_review_continue_count == 2
    refute Map.has_key?(run.results, "finalizer")

    assert Enum.count(run.events, &(&1.type == :agentic_review_decided)) == 2
  end

  test "agentic persistence reviewers and follow-ups count against max_steps" do
    agents = [agentic_persistence_planner()]

    assert {:error, {:failed, run}} =
             Orchestrator.run(agents,
               timeout: 1_000,
               max_steps: 4,
               finalizer: agentic_persistence_finalizer(),
               goal_reviewer: agentic_persistence_reviewer("continue-once"),
               agentic_persistence_rounds: 1
             )

    assert run.status == :failed
    assert run.error =~ "exceed max_steps 4"
    assert run.agent_order == ["planner", "worker-a", "goal-reviewer-1", "follow-up"]
    refute Map.has_key?(run.results, "goal-reviewer-2")
    refute Map.has_key?(run.results, "finalizer")
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

  test "direct planner decisions bypass agentic persistence reviewers" do
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

    assert {:ok, run} =
             Orchestrator.run(agents,
               timeout: 1_000,
               max_steps: 3,
               finalizer: agentic_persistence_finalizer(),
               goal_reviewer: agentic_persistence_reviewer("continue-once"),
               agentic_persistence_rounds: 1
             )

    assert run.status == :completed
    assert run.agent_order == ["planner"]
    refute Map.has_key?(run.results, "goal-reviewer-1")
    refute Map.has_key?(run.results, "finalizer")
    assert run.goal_review_completed == false
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

  test "outside-root tool failures terminate the agent instead of letting it recover elsewhere" do
    root = tmp_root("agent-machine-outside-root-terminal")

    outside_path =
      Path.join(System.tmp_dir!(), "agent-machine-outside-#{System.unique_integer()}")

    on_exit(fn -> File.rm_rf(outside_path) end)

    agents = [
      %{
        id: "tool-user",
        provider: AgentMachine.TestProviders.OutsideRootThenFallback,
        model: "test",
        input: outside_path,
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    callback = fn context ->
      assert context.kind == :tool_execution
      :approved
    end

    assert {:ok, run} =
             Orchestrator.run(agents,
               timeout: 1_000,
               allowed_tools: [AgentMachine.Tools.CreateDir],
               tool_policy: AgentMachine.ToolPolicy.new!(permissions: [:local_files_create_dir]),
               tool_root: root,
               tool_timeout_ms: 100,
               tool_max_rounds: 3,
               tool_approval_mode: :ask_before_write,
               tool_approval_callback: callback
             )

    assert run.results["tool-user"].status == :error
    assert run.results["tool-user"].error =~ "outside tool root"
    refute File.exists?(Path.join(root, "super"))
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

  test "ask-before-write approval mode allows reads without callback" do
    agents = [
      %{
        id: "tool-user",
        provider: AgentMachine.TestProviders.ReadToolUsing,
        model: "test",
        input: "hello",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:ok, run} =
             Orchestrator.run(agents,
               timeout: 1_000,
               allowed_tools: [AgentMachine.TestTools.ReadEcho],
               tool_policy: AgentMachine.ToolPolicy.new!(permissions: [:test_read_echo]),
               tool_timeout_ms: 100,
               tool_max_rounds: 1,
               tool_approval_mode: :ask_before_write
             )

    assert run.results["tool-user"].status == :ok
    assert run.results["tool-user"].tool_results["read-echo"].value == "hello"
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
      assert is_binary(context.request_id)
      assert context.kind == :tool_execution
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

    assert Enum.any?(run.events, fn event ->
             event.type == :permission_requested and event.kind == :tool_execution and
               event.tool_call_id == "uppercase" and event.approval_risk == :write and
               is_binary(event.request_id)
           end)

    assert Enum.any?(run.events, fn event ->
             event.type == :permission_decided and event.kind == :tool_execution and
               event.tool_call_id == "uppercase" and event.decision == :approved
           end)
  end

  test "denied approval fingerprints avoid repeating identical prompts" do
    parent = self()

    agents = [
      %{
        id: "tool-user",
        provider: AgentMachine.TestProviders.RetryDeniedTool,
        model: "test",
        input: "hello",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    callback = fn context ->
      send(parent, {:approval_context, context.tool_call_id})
      {:denied, "not now"}
    end

    assert {:ok, run} =
             Orchestrator.run(agents,
               timeout: 1_000,
               allowed_tools: [AgentMachine.TestTools.Uppercase],
               tool_policy: AgentMachine.ToolPolicy.new!(permissions: [:test_uppercase]),
               tool_timeout_ms: 100,
               tool_max_rounds: 3,
               tool_approval_mode: :ask_before_write,
               tool_approval_callback: callback
             )

    assert run.results["tool-user"].status == :ok
    assert_receive {:approval_context, "uppercase-1"}
    refute_received {:approval_context, "uppercase-2"}

    permission_requests =
      Enum.filter(run.events, fn event ->
        event.type == :permission_requested and event.kind == :tool_execution
      end)

    assert length(permission_requests) == 1
  end

  test "tool approval callback and events include swarm metadata" do
    parent = self()

    agents = [
      %{
        id: "variant-minimal",
        provider: AgentMachine.TestProviders.ToolUsing,
        model: "test",
        input: "hello",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0},
        metadata: %{
          agent_machine_role: "swarm_variant",
          swarm_id: "default",
          variant_id: "minimal",
          workspace: ".agent-machine/swarm/run-approval/minimal"
        }
      }
    ]

    callback = fn context ->
      send(parent, {:approval_context, context})
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

    assert run.results["variant-minimal"].status == :ok

    assert_receive {:approval_context, context}
    assert context.agent_machine_role == "swarm_variant"
    assert context.swarm_id == "default"
    assert context.variant_id == "minimal"
    assert context.workspace == ".agent-machine/swarm/run-approval/minimal"
    assert context.spawn_depth == 0

    assert Enum.any?(run.events, fn event ->
             event.type == :tool_call_finished and event.agent_id == "variant-minimal" and
               event.agent_machine_role == "swarm_variant" and event.variant_id == "minimal" and
               event.workspace == ".agent-machine/swarm/run-approval/minimal" and
               event.spawn_depth == 0
           end)
  end

  test "request_capability can grant local files to the current agent attempt" do
    root = tmp_root("agent-machine-capability-grant")
    parent = self()

    agents = [
      %{
        id: "tool-user",
        provider: AgentMachine.TestProviders.CapabilityRequesting,
        model: "test",
        input: root,
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    callback = fn context ->
      send(parent, {:approval_context, context.kind, context.tool_call_id})
      :approved
    end

    assert {:ok, run} =
             Orchestrator.run(agents,
               timeout: 1_000,
               allowed_tools: [AgentMachine.Tools.RequestCapability],
               tool_policy:
                 AgentMachine.ToolPolicy.new!(permissions: [:permission_control_request]),
               tool_timeout_ms: 100,
               tool_max_rounds: 3,
               tool_approval_mode: :ask_before_write,
               tool_approval_callback: callback
             )

    assert run.results["tool-user"].status == :ok
    assert File.read!(Path.join(root, "granted.txt")) == "granted"
    assert_receive {:approval_context, :capability_grant, "capability"}
    assert_receive {:approval_context, :tool_execution, "write"}

    assert Enum.any?(run.events, fn event ->
             event.type == :permission_requested and event.kind == :capability_grant and
               event.capability == "local_files" and event.requested_root == root
           end)
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

  defp agentic_persistence_planner do
    %{
      id: "planner",
      provider: AgentMachine.TestProviders.AgenticPersistence,
      model: "test",
      input: "plan persistent work",
      pricing: %{input_per_million: 0.0, output_per_million: 0.0}
    }
  end

  defp agentic_persistence_reviewer(mode) do
    %{
      id: "goal-reviewer",
      provider: AgentMachine.TestProviders.AgenticPersistence,
      model: "test",
      input: mode,
      pricing: %{input_per_million: 0.0, output_per_million: 0.0},
      metadata: %{
        agent_machine_response: "agentic_review",
        agent_machine_role: "goal_reviewer",
        agent_machine_worker_instructions: "Runtime follow-up rules."
      }
    }
  end

  defp agentic_persistence_finalizer do
    %{
      id: "finalizer",
      provider: AgentMachine.TestProviders.AgenticPersistence,
      model: "test",
      input: "finalize persistent run",
      pricing: %{input_per_million: 0.0, output_per_million: 0.0}
    }
  end

  defp drain_approval_contexts(acc) do
    receive do
      {:approval_context, context} ->
        drain_approval_contexts([context | acc])
    after
      0 -> Enum.reverse(acc)
    end
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

defmodule AgentMachine.TestProviders.SwarmGraph do
  @behaviour AgentMachine.Provider

  alias AgentMachine.Agent

  @impl true
  def complete(%Agent{id: "planner"} = agent, _opts) do
    output = "planned swarm graph"

    {:ok,
     %{
       output: output,
       usage: usage(agent, output),
       next_agents: [
         variant("variant-minimal", "minimal", agent.pricing),
         variant("variant-robust", "robust", agent.pricing),
         %{
           id: "evaluator",
           provider: __MODULE__,
           model: "test",
           input: "evaluate variants",
           pricing: agent.pricing,
           depends_on: ["variant-minimal", "variant-robust"],
           metadata: %{agent_machine_role: "swarm_evaluator", swarm_id: "default"}
         }
       ]
     }}
  end

  def complete(%Agent{id: "evaluator"} = agent, opts) do
    context = Keyword.fetch!(opts, :run_context)
    minimal = context.results |> Map.fetch!("variant-minimal") |> Map.fetch!(:output)
    robust = context.results |> Map.fetch!("variant-robust") |> Map.fetch!(:output)
    output = "evaluated #{minimal} + #{robust}"
    {:ok, %{output: output, usage: usage(agent, output)}}
  end

  def complete(%Agent{} = agent, _opts) do
    output = "#{agent.metadata.variant_id} output"
    {:ok, %{output: output, usage: usage(agent, output)}}
  end

  defp variant(id, variant_id, pricing) do
    %{
      id: id,
      provider: __MODULE__,
      model: "test",
      input: "build #{variant_id}",
      pricing: pricing,
      metadata: %{
        agent_machine_role: "swarm_variant",
        swarm_id: "default",
        variant_id: variant_id,
        workspace: ".agent-machine/swarm/run-graph/#{variant_id}"
      }
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

defmodule AgentMachine.TestProviders.SwarmWorkspace do
  @behaviour AgentMachine.Provider

  alias AgentMachine.Agent

  @impl true
  def complete(%Agent{id: "planner"} = agent, opts) do
    run_id = opts |> Keyword.fetch!(:run_context) |> Map.fetch!(:run_id)
    output = "planned isolated workspaces"

    {:ok,
     %{
       output: output,
       usage: usage(agent, output),
       next_agents: [
         variant("variant-minimal", "minimal", run_id, agent.pricing),
         variant("variant-robust", "robust", run_id, agent.pricing),
         %{
           id: "evaluator",
           provider: __MODULE__,
           model: "test",
           input: "evaluate workspace variants",
           pricing: agent.pricing,
           depends_on: ["variant-minimal", "variant-robust"],
           metadata: %{agent_machine_role: "swarm_evaluator", swarm_id: "default"}
         }
       ]
     }}
  end

  def complete(%Agent{id: "evaluator"} = agent, opts) do
    context = Keyword.fetch!(opts, :run_context)

    variant_ids =
      context.results |> Map.keys() |> Enum.filter(&String.starts_with?(&1, "variant-"))

    output = "evaluated #{Enum.join(Enum.sort(variant_ids), ", ")}"
    {:ok, %{output: output, usage: usage(agent, output)}}
  end

  def complete(%Agent{} = agent, opts) do
    case Keyword.get(opts, :tool_continuation) do
      nil ->
        {:ok,
         %{
           output: "requesting workspace escape write",
           usage: usage(agent, "requesting workspace escape write"),
           tool_calls: [
             %{
               id: "#{agent.id}-write",
               tool: AgentMachine.Tools.WriteFile,
               input: %{path: "../outside.txt", content: "should not be written"}
             }
           ],
           tool_state: %{round: 1}
         }}

      %{results: [%{result: result}]} ->
        root = Keyword.fetch!(opts, :tool_root)
        output = "tool_root=#{root} result=#{inspect(result)}"
        {:ok, %{output: output, usage: usage(agent, output)}}
    end
  end

  defp variant(id, variant_id, run_id, pricing) do
    %{
      id: id,
      provider: __MODULE__,
      model: "test",
      input: "build #{variant_id}",
      pricing: pricing,
      metadata: %{
        agent_machine_role: "swarm_variant",
        swarm_id: "default",
        variant_id: variant_id,
        workspace: ".agent-machine/swarm/#{run_id}/#{variant_id}"
      }
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

defmodule AgentMachine.TestProviders.SwarmCodeEdit do
  @behaviour AgentMachine.Provider

  alias AgentMachine.Agent

  @variants ["minimal", "robust", "experimental"]

  @impl true
  def complete(%Agent{id: "planner"} = agent, opts) do
    run_id = opts |> Keyword.fetch!(:run_context) |> Map.fetch!(:run_id)
    output = "planned code-edit swarm"

    {:ok,
     %{
       output: output,
       usage: usage(agent, output),
       next_agents:
         Enum.map(@variants, &variant(&1, run_id, agent.pricing)) ++
           [
             %{
               id: "evaluator",
               provider: __MODULE__,
               model: "test",
               input: "evaluate code-edit variants",
               pricing: agent.pricing,
               depends_on: Enum.map(@variants, &"variant-#{&1}"),
               metadata: %{agent_machine_role: "swarm_evaluator", swarm_id: "default"}
             }
           ]
     }}
  end

  def complete(%Agent{id: "evaluator"} = agent, opts) do
    context = Keyword.fetch!(opts, :run_context)

    outputs =
      Enum.map_join(@variants, ", ", fn variant_id ->
        result = Map.fetch!(context.results, "variant-#{variant_id}")
        "#{variant_id}=#{Map.fetch!(result, :status)}"
      end)

    output = "evaluated code-edit swarm #{outputs}; recommended=robust"
    {:ok, %{output: output, usage: usage(agent, output)}}
  end

  def complete(%Agent{} = agent, opts) do
    variant_id = Map.fetch!(agent.metadata, :variant_id)

    case Keyword.get(opts, :tool_continuation) do
      nil ->
        request_patch(agent, variant_id)

      %{state: %{stage: "patch"}} ->
        request_test(agent, variant_id)

      %{state: %{stage: "test"}, results: [%{result: result}]} ->
        output = "#{variant_id} completed sort_check.exs exit_status=#{result.exit_status}"
        {:ok, %{output: output, usage: usage(agent, output)}}
    end
  end

  defp request_patch(agent, variant_id) do
    output = "#{variant_id} creating sort_check.exs"

    {:ok,
     %{
       output: output,
       usage: usage(agent, output),
       tool_calls: [
         %{
           id: "#{variant_id}-patch",
           tool: AgentMachine.Tools.ApplyPatch,
           input: %{patch: sort_patch(variant_id)}
         }
       ],
       tool_state: %{stage: "patch"}
     }}
  end

  defp request_test(agent, variant_id) do
    output = "#{variant_id} running sort_check.exs"

    {:ok,
     %{
       output: output,
       usage: usage(agent, output),
       tool_calls: [
         %{
           id: "#{variant_id}-test",
           tool: AgentMachine.Tools.RunTestCommand,
           input: %{command: "elixir sort_check.exs", cwd: "."}
         }
       ],
       tool_state: %{stage: "test"}
     }}
  end

  defp variant(variant_id, run_id, pricing) do
    %{
      id: "variant-#{variant_id}",
      provider: __MODULE__,
      model: "test",
      input: "build #{variant_id} sorting variant",
      pricing: pricing,
      metadata: %{
        agent_machine_role: "swarm_variant",
        swarm_id: "default",
        variant_id: variant_id,
        workspace: ".agent-machine/swarm/#{run_id}/#{variant_id}"
      }
    }
  end

  defp sort_patch(variant_id) do
    content_lines =
      variant_id
      |> sort_check_content()
      |> String.split("\n")

    ([
       "diff --git a/sort_check.exs b/sort_check.exs",
       "new file mode 100644",
       "--- /dev/null",
       "+++ b/sort_check.exs",
       "@@ -0,0 +1,#{length(content_lines)} @@"
     ] ++ Enum.map(content_lines, &"+#{&1}"))
    |> Enum.join("\n")
  end

  defp sort_check_content("minimal") do
    """
    defmodule SortVariant do
      def sort(list), do: Enum.sort(list)
    end

    checks = [[], [1], [1, 2, 3], [3, 1, 2], [2, 1, 2, 1], [-1, 3, 0, -1]]

    Enum.each(checks, fn input ->
      expected = Enum.sort(input)
      actual = SortVariant.sort(input)
      unless actual == expected, do: raise("minimal sort failed")
    end)

    IO.puts("SORT_CHECK_OK minimal")
    """
    |> String.trim()
  end

  defp sort_check_content("robust") do
    """
    defmodule SortVariant do
      def sort(list), do: merge_sort(list)

      defp merge_sort([]), do: []
      defp merge_sort([item]), do: [item]

      defp merge_sort(list) do
        {left, right} = Enum.split(list, div(length(list), 2))
        merge(merge_sort(left), merge_sort(right))
      end

      defp merge([], right), do: right
      defp merge(left, []), do: left

      defp merge([left | left_tail] = left_items, [right | right_tail] = right_items) do
        if left <= right do
          [left | merge(left_tail, right_items)]
        else
          [right | merge(left_items, right_tail)]
        end
      end
    end

    checks = [[], [1], [1, 2, 3], [3, 1, 2], [2, 1, 2, 1], [-1, 3, 0, -1]]

    Enum.each(checks, fn input ->
      expected = Enum.sort(input)
      actual = SortVariant.sort(input)
      unless actual == expected, do: raise("robust merge sort failed")
    end)

    IO.puts("SORT_CHECK_OK robust")
    """
    |> String.trim()
  end

  defp sort_check_content("experimental") do
    """
    defmodule SortVariant do
      def sort([]), do: []

      def sort([pivot | rest]) do
        {lower, greater} = Enum.split_with(rest, &(&1 <= pivot))
        sort(lower) ++ [pivot] ++ sort(greater)
      end
    end

    checks = [[], [1], [1, 2, 3], [3, 1, 2], [2, 1, 2, 1], [-1, 3, 0, -1]]

    Enum.each(checks, fn input ->
      expected = Enum.sort(input)
      actual = SortVariant.sort(input)
      unless actual == expected, do: raise("experimental quicksort failed")
    end)

    IO.puts("SORT_CHECK_OK experimental")
    """
    |> String.trim()
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

defmodule AgentMachine.TestProviders.CapabilityRequesting do
  @behaviour AgentMachine.Provider

  alias AgentMachine.Agent

  @impl true
  def complete(%Agent{} = agent, opts) do
    usage = usage(agent, "ok")

    case Keyword.get(opts, :tool_continuation) do
      nil ->
        {:ok,
         %{
           output: "requesting capability",
           usage: usage,
           tool_calls: [
             %{
               id: "capability",
               tool: AgentMachine.Tools.RequestCapability,
               input: %{capability: "local_files", root: agent.input, reason: "write granted.txt"}
             }
           ],
           tool_state: %{stage: "capability"}
         }}

      %{state: %{stage: "capability"}} ->
        {:ok,
         %{
           output: "writing file",
           usage: usage,
           tool_calls: [
             %{
               id: "write",
               tool: AgentMachine.Tools.WriteFile,
               input: %{path: "granted.txt", content: "granted"}
             }
           ],
           tool_state: %{stage: "write"}
         }}

      %{state: %{stage: "write"}} ->
        {:ok, %{output: "done", usage: usage}}
    end
  end

  defp usage(agent, output) do
    %{
      input_tokens: String.length(agent.input),
      output_tokens: String.length(output),
      total_tokens: String.length(agent.input) + String.length(output)
    }
  end
end

defmodule AgentMachine.TestProviders.InvalidDynamicGraph do
  @behaviour AgentMachine.Provider

  alias AgentMachine.Agent

  @impl true
  def complete(%Agent{input: "cycle"} = agent, _opts) do
    output = "planned invalid cycle"

    {:ok,
     %{
       output: output,
       usage: usage(agent, output),
       next_agents: [
         child("cycle-a", ["cycle-b"], agent.pricing),
         child("cycle-b", ["cycle-a"], agent.pricing)
       ]
     }}
  end

  def complete(%Agent{input: "too many children"} = agent, _opts) do
    output = "planned too many children"

    {:ok,
     %{
       output: output,
       usage: usage(agent, output),
       next_agents: Enum.map(1..9, &child("child-#{&1}", [], agent.pricing))
     }}
  end

  defp child(id, depends_on, pricing) do
    %{
      id: id,
      provider: __MODULE__,
      model: "test",
      input: "child",
      pricing: pricing,
      depends_on: depends_on
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

defmodule AgentMachine.TestProviders.RecursiveDelegating do
  @behaviour AgentMachine.Provider

  alias AgentMachine.Agent

  @impl true
  def complete(%Agent{id: "planner"} = agent, _opts), do: delegate(agent, 1)

  def complete(%Agent{id: "depth-" <> depth_text} = agent, _opts) do
    depth_text
    |> String.to_integer()
    |> Kernel.+(1)
    |> then(&delegate(agent, &1))
  end

  defp delegate(agent, next_depth) do
    output = "depth #{next_depth - 1}"

    {:ok,
     %{
       output: output,
       usage: usage(agent, output),
       next_agents: [
         %{
           id: "depth-#{next_depth}",
           provider: __MODULE__,
           model: "test",
           input: "recurse",
           pricing: agent.pricing
         }
       ]
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

defmodule AgentMachine.TestProviders.AgenticPersistence do
  @behaviour AgentMachine.Provider

  alias AgentMachine.{Agent, JSON}

  @impl true
  def complete(%Agent{id: "planner"} = agent, _opts) do
    output = "planned persistent worker"

    {:ok,
     %{
       output: output,
       usage: usage(agent, output),
       next_agents: [
         %{
           id: "worker-a",
           provider: __MODULE__,
           model: "test",
           input: "initial persistent worker",
           pricing: agent.pricing
         }
       ]
     }}
  end

  def complete(%Agent{id: "worker-a"} = agent, _opts) do
    output = "worker-a output"

    {:ok,
     %{
       output: output,
       artifacts: %{"worker_marker" => "worker-a completed initial work"},
       usage: usage(agent, output)
     }}
  end

  def complete(%Agent{id: "follow-up"} = agent, _opts) do
    output = "follow-up output"

    {:ok,
     %{
       output: output,
       usage: usage(agent, output)
     }}
  end

  def complete(%Agent{id: "follow-up-" <> _suffix} = agent, _opts) do
    output = "#{agent.id} output"

    {:ok,
     %{
       output: output,
       usage: usage(agent, output)
     }}
  end

  def complete(%Agent{id: "goal-reviewer-" <> _suffix, input: "complete"} = agent, _opts) do
    review_complete(agent, "initial worker completed the task")
  end

  def complete(%Agent{id: "goal-reviewer-" <> _suffix, input: "complete-artifact"} = agent, _opts) do
    review_complete_artifact(agent)
  end

  def complete(
        %Agent{id: "goal-reviewer-" <> _suffix, input: "complete-unknown-evidence"} = agent,
        _opts
      ) do
    review_complete(agent, "missing worker supposedly completed the task", "missing-worker")
  end

  def complete(%Agent{id: "goal-reviewer-" <> _suffix, input: "continue-once"} = agent, opts) do
    context = Keyword.fetch!(opts, :run_context)

    if Map.has_key?(context.results, "follow-up") do
      review_complete(agent, "follow-up completed missing work", "follow-up")
    else
      review_continue(agent, "missing follow-up evidence", "follow-up")
    end
  end

  def complete(%Agent{id: "goal-reviewer-" <> suffix, input: "always-continue"} = agent, _opts) do
    review_continue(agent, "still missing evidence", "follow-up-#{suffix}")
  end

  def complete(%Agent{id: "finalizer"} = agent, opts) do
    context = Keyword.fetch!(opts, :run_context)

    reviewer =
      context.results
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, "goal-reviewer-"))
      |> Enum.sort()
      |> List.last()

    follow_up? = Map.has_key?(context.results, "follow-up")
    output = "reviewed=#{reviewer} complete follow_up=#{follow_up?}"

    {:ok,
     %{
       output: output,
       usage: usage(agent, output)
     }}
  end

  defp review_complete(agent, reason, source_agent_id \\ "worker-a") do
    output = "review complete: #{reason}"

    review(agent, %{
      "decision" => %{"mode" => "complete", "reason" => reason},
      "output" => output,
      "completion_evidence" => [
        %{
          "source_agent_id" => source_agent_id,
          "kind" => "agent_output",
          "summary" => "#{source_agent_id} confirms #{reason}"
        }
      ],
      "next_agents" => []
    })
  end

  defp review_complete_artifact(agent) do
    output = "review complete: worker-a produced artifact"

    review(agent, %{
      "decision" => %{
        "mode" => "complete",
        "reason" => "worker-a produced the worker_marker artifact"
      },
      "output" => output,
      "completion_evidence" => [
        %{
          "source_agent_id" => "worker-a",
          "kind" => "artifact",
          "summary" => "worker-a produced the worker_marker artifact",
          "artifact_key" => "worker_marker"
        }
      ],
      "next_agents" => []
    })
  end

  defp review_continue(agent, reason, follow_up_id) do
    output = "review continue: #{reason}"

    review(agent, %{
      "decision" => %{"mode" => "continue", "reason" => reason},
      "output" => output,
      "completion_evidence" => [],
      "next_agents" => [
        %{
          "id" => follow_up_id,
          "input" => "Collect missing completion evidence.",
          "instructions" => "Report concrete evidence."
        }
      ]
    })
  end

  defp review(agent, body) do
    output = JSON.encode!(body)

    {:ok,
     %{
       output: output,
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

defmodule AgentMachine.TestProviders.RetryDeniedTool do
  @behaviour AgentMachine.Provider

  alias AgentMachine.Agent

  @impl true
  def complete(%Agent{} = agent, opts) do
    case Keyword.get(opts, :tool_continuation) do
      nil ->
        tool_request(agent, "uppercase-1")

      %{results: [%{result: %{status: "denied"}}], state: %{round: 1}} ->
        tool_request(agent, "uppercase-2")

      %{results: [%{result: %{status: "denied"}}]} ->
        final_response("denied twice")
    end
  end

  defp tool_request(agent, id) do
    output = "requested uppercase"

    {:ok,
     %{
       output: output,
       tool_calls: [
         %{
           id: id,
           tool: AgentMachine.TestTools.Uppercase,
           input: %{value: agent.input}
         }
       ],
       tool_state: %{round: if(id == "uppercase-1", do: 1, else: 2)},
       usage: usage(agent, output)
     }}
  end

  defp final_response(output) do
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

defmodule AgentMachine.TestProviders.ReadToolUsing do
  @behaviour AgentMachine.Provider

  alias AgentMachine.Agent

  @impl true
  def complete(%Agent{} = agent, opts) do
    case Keyword.get(opts, :tool_continuation) do
      %{results: [%{result: %{value: value}}]} ->
        output = "final answer: #{value}"
        {:ok, %{output: output, usage: usage(agent, output)}}

      nil ->
        output = "called read echo tool"

        {:ok,
         %{
           output: output,
           tool_calls: [
             %{
               id: "read-echo",
               tool: AgentMachine.TestTools.ReadEcho,
               input: %{value: agent.input}
             }
           ],
           tool_state: %{round: 1},
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

defmodule AgentMachine.TestProviders.OutsideRootThenFallback do
  @behaviour AgentMachine.Provider

  alias AgentMachine.Agent

  @impl true
  def complete(%Agent{} = agent, opts) do
    case Keyword.get(opts, :tool_continuation) do
      nil ->
        tool_request(agent.input, "outside-root")

      %{results: [%{result: %{status: "error"}}]} ->
        tool_request("super", "fallback")
    end
  end

  defp tool_request(path, id) do
    output = "requested create_dir"

    {:ok,
     %{
       output: output,
       tool_calls: [
         %{
           id: id,
           tool: AgentMachine.Tools.CreateDir,
           input: %{path: path}
         }
       ],
       tool_state: %{round: if(id == "outside-root", do: 1, else: 2)},
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

defmodule AgentMachine.TestProviders.RunContextCompacting do
  @behaviour AgentMachine.Provider

  alias AgentMachine.Agent
  alias AgentMachine.RunContextPrompt

  @impl true
  def context_budget_request(%Agent{} = agent, opts) do
    sections = RunContextPrompt.budget_sections(opts)

    {:ok,
     %{
       provider: :test_run_context_compacting,
       request: %{
         "model" => agent.model,
         "input" => input(agent, sections)
       },
       breakdown: %{
         instructions: agent.instructions,
         task_input: agent.input,
         run_context: sections.run_context,
         skills: sections.skills,
         tools: [],
         mcp_tools: [],
         tool_continuation: nil
       }
     }}
  end

  @impl true
  def complete(%Agent{id: "planner"} = agent, _opts) do
    output = "raw planner output that should stay in summary"

    {:ok,
     %{
       output: output,
       artifacts: %{plan: "raw plan"},
       usage: %{input_tokens: 50, output_tokens: 50, total_tokens: 100},
       next_agents: [
         %{
           id: "worker",
           provider: __MODULE__,
           model: "test",
           input: "inspect compacted context",
           pricing: agent.pricing
         }
       ]
     }}
  end

  def complete(%Agent{id: "__context_compactor__"} = agent, _opts) do
    output =
      AgentMachine.JSON.encode!(%{
        summary: "compacted planner context",
        covered_items: ["planner"]
      })

    {:ok,
     %{
       output: output,
       usage: usage(agent, output)
     }}
  end

  def complete(%Agent{id: "worker"} = agent, opts) do
    context = Keyword.fetch!(opts, :run_context)
    saw_raw = Map.has_key?(context.results, "planner")
    saw_plan = Map.has_key?(context.artifacts, :plan)

    compacted =
      if Map.has_key?(context, :compacted_context),
        do: context.compacted_context.summary,
        else: "none"

    output = "saw_raw=#{saw_raw} saw_plan=#{saw_plan} compacted=#{compacted}"

    {:ok,
     %{
       output: output,
       usage: usage(agent, output)
     }}
  end

  defp input(%Agent{} = agent, %{full_text: ""}), do: agent.input

  defp input(%Agent{} = agent, %{full_text: context}),
    do: agent.input <> "\n\nRun context:\n" <> context

  defp usage(agent, output) do
    input = token_count(agent.input)
    output = token_count(output)
    %{input_tokens: input, output_tokens: output, total_tokens: input + output}
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

defmodule AgentMachine.TestTools.ReadEcho do
  @behaviour AgentMachine.Tool

  @impl true
  def permission, do: :test_read_echo

  @impl true
  def approval_risk, do: :read

  @impl true
  def run(input, _opts), do: {:ok, %{value: Map.fetch!(input, :value)}}
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
