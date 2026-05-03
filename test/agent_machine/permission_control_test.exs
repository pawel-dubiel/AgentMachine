defmodule AgentMachine.PermissionControlTest do
  use ExUnit.Case, async: true

  alias AgentMachine.PermissionControl

  test "parses approve and deny decisions" do
    assert {"req-1", {:approved, "ok"}} =
             PermissionControl.parse_decision!(
               ~s({"type":"permission_decision","request_id":"req-1","decision":"approve","reason":"ok"})
             )

    assert {"req-2", {:denied, "no"}} =
             PermissionControl.parse_decision!(
               ~s({"type":"permission_decision","request_id":"req-2","decision":"deny","reason":"no"})
             )
  end

  test "parses planner review decisions" do
    assert {"review-1", {:approved, "ok"}} =
             PermissionControl.parse_decision!(
               ~s({"type":"planner_review_decision","request_id":"review-1","decision":"approve","reason":"ok"})
             )

    assert {"review-2", {:denied, "no"}} =
             PermissionControl.parse_decision!(
               ~s({"type":"planner_review_decision","request_id":"review-2","decision":"decline","reason":"no"})
             )

    assert {"review-3", {:revision_requested, "split less"}} =
             PermissionControl.parse_decision!(
               ~s({"type":"planner_review_decision","request_id":"review-3","decision":"revise","feedback":"split less"})
             )
  end

  test "planner review revise requires feedback" do
    assert_raise ArgumentError, ~r/feedback must be a non-empty binary/, fn ->
      PermissionControl.parse_decision!(
        ~s({"type":"planner_review_decision","request_id":"review-1","decision":"revise"})
      )
    end
  end

  test "routes concurrent decisions by request id" do
    {:ok, control} = PermissionControl.start_link(input: false)

    task_1 =
      Task.async(fn ->
        PermissionControl.request(control, %{request_id: "req-1"})
      end)

    task_2 =
      Task.async(fn ->
        PermissionControl.request(control, %{request_id: "req-2"})
      end)

    wait_until_pending(control, 2)

    send(
      control,
      {:permission_control_line,
       ~s({"type":"permission_decision","request_id":"req-2","decision":"deny","reason":"second"})}
    )

    send(
      control,
      {:permission_control_line,
       ~s({"type":"permission_decision","request_id":"req-1","decision":"approve","reason":"first"})}
    )

    assert Task.await(task_1) == {:approved, "first"}
    assert Task.await(task_2) == {:denied, "second"}
  end

  test "malformed control input cancels pending requests" do
    {:ok, control} = PermissionControl.start_link(input: false)

    task =
      Task.async(fn ->
        PermissionControl.request(control, %{request_id: "req-1"})
      end)

    wait_until_pending(control, 1)
    send(control, {:permission_control_line, ~s({"type":"nope"})})

    assert {:cancelled, reason} = Task.await(task)
    assert reason =~ "permission control input"
  end

  test "closed control input fails future requests closed" do
    {:ok, control} = PermissionControl.start_link(input: false)

    send(control, {:permission_control_closed, "permission control input reached EOF"})

    assert {:cancelled, "permission control input reached EOF"} =
             PermissionControl.request(control, %{request_id: "req-1"})
  end

  defp wait_until_pending(control, count) do
    if :sys.get_state(control).pending |> map_size() == count do
      :ok
    else
      Process.sleep(10)
      wait_until_pending(control, count)
    end
  end
end
