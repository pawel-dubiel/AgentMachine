defmodule AgentMachine.WorkflowProviderTest do
  use ExUnit.Case, async: true

  alias AgentMachine.{RunSpec, WorkflowProvider}

  test "returns echo provider runtime values without HTTP options" do
    spec =
      RunSpec.new!(%{
        task: "hello",
        workflow: :agentic,
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

  test "returns ReqLLM runtime values and explicit HTTP/provider options" do
    pricing = %{input_per_million: 0.15, output_per_million: 0.60}
    provider_options = %{"project_id" => "project-1", "region" => "us-central1"}

    spec =
      RunSpec.new!(%{
        task: "hello",
        workflow: :agentic,
        provider: "google_vertex",
        model: "openai/gpt-4o-mini",
        timeout_ms: 1_000,
        max_steps: 2,
        max_attempts: 1,
        http_timeout_ms: 25_000,
        pricing: pricing,
        provider_options: provider_options
      })

    assert WorkflowProvider.provider_module(spec) == AgentMachine.Providers.ReqLLM
    assert WorkflowProvider.model(spec) == "google_vertex:openai/gpt-4o-mini"
    assert WorkflowProvider.pricing(spec) == pricing

    assert WorkflowProvider.put_http_opts([timeout: 1_000], spec) == [
             provider_options: provider_options,
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
