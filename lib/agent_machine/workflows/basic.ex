defmodule AgentMachine.Workflows.Basic do
  @moduledoc """
  Basic high-level workflow for client applications.

  The workflow starts one assistant agent and then runs a finalizer. It keeps the
  first client experience small while still exercising the runtime's run context,
  finalizer, usage, events, and retry paths.
  """

  alias AgentMachine.{RunSpec, WorkflowOptions, WorkflowProvider, WorkflowToolOptions}

  def build!(%RunSpec{} = spec) do
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

    finalizer = %{
      id: "finalizer",
      provider: provider,
      model: WorkflowProvider.model(spec),
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
        finalizer: finalizer,
        stream_response: spec.stream_response
      ]
      |> WorkflowProvider.put_http_opts(spec)
      |> WorkflowToolOptions.put_full_tool_opts(spec)
      |> WorkflowOptions.put_context_opts(spec)

    {agents, opts}
  end

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
    If an earlier agent has status "error", do not say the task completed or is ready unless later run context explicitly proves recovery.
    Do not call tools. Summarize only the run context.
    """
    |> String.trim()
  end
end
