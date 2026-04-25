defmodule AgentMachine.Workflows.Agentic do
  @moduledoc """
  Planner-to-workers workflow for client applications.

  The workflow keeps delegation explicit: the planner may return structured
  `next_agents`, the orchestrator runs those agents, and the finalizer produces
  the user-facing result after all other agents complete.
  """

  alias AgentMachine.RunSpec

  def build!(%RunSpec{} = spec) do
    provider = provider_module(spec)
    pricing = pricing(spec)

    planner = %{
      id: "planner",
      provider: provider,
      model: model(spec),
      instructions: planner_instructions(),
      input: spec.task,
      pricing: pricing,
      metadata: %{agent_machine_response: "delegation"}
    }

    finalizer = %{
      id: "finalizer",
      provider: provider,
      model: model(spec),
      instructions: finalizer_instructions(),
      input: "Create the final answer for this task: #{spec.task}",
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
      |> put_tool_opts(spec)

    {[planner], opts}
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
         %RunSpec{tool_harness: harness, tool_timeout_ms: tool_timeout_ms} = spec
       ) do
    opts
    |> Keyword.put(:allowed_tools, AgentMachine.ToolHarness.builtin!(harness))
    |> Keyword.put(:tool_timeout_ms, tool_timeout_ms)
    |> maybe_put_tool_root(harness, spec)
  end

  defp maybe_put_tool_root(opts, :local_files, %RunSpec{tool_root: root}) do
    Keyword.put(opts, :tool_root, root)
  end

  defp maybe_put_tool_root(opts, _harness, _spec), do: opts

  defp planner_instructions do
    """
    You are the planning agent for AgentMachine.

    Decide whether the task needs worker agents. Return only JSON with this shape:
    {"output":"short planning note","next_agents":[{"id":"worker-id","input":"worker task","instructions":"optional worker instructions"}]}

    Use an empty next_agents list when no split is useful. Keep worker ids short, lowercase, and unique.
    If the task needs external side effects such as writing files, delegate that exact action to a worker and require it to use available tools.
    Do not claim side effects happened unless tool_results confirm them.
    """
    |> String.trim()
  end

  defp finalizer_instructions do
    """
    Create the final user-facing answer from the completed run context.
    Use worker outputs when they exist. Do not delegate follow-up agents.
    Only report side effects that are present in prior results or tool_results.
    """
    |> String.trim()
  end
end
