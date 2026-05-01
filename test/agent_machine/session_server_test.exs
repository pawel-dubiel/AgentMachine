defmodule AgentMachine.SessionServerTest do
  use ExUnit.Case, async: false

  alias AgentMachine.{JSON, PermissionControl, SessionServer, SessionWriter}

  test "runs a coordinator turn and writes a summary over JSONL" do
    %{server: server, output: output} = start_session!()

    assert {:ok, %{status: "started"}} =
             SessionServer.user_message(server, user_message("msg-1", "say hello"))

    wait_until(fn ->
      output
      |> StringIO.contents()
      |> elem(1)
      |> String.contains?(~s("type":"summary"))
    end)

    summary = last_summary(output)
    assert summary["workflow_route"]["selected"] == "session"
    assert Map.has_key?(summary["results"], "coordinator")
  end

  test "auto-routed code mutation starts a primary sidechain and writes its summary" do
    %{server: server, output: output} = start_session!()
    root = tmp_dir!("agent-machine-session-code-edit")

    assert {:ok, %{status: "started"}} =
             SessionServer.user_message(
               server,
               user_message(
                 "msg-1",
                 "create a react app file src/main.js with hello world",
                 workflow: :auto,
                 max_steps: 6,
                 tool_harnesses: [:code_edit],
                 tool_root: root,
                 tool_timeout_ms: 1_000,
                 tool_max_rounds: 4,
                 tool_approval_mode: :auto_approved_safe
               )
             )

    wait_until(fn ->
      :sys.get_state(server).agents
      |> Map.values()
      |> Enum.any?(&(&1.status == :completed))
    end)

    state = :sys.get_state(server)
    assert state.coordinator_tasks == %{}
    assert [%{name: "request-1", status: :completed}] = Map.values(state.agents)

    summary = last_summary(output)
    assert summary["workflow_route"]["selected"] == "agentic"
    assert summary["workflow_route"]["tool_intent"] == "code_mutation"
    assert Map.has_key?(summary["results"], "planner")
    refute Map.has_key?(summary["results"], "coordinator")

    assert output_event?(output, "session_agent_started")
  end

  test "auto-routed code mutation fails fast without code-edit capability" do
    %{server: server, output: output} = start_session!()
    root = tmp_dir!("agent-machine-session-local-files")

    assert {:error, reason} =
             SessionServer.user_message(
               server,
               user_message(
                 "msg-1",
                 "create a react app file src/main.js with hello world",
                 workflow: :auto,
                 tool_harnesses: [:local_files],
                 tool_root: root,
                 tool_timeout_ms: 1_000,
                 tool_max_rounds: 4,
                 tool_approval_mode: :auto_approved_safe
               )
             )

    assert reason =~ "auto workflow detected code mutation intent"
    assert reason =~ ":code_edit tool harness is not configured"
    assert :sys.get_state(server).coordinator_tasks == %{}
    assert :sys.get_state(server).agents == %{}
    refute output_event?(output, "session_agent_started")
  end

  test "starts background sidechain agents and records completion" do
    %{server: server} = start_session!()

    assert {:ok, %{status: "started"}} =
             SessionServer.user_message(server, user_message("msg-1", "prepare session"))

    wait_until(fn -> :sys.get_state(server).coordinator_tasks == %{} end)

    assert {:ok, %{agent_id: agent_id, status: "running"}} =
             SessionServer.spawn_agent(server, %{
               "name" => "worker",
               "briefing" => "answer from worker",
               "background" => true
             })

    wait_until(fn ->
      %{agents: agents} = :sys.get_state(server)
      agents[agent_id].status == :completed
    end)

    assert {:ok, %{agent: %{status: "completed"}, transcript_tail: tail}} =
             SessionServer.read_agent_output(server, %{"agent_id" => agent_id})

    assert Enum.any?(tail, &(&1["type"] == "summary"))
  end

  test "foreground sidechain agent replies after completion" do
    %{server: server} = start_session!()

    assert {:ok, %{status: "started"}} =
             SessionServer.user_message(server, user_message("msg-1", "prepare session"))

    wait_until(fn -> :sys.get_state(server).coordinator_tasks == %{} end)

    assert {:ok, %{agent: %{status: "completed"}, output: output}} =
             SessionServer.spawn_agent(server, %{
               "name" => "foreground",
               "briefing" => "answer from foreground"
             })

    assert is_binary(output)
  end

  test "queues messages to running agents and rejects duplicate names" do
    %{server: server} = start_session!()

    assert {:ok, %{status: "started"}} =
             SessionServer.user_message(server, user_message("msg-1", "prepare session"))

    wait_until(fn -> :sys.get_state(server).coordinator_tasks == %{} end)

    assert {:ok, %{agent_id: agent_id}} =
             SessionServer.spawn_agent(server, %{
               "name" => "worker",
               "briefing" => "answer from worker",
               "background" => true
             })

    assert {:error, reason} =
             SessionServer.spawn_agent(server, %{
               "name" => "worker",
               "briefing" => "duplicate",
               "background" => true
             })

    assert reason =~ "already exists"

    wait_until(fn ->
      %{agents: agents} = :sys.get_state(server)
      agents[agent_id].status == :completed
    end)
  end

  defp start_session! do
    session_id = "session-#{System.unique_integer([:positive])}"

    session_dir =
      Path.join(
        System.tmp_dir!(),
        "agent-machine-session-server-test-#{System.unique_integer([:positive])}"
      )

    {:ok, output} = StringIO.open("")
    {:ok, writer} = SessionWriter.start_link(output: output)
    {:ok, control} = PermissionControl.start_link(input: false)

    {:ok, server} =
      AgentMachine.SessionSupervisor.start_session(
        session_id: session_id,
        session_dir: session_dir,
        writer: writer,
        permission_control: control
      )

    %{server: server, output: output, session_dir: session_dir, session_id: session_id}
  end

  defp user_message(message_id, task, run_overrides \\ []) do
    run =
      %{
        task: task,
        workflow: :chat,
        provider: :echo,
        timeout_ms: 10_000,
        max_steps: 1,
        max_attempts: 1,
        stream_response: false
      }
      |> Map.merge(Map.new(run_overrides))

    %{
      type: :user_message,
      message_id: message_id,
      run: run,
      session_tool_opts: %{timeout_ms: 10_000, max_rounds: 4}
    }
  end

  defp tmp_dir!(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end

  defp last_summary(output) do
    wait_until(fn -> Enum.any?(jsonl_entries(output), &(&1["type"] == "summary")) end)

    output
    |> jsonl_entries()
    |> Enum.filter(&(&1["type"] == "summary"))
    |> List.last()
    |> Map.fetch!("summary")
  end

  defp output_event?(output, type) do
    Enum.any?(jsonl_entries(output), fn
      %{"type" => "event", "event" => %{"type" => ^type}} -> true
      _entry -> false
    end)
  end

  defp jsonl_entries(output) do
    output
    |> StringIO.contents()
    |> elem(1)
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
  end

  defp wait_until(callback, attempts \\ 100)

  defp wait_until(callback, attempts) when attempts > 0 do
    if callback.() do
      :ok
    else
      Process.sleep(10)
      wait_until(callback, attempts - 1)
    end
  end

  defp wait_until(_callback, 0), do: flunk("condition was not met before timeout")
end
