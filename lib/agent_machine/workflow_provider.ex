defmodule AgentMachine.WorkflowProvider do
  @moduledoc false

  alias AgentMachine.RunSpec

  def provider_module(%RunSpec{provider: :echo}), do: AgentMachine.Providers.Echo

  def provider_module(%RunSpec{provider: provider}) when is_binary(provider),
    do: AgentMachine.Providers.ReqLLM

  def provider_module(spec) do
    raise ArgumentError, "workflow provider requires a RunSpec, got: #{inspect(spec)}"
  end

  def model(%RunSpec{provider: :echo}), do: "echo"

  def model(%RunSpec{provider: provider, model: model})
      when is_binary(provider) and is_binary(model) do
    provider <> ":" <> model
  end

  def model(spec) do
    raise ArgumentError, "workflow provider requires a RunSpec, got: #{inspect(spec)}"
  end

  def pricing(%RunSpec{provider: :echo}) do
    %{input_per_million: 0.0, output_per_million: 0.0}
  end

  def pricing(%RunSpec{provider: provider, pricing: pricing})
      when is_binary(provider) do
    pricing
  end

  def pricing(spec) do
    raise ArgumentError, "workflow provider requires a RunSpec, got: #{inspect(spec)}"
  end

  def put_http_opts(opts, %RunSpec{provider: :echo}) when is_list(opts), do: opts

  def put_http_opts(opts, %RunSpec{
        provider: provider,
        http_timeout_ms: http_timeout_ms,
        provider_options: provider_options
      })
      when is_list(opts) and is_binary(provider) do
    opts
    |> Keyword.put(:http_timeout_ms, http_timeout_ms)
    |> Keyword.put(:provider_options, provider_options || %{})
  end

  def put_http_opts(opts, spec) do
    raise ArgumentError,
          "workflow provider requires keyword opts and a RunSpec, got: #{inspect({opts, spec})}"
  end
end
