defmodule AgentMachine.WorkflowProviderTest do
  use ExUnit.Case, async: true

  alias AgentMachine.{RunSpec, WorkflowProvider}

  test "returns echo provider runtime values without HTTP options" do
    spec =
      RunSpec.new!(%{
        task: "hello",
        workflow: :chat,
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 1,
        max_attempts: 1
      })

    assert WorkflowProvider.provider_module(spec) == AgentMachine.Providers.Echo
    assert WorkflowProvider.model(spec) == "echo"
    assert WorkflowProvider.pricing(spec) == %{input_per_million: 0.0, output_per_million: 0.0}
    assert WorkflowProvider.put_http_opts([timeout: 1_000], spec) == [timeout: 1_000]
  end

  test "returns OpenRouter runtime values and explicit HTTP option" do
    pricing = %{input_per_million: 0.15, output_per_million: 0.60}

    spec =
      RunSpec.new!(%{
        task: "hello",
        workflow: :basic,
        provider: :openrouter,
        model: "openai/gpt-4o-mini",
        timeout_ms: 1_000,
        max_steps: 2,
        max_attempts: 1,
        http_timeout_ms: 25_000,
        pricing: pricing
      })

    assert WorkflowProvider.provider_module(spec) == AgentMachine.Providers.OpenRouterChat
    assert WorkflowProvider.model(spec) == "openai/gpt-4o-mini"
    assert WorkflowProvider.pricing(spec) == pricing

    assert WorkflowProvider.put_http_opts([timeout: 1_000], spec) == [
             http_timeout_ms: 25_000,
             timeout: 1_000
           ]
  end

  test "fails fast for invalid input" do
    assert_raise ArgumentError, ~r/workflow provider requires a RunSpec/, fn ->
      WorkflowProvider.provider_module(%{})
    end
  end
end
