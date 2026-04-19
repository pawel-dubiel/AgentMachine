defmodule AgentMachine.Workflows.Basic do
  @moduledoc """
  Basic high-level workflow for client applications.

  The workflow starts one assistant agent and then runs a finalizer. It keeps the
  first client experience small while still exercising the runtime's run context,
  finalizer, usage, events, and retry paths.
  """

  alias AgentMachine.RunSpec

  def build!(%RunSpec{} = spec) do
    provider = provider_module(spec)
    pricing = pricing(spec)

    agents = [
      %{
        id: "assistant",
        provider: provider,
        model: model(spec),
        instructions: assistant_instructions(),
        input: spec.task,
        pricing: pricing
      }
    ]

    finalizer = %{
      id: "finalizer",
      provider: provider,
      model: model(spec),
      instructions: finalizer_instructions(),
      input: "Prepare the final answer for this task: #{spec.task}",
      pricing: pricing
    }

    opts =
      [
        timeout: spec.timeout_ms,
        max_steps: spec.max_steps,
        max_attempts: spec.max_attempts,
        finalizer: finalizer
      ]
      |> put_http_opts(spec)

    {agents, opts}
  end

  defp provider_module(%RunSpec{provider: :echo}), do: AgentMachine.Providers.Echo
  defp provider_module(%RunSpec{provider: :openai}), do: AgentMachine.Providers.OpenAIResponses
  defp provider_module(%RunSpec{provider: :openrouter}), do: AgentMachine.Providers.OpenRouterChat

  defp model(%RunSpec{provider: :echo}), do: "echo"

  defp model(%RunSpec{provider: provider, model: model})
       when provider in [:openai, :openrouter] do
    model
  end

  defp pricing(%RunSpec{provider: :echo}) do
    %{input_per_million: 0.0, output_per_million: 0.0}
  end

  defp pricing(%RunSpec{provider: provider, pricing: pricing})
       when provider in [:openai, :openrouter] do
    pricing
  end

  defp put_http_opts(opts, %RunSpec{provider: :echo}), do: opts

  defp put_http_opts(opts, %RunSpec{provider: provider, http_timeout_ms: http_timeout_ms})
       when provider in [:openai, :openrouter] do
    Keyword.put(opts, :http_timeout_ms, http_timeout_ms)
  end

  defp assistant_instructions do
    "Answer the user's task directly. Keep the response concise and actionable."
  end

  defp finalizer_instructions do
    "Create the final user-facing answer from the completed run context."
  end
end
