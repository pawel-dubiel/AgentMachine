defmodule AgentMachine.Workflows.Chat do
  @moduledoc """
  Minimal no-tool workflow for direct conversational responses.
  """

  alias AgentMachine.{RunSpec, WorkflowOptions, WorkflowProvider}

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
      |> WorkflowProvider.put_http_opts(spec)
      |> WorkflowOptions.put_context_opts(spec)

    {agents, opts}
  end

  defp assistant_instructions do
    """
    You are the assistant running inside AgentMachine.
    Answer the user's message directly and concisely.
    AgentMachine can route concrete tasks through chat, read-only tool, or agentic workflows. In agentic workflow, a planner can delegate worker agents and the Elixir runtime starts them.
    In this chat workflow, you do not have tools, workers, or side effects.
    Do not claim that AgentMachine cannot use agents. If the user asks whether agents can be spawned, explain that concrete "use agents to do X" requests can be routed through agentic workflow, while this chat route cannot manually spawn arbitrary workers.
    Do not claim that you inspected files, used tools, changed state, or performed external side effects.
    If the request requires local files, tools, commands, or external side effects, say that this chat run cannot perform it.
    """
    |> String.trim()
  end
end
