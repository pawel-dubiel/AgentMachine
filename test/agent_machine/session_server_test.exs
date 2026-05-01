defmodule AgentMachine.SessionServerTest do
  use ExUnit.Case, async: false

  alias AgentMachine.{PermissionControl, SessionServer, SessionWriter}

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

    %{server: server, output: output}
  end

  defp user_message(message_id, task) do
    %{
      type: :user_message,
      message_id: message_id,
      run: %{
        task: task,
        workflow: :chat,
        provider: :echo,
        timeout_ms: 10_000,
        max_steps: 1,
        max_attempts: 1,
        stream_response: false
      },
      session_tool_opts: %{timeout_ms: 10_000, max_rounds: 4}
    }
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
