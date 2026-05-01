defmodule AgentMachine.ClientRunnerTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias AgentMachine.{AgentResult, ClientRunner, EventLog, JSON, RunSpec, UsageLedger}
  alias AgentMachine.Tools.ApplyEdits
  alias AgentMachine.Workflows.{Agentic, Basic, Chat, Tool}
  alias Mix.Tasks.AgentMachine.{Rollback, Run}

  setup do
    UsageLedger.reset!()
    EventLog.close()

    on_exit(fn ->
      EventLog.close()
    end)

    :ok
  end

  test "validates required high-level run spec fields" do
    assert_raise ArgumentError, ~r/:workflow/, fn ->
      RunSpec.new!(%{
        task: "do work",
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 2,
        max_attempts: 1
      })
    end

    assert_raise ArgumentError, ~r/run spec :task must be a non-empty binary/, fn ->
      RunSpec.new!(%{
        task: "",
        workflow: :basic,
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 2,
        max_attempts: 1
      })
    end

    assert_raise ArgumentError,
                 ~r/run spec :provider must be :echo, :openai, or :openrouter/,
                 fn ->
                   RunSpec.new!(%{
                     task: "do work",
                     workflow: :basic,
                     provider: :unknown,
                     timeout_ms: 1_000,
                     max_steps: 2,
                     max_attempts: 1
                   })
                 end
  end

  test "validates new workflow request values" do
    for workflow <- [:chat, :basic, :agentic, :auto] do
      assert %RunSpec{workflow: ^workflow} =
               RunSpec.new!(%{
                 task: "do work",
                 workflow: workflow,
                 provider: :echo,
                 timeout_ms: 1_000,
                 max_steps: 2,
                 max_attempts: 1
               })
    end

    assert_raise ArgumentError, ~r/:workflow must be :chat, :basic, :agentic, or :auto/, fn ->
      RunSpec.new!(%{
        task: "do work",
        workflow: :unknown,
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 2,
        max_attempts: 1
      })
    end
  end

  test "validates explicit context options without guessed defaults" do
    assert %RunSpec{
             context_window_tokens: 10_000,
             context_warning_percent: 80,
             run_context_compaction: :on,
             run_context_compact_percent: 90,
             max_context_compactions: 2
           } =
             RunSpec.new!(%{
               task: "do work",
               workflow: :agentic,
               provider: :echo,
               timeout_ms: 1_000,
               max_steps: 3,
               max_attempts: 1,
               context_window_tokens: 10_000,
               context_warning_percent: 80,
               run_context_compaction: :on,
               run_context_compact_percent: 90,
               max_context_compactions: 2
             })

    assert_raise ArgumentError,
                 ~r/:context_warning_percent requires :context_window_tokens/,
                 fn ->
                   RunSpec.new!(%{
                     task: "do work",
                     workflow: :agentic,
                     provider: :echo,
                     timeout_ms: 1_000,
                     max_steps: 3,
                     max_attempts: 1,
                     context_warning_percent: 80
                   })
                 end

    assert_raise ArgumentError, ~r/:context_window_tokens/, fn ->
      RunSpec.new!(%{
        task: "do work",
        workflow: :agentic,
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 3,
        max_attempts: 1,
        run_context_compaction: :on,
        run_context_compact_percent: 90,
        max_context_compactions: 2
      })
    end

    assert_raise ArgumentError,
                 ~r/run-context compaction options require :run_context_compaction :on/,
                 fn ->
                   RunSpec.new!(%{
                     task: "do work",
                     workflow: :agentic,
                     provider: :echo,
                     timeout_ms: 1_000,
                     max_steps: 3,
                     max_attempts: 1,
                     context_window_tokens: 10_000,
                     run_context_compact_percent: 90
                   })
                 end
  end

  test "builds the basic workflow with OpenRouter provider options" do
    spec =
      RunSpec.new!(%{
        task: "do work",
        workflow: :basic,
        provider: :openrouter,
        model: "openai/gpt-4o-mini",
        timeout_ms: 1_000,
        max_steps: 2,
        max_attempts: 1,
        http_timeout_ms: 25_000,
        pricing: %{input_per_million: 0.15, output_per_million: 0.60}
      })

    {agents, opts} = Basic.build!(spec)

    assert [%{provider: AgentMachine.Providers.OpenRouterChat, model: "openai/gpt-4o-mini"}] =
             agents

    assert Keyword.fetch!(opts, :http_timeout_ms) == 25_000

    assert %{
             provider: AgentMachine.Providers.OpenRouterChat,
             model: "openai/gpt-4o-mini"
           } = Keyword.fetch!(opts, :finalizer)
  end

  test "builds the chat workflow without tools or finalizer" do
    spec =
      RunSpec.new!(%{
        task: "hello",
        workflow: :chat,
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 1,
        max_attempts: 1
      })

    {[assistant], opts} = Chat.build!(spec)

    assert assistant.id == "assistant"
    assert assistant.instructions =~ "assistant running inside AgentMachine"
    assert assistant.instructions =~ "AgentMachine can route concrete tasks"
    assert assistant.instructions =~ "this chat route cannot manually spawn arbitrary workers"
    assert assistant.metadata == %{agent_machine_disable_tools: true}
    refute Keyword.has_key?(opts, :finalizer)
    refute Keyword.has_key?(opts, :allowed_tools)
  end

  test "builds the internal tool workflow with read-only time tools" do
    spec =
      RunSpec.new!(%{
        task: "what time is it?",
        workflow: :auto,
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 6,
        max_attempts: 1,
        tool_harnesses: [:code_edit, :time],
        tool_root: "/tmp/agent-machine",
        tool_timeout_ms: 100,
        tool_max_rounds: 2,
        tool_approval_mode: :auto_approved_safe
      })

    {[assistant], opts} = Tool.build!(spec, %{tool_intent: "time"})

    assert assistant.id == "assistant"
    refute Keyword.has_key?(opts, :finalizer)
    assert Keyword.fetch!(opts, :allowed_tools) == [AgentMachine.Tools.Now]

    assert %AgentMachine.ToolPolicy{harness: [:code_edit, :time], permissions: permissions} =
             Keyword.fetch!(opts, :tool_policy)

    assert MapSet.equal?(permissions, MapSet.new([:time_read]))
  end

  test "builds workflow tool options from an explicit harness" do
    spec =
      RunSpec.new!(%{
        task: "what time is it?",
        workflow: :basic,
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 2,
        max_attempts: 1,
        tool_harness: :time,
        tool_timeout_ms: 100,
        tool_max_rounds: 2,
        tool_approval_mode: :read_only
      })

    {_agents, opts} = Basic.build!(spec)

    assert Keyword.fetch!(opts, :allowed_tools) == [AgentMachine.Tools.Now]

    assert %AgentMachine.ToolPolicy{harness: :time, permissions: permissions} =
             Keyword.fetch!(opts, :tool_policy)

    assert MapSet.member?(permissions, :time_read)
    assert Keyword.fetch!(opts, :tool_timeout_ms) == 100
    assert Keyword.fetch!(opts, :tool_max_rounds) == 2
    assert Keyword.fetch!(opts, :tool_approval_mode) == :read_only
  end

  test "requires tool timeout when a tool harness is enabled" do
    assert_raise ArgumentError, ~r/:tool_timeout_ms/, fn ->
      RunSpec.new!(%{
        task: "what time is it?",
        workflow: :basic,
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 2,
        max_attempts: 1,
        tool_harness: :demo,
        tool_max_rounds: 2,
        tool_approval_mode: :read_only
      })
    end
  end

  test "requires tool max rounds when a tool harness is enabled" do
    assert_raise ArgumentError, ~r/:tool_max_rounds/, fn ->
      RunSpec.new!(%{
        task: "what time is it?",
        workflow: :basic,
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 2,
        max_attempts: 1,
        tool_harness: :demo,
        tool_timeout_ms: 100,
        tool_approval_mode: :read_only
      })
    end
  end

  test "requires tool approval mode when a tool harness is enabled" do
    assert_raise ArgumentError, ~r/:tool_approval_mode/, fn ->
      RunSpec.new!(%{
        task: "what time is it?",
        workflow: :basic,
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 2,
        max_attempts: 1,
        tool_harness: :demo,
        tool_timeout_ms: 100,
        tool_max_rounds: 2
      })
    end
  end

  test "builds local file tool options from explicit harness and root" do
    spec =
      RunSpec.new!(%{
        task: "write a file",
        workflow: :basic,
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 2,
        max_attempts: 1,
        tool_harness: :local_files,
        tool_timeout_ms: 100,
        tool_max_rounds: 2,
        tool_root: "/tmp/agent-machine",
        tool_approval_mode: :auto_approved_safe
      })

    {_agents, opts} = Basic.build!(spec)

    assert Keyword.fetch!(opts, :allowed_tools) == [
             AgentMachine.Tools.AppendFile,
             AgentMachine.Tools.CreateDir,
             AgentMachine.Tools.FileInfo,
             AgentMachine.Tools.ListFiles,
             AgentMachine.Tools.ReadFile,
             AgentMachine.Tools.ReplaceInFile,
             AgentMachine.Tools.SearchFiles,
             AgentMachine.Tools.WriteFile
           ]

    assert Keyword.fetch!(opts, :tool_timeout_ms) == 100
    assert Keyword.fetch!(opts, :tool_max_rounds) == 2
    assert Keyword.fetch!(opts, :tool_root) == "/tmp/agent-machine"
    assert Keyword.fetch!(opts, :tool_approval_mode) == :auto_approved_safe

    assert %AgentMachine.ToolPolicy{harness: :local_files, permissions: permissions} =
             Keyword.fetch!(opts, :tool_policy)

    assert MapSet.member?(permissions, :local_files_write)
  end

  test "requires tool root for local file harness" do
    assert_raise ArgumentError, ~r/:tool_root/, fn ->
      RunSpec.new!(%{
        task: "write a file",
        workflow: :basic,
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 2,
        max_attempts: 1,
        tool_harness: :local_files,
        tool_timeout_ms: 100,
        tool_max_rounds: 2,
        tool_approval_mode: :auto_approved_safe
      })
    end
  end

  test "builds code edit tool options from explicit harness and root" do
    spec =
      RunSpec.new!(%{
        task: "edit code",
        workflow: :basic,
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 2,
        max_attempts: 1,
        tool_harness: :code_edit,
        tool_timeout_ms: 100,
        tool_max_rounds: 2,
        tool_root: "/tmp/agent-machine",
        tool_approval_mode: :full_access
      })

    {_agents, opts} = Basic.build!(spec)

    allowed_tools = Keyword.fetch!(opts, :allowed_tools)

    for tool <- [
          AgentMachine.Tools.ApplyEdits,
          AgentMachine.Tools.ApplyPatch,
          AgentMachine.Tools.FileInfo,
          AgentMachine.Tools.ListFiles,
          AgentMachine.Tools.RollbackCheckpoint,
          AgentMachine.Tools.ReadFile,
          AgentMachine.Tools.SearchFiles,
          AgentMachine.Tools.RunShellCommand,
          AgentMachine.Tools.StartShellCommand,
          AgentMachine.Tools.ReadShellCommandOutput,
          AgentMachine.Tools.StopShellCommand,
          AgentMachine.Tools.ListShellCommands
        ] do
      assert tool in allowed_tools
    end

    assert Keyword.fetch!(opts, :tool_root) == "/tmp/agent-machine"
    assert Keyword.fetch!(opts, :tool_approval_mode) == :full_access

    assert %AgentMachine.ToolPolicy{harness: :code_edit, permissions: permissions} =
             Keyword.fetch!(opts, :tool_policy)

    assert MapSet.member?(permissions, :code_edit_apply_edits)
    assert MapSet.member?(permissions, :code_edit_apply_patch)
    assert MapSet.member?(permissions, :code_edit_rollback_checkpoint)
    assert MapSet.member?(permissions, :code_edit_shell_run)
    assert MapSet.member?(permissions, :code_edit_shell_background)
    assert MapSet.member?(permissions, :code_edit_shell_stop)
  end

  test "builds code edit tool options with explicit test commands" do
    spec =
      RunSpec.new!(%{
        task: "edit code",
        workflow: :basic,
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 2,
        max_attempts: 1,
        tool_harness: :code_edit,
        tool_timeout_ms: 100,
        tool_max_rounds: 2,
        tool_root: "/tmp/agent-machine",
        tool_approval_mode: :full_access,
        test_commands: ["mix test"]
      })

    {_agents, opts} = Basic.build!(spec)

    assert AgentMachine.Tools.RunTestCommand in Keyword.fetch!(opts, :allowed_tools)
    assert Keyword.fetch!(opts, :test_commands) == ["mix test"]

    assert %AgentMachine.ToolPolicy{harness: :code_edit, permissions: permissions} =
             Keyword.fetch!(opts, :tool_policy)

    assert MapSet.member?(permissions, :test_command_run)
  end

  test "accepts code-edit test commands with ask-before-write approval" do
    spec =
      RunSpec.new!(%{
        task: "edit code",
        workflow: :basic,
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 2,
        max_attempts: 1,
        tool_harness: :code_edit,
        tool_timeout_ms: 100,
        tool_max_rounds: 2,
        tool_root: "/tmp/agent-machine",
        tool_approval_mode: :ask_before_write,
        test_commands: ["mix test"]
      })

    {_agents, opts} = Basic.build!(spec)

    assert AgentMachine.Tools.RunTestCommand in Keyword.fetch!(opts, :allowed_tools)
    assert Keyword.fetch!(opts, :tool_approval_mode) == :ask_before_write
    assert Keyword.fetch!(opts, :test_commands) == ["mix test"]
  end

  test "requires code-edit and command-capable approval mode for test commands" do
    base = %{
      task: "edit code",
      workflow: :basic,
      provider: :echo,
      timeout_ms: 1_000,
      max_steps: 2,
      max_attempts: 1,
      tool_timeout_ms: 100,
      tool_max_rounds: 2,
      tool_root: "/tmp/agent-machine",
      test_commands: ["mix test"]
    }

    assert_raise ArgumentError, ~r/test_commands require :tool_harness :code_edit/, fn ->
      RunSpec.new!(
        Map.merge(base, %{tool_harness: :local_files, tool_approval_mode: :full_access})
      )
    end

    assert_raise ArgumentError, ~r/test_commands require :tool_approval_mode :full_access/, fn ->
      RunSpec.new!(
        Map.merge(base, %{tool_harness: :code_edit, tool_approval_mode: :auto_approved_safe})
      )
    end
  end

  test "requires client approval callback for ask-before-write test commands" do
    root =
      Path.join(System.tmp_dir!(), "agent-machine-client-approval-#{System.unique_integer()}")

    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)

    attrs = %{
      task: "edit code",
      workflow: :basic,
      provider: :echo,
      timeout_ms: 1_000,
      max_steps: 2,
      max_attempts: 1,
      tool_harness: :code_edit,
      tool_timeout_ms: 100,
      tool_max_rounds: 2,
      tool_root: root,
      tool_approval_mode: :ask_before_write,
      test_commands: ["mix test"]
    }

    assert_raise ArgumentError, ~r/:tool_approval_callback is required/, fn ->
      ClientRunner.run!(attrs)
    end

    summary = ClientRunner.run!(attrs, tool_approval_callback: fn _context -> :approved end)
    assert summary.status == "completed"
  end

  test "requires client approval callback for ask-before-write write-risk tools" do
    root =
      Path.join(
        System.tmp_dir!(),
        "agent-machine-client-write-approval-#{System.unique_integer()}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)

    attrs = %{
      task: "write a file",
      workflow: :basic,
      provider: :echo,
      timeout_ms: 1_000,
      max_steps: 2,
      max_attempts: 1,
      tool_harness: :local_files,
      tool_timeout_ms: 100,
      tool_max_rounds: 2,
      tool_root: root,
      tool_approval_mode: :ask_before_write
    }

    assert_raise ArgumentError, ~r/:tool_approval_callback is required/, fn ->
      ClientRunner.run!(attrs)
    end

    summary = ClientRunner.run!(attrs, tool_approval_callback: fn _context -> :approved end)
    assert summary.status == "completed"
  end

  test "allows ask-before-write without callback when exposed tools are read-only" do
    summary =
      ClientRunner.run!(%{
        task: "what time is it?",
        workflow: :basic,
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 2,
        max_attempts: 1,
        tool_harness: :time,
        tool_timeout_ms: 100,
        tool_max_rounds: 2,
        tool_approval_mode: :ask_before_write
      })

    assert summary.status == "completed"
  end

  test "validates client approval callback option" do
    attrs = %{
      task: "summarize",
      workflow: :basic,
      provider: :echo,
      timeout_ms: 1_000,
      max_steps: 2,
      max_attempts: 1
    }

    assert_raise ArgumentError, ~r/:tool_approval_callback must be a function of arity 1/, fn ->
      ClientRunner.run!(attrs, tool_approval_callback: :approved)
    end

    summary = ClientRunner.run!(attrs, tool_approval_callback: fn _context -> :approved end)
    assert summary.status == "completed"
  end

  test "rejects duplicate or malformed test commands" do
    base = %{
      task: "edit code",
      workflow: :basic,
      provider: :echo,
      timeout_ms: 1_000,
      max_steps: 2,
      max_attempts: 1,
      tool_harness: :code_edit,
      tool_timeout_ms: 100,
      tool_max_rounds: 2,
      tool_root: "/tmp/agent-machine",
      tool_approval_mode: :full_access
    }

    assert_raise ArgumentError, ~r/test_commands must not contain duplicates/, fn ->
      RunSpec.new!(Map.put(base, :test_commands, ["mix test", "mix test"]))
    end

    assert_raise ArgumentError, ~r/unsupported shell syntax/, fn ->
      RunSpec.new!(Map.put(base, :test_commands, ["mix test && rm -rf tmp"]))
    end
  end

  test "requires tool root for code edit harness" do
    assert_raise ArgumentError, ~r/:tool_root/, fn ->
      RunSpec.new!(%{
        task: "edit code",
        workflow: :basic,
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 2,
        max_attempts: 1,
        tool_harness: :code_edit,
        tool_timeout_ms: 100,
        tool_max_rounds: 2,
        tool_approval_mode: :full_access
      })
    end
  end

  test "builds the agentic workflow with an opt-in structured planner" do
    spec =
      RunSpec.new!(%{
        task: "do work",
        workflow: :agentic,
        provider: :openrouter,
        model: "openai/gpt-4o-mini",
        timeout_ms: 1_000,
        max_steps: 6,
        max_attempts: 1,
        http_timeout_ms: 25_000,
        pricing: %{input_per_million: 0.15, output_per_million: 0.60}
      })

    {[planner], opts} = Agentic.build!(spec)

    assert planner.id == "planner"

    assert %{
             agent_machine_response: "delegation",
             agent_machine_disable_tools: true,
             agent_machine_worker_instructions: worker_instructions
           } = planner.metadata

    assert planner.instructions =~ "Return only JSON"
    assert planner.instructions =~ "\"direct\""
    assert planner.instructions =~ "\"delegate\""
    assert planner.instructions =~ "The Elixir runtime parses that JSON"
    assert planner.instructions =~ "Return one complete JSON object only"
    assert planner.instructions =~ "Do not use trailing commas"
    assert planner.instructions =~ "JSON.parse"
    assert planner.instructions =~ "Worker agents start from the worker input/instructions"
    assert planner.instructions =~ "Do not predict or fabricate worker results"
    assert planner.instructions =~ "web_browse"
    assert planner.instructions =~ "MCP browser"
    assert worker_instructions =~ "You are a worker agent running inside AgentMachine"
    assert worker_instructions =~ "tool_results confirm it"
    assert worker_instructions =~ "MCP browser"
    assert Keyword.fetch!(opts, :max_steps) == 6
    finalizer = Keyword.fetch!(opts, :finalizer)
    assert finalizer.id == "finalizer"
    assert finalizer.metadata == %{agent_machine_disable_tools: true}
    assert finalizer.instructions =~ "what completed"
    assert finalizer.instructions =~ "what was not verified"
  end

  test "builds swarm-specific agentic planner and finalizer instructions" do
    spec =
      RunSpec.new!(%{
        task: "build multiple versions",
        workflow: :agentic,
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 6,
        max_attempts: 1,
        router_mode: :deterministic
      })

    {[planner], opts} = Agentic.build!(spec, %{selected: "agentic", strategy: "swarm"})

    assert planner.metadata.agent_machine_strategy == "swarm"
    assert planner.instructions =~ "\"swarm\""
    assert planner.instructions =~ "minimal"
    assert planner.instructions =~ "robust"
    assert planner.instructions =~ "experimental"
    assert planner.instructions =~ "swarm_evaluator"

    worker_instructions = planner.metadata.agent_machine_worker_instructions
    assert worker_instructions =~ "swarm_variant"
    assert worker_instructions =~ "workspace"

    finalizer = Keyword.fetch!(opts, :finalizer)
    assert finalizer.instructions =~ "recommended variant"
    assert finalizer.instructions =~ "Do not auto-merge"
  end

  test "runs the basic echo workflow and returns a client summary" do
    summary =
      ClientRunner.run!(%{
        task: "summarize the project",
        workflow: :basic,
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 2,
        max_attempts: 1
      })

    assert summary.status == "completed"
    assert summary.final_output =~ "finalizer"
    assert Map.keys(summary.results) |> Enum.sort() == ["assistant", "finalizer"]
    assert summary.usage.agents == 2
    assert Enum.map(summary.events, & &1.type) |> List.last() == "run_completed"
  end

  test "summary includes runtime checklist" do
    at = DateTime.from_naive!(~N[2026-04-30 10:00:00], "Etc/UTC")

    summary =
      ClientRunner.summarize_for_test!(%{
        id: "run-1",
        status: :completed,
        error: nil,
        results: %{
          "assistant" => %AgentResult{
            run_id: "run-1",
            agent_id: "assistant",
            status: :ok,
            output: "done",
            attempt: 1
          }
        },
        artifacts: %{},
        usage: nil,
        opts: [],
        events: [
          %{type: :agent_started, run_id: "run-1", agent_id: "assistant", attempt: 1, at: at},
          %{
            type: :agent_finished,
            run_id: "run-1",
            agent_id: "assistant",
            status: :ok,
            duration_ms: 10,
            at: at
          }
        ]
      })

    assert [%{id: "agent:assistant", status: "done", duration_ms: 10}] = summary.checklist
  end

  test "runs the chat echo workflow and returns assistant output directly" do
    summary =
      ClientRunner.run!(%{
        task: "summarize the project",
        workflow: :chat,
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 1,
        max_attempts: 1
      })

    assert summary.status == "completed"
    assert summary.final_output =~ "agent assistant: summarize the project"
    assert Map.keys(summary.results) == ["assistant"]

    assert summary.workflow_route == %{
             requested: "chat",
             selected: "chat",
             reason: "explicit_chat_workflow",
             tool_intent: "none",
             tools_exposed: false,
             classifier: "deterministic",
             classifier_model: nil,
             confidence: nil,
             classified_intent: "none"
           }
  end

  test "runs auto chat without planner when no tool intent is detected" do
    summary =
      ClientRunner.run!(%{
        task: "explain progressive escalation",
        workflow: :auto,
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 6,
        max_attempts: 1,
        router_mode: :deterministic
      })

    assert summary.status == "completed"
    assert summary.workflow_route.selected == "chat"
    assert Map.keys(summary.results) == ["assistant"]
    refute Map.has_key?(summary.results, "planner")
    assert summary.final_output =~ "agent assistant: explain progressive escalation"
  end

  test "emits workflow route telemetry" do
    parent = self()
    handler_id = {:client_runner_test, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:agent_machine, :workflow, :route],
        &AgentMachine.TestTelemetryForwarder.handle/4,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert %{status: "completed"} =
             ClientRunner.run!(%{
               task: "explain progressive escalation",
               workflow: :auto,
               provider: :echo,
               timeout_ms: 1_000,
               max_steps: 6,
               max_attempts: 1,
               router_mode: :deterministic
             })

    assert_receive {:telemetry, [:agent_machine, :workflow, :route], %{system_time: _},
                    %{workflow_route: %{requested: "auto", selected: "chat"}}}
  end

  test "runs auto time intent with time tool when another harness is configured" do
    root = Path.join(System.tmp_dir!(), "agent-machine-auto-time-#{System.unique_integer()}")
    File.mkdir_p!(root)

    summary =
      ClientRunner.run!(%{
        task: "what time is it?",
        workflow: :auto,
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 6,
        max_attempts: 1,
        router_mode: :deterministic,
        tool_harness: :code_edit,
        tool_root: root,
        tool_timeout_ms: 100,
        tool_max_rounds: 2,
        tool_approval_mode: :auto_approved_safe
      })

    assert summary.status == "completed"
    assert summary.workflow_route.selected == "tool"
    assert summary.workflow_route.reason == "time_intent_with_read_only_tool"
    assert Map.keys(summary.results) == ["assistant"]
    refute Map.has_key?(summary.results, "finalizer")
    assert summary.final_output =~ "agent assistant: what time is it?"
  end

  test "runs auto read-only file intent through tool workflow without finalizer" do
    root = Path.join(System.tmp_dir!(), "agent-machine-auto-read-#{System.unique_integer()}")
    File.mkdir_p!(root)

    summary =
      ClientRunner.run!(%{
        task: "read README.md",
        workflow: :auto,
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 6,
        max_attempts: 1,
        router_mode: :deterministic,
        tool_harness: :local_files,
        tool_root: root,
        tool_timeout_ms: 100,
        tool_max_rounds: 2,
        tool_approval_mode: :read_only
      })

    assert summary.status == "completed"
    assert summary.workflow_route.selected == "tool"
    assert summary.workflow_route.tool_intent == "file_read"
    assert Map.keys(summary.results) == ["assistant"]
  end

  test "collector records workflow route, runtime events, and final summary" do
    path =
      Path.join(System.tmp_dir!(), "agent-machine-client-events-#{System.unique_integer()}.jsonl")

    EventLog.configure!(path, %{session_id: "session-1"})

    summary =
      ClientRunner.run!(%{
        task: "explain progressive escalation",
        workflow: :auto,
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 6,
        max_attempts: 1,
        router_mode: :deterministic
      })

    EventLog.close()

    assert summary.status == "completed"

    lines = path |> File.read!() |> String.split("\n", trim: true)
    decoded = Enum.map(lines, &JSON.decode!/1)

    event_types =
      decoded
      |> Enum.filter(&(&1["type"] == "event"))
      |> Enum.map(&get_in(&1, ["event", "type"]))

    assert "workflow_routed" in event_types
    assert "run_started" in event_types
    assert "agent_started" in event_types

    route_event = Enum.find(decoded, &(get_in(&1, ["event", "type"]) == "workflow_routed"))
    assert get_in(route_event, ["event", "tools_exposed"]) == false

    assert Enum.any?(
             decoded,
             &(&1["type"] == "summary" and &1["summary"]["run_id"] == summary.run_id)
           )
  end

  test "runs the agentic echo workflow in direct mode and exposes planner decision" do
    summary =
      ClientRunner.run!(%{
        task: "summarize the project",
        workflow: :agentic,
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 6,
        max_attempts: 1
      })

    assert summary.status == "completed"
    assert summary.final_output =~ "agent planner: summarize the project"
    assert Map.keys(summary.results) == ["planner"]
    assert summary.usage.agents == 1

    assert summary.results["planner"].decision == %{
             mode: "direct",
             reason: "Echo provider completes structured planner requests directly.",
             delegated_agent_ids: []
           }

    assert summary.results["planner"].output =~ "agent planner: summarize the project"
  end

  test "streams live events without changing the final summary" do
    parent = self()

    summary =
      ClientRunner.run!(
        %{
          task: "summarize the project",
          workflow: :basic,
          provider: :echo,
          timeout_ms: 1_000,
          max_steps: 2,
          max_attempts: 1
        },
        event_sink: fn event -> send(parent, {:event, event.type, event}) end
      )

    assert summary.status == "completed"
    assert summary.final_output =~ "finalizer"
    assert_receive {:event, :run_started, %{run_id: _run_id}}
    assert_receive {:event, :agent_started, %{agent_id: "assistant"}}
    assert_receive {:event, :agent_finished, %{agent_id: "assistant", status: :ok}}
    assert_receive {:event, :agent_started, %{agent_id: "finalizer"}}
    assert_receive {:event, :run_completed, %{run_id: _run_id}}
  end

  test "streams assistant deltas when stream_response is enabled" do
    parent = self()

    summary =
      ClientRunner.run!(
        %{
          task: "summarize the project",
          workflow: :basic,
          provider: :echo,
          timeout_ms: 1_000,
          max_steps: 2,
          max_attempts: 1,
          stream_response: true
        },
        event_sink: fn event -> send(parent, {:event, event.type, event}) end
      )

    assert summary.status == "completed"
    assert_receive {:event, :assistant_delta, %{agent_id: "assistant", delta: delta}}
    assert delta =~ "agent assistant:"
    assert_receive {:event, :assistant_done, %{agent_id: "assistant"}}
  end

  test "requires event sink to be an arity one function" do
    assert_raise ArgumentError, ~r/:event_sink must be a function of arity 1/, fn ->
      ClientRunner.run!(
        %{
          task: "summarize the project",
          workflow: :basic,
          provider: :echo,
          timeout_ms: 1_000,
          max_steps: 2,
          max_attempts: 1
        },
        event_sink: :not_a_function
      )
    end
  end

  test "encodes JSONL event and summary envelopes" do
    event_json =
      ClientRunner.jsonl_event!(%{
        type: :agent_started,
        run_id: "run-1",
        agent_id: "assistant",
        parent_agent_id: nil,
        attempt: 1,
        at: DateTime.utc_now()
      })

    summary_json = ClientRunner.jsonl_summary!(%{run_id: "run-1", status: "completed"})

    assert %{"type" => "event", "event" => %{"type" => "agent_started"}} =
             JSON.decode!(event_json)

    assert %{"type" => "summary", "summary" => %{"status" => "completed"}} =
             JSON.decode!(summary_json)
  end

  test "marks client summary failed when completed run contains failed agent results" do
    summary =
      ClientRunner.summarize_for_test!(%{
        id: "run-1",
        status: :completed,
        results: %{
          "assistant" => %AgentResult{
            run_id: "run-1",
            agent_id: "assistant",
            status: :error,
            attempt: 1,
            error: "provider rejected request"
          }
        },
        artifacts: %{},
        usage: nil,
        events: [],
        error: nil
      })

    assert summary.status == "failed"
    assert summary.error == "assistant: provider rejected request"
    assert summary.final_output == nil
    assert summary.results["assistant"].status == "error"
  end

  test "timeout summaries include timeout status and explicit reason" do
    summary =
      ClientRunner.summarize_for_test!(%{
        id: "run-timeout",
        status: :timeout,
        results: %{},
        artifacts: %{},
        usage: nil,
        events: [
          %{
            type: :run_timed_out,
            run_id: "run-timeout",
            reason: "idle lease expired after 1000ms without runtime activity",
            idle_timeout_ms: 1_000,
            hard_timeout_ms: 3_000,
            elapsed_ms: 1_001,
            at: DateTime.utc_now()
          }
        ],
        error: "idle lease expired after 1000ms without runtime activity"
      })

    assert summary.status == "timeout"
    assert summary.error == "idle lease expired after 1000ms without runtime activity"
    assert [%{type: "run_timed_out", summary: summary_text}] = summary.events
    assert summary_text =~ "Run timed out"
  end

  test "mix agent_machine.run prints JSON summary" do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(previous_shell)
    end)

    Mix.Task.reenable("agent_machine.run")

    Run.run([
      "--workflow",
      "basic",
      "--provider",
      "echo",
      "--router-mode",
      "deterministic",
      "--timeout-ms",
      "1000",
      "--max-steps",
      "2",
      "--max-attempts",
      "1",
      "--json",
      "summarize the project"
    ])

    assert_receive {:mix_shell, :info, [json]}

    decoded = JSON.decode!(json)
    assert decoded["status"] == "completed"
    assert decoded["final_output"] =~ "finalizer"
  end

  test "mix agent_machine.run accepts auto workflow and reports selected route" do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(previous_shell)
    end)

    Mix.Task.reenable("agent_machine.run")

    Run.run([
      "--workflow",
      "auto",
      "--provider",
      "echo",
      "--router-mode",
      "deterministic",
      "--timeout-ms",
      "1000",
      "--max-steps",
      "6",
      "--max-attempts",
      "1",
      "--json",
      "explain progressive escalation"
    ])

    assert_receive {:mix_shell, :info, [json]}

    decoded = JSON.decode!(json)
    assert decoded["workflow_route"]["requested"] == "auto"
    assert decoded["workflow_route"]["selected"] == "chat"
    assert Map.keys(decoded["results"]) == ["assistant"]
  end

  test "client runner returns structured capability requirement before runtime starts" do
    summary =
      ClientRunner.run!(%{
        task: "patch lib/foo.ex",
        workflow: :auto,
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 6,
        max_attempts: 1,
        router_mode: :deterministic,
        tool_harness: :local_files,
        tool_root: "/tmp/project",
        tool_timeout_ms: 100,
        tool_max_rounds: 2,
        tool_approval_mode: :auto_approved_safe
      })

    assert summary.status == "failed"
    assert summary.capability_required.reason == "missing_code_edit_harness"
    assert summary.capability_required.required_harness == "code-edit"
    assert summary.capability_required.requested_root == "/tmp/project"
    assert [%{type: "capability_required"}] = summary.events
  end

  test "mix agent_machine.run writes session event log through collector" do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    path =
      Path.join(
        System.tmp_dir!(),
        "agent-machine-session-events-#{System.unique_integer()}.jsonl"
      )

    on_exit(fn ->
      Mix.shell(previous_shell)
    end)

    Mix.Task.reenable("agent_machine.run")

    Run.run([
      "--workflow",
      "auto",
      "--provider",
      "echo",
      "--router-mode",
      "deterministic",
      "--timeout-ms",
      "1000",
      "--max-steps",
      "6",
      "--max-attempts",
      "1",
      "--event-log-file",
      path,
      "--event-session-id",
      "session-1",
      "--json",
      "explain progressive escalation"
    ])

    assert_receive {:mix_shell, :info, [_json]}

    decoded =
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    assert Enum.any?(
             decoded,
             &(get_in(&1, ["event", "type"]) == "event_log_configured" and
                 get_in(&1, ["event", "session_id"]) == "session-1")
           )

    assert Enum.any?(decoded, &(get_in(&1, ["event", "type"]) == "workflow_routed"))
    assert Enum.any?(decoded, &(&1["type"] == "summary"))
  end

  test "mix agent_machine.run rejects event session id without event log file" do
    Mix.Task.reenable("agent_machine.run")

    assert_raise Mix.Error, ~r/--event-session-id requires --event-log-file/, fn ->
      Run.run([
        "--workflow",
        "chat",
        "--provider",
        "echo",
        "--timeout-ms",
        "1000",
        "--max-steps",
        "1",
        "--max-attempts",
        "1",
        "--event-session-id",
        "session-1",
        "hello"
      ])
    end
  end

  test "mix agent_machine.run accepts local router flags" do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(previous_shell)
    end)

    Mix.Task.reenable("agent_machine.run")

    Run.run([
      "--workflow",
      "basic",
      "--provider",
      "echo",
      "--router-mode",
      "deterministic",
      "--timeout-ms",
      "1000",
      "--max-steps",
      "2",
      "--max-attempts",
      "1",
      "--router-mode",
      "local",
      "--router-model-dir",
      "/tmp/agent-machine-router-model",
      "--router-timeout-ms",
      "100",
      "--router-confidence-threshold",
      "0.5",
      "--json",
      "hello"
    ])

    assert_receive {:mix_shell, :info, [json]}
    assert JSON.decode!(json)["status"] == "completed"
  end

  test "mix agent_machine.run rejects invalid local router options" do
    Mix.Task.reenable("agent_machine.run")

    assert_raise ArgumentError, ~r/:router_model_dir/, fn ->
      Run.run([
        "--workflow",
        "basic",
        "--provider",
        "echo",
        "--timeout-ms",
        "1000",
        "--max-steps",
        "2",
        "--max-attempts",
        "1",
        "--router-mode",
        "local",
        "--json",
        "hello"
      ])
    end

    Mix.Task.reenable("agent_machine.run")

    assert_raise ArgumentError, ~r/:router_timeout_ms/, fn ->
      Run.run([
        "--workflow",
        "basic",
        "--provider",
        "echo",
        "--timeout-ms",
        "1000",
        "--max-steps",
        "2",
        "--max-attempts",
        "1",
        "--router-mode",
        "local",
        "--router-model-dir",
        "/tmp/agent-machine-router-model",
        "--router-timeout-ms",
        "0",
        "--router-confidence-threshold",
        "0.5",
        "--json",
        "hello"
      ])
    end

    Mix.Task.reenable("agent_machine.run")

    assert_raise ArgumentError, ~r/:router_confidence_threshold/, fn ->
      Run.run([
        "--workflow",
        "basic",
        "--provider",
        "echo",
        "--timeout-ms",
        "1000",
        "--max-steps",
        "2",
        "--max-attempts",
        "1",
        "--router-mode",
        "local",
        "--router-model-dir",
        "/tmp/agent-machine-router-model",
        "--router-timeout-ms",
        "100",
        "--router-confidence-threshold",
        "1.5",
        "--json",
        "hello"
      ])
    end
  end

  test "mix agent_machine.run accepts explicit llm router mode" do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(previous_shell)
    end)

    Mix.Task.reenable("agent_machine.run")

    Run.run([
      "--workflow",
      "basic",
      "--provider",
      "echo",
      "--timeout-ms",
      "1000",
      "--max-steps",
      "2",
      "--max-attempts",
      "1",
      "--router-mode",
      "llm",
      "--json",
      "hello"
    ])

    assert_receive {:mix_shell, :info, [json]}
    assert JSON.decode!(json)["status"] == "completed"
  end

  test "mix agent_machine.run rejects explicit chat with tool harness options" do
    Mix.Task.reenable("agent_machine.run")

    assert_raise ArgumentError, ~r/workflow :chat does not accept tool harness options/, fn ->
      Run.run([
        "--workflow",
        "chat",
        "--provider",
        "echo",
        "--timeout-ms",
        "1000",
        "--max-steps",
        "1",
        "--max-attempts",
        "1",
        "--tool-harness",
        "local-files",
        "--tool-root",
        System.tmp_dir!(),
        "--tool-timeout-ms",
        "100",
        "--tool-max-rounds",
        "2",
        "--tool-approval-mode",
        "read-only",
        "--json",
        "hello"
      ])
    end
  end

  test "mix agent_machine.run rejects run-context compaction without required limits" do
    Mix.Task.reenable("agent_machine.run")

    assert_raise ArgumentError, ~r/:context_window_tokens/, fn ->
      Run.run([
        "--workflow",
        "agentic",
        "--provider",
        "echo",
        "--timeout-ms",
        "1000",
        "--max-steps",
        "3",
        "--max-attempts",
        "1",
        "--run-context-compaction",
        "on",
        "--run-context-compact-percent",
        "90",
        "--max-context-compactions",
        "1",
        "--json",
        "hello"
      ])
    end
  end

  test "mix agent_machine.run prints JSONL events before final summary" do
    Mix.Task.reenable("agent_machine.run")

    output =
      capture_io(fn ->
        Run.run([
          "--workflow",
          "basic",
          "--provider",
          "echo",
          "--timeout-ms",
          "1000",
          "--max-steps",
          "2",
          "--max-attempts",
          "1",
          "--jsonl",
          "summarize the project"
        ])
      end)

    messages = output |> String.trim() |> String.split("\n", trim: true)
    decoded = Enum.map(messages, &JSON.decode!/1)

    assert %{"type" => "event", "event" => %{"type" => "run_started"}} = hd(decoded)
    assert %{"type" => "summary", "summary" => %{"status" => "completed"}} = List.last(decoded)

    assert Enum.any?(
             decoded,
             &match?(
               %{
                 "type" => "event",
                 "event" => %{"type" => "agent_started", "agent_id" => "assistant"}
               },
               &1
             )
           )
  end

  test "mix agent_machine.run requires JSONL for response streaming" do
    Mix.Task.reenable("agent_machine.run")

    assert_raise Mix.Error, ~r/--stream-response requires --jsonl/, fn ->
      Run.run([
        "--workflow",
        "basic",
        "--provider",
        "echo",
        "--timeout-ms",
        "1000",
        "--max-steps",
        "2",
        "--max-attempts",
        "1",
        "--stream-response",
        "summarize"
      ])
    end
  end

  test "mix agent_machine.run requires tool max rounds with a tool harness" do
    Mix.Task.reenable("agent_machine.run")

    assert_raise ArgumentError, ~r/:tool_max_rounds/, fn ->
      Run.run([
        "--workflow",
        "basic",
        "--provider",
        "echo",
        "--timeout-ms",
        "1000",
        "--max-steps",
        "2",
        "--max-attempts",
        "1",
        "--tool-harness",
        "demo",
        "--tool-timeout-ms",
        "100",
        "--json",
        "what time is it?"
      ])
    end
  end

  test "mix agent_machine.run accepts time tool harness" do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(previous_shell)
    end)

    Mix.Task.reenable("agent_machine.run")

    Run.run([
      "--workflow",
      "auto",
      "--provider",
      "echo",
      "--router-mode",
      "deterministic",
      "--timeout-ms",
      "1000",
      "--max-steps",
      "6",
      "--max-attempts",
      "1",
      "--tool-harness",
      "time",
      "--tool-timeout-ms",
      "100",
      "--tool-max-rounds",
      "2",
      "--tool-approval-mode",
      "read-only",
      "--json",
      "what time is it?"
    ])

    assert_receive {:mix_shell, :info, [json]}

    decoded = JSON.decode!(json)
    assert decoded["workflow_route"]["selected"] == "tool"
    assert decoded["workflow_route"]["reason"] == "time_intent_with_read_only_tool"
    assert Map.keys(decoded["results"]) == ["assistant"]
  end

  test "mix agent_machine.run accepts code-edit tool harness with explicit root budget and timeout" do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    root = Path.join(System.tmp_dir!(), "agent-machine-code-edit-cli-#{System.unique_integer()}")

    on_exit(fn ->
      Mix.shell(previous_shell)
      File.rm_rf(root)
    end)

    File.mkdir_p!(root)
    Mix.Task.reenable("agent_machine.run")

    Run.run([
      "--workflow",
      "basic",
      "--provider",
      "echo",
      "--router-mode",
      "deterministic",
      "--timeout-ms",
      "1000",
      "--max-steps",
      "2",
      "--max-attempts",
      "1",
      "--tool-harness",
      "code-edit",
      "--tool-root",
      root,
      "--tool-timeout-ms",
      "100",
      "--tool-max-rounds",
      "2",
      "--tool-approval-mode",
      "full-access",
      "--json",
      "summarize"
    ])

    assert_receive {:mix_shell, :info, [line]}
    assert %{"status" => "completed"} = JSON.decode!(line)
  end

  test "mix agent_machine.run preserves repeated tool harness flags" do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    root =
      Path.join(System.tmp_dir!(), "agent-machine-local-files-cli-#{System.unique_integer()}")

    event_log =
      Path.join(
        System.tmp_dir!(),
        "agent-machine-repeated-harnesses-#{System.unique_integer()}.jsonl"
      )

    mcp_config =
      Path.join(
        System.tmp_dir!(),
        "agent-machine-repeated-harnesses-#{System.unique_integer()}.mcp.json"
      )

    on_exit(fn ->
      Mix.shell(previous_shell)
      File.rm_rf(root)
      File.rm(event_log)
      File.rm(mcp_config)
    end)

    File.mkdir_p!(root)

    File.write!(
      mcp_config,
      JSON.encode!(%{
        "servers" => [
          %{
            "id" => "browser",
            "transport" => "stdio",
            "command" => "mcp-browser",
            "args" => [],
            "env" => %{},
            "tools" => [
              %{
                "name" => "snapshot",
                "permission" => "mcp_browser_snapshot",
                "risk" => "read",
                "inputSchema" => %{"type" => "object"}
              }
            ]
          }
        ]
      })
    )

    Mix.Task.reenable("agent_machine.run")

    Run.run([
      "--workflow",
      "auto",
      "--provider",
      "echo",
      "--router-mode",
      "deterministic",
      "--timeout-ms",
      "1000",
      "--max-steps",
      "6",
      "--max-attempts",
      "1",
      "--tool-harness",
      "local-files",
      "--tool-harness",
      "mcp",
      "--tool-root",
      root,
      "--tool-timeout-ms",
      "100",
      "--tool-max-rounds",
      "2",
      "--tool-approval-mode",
      "read-only",
      "--mcp-config",
      mcp_config,
      "--event-log-file",
      event_log,
      "--json",
      "hello"
    ])

    assert_receive {:mix_shell, :info, [line]}
    assert %{"status" => "completed"} = JSON.decode!(line)

    route_event =
      event_log
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)
      |> Enum.find(&(get_in(&1, ["event", "type"]) == "workflow_routed"))

    assert get_in(route_event, ["event", "active_harnesses"]) == ["local_files", "mcp"]
  end

  test "mix agent_machine.run accepts repeated test commands with code-edit full-access" do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    root = Path.join(System.tmp_dir!(), "agent-machine-code-edit-cli-#{System.unique_integer()}")

    on_exit(fn ->
      Mix.shell(previous_shell)
      File.rm_rf(root)
    end)

    File.mkdir_p!(root)
    Mix.Task.reenable("agent_machine.run")

    Run.run([
      "--workflow",
      "basic",
      "--provider",
      "echo",
      "--timeout-ms",
      "1000",
      "--max-steps",
      "2",
      "--max-attempts",
      "1",
      "--tool-harness",
      "code-edit",
      "--tool-root",
      root,
      "--tool-timeout-ms",
      "100",
      "--tool-max-rounds",
      "2",
      "--tool-approval-mode",
      "full-access",
      "--test-command",
      "mix test",
      "--test-command",
      "go test ./...",
      "--json",
      "summarize"
    ])

    assert_receive {:mix_shell, :info, [line]}
    assert %{"status" => "completed"} = JSON.decode!(line)
  end

  test "mix agent_machine.run rejects test commands without supported non-interactive approval" do
    Mix.Task.reenable("agent_machine.run")

    assert_raise ArgumentError, ~r/test_commands require :tool_harness :code_edit/, fn ->
      Run.run([
        "--workflow",
        "basic",
        "--provider",
        "echo",
        "--timeout-ms",
        "1000",
        "--max-steps",
        "2",
        "--max-attempts",
        "1",
        "--tool-harness",
        "demo",
        "--tool-timeout-ms",
        "100",
        "--tool-max-rounds",
        "2",
        "--tool-approval-mode",
        "full-access",
        "--test-command",
        "mix test",
        "--json",
        "what time is it?"
      ])
    end

    Mix.Task.reenable("agent_machine.run")

    assert_raise ArgumentError, ~r/test_commands require :tool_approval_mode :full_access/, fn ->
      Run.run([
        "--workflow",
        "basic",
        "--provider",
        "echo",
        "--timeout-ms",
        "1000",
        "--max-steps",
        "2",
        "--max-attempts",
        "1",
        "--tool-harness",
        "code-edit",
        "--tool-root",
        System.tmp_dir!(),
        "--tool-timeout-ms",
        "100",
        "--tool-max-rounds",
        "2",
        "--tool-approval-mode",
        "auto-approved-safe",
        "--test-command",
        "mix test",
        "--json",
        "edit"
      ])
    end

    Mix.Task.reenable("agent_machine.run")

    assert_raise ArgumentError, ~r/:tool_approval_callback is required/, fn ->
      Run.run([
        "--workflow",
        "basic",
        "--provider",
        "echo",
        "--timeout-ms",
        "1000",
        "--max-steps",
        "2",
        "--max-attempts",
        "1",
        "--tool-harness",
        "code-edit",
        "--tool-root",
        System.tmp_dir!(),
        "--tool-timeout-ms",
        "100",
        "--tool-max-rounds",
        "2",
        "--tool-approval-mode",
        "ask-before-write",
        "--test-command",
        "mix test",
        "--json",
        "edit"
      ])
    end
  end

  test "mix agent_machine.run rejects invalid tool approval mode" do
    Mix.Task.reenable("agent_machine.run")

    assert_raise Mix.Error, ~r/--tool-approval-mode/, fn ->
      Run.run([
        "--workflow",
        "basic",
        "--provider",
        "echo",
        "--timeout-ms",
        "1000",
        "--max-steps",
        "2",
        "--max-attempts",
        "1",
        "--tool-harness",
        "demo",
        "--tool-timeout-ms",
        "100",
        "--tool-max-rounds",
        "2",
        "--tool-approval-mode",
        "maybe",
        "--json",
        "what time is it?"
      ])
    end
  end

  test "mix agent_machine.run writes JSONL run log file" do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(previous_shell)
    end)

    Mix.Task.reenable("agent_machine.run")
    log_path = Path.join(System.tmp_dir!(), "agent-machine-run-#{System.unique_integer()}.jsonl")
    on_exit(fn -> File.rm(log_path) end)

    Run.run([
      "--workflow",
      "basic",
      "--provider",
      "echo",
      "--timeout-ms",
      "1000",
      "--max-steps",
      "2",
      "--max-attempts",
      "1",
      "--log-file",
      log_path,
      "--json",
      "summarize the project"
    ])

    assert_receive {:mix_shell, :info, [json]}
    assert %{"status" => "completed"} = JSON.decode!(json)

    decoded =
      log_path
      |> File.read!()
      |> String.trim()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    assert %{"type" => "event", "event" => %{"type" => "run_started"}} = hd(decoded)
    assert %{"type" => "summary", "summary" => %{"status" => "completed"}} = List.last(decoded)
  end

  test "mix agent_machine.rollback restores files and prints JSON" do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    root = Path.join(System.tmp_dir!(), "agent-machine-rollback-cli-#{System.unique_integer()}")

    on_exit(fn ->
      Mix.shell(previous_shell)
      File.rm_rf(root)
    end)

    File.mkdir_p!(root)
    File.write!(Path.join(root, "source.txt"), "old")

    {:ok, edit} =
      ApplyEdits.run(
        %{
          "changes" => [
            %{
              "op" => "replace",
              "path" => "source.txt",
              "old_text" => "old",
              "new_text" => "new",
              "expected_replacements" => 1
            }
          ]
        },
        tool_root: root
      )

    Mix.Task.reenable("agent_machine.rollback")

    Rollback.run([
      "--tool-root",
      root,
      "--checkpoint-id",
      edit.checkpoint_id,
      "--json"
    ])

    assert_receive {:mix_shell, :info, [json]}
    assert %{"rolled_back_checkpoint_id" => rolled_back} = JSON.decode!(json)
    assert rolled_back == edit.checkpoint_id
    assert File.read!(Path.join(root, "source.txt")) == "old"
  end

  test "mix agent_machine.rollback fails fast on missing options" do
    Mix.Task.reenable("agent_machine.rollback")

    assert_raise Mix.Error, ~r/missing required --tool-root option/, fn ->
      Rollback.run(["--checkpoint-id", "20260426T000000Z-1"])
    end

    root =
      Path.join(System.tmp_dir!(), "agent-machine-rollback-missing-#{System.unique_integer()}")

    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)
    Mix.Task.reenable("agent_machine.rollback")

    assert_raise Mix.Error, ~r/missing required --checkpoint-id option/, fn ->
      Rollback.run(["--tool-root", root])
    end
  end
end
