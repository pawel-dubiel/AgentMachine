defmodule AgentMachine.SessionTranscriptTest do
  use ExUnit.Case, async: true

  alias AgentMachine.SessionTranscript

  test "appends and loads strict JSONL records" do
    dir = tmp_dir()

    SessionTranscript.append_agent!(dir, "session-1", "agent-1", %{
      type: "user_message",
      message: "hello"
    })

    assert [
             %{
               "type" => "user_message",
               "message" => "hello",
               "at" => at
             }
           ] = SessionTranscript.load_agent!(dir, "session-1", "agent-1")

    assert is_binary(at)
  end

  test "rejects corrupt transcript lines" do
    dir = tmp_dir()
    path = SessionTranscript.agent_path(dir, "session-1", "agent-1")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "not-json\n")

    assert_raise ArgumentError, ~r/invalid transcript/, fn ->
      SessionTranscript.load_agent!(dir, "session-1", "agent-1")
    end
  end

  test "redacts records before persisting" do
    dir = tmp_dir()

    SessionTranscript.append_agent!(dir, "session-1", "agent-1", %{
      type: "assistant_message",
      output: "OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz"
    })

    [record] = SessionTranscript.load_agent!(dir, "session-1", "agent-1")
    assert record["output"] =~ "[REDACTED:"
  end

  test "rejects session ids that would escape the session directory" do
    session_dir = tmp_dir()
    outside_dir = tmp_dir()
    malicious_session_id = "../#{Path.basename(outside_dir)}"

    assert_raise ArgumentError, ~r/session_id/, fn ->
      SessionTranscript.append_session!(session_dir, malicious_session_id, %{
        type: "metadata",
        event: "poc"
      })
    end

    refute File.exists?(Path.join(outside_dir, "context.jsonl"))
  end

  test "rejects agent ids that are not safe path segments" do
    assert_raise ArgumentError, ~r/agent_id/, fn ->
      SessionTranscript.agent_path(tmp_dir(), "session-1", "../agent-1")
    end
  end

  defp tmp_dir do
    Path.join(
      System.tmp_dir!(),
      "agent-machine-session-test-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    )
  end
end
