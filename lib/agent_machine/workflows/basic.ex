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
      pricing: pricing,
      metadata: %{agent_machine_disable_tools: true}
    }

    opts =
      [
        timeout: spec.timeout_ms,
        max_steps: spec.max_steps,
        max_attempts: spec.max_attempts,
        finalizer: finalizer
      ]
      |> put_http_opts(spec)
      |> put_tool_opts(spec)

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

  defp put_tool_opts(opts, %RunSpec{tool_harness: nil}), do: opts

  defp put_tool_opts(
         opts,
         %RunSpec{
           tool_harness: harness,
           tool_timeout_ms: tool_timeout_ms,
           tool_max_rounds: tool_max_rounds,
           tool_approval_mode: tool_approval_mode
         } = spec
       ) do
    opts
    |> Keyword.put(:allowed_tools, AgentMachine.ToolHarness.builtin!(harness))
    |> Keyword.put(:tool_policy, AgentMachine.ToolHarness.builtin_policy!(harness))
    |> Keyword.put(:tool_timeout_ms, tool_timeout_ms)
    |> Keyword.put(:tool_max_rounds, tool_max_rounds)
    |> Keyword.put(:tool_approval_mode, tool_approval_mode)
    |> maybe_put_tool_root(harness, spec)
  end

  defp maybe_put_tool_root(opts, harness, %RunSpec{tool_root: root})
       when harness in [:local_files, :code_edit] do
    Keyword.put(opts, :tool_root, root)
  end

  defp maybe_put_tool_root(opts, _harness, _spec), do: opts

  defp assistant_instructions do
    """
    Answer the user's task directly. Keep the response concise and actionable.
    If a task requires external side effects such as writing files, use an available tool.
    Do not claim that you created, changed, read, or deleted a file unless a tool result proves it.
    If no relevant tool is available, say that you cannot perform that action in this run.
    """
    |> String.trim()
  end

  defp finalizer_instructions do
    """
    Create the final user-facing answer from the completed run context.
    Only report side effects that are present in prior results or tool_results.
    Do not claim that files were created or changed unless a tool result confirms it.
    Do not call tools. Summarize only the run context.
    """
    |> String.trim()
  end
end
