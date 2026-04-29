defmodule AgentMachine.EventLogTest do
  use ExUnit.Case, async: false

  alias AgentMachine.{EventLog, JSON}

  setup do
    EventLog.close()

    on_exit(fn ->
      EventLog.close()
    end)

    :ok
  end

  test "writes redacted event and summary JSONL through the collector" do
    path =
      Path.join(System.tmp_dir!(), "agent-machine-event-log-#{System.unique_integer()}.jsonl")

    EventLog.configure!(path, %{session_id: "session-1"})

    EventLog.write_event(%{
      type: :workflow_routed,
      requested: "auto",
      selected: "basic",
      reason: "token=secret-value",
      tool_intent: "time",
      tools_exposed: true,
      at: DateTime.utc_now()
    })

    EventLog.write_summary(%{
      run_id: "run-1",
      status: "completed",
      final_output: "done",
      secret: "token=secret-value"
    })

    EventLog.close()

    lines = path |> File.read!() |> String.split("\n", trim: true)

    assert length(lines) == 3

    assert %{"event" => %{"type" => "event_log_configured", "session_id" => "session-1"}} =
             JSON.decode!(Enum.at(lines, 0))

    assert %{
             "type" => "event",
             "event" => %{
               "type" => "workflow_routed",
               "selected" => "basic",
               "summary" => "Workflow routed to basic"
             }
           } = JSON.decode!(Enum.at(lines, 1))

    assert %{"type" => "summary", "summary" => %{"run_id" => "run-1"}} =
             JSON.decode!(Enum.at(lines, 2))

    refute File.read!(path) =~ "secret-value"
  end

  test "write is a no-op when the collector is not configured" do
    assert :ok = EventLog.write_event(%{type: :run_started, run_id: "run-1"})
    assert :ok = EventLog.write_summary(%{run_id: "run-1"})
  end
end
