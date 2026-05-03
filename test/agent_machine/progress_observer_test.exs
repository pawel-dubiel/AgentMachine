defmodule AgentMachine.ProgressObserverTest do
  use ExUnit.Case, async: false

  alias AgentMachine.{Orchestrator, ProgressObserver, RunSpec, ToolPolicy}

  setup do
    previous = Application.get_env(:agent_machine, :progress_observer_test_pid)
    Application.put_env(:agent_machine, :progress_observer_test_pid, self())

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:agent_machine, :progress_observer_test_pid)
      else
        Application.put_env(:agent_machine, :progress_observer_test_pid, previous)
      end
    end)

    :ok
  end

  test "builds bounded evidence for read-style and command tool results" do
    read_evidence =
      ProgressObserver.tool_result_evidence("read_file", %{
        content: String.duplicate("line\n", 800),
        summary: %{path: "README.md", line_count: 800, truncated: true}
      })

    assert read_evidence.kind == "tool_result"
    assert read_evidence.tool == "read_file"
    assert read_evidence.result.path == "README.md"
    assert byte_size(read_evidence.result.content_excerpt) <= 2_000
    refute read_evidence.result.content_excerpt =~ String.duplicate("line\n", 800)

    command_evidence =
      ProgressObserver.tool_result_evidence("run_test_command", %{
        command: "mix test",
        cwd: "/workspace/project",
        exit_status: 0,
        output: String.duplicate("ok\n", 1_000)
      })

    assert command_evidence.result.command == "mix test"
    assert command_evidence.result.exit_status == 0
    assert byte_size(command_evidence.result.output_excerpt) <= 2_000
  end

  test "fails fast when public config uses echo provider for observer" do
    spec =
      RunSpec.new!(%{
        task: "observe progress",
        workflow: :chat,
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 1,
        max_attempts: 1,
        progress_observer: true
      })

    assert_raise ArgumentError, ~r/echo provider cannot run observer commentary/, fn ->
      ProgressObserver.from_run_spec!(spec)
    end
  end

  test "emits observer commentary from runtime events without exposing tools to observer" do
    agents = [
      %{
        id: "tool-user",
        provider: AgentMachine.ProgressObserverTest.ToolUsingProvider,
        model: "test-main",
        input: "hello",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    observer = %{
      provider: AgentMachine.ProgressObserverTest.ObserverProvider,
      model: "test-observer",
      pricing: %{input_per_million: 0.0, output_per_million: 0.0},
      provider_opts: [],
      task: "observe tool run",
      debounce_ms: 0,
      cooldown_ms: 0
    }

    parent = self()

    assert {:ok, run} =
             Orchestrator.run(agents,
               timeout: 1_000,
               allowed_tools: [AgentMachine.ProgressObserverTest.EchoTool],
               tool_policy: ToolPolicy.new!(permissions: [:test_echo]),
               tool_timeout_ms: 100,
               tool_max_rounds: 2,
               tool_approval_mode: :auto_approved_safe,
               event_sink: fn event -> send(parent, {:event, event}) end,
               progress_observer: observer
             )

    assert run.results["tool-user"].status == :ok
    refute Enum.any?(run.events, &Map.has_key?(&1, :progress_observer_evidence))
    refute Enum.any?(run.events, &Map.has_key?(&1, "progress_observer_evidence"))

    assert_receive {:observer_call, observer_agent, observer_opts}, 500
    assert observer_agent.id == "progress-observer"
    assert observer_agent.model == "test-observer"
    assert observer_agent.input =~ "tool_call_finished"
    assert observer_agent.input =~ "echo-call"
    refute Keyword.has_key?(observer_opts, :allowed_tools)
    refute Keyword.has_key?(observer_opts, :tool_policy)
    refute Keyword.has_key?(observer_opts, :tool_approval_mode)

    assert_receive {:event, %{type: :progress_commentary} = event}, 500
    assert event.commentary == "Observer saw the tool activity and summarized it."
    assert event.source == :observer
    assert "tool-user" in event.agent_ids
    assert "echo-call" in event.tool_call_ids
    assert event.evidence_count > 0
  end

  test "observer provider call does not block the main run" do
    agents = [
      %{
        id: "assistant",
        provider: AgentMachine.ProgressObserverTest.SimpleProvider,
        model: "test-main",
        input: "hello",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    observer = %{
      provider: AgentMachine.ProgressObserverTest.SlowObserverProvider,
      model: "test-observer",
      pricing: %{input_per_million: 0.0, output_per_million: 0.0},
      provider_opts: [],
      task: "observe quick run",
      debounce_ms: 0,
      cooldown_ms: 0
    }

    parent = self()
    started_at = System.monotonic_time(:millisecond)

    assert {:ok, run} =
             Orchestrator.run(agents,
               timeout: 1_000,
               max_steps: 1,
               max_attempts: 1,
               event_sink: fn event -> send(parent, {:event, event}) end,
               progress_observer: observer
             )

    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert run.results["assistant"].status == :ok
    assert elapsed_ms < 800

    assert_receive {:event, %{type: :progress_commentary, commentary: "Slow observer done."}},
                   1_500
  end

  test "guards misleading success commentary when terminal evidence includes failed agents" do
    observer = %{
      provider: AgentMachine.ProgressObserverTest.MisleadingObserverProvider,
      model: "test-observer",
      pricing: %{input_per_million: 0.0, output_per_million: 0.0},
      provider_opts: [],
      task: "research AI news",
      debounce_ms: 0,
      cooldown_ms: 0
    }

    parent = self()
    name = :"progress-observer-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      ProgressObserver.start_link(
        {"run-1", observer, fn event -> send(parent, {:event, event}) end, name: name}
      )

    at = DateTime.utc_now()

    ProgressObserver.observe(pid, %{
      type: :agent_finished,
      run_id: "run-1",
      agent_id: "ai-news-researcher",
      status: :error,
      attempt: 1,
      at: at
    })

    ProgressObserver.observe(pid, %{
      type: :agent_finished,
      run_id: "run-1",
      agent_id: "finalizer",
      status: :ok,
      attempt: 1,
      at: at
    })

    ProgressObserver.observe(pid, %{type: :run_completed, run_id: "run-1", at: at})

    assert_receive {:event, %{type: :progress_commentary} = event}, 500
    assert event.commentary =~ "failed agent work"
    refute String.contains?(String.downcase(event.commentary), "completed successfully")
  end
end

defmodule AgentMachine.ProgressObserverTest.EchoTool do
  @behaviour AgentMachine.Tool

  @impl true
  def permission, do: :test_echo

  @impl true
  def approval_risk, do: :read

  @impl true
  def run(input, _opts) when is_map(input) do
    {:ok,
     %{
       value: Map.fetch!(input, :value),
       summary: %{tool: "echo_tool", status: "ok", path: "virtual.txt"}
     }}
  end
end

defmodule AgentMachine.ProgressObserverTest.ToolUsingProvider do
  @behaviour AgentMachine.Provider

  alias AgentMachine.Agent

  @impl true
  def complete(%Agent{} = agent, opts) do
    case Keyword.get(opts, :tool_continuation) do
      %{results: [%{result: %{value: value}}]} ->
        output = "final answer: #{value}"
        {:ok, %{output: output, usage: usage(agent, output)}}

      nil ->
        output = "calling tool"

        {:ok,
         %{
           output: output,
           tool_calls: [
             %{
               id: "echo-call",
               tool: AgentMachine.ProgressObserverTest.EchoTool,
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

  defp token_count(text), do: text |> String.split(~r/\s+/, trim: true) |> length()
end

defmodule AgentMachine.ProgressObserverTest.ObserverProvider do
  @behaviour AgentMachine.Provider

  alias AgentMachine.Agent
  alias AgentMachine.ProgressObserverTest.ObserverProbe

  @impl true
  def complete(%Agent{} = agent, opts) do
    ObserverProbe.record!(agent, opts)

    output = "Observer saw the tool activity and summarized it."
    {:ok, %{output: output, usage: %{input_tokens: 1, output_tokens: 7, total_tokens: 8}}}
  end
end

defmodule AgentMachine.ProgressObserverTest.SimpleProvider do
  @behaviour AgentMachine.Provider

  alias AgentMachine.Agent

  @impl true
  def complete(%Agent{} = agent, _opts) do
    output = "simple output"
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

  defp token_count(text), do: text |> String.split(~r/\s+/, trim: true) |> length()
end

defmodule AgentMachine.ProgressObserverTest.SlowObserverProvider do
  @behaviour AgentMachine.Provider

  alias AgentMachine.Agent

  @impl true
  def complete(%Agent{}, _opts) do
    Process.sleep(1_000)

    {:ok,
     %{
       output: "Slow observer done.",
       usage: %{input_tokens: 1, output_tokens: 3, total_tokens: 4}
     }}
  end
end

defmodule AgentMachine.ProgressObserverTest.MisleadingObserverProvider do
  @behaviour AgentMachine.Provider

  alias AgentMachine.Agent

  @impl true
  def complete(%Agent{}, _opts) do
    {:ok,
     %{
       output:
         "The research run completed successfully; the finalizer finished analyzing recent AI news.",
       usage: %{input_tokens: 1, output_tokens: 10, total_tokens: 11}
     }}
  end
end

defmodule AgentMachine.ProgressObserverTest.ObserverProbe do
  @moduledoc false

  def record!(agent, opts) do
    pid = Application.fetch_env!(:agent_machine, :progress_observer_test_pid)
    send(pid, {:observer_call, agent, opts})
  end
end
