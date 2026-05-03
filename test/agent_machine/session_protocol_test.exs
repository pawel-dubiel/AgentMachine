defmodule AgentMachine.SessionProtocolTest do
  use ExUnit.Case, async: true

  alias AgentMachine.SessionProtocol

  test "parses user_message commands into explicit run attrs" do
    line =
      AgentMachine.JSON.encode!(%{
        type: "user_message",
        message_id: "msg-1",
        run: %{
          task: "hello",
          workflow: "agentic",
          provider: "echo",
          log_file: "/tmp/agent-machine-run.jsonl",
          timeout_ms: 1_000,
          max_steps: 6,
          max_attempts: 1,
          agentic_persistence_rounds: 2,
          router_mode: "llm",
          stream_response: true,
          progress_observer: true,
          session_tool_timeout_ms: 1_000,
          session_tool_max_rounds: 4
        }
      })

    assert %{
             type: :user_message,
             message_id: "msg-1",
             run: %{
               task: "hello",
               workflow: :agentic,
               provider: :echo,
               timeout_ms: 1_000,
               max_steps: 6,
               max_attempts: 1,
               agentic_persistence_rounds: 2,
               router_mode: :llm,
               stream_response: true,
               progress_observer: true
             },
             log_file: "/tmp/agent-machine-run.jsonl",
             session_tool_opts: %{timeout_ms: 1_000, max_rounds: 4}
           } = SessionProtocol.parse_command!(line)

    refute Map.has_key?(SessionProtocol.parse_command!(line).run, :log_file)
  end

  test "rejects unknown run keys" do
    line =
      ~s({"type":"user_message","message_id":"msg-1","run":{"task":"hello","workflow":"chat","provider":"echo","timeout_ms":1000,"max_steps":1,"max_attempts":1,"stream_response":true,"session_tool_timeout_ms":1000,"session_tool_max_rounds":4,"surprise":true}})

    assert_raise ArgumentError, ~r/run contains unknown key/, fn ->
      SessionProtocol.parse_command!(line)
    end
  end

  test "parses permission decisions without consuming them" do
    assert %{type: :permission_decision, line: line} =
             SessionProtocol.parse_command!(
               ~s({"type":"permission_decision","request_id":"req-1","decision":"approve"})
             )

    assert line =~ "permission_decision"
  end
end
