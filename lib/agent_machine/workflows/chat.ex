defmodule AgentMachine.Workflows.Chat do
  @moduledoc """
  Minimal no-tool workflow for direct conversational responses.
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
        pricing: pricing,
        metadata: %{agent_machine_disable_tools: true}
      }
    ]

    opts =
      [
        timeout: spec.timeout_ms,
        max_steps: spec.max_steps,
        max_attempts: spec.max_attempts,
        stream_response: spec.stream_response
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
    """
    Answer the user's message directly and concisely.
    Do not claim that you inspected files, used tools, changed state, or performed external side effects.
    If the request requires local files, tools, commands, or external side effects, say that this chat run cannot perform it.
    """
    |> String.trim()
  end
end
