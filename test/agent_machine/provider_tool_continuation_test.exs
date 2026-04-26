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
end
