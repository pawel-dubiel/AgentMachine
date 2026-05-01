defmodule AgentMachine.LLMRouterTest do
  use ExUnit.Case, async: false

  alias AgentMachine.{JSON, LLMRouter}
  alias AgentMachine.Providers.OpenRouterChat

  defmodule ValidProvider do
    def complete(agent, opts) do
      send(self(), {:router_provider_called, agent, opts})

      {:ok,
       %{
         output:
           JSON.encode!(%{
             intent: "file_mutation",
             confidence: 0.87,
             reason: "local file creation"
           }),
         usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}
       }}
    end
  end

  defmodule ProviderContractProvider do
    def complete(agent, opts) do
      OpenRouterChat.request_body_for_test!(agent, opts)

      {:ok,
       %{
         output:
           JSON.encode!(%{
             intent: "file_mutation",
             confidence: 0.82,
             reason: "provider contract satisfied"
           }),
         usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}
       }}
    end
  end

  defmodule MalformedJSONProvider do
    def complete(_agent, _opts) do
      {:ok, %{output: "not json", usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}}}
    end
  end

  defmodule InvalidIntentProvider do
    def complete(_agent, _opts) do
      {:ok,
       %{
         output:
           JSON.encode!(%{
             intent: "not_real",
             confidence: 0.9,
             reason: "bad intent"
           }),
         usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}
       }}
    end
  end

  defmodule InvalidConfidenceProvider do
    def complete(_agent, _opts) do
      {:ok,
       %{
         output:
           JSON.encode!(%{
             intent: "file_mutation",
             confidence: 1.5,
             reason: "bad confidence"
           }),
         usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}
       }}
    end
  end

  defmodule MissingReasonProvider do
    def complete(_agent, _opts) do
      {:ok,
       %{
         output: JSON.encode!(%{intent: "file_mutation", confidence: 0.9}),
         usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}
       }}
    end
  end

  defmodule ErrorProvider do
    def complete(_agent, _opts), do: {:error, :boom}
  end

  test "classifies strict provider JSON into workflow classifier shape" do
    result = LLMRouter.classify!(input(ValidProvider))

    assert result == %{
             intent: :file_mutation,
             classified_intent: :file_mutation,
             classifier: "llm",
             classifier_model: "test-router-model",
             confidence: 0.87,
             reason: "local file creation"
           }
  end

  test "calls providers with the normal empty run context contract" do
    result = LLMRouter.classify!(input(ProviderContractProvider))

    assert result.intent == :file_mutation
    assert result.reason == "provider contract satisfied"
  end

  test "fails fast on malformed provider JSON" do
    assert_raise ArgumentError, ~r/llm router invalid JSON response/, fn ->
      LLMRouter.classify!(input(MalformedJSONProvider))
    end
  end

  test "fails fast on invalid intent" do
    assert_raise ArgumentError, ~r/invalid intent/, fn ->
      LLMRouter.classify!(input(InvalidIntentProvider))
    end
  end

  test "fails fast on invalid confidence" do
    assert_raise ArgumentError, ~r/confidence/, fn ->
      LLMRouter.classify!(input(InvalidConfidenceProvider))
    end
  end

  test "fails fast on missing reason" do
    assert_raise ArgumentError, ~r/missing \"reason\"/, fn ->
      LLMRouter.classify!(input(MissingReasonProvider))
    end
  end

  test "fails fast on provider errors" do
    assert_raise ArgumentError, ~r/provider failed: :boom/, fn ->
      LLMRouter.classify!(input(ErrorProvider))
    end
  end

  test "fails fast when the run provider cannot support LLM routing" do
    assert_raise ArgumentError, ~r/does not support provider :echo/, fn ->
      LLMRouter.classify!(input(:echo))
    end
  end

  defp input(provider) do
    %{
      task: "create a file",
      provider: provider,
      model: "test-router-model",
      pricing: %{input_per_million: 0.0, output_per_million: 0.0},
      http_timeout_ms: 1_000
    }
  end
end
