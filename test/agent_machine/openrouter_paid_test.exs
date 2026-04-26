defmodule AgentMachine.OpenRouterPaidTest do
  use ExUnit.Case, async: false

  alias AgentMachine.{Agent, ClientRunner, Providers.OpenRouterChat}

  @moduletag :paid_openrouter
  @model "stepfun/step-3.5-flash"
  @pricing %{input_per_million: 0.0, output_per_million: 0.0}

  setup_all do
    case System.fetch_env("OPENROUTER_API_KEY") do
      {:ok, key} when byte_size(key) > 0 ->
        :ok

      _missing ->
        flunk("OPENROUTER_API_KEY is required for paid OpenRouter integration tests")
    end
  end

  test "OpenRouter Step 3.5 Flash returns a provider response" do
    agent =
      Agent.new!(%{
        id: "openrouter-paid-provider",
        provider: OpenRouterChat,
        model: @model,
        pricing: @pricing,
        instructions:
          "Reply with one short sentence. Do not call tools. Include the word AgentMachine.",
        input: "Say that this paid OpenRouter integration test is working."
      })

    assert {:ok, payload} =
             OpenRouterChat.complete(agent,
               http_timeout_ms: 120_000,
               run_context: empty_run_context()
             )

    assert is_binary(payload.output)
    assert String.trim(payload.output) != ""
    assert payload.usage.total_tokens > 0
    assert payload.usage.input_tokens > 0
  end

  test "ClientRunner completes a basic run through OpenRouter Step 3.5 Flash" do
    summary =
      ClientRunner.run!(%{
        task: "Reply with one concise sentence that includes AgentMachine.",
        workflow: :basic,
        provider: :openrouter,
        model: @model,
        timeout_ms: 120_000,
        max_steps: 2,
        max_attempts: 1,
        http_timeout_ms: 120_000,
        pricing: @pricing
      })

    assert summary.status == "completed"
    assert is_binary(summary.final_output)
    assert String.trim(summary.final_output) != ""
    assert summary.usage.total_tokens > 0
    assert Enum.any?(summary.events, &(&1.type == "run_completed"))
  end

  defp empty_run_context do
    %{
      run_id: "paid-openrouter-test",
      agent_id: "openrouter-paid-provider",
      parent_agent_id: nil,
      attempt: 1,
      results: %{},
      artifacts: %{}
    }
  end
end
