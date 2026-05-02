defmodule AgentMachine.Workflows.Tool do
  @moduledoc """
  Internal auto-selected workflow for single-agent read-only tool requests.
  """

  alias AgentMachine.{RunSpec, WorkflowOptions, WorkflowProvider, WorkflowToolOptions}

  def build!(%RunSpec{} = spec, %{tool_intent: intent}) do
    provider = WorkflowProvider.provider_module(spec)
    pricing = WorkflowProvider.pricing(spec)

    agents = [
      %{
        id: "assistant",
        provider: provider,
        model: WorkflowProvider.model(spec),
        instructions: assistant_instructions(),
        input: spec.task,
        pricing: pricing
      }
    ]

    opts =
      [
        timeout: spec.timeout_ms,
        max_steps: spec.max_steps,
        max_attempts: spec.max_attempts,
        stream_response: spec.stream_response
      ]
      |> WorkflowProvider.put_http_opts(spec)
      |> WorkflowToolOptions.put_read_only_tool_opts(spec, intent)
      |> WorkflowOptions.put_context_opts(spec)

    {agents, opts}
  end

  def build!(%RunSpec{}, route) do
    raise ArgumentError, "tool workflow route must include :tool_intent, got: #{inspect(route)}"
  end

  defp assistant_instructions do
    """
    Answer the user's task directly and concisely.
    Use only the available read-only tools needed to answer.
    Do not claim that you wrote, changed, deleted, patched, or executed anything.
    If the available read-only tools cannot answer the request, say what is missing.
    """
    |> String.trim()
  end
end
