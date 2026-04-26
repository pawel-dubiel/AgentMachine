defmodule AgentMachine.ClientRunnerTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias AgentMachine.{AgentResult, ClientRunner, JSON, RunSpec, UsageLedger}
  alias AgentMachine.Workflows.{Agentic, Basic}
  alias Mix.Tasks.AgentMachine.Run

  setup do
    UsageLedger.reset!()
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

  test "builds workflow tool options from an explicit harness" do
    spec =
      RunSpec.new!(%{
        task: "what time is it?",
        workflow: :basic,
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 2,
        max_attempts: 1,
        tool_harness: :demo,
        tool_timeout_ms: 100,
        tool_max_rounds: 2,
        tool_approval_mode: :read_only
      })

    {_agents, opts} = Basic.build!(spec)

    assert Keyword.fetch!(opts, :allowed_tools) == [AgentMachine.Tools.Now]

    assert %AgentMachine.ToolPolicy{harness: :demo, permissions: permissions} =
             Keyword.fetch!(opts, :tool_policy)

    assert MapSet.member?(permissions, :demo_time)
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

    assert Keyword.fetch!(opts, :allowed_tools) == [
             AgentMachine.Tools.ApplyEdits,
             AgentMachine.Tools.ApplyPatch,
             AgentMachine.Tools.FileInfo,
             AgentMachine.Tools.ListFiles,
             AgentMachine.Tools.ReadFile,
             AgentMachine.Tools.SearchFiles
           ]

    assert Keyword.fetch!(opts, :tool_root) == "/tmp/agent-machine"
    assert Keyword.fetch!(opts, :tool_approval_mode) == :full_access

    assert %AgentMachine.ToolPolicy{harness: :code_edit, permissions: permissions} =
             Keyword.fetch!(opts, :tool_policy)

    assert MapSet.member?(permissions, :code_edit_apply_edits)
    assert MapSet.member?(permissions, :code_edit_apply_patch)
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
    assert planner.metadata == %{agent_machine_response: "delegation"}
    assert planner.instructions =~ "Return only JSON"
    assert Keyword.fetch!(opts, :max_steps) == 6
    assert Keyword.fetch!(opts, :finalizer).id == "finalizer"
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
      "--json",
      "summarize"
    ])

    assert_receive {:mix_shell, :info, [line]}
    assert %{"status" => "completed"} = JSON.decode!(line)
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
end
