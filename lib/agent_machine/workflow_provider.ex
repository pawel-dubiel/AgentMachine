defmodule AgentMachine.WorkflowProvider do
  @moduledoc false

  alias AgentMachine.RunSpec

  def provider_module(%RunSpec{provider: :echo}), do: AgentMachine.Providers.Echo
  def provider_module(%RunSpec{provider: :openai}), do: AgentMachine.Providers.OpenAIResponses
  def provider_module(%RunSpec{provider: :openrouter}), do: AgentMachine.Providers.OpenRouterChat

  def provider_module(spec) do
    raise ArgumentError, "workflow provider requires a RunSpec, got: #{inspect(spec)}"
  end

  def model(%RunSpec{provider: :echo}), do: "echo"

  def model(%RunSpec{provider: provider, model: model})
      when provider in [:openai, :openrouter] do
    model
  end

  def model(spec) do
    raise ArgumentError, "workflow provider requires a RunSpec, got: #{inspect(spec)}"
  end

  def pricing(%RunSpec{provider: :echo}) do
    %{input_per_million: 0.0, output_per_million: 0.0}
  end

  def pricing(%RunSpec{provider: provider, pricing: pricing})
      when provider in [:openai, :openrouter] do
    pricing
  end

  def pricing(spec) do
    raise ArgumentError, "workflow provider requires a RunSpec, got: #{inspect(spec)}"
  end

  def put_http_opts(opts, %RunSpec{provider: :echo}) when is_list(opts), do: opts

  def put_http_opts(opts, %RunSpec{provider: provider, http_timeout_ms: http_timeout_ms})
      when is_list(opts) and provider in [:openai, :openrouter] do
    Keyword.put(opts, :http_timeout_ms, http_timeout_ms)
  end

  def put_http_opts(opts, spec) do
    raise ArgumentError,
          "workflow provider requires keyword opts and a RunSpec, got: #{inspect({opts, spec})}"
  end
end
