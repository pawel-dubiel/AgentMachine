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
      |> put_openai_opts(spec)

    {agents, opts}
  end

  defp provider_module(%RunSpec{provider: :echo}), do: AgentMachine.Providers.Echo
  defp provider_module(%RunSpec{provider: :openai}), do: AgentMachine.Providers.OpenAIResponses

  defp model(%RunSpec{provider: :echo}), do: "echo"
  defp model(%RunSpec{provider: :openai, model: model}), do: model

  defp pricing(%RunSpec{provider: :echo}) do
    %{input_per_million: 0.0, output_per_million: 0.0}
  end

  defp pricing(%RunSpec{provider: :openai, pricing: pricing}), do: pricing

  defp put_openai_opts(opts, %RunSpec{provider: :echo}), do: opts

  defp put_openai_opts(opts, %RunSpec{provider: :openai, http_timeout_ms: http_timeout_ms}) do
    Keyword.put(opts, :http_timeout_ms, http_timeout_ms)
  end

  defp assistant_instructions do
    "Answer the user's task directly. Keep the response concise and actionable."
  end

  defp finalizer_instructions do
    "Create the final user-facing answer from the completed run context."
  end
end
