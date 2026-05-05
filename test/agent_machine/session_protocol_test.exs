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
          recent_context: "user created mdp1; assistant confirmed completion",
          pending_action: "continue work inside mdp1",
          workflow: "agentic",
          provider: "echo",
          log_file: "/tmp/agent-machine-run.jsonl",
          timeout_ms: 1_000,
          max_steps: 6,
          max_attempts: 1,
          agentic_persistence_rounds: 2,
          planner_review_mode: "jsonl-stdio",
          planner_review_max_revisions: 2,
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
               recent_context: "user created mdp1; assistant confirmed completion",
               pending_action: "continue work inside mdp1",
               workflow: :agentic,
               provider: :echo,
               timeout_ms: 1_000,
               max_steps: 6,
               max_attempts: 1,
               agentic_persistence_rounds: 2,
               planner_review_mode: :jsonl_stdio,
               planner_review_max_revisions: 2,
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
      ~s({"type":"user_message","message_id":"msg-1","run":{"task":"hello","workflow":"agentic","provider":"echo","timeout_ms":1000,"max_steps":1,"max_attempts":1,"stream_response":true,"session_tool_timeout_ms":1000,"session_tool_max_rounds":4,"surprise":true}})

    assert_raise ArgumentError, ~r/run contains unknown key/, fn ->
      SessionProtocol.parse_command!(line)
    end
  end

  test "rejects empty structured conversation context fields" do
    line =
      ~s({"type":"user_message","message_id":"msg-1","run":{"task":"hello","recent_context":"","provider":"echo","timeout_ms":1000,"max_steps":1,"max_attempts":1,"stream_response":true,"session_tool_timeout_ms":1000,"session_tool_max_rounds":4}})

    assert_raise ArgumentError, ~r/recent_context/, fn ->
      SessionProtocol.parse_command!(line)
    end
  end

  test "rejects legacy public workflow values" do
    line =
      ~s({"type":"user_message","message_id":"msg-1","run":{"task":"hello","workflow":"basic","provider":"echo","timeout_ms":1000,"max_steps":1,"max_attempts":1,"stream_response":true,"session_tool_timeout_ms":1000,"session_tool_max_rounds":4}})

    assert_raise ArgumentError, ~r/unsupported run :workflow value/, fn ->
      SessionProtocol.parse_command!(line)
    end
  end

  test "parses remote provider ids and provider options without secrets" do
    line =
      AgentMachine.JSON.encode!(%{
        type: "user_message",
        message_id: "msg-1",
        run: %{
          task: "hello",
          workflow: "agentic",
          provider: "google_vertex",
          model: "gemini-2.5-flash",
          timeout_ms: 1_000,
          max_steps: 2,
          max_attempts: 1,
          http_timeout_ms: 1_000,
          pricing: %{"input_per_million" => 0.1, "output_per_million" => 0.2},
          provider_options: %{"project_id" => "project-1", "region" => "us-central1"},
          stream_response: false,
          session_tool_timeout_ms: 1_000,
          session_tool_max_rounds: 4
        }
      })

    assert %{
             run: %{
               provider: "google_vertex",
               provider_options: %{"project_id" => "project-1", "region" => "us-central1"},
               pricing: %{input_per_million: 0.1, output_per_million: 0.2}
             }
           } = SessionProtocol.parse_command!(line)
  end

  test "rejects provider option values that cannot be passed through the session boundary" do
    line =
      ~s({"type":"user_message","message_id":"msg-1","run":{"task":"hello","workflow":"agentic","provider":"openrouter","model":"openai/gpt-4o-mini","timeout_ms":1000,"max_steps":2,"max_attempts":1,"http_timeout_ms":1000,"pricing":{"input_per_million":0.1,"output_per_million":0.2},"provider_options":{"base_url":123},"stream_response":false,"session_tool_timeout_ms":1000,"session_tool_max_rounds":4}})

    assert_raise ArgumentError, ~r/unsupported provider_options entry/, fn ->
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

  test "parses planner review decisions without consuming them" do
    assert %{type: :planner_review_decision, line: line} =
             SessionProtocol.parse_command!(
               ~s({"type":"planner_review_decision","request_id":"req-1","decision":"approve"})
             )

    assert line =~ "planner_review_decision"
  end
end
