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
             work_shape: "mutation",
             route_hint: "agentic",
             confidence: 0.87,
             reason: "local file creation"
           }),
         usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}
       }}
    end
  end

  defmodule ProviderContractProvider do
    def complete(agent, opts) do
      body = OpenRouterChat.request_body_for_test!(agent, opts)

      if Keyword.fetch!(opts, :response_format) == %{"type" => "json_object"} and
           body["response_format"] == %{"type" => "json_object"} do
        {:ok,
         %{
           output:
             JSON.encode!(%{
               intent: "file_mutation",
               work_shape: "mutation",
               route_hint: "agentic",
               confidence: 0.82,
               reason: "provider contract satisfied"
             }),
           usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}
         }}
      else
        {:error, :missing_router_response_format}
      end
    end
  end

  defmodule MalformedJSONProvider do
    def complete(_agent, _opts) do
      {:ok, %{output: "not json", usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}}}
    end
  end

  defmodule MarkdownWrappedProvider do
    def complete(_agent, _opts) do
      {:ok,
       %{
         output: """
         **Router decision**

         ```json
         {
             "intent": "none",
             "work_shape": "conversation",
           "route_hint": "chat",
           "confidence": 0.91,
           "reason": "The user asked for a short summary of existing context."
         }
         ```
         """,
         usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}
       }}
    end
  end

  defmodule InvalidIntentProvider do
    def complete(_agent, _opts) do
      {:ok,
       %{
         output:
           JSON.encode!(%{
             intent: "not_real",
             work_shape: "mutation",
             route_hint: "agentic",
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
             work_shape: "mutation",
             route_hint: "agentic",
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
         output:
           JSON.encode!(%{
             intent: "file_mutation",
             work_shape: "mutation",
             route_hint: "agentic",
             confidence: 0.9
           }),
         usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}
       }}
    end
  end

  defmodule MissingWorkShapeProvider do
    def complete(_agent, _opts) do
      {:ok,
       %{
         output:
           JSON.encode!(%{
             intent: "file_mutation",
             route_hint: "agentic",
             confidence: 0.9,
             reason: "missing work shape"
           }),
         usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}
       }}
    end
  end

  defmodule InvalidWorkShapeProvider do
    def complete(_agent, _opts) do
      {:ok,
       %{
         output:
           JSON.encode!(%{
             intent: "file_read",
             work_shape: "large-ish",
             route_hint: "agentic",
             confidence: 0.9,
             reason: "bad work shape"
           }),
         usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}
       }}
    end
  end

  defmodule InvalidRouteHintProvider do
    def complete(_agent, _opts) do
      {:ok,
       %{
         output:
           JSON.encode!(%{
             intent: "file_read",
             work_shape: "broad_project_analysis",
             route_hint: "worker",
             confidence: 0.9,
             reason: "bad route hint"
           }),
         usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}
       }}
    end
  end

  defmodule UnknownKeyProvider do
    def complete(_agent, _opts) do
      {:ok,
       %{
         output:
           JSON.encode!(%{
             intent: "file_read",
             work_shape: "narrow_read",
             route_hint: "tool",
             confidence: 0.9,
             reason: "extra key",
             selected: "tool"
           }),
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
             work_shape: :mutation,
             route_hint: :agentic,
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

  test "fails fast on provider output without a JSON object" do
    assert_raise ArgumentError, ~r/provider returned no JSON object/, fn ->
      LLMRouter.classify!(input(MalformedJSONProvider))
    end
  end

  test "classifies markdown-wrapped provider JSON" do
    result = LLMRouter.classify!(input(MarkdownWrappedProvider))

    assert result.intent == :none
    assert result.work_shape == :conversation
    assert result.route_hint == :chat
    assert result.reason == "The user asked for a short summary of existing context."
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

  test "fails fast on missing work shape" do
    assert_raise ArgumentError, ~r/missing \"work_shape\"/, fn ->
      LLMRouter.classify!(input(MissingWorkShapeProvider))
    end
  end

  test "fails fast on invalid work shape" do
    assert_raise ArgumentError, ~r/invalid work_shape/, fn ->
      LLMRouter.classify!(input(InvalidWorkShapeProvider))
    end
  end

  test "fails fast on invalid route hint" do
    assert_raise ArgumentError, ~r/invalid route_hint/, fn ->
      LLMRouter.classify!(input(InvalidRouteHintProvider))
    end
  end

  test "fails fast on unknown response keys" do
    assert_raise ArgumentError, ~r/unknown keys/, fn ->
      LLMRouter.classify!(input(UnknownKeyProvider))
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
