defmodule AgentMachine.ProviderToolContinuationTest do
  use ExUnit.Case, async: true

  alias AgentMachine.Agent
  alias AgentMachine.Providers.{OpenAIResponses, OpenRouterChat}

  defp agent do
    Agent.new!(%{
      id: "assistant",
      provider: OpenRouterChat,
      model: "test-model",
      instructions: "Use tools when needed.",
      input: "write a file",
      pricing: %{input_per_million: 0.0, output_per_million: 0.0}
    })
  end

  defp run_context do
    %{
      run_id: "run-provider-budget",
      agent_id: "assistant",
      results: %{"planner" => %{status: :ok, output: "plan output"}},
      artifacts: %{plan: "artifact"}
    }
  end

  test "OpenRouter continuation appends tool result messages and resends tools" do
    state = %{
      messages: [
        %{"role" => "system", "content" => "Use tools when needed."},
        %{"role" => "user", "content" => "write a file"},
        %{
          "role" => "assistant",
          "content" => nil,
          "tool_calls" => [
            %{"id" => "call-1", "function" => %{"name" => "now", "arguments" => "{}"}}
          ]
        }
      ]
    }

    body =
      OpenRouterChat.request_body_for_test!(agent(),
        allowed_tools: [AgentMachine.Tools.Now],
        tool_continuation: %{state: state, results: [%{id: "call-1", result: %{ok: true}}]}
      )

    assert %{"role" => "tool", "tool_call_id" => "call-1", "content" => "{\"ok\":true}"} =
             List.last(body["messages"])

    assert [%{"type" => "function", "function" => %{"name" => "now"}}] = body["tools"]
  end

  test "OpenAI continuation sends function_call_output with previous response id and resends tools" do
    body =
      OpenAIResponses.request_body_for_test!(%{agent() | provider: OpenAIResponses},
        allowed_tools: [AgentMachine.Tools.Now],
        tool_continuation: %{
          state: %{response_id: "resp-1"},
          results: [%{id: "call-1", result: %{ok: true}}]
        }
      )

    assert body["previous_response_id"] == "resp-1"

    assert [
             %{
               "type" => "function_call_output",
               "call_id" => "call-1",
               "output" => "{\"ok\":true}"
             }
           ] = body["input"]

    assert [%{"type" => "function", "name" => "now"}] = body["tools"]
    assert body["instructions"] == "Use tools when needed."
  end

  test "OpenRouter budget request uses the provider request body and separates components" do
    opts = [
      run_context: run_context(),
      runtime_facts: false,
      allowed_tools: [AgentMachine.Tools.Now],
      tool_policy: AgentMachine.ToolHarness.builtin_policy!(:time),
      tool_approval_mode: :read_only
    ]

    assert {:ok, budget} = OpenRouterChat.context_budget_request_for_test!(agent(), opts)
    assert budget.provider == :openrouter_chat
    assert budget.request == OpenRouterChat.request_body_for_test!(agent(), opts)
    assert budget.breakdown.instructions == "Use tools when needed."
    assert budget.breakdown.task_input == "write a file"
    assert budget.breakdown.run_context =~ "plan output"
    assert [%{"type" => "function", "function" => %{"name" => "now"}}] = budget.breakdown.tools
    assert budget.breakdown.mcp_tools == []
  end

  test "OpenAI budget request uses the provider request body and separates components" do
    agent = %{agent() | provider: OpenAIResponses}

    opts = [
      run_context: run_context(),
      runtime_facts: false,
      allowed_tools: [AgentMachine.Tools.Now],
      tool_policy: AgentMachine.ToolHarness.builtin_policy!(:time),
      tool_approval_mode: :read_only
    ]

    assert {:ok, budget} = OpenAIResponses.context_budget_request_for_test!(agent, opts)
    assert budget.provider == :openai_responses
    assert budget.request == OpenAIResponses.request_body_for_test!(agent, opts)
    assert budget.breakdown.instructions == "Use tools when needed."
    assert budget.breakdown.task_input == "write a file"
    assert budget.breakdown.run_context =~ "plan output"
    assert [%{"type" => "function", "name" => "now"}] = budget.breakdown.tools
    assert budget.breakdown.mcp_tools == []
  end

  test "provider budget continuation components match continuation payloads" do
    openrouter_state = %{
      messages: [%{"role" => "user", "content" => "write a file"}]
    }

    continuation = %{state: openrouter_state, results: [%{id: "call-1", result: %{ok: true}}]}

    assert {:ok, budget} =
             OpenRouterChat.context_budget_request_for_test!(agent(),
               allowed_tools: [AgentMachine.Tools.Now],
               tool_continuation: continuation
             )

    assert budget.breakdown.tool_continuation == budget.request["messages"]

    openai_agent = %{agent() | provider: OpenAIResponses}

    openai_continuation = %{
      state: %{response_id: "resp-1"},
      results: [%{id: "call-1", result: %{ok: true}}]
    }

    assert {:ok, budget} =
             OpenAIResponses.context_budget_request_for_test!(openai_agent,
               allowed_tools: [AgentMachine.Tools.Now],
               tool_continuation: openai_continuation
             )

    assert budget.breakdown.tool_continuation == budget.request["input"]
  end
end
