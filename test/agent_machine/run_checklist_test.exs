defmodule AgentMachine.RunChecklistTest do
  use ExUnit.Case, async: true

  alias AgentMachine.RunChecklist

  test "derives agent and tool rows from runtime events" do
    started_at = DateTime.from_naive!(~N[2026-04-30 10:00:00], "Etc/UTC")
    finished_at = DateTime.from_naive!(~N[2026-04-30 10:00:01], "Etc/UTC")

    checklist =
      RunChecklist.from_events([
        %{
          type: :agent_started,
          agent_id: "planner",
          attempt: 1,
          at: started_at
        },
        %{
          type: :agent_delegation_scheduled,
          agent_id: "planner",
          delegated_agent_ids: ["worker"],
          count: 1,
          at: started_at
        },
        %{
          type: :agent_started,
          agent_id: "worker",
          parent_agent_id: "planner",
          attempt: 1,
          at: started_at
        },
        %{
          type: :tool_call_started,
          agent_id: "worker",
          tool_call_id: "call-1",
          tool: "read_file",
          status: :running,
          input_summary: %{path: "README.md"},
          at: started_at
        },
        %{
          type: :tool_call_finished,
          agent_id: "worker",
          tool_call_id: "call-1",
          tool: "read_file",
          status: :ok,
          result_summary: %{path: "README.md", bytes: 12, line_count: 2},
          duration_ms: 15,
          at: finished_at
        },
        %{
          type: :agent_finished,
          agent_id: "worker",
          status: :ok,
          duration_ms: 25,
          at: finished_at
        }
      ])

    assert Enum.map(checklist, & &1.id) == [
             "agent:planner",
             "agent:worker",
             "tool:worker:call-1"
           ]

    assert %{status: "done", parent_id: "agent:planner"} =
             Enum.find(checklist, &(&1.id == "agent:worker"))

    assert %{kind: "tool", status: "done", duration_ms: 15, latest_summary: summary} =
             Enum.find(checklist, &(&1.id == "tool:worker:call-1"))

    assert summary =~ "read README.md"
  end

  test "marks pending and running rows timed out" do
    at = DateTime.from_naive!(~N[2026-04-30 10:00:00], "Etc/UTC")

    checklist =
      RunChecklist.from_events([
        %{
          type: :agent_delegation_scheduled,
          agent_id: "planner",
          delegated_agent_ids: ["worker"]
        },
        %{type: :agent_started, agent_id: "worker", parent_agent_id: "planner", at: at},
        %{type: :run_timed_out, reason: "hard timeout reached", at: at}
      ])

    assert [%{status: "timeout"}] = Enum.filter(checklist, &(&1.id == "agent:worker"))
  end
end
