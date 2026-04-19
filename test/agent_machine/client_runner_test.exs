defmodule AgentMachine.ClientRunnerTest do
  use ExUnit.Case, async: false

  alias AgentMachine.{AgentResult, ClientRunner, JSON, RunSpec, UsageLedger}
  alias AgentMachine.Workflows.Basic
  alias Mix.Tasks.AgentMachine.Run

  setup do
    UsageLedger.reset!()
    :ok
  end

  test "validates required high-level run spec fields" do
    assert_raise ArgumentError, ~r/run spec :task must be a non-empty binary/, fn ->
      RunSpec.new!(%{
        task: "",
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

  test "runs the basic echo workflow and returns a client summary" do
    summary =
      ClientRunner.run!(%{
        task: "summarize the project",
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
end
