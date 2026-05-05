defmodule AgentMachine.Secrets.ClientRunnerRedactionTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias AgentMachine.{AgentResult, ClientRunner, JSON}
  alias Mix.Tasks.AgentMachine.Run

  @secret "sk-proj-abcdefghijklmnopqrstuvwxyz123456"

  test "client summaries redact result output, errors, artifacts, tool results, and events" do
    summary =
      ClientRunner.summarize_for_test!(%{
        id: "run-1",
        status: :completed,
        results: %{
          "assistant" => %AgentResult{
            run_id: "run-1",
            agent_id: "assistant",
            status: :ok,
            attempt: 1,
            output: "leaked #{@secret}",
            artifacts: %{env: "OPENAI_API_KEY=#{@secret}"},
            tool_results: %{"read" => %{content: "Authorization: Bearer #{@secret}"}}
          },
          "failing" => %AgentResult{
            run_id: "run-1",
            agent_id: "failing",
            status: :error,
            attempt: 1,
            error: "provider returned #{@secret}"
          }
        },
        artifacts: %{global: "token=#{@secret}"},
        usage: nil,
        events: [%{type: :run_failed, reason: "bad #{@secret}", at: DateTime.utc_now()}],
        error: nil
      })

    encoded = ClientRunner.json!(summary)

    refute encoded =~ @secret
    assert encoded =~ "[REDACTED:"
    decoded = JSON.decode!(encoded)
    assert decoded["redaction"]["redacted"] == true
    assert decoded["redaction"]["count"] >= 1
  end

  test "JSONL event and summary envelopes redact secrets" do
    event_line =
      ClientRunner.jsonl_event!(%{
        type: :run_failed,
        reason: "Authorization: Bearer #{@secret}",
        at: DateTime.utc_now()
      })

    summary_line = ClientRunner.jsonl_summary!(%{status: "failed", error: "token=#{@secret}"})

    refute event_line =~ @secret
    refute summary_line =~ @secret

    assert %{"type" => "event", "event" => %{"redaction" => %{"redacted" => true}}} =
             JSON.decode!(event_line)

    assert %{"type" => "summary", "summary" => %{"redaction" => %{"redacted" => true}}} =
             JSON.decode!(summary_line)
  end

  test "mix agent_machine.run JSONL log file redacts secrets" do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(previous_shell)
    end)

    Mix.Task.reenable("agent_machine.run")

    log_path =
      Path.join(System.tmp_dir!(), "agent-machine-redacted-#{System.unique_integer()}.jsonl")

    on_exit(fn -> File.rm(log_path) end)

    Run.run([
      "--workflow",
      "agentic",
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
      "summarize #{@secret}"
    ])

    assert_receive {:mix_shell, :info, [json]}
    refute json =~ @secret
    refute File.read!(log_path) =~ @secret
  end

  test "mix agent_machine.run JSONL stdout redacts secrets" do
    Mix.Task.reenable("agent_machine.run")

    output =
      capture_io(fn ->
        Run.run([
          "--workflow",
          "agentic",
          "--provider",
          "echo",
          "--timeout-ms",
          "1000",
          "--max-steps",
          "2",
          "--max-attempts",
          "1",
          "--jsonl",
          "summarize #{@secret}"
        ])
      end)

    refute output =~ @secret
    assert output =~ "[REDACTED:"
  end
end
