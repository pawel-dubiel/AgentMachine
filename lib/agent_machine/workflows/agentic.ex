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
      metadata: %{agent_machine_response: "delegation", agent_machine_disable_tools: true}
    }

    finalizer = %{
      id: "finalizer",
      provider: provider,
      model: model(spec),
      instructions: finalizer_instructions(),
      input: "Create the final answer for this task: #{spec.task}",
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

  defp put_tool_opts(opts, %RunSpec{tool_harnesses: nil}), do: opts

  defp put_tool_opts(
         opts,
         %RunSpec{
           tool_harnesses: harnesses,
           tool_timeout_ms: tool_timeout_ms,
           tool_max_rounds: tool_max_rounds,
           tool_approval_mode: tool_approval_mode
         } = spec
       ) do
    opts
    |> Keyword.put(
      :allowed_tools,
      AgentMachine.ToolHarness.builtin_many!(harnesses, tool_harness_opts(spec))
    )
    |> Keyword.put(
      :tool_policy,
      AgentMachine.ToolHarness.builtin_policy_many!(harnesses, tool_harness_opts(spec))
    )
    |> Keyword.put(:tool_timeout_ms, tool_timeout_ms)
    |> Keyword.put(:tool_max_rounds, tool_max_rounds)
    |> Keyword.put(:tool_approval_mode, tool_approval_mode)
    |> maybe_put_tool_root(harnesses, spec)
    |> maybe_put_test_commands(spec)
    |> maybe_put_mcp_config(spec)
  end

  defp tool_harness_opts(%RunSpec{
         test_commands: test_commands,
         mcp_config: mcp_config,
         allow_skill_scripts: allow_skill_scripts
       }),
       do: [
         test_commands: test_commands,
         mcp_config: mcp_config,
         allow_skill_scripts: allow_skill_scripts
       ]

  defp maybe_put_tool_root(opts, harnesses, %RunSpec{tool_root: root})
       when is_list(harnesses) do
    if Enum.any?(harnesses, &(&1 in [:local_files, :code_edit])) do
      Keyword.put(opts, :tool_root, root)
    else
      opts
    end
  end

  defp maybe_put_tool_root(opts, _harnesses, _spec), do: opts

  defp maybe_put_test_commands(opts, %RunSpec{test_commands: nil}), do: opts

  defp maybe_put_test_commands(opts, %RunSpec{test_commands: commands}),
    do: Keyword.put(opts, :test_commands, commands)

  defp maybe_put_mcp_config(opts, %RunSpec{mcp_config: nil}), do: opts

  defp maybe_put_mcp_config(opts, %RunSpec{mcp_config: config}),
    do: Keyword.put(opts, :mcp_config, config)

  defp planner_instructions do
    """
    You are the planning agent for AgentMachine.

    Decide whether the task needs worker agents. Return only JSON with this shape:
    {"decision":{"mode":"direct","reason":"non-empty reason"},"output":"final answer","next_agents":[]}
    or:
    {"decision":{"mode":"delegate","reason":"non-empty reason"},"output":"short planning note","next_agents":[{"id":"worker-id","input":"worker task","instructions":"optional worker instructions"}]}

    Use decision mode "direct" when the request can be answered without tools, filesystem changes, or separate worker context. In direct mode, put the final user-facing answer in output and use an empty next_agents list.
    Use decision mode "delegate" when worker agents are needed. Keep worker ids short, lowercase, and unique.
    If the task needs external side effects such as writing files or creating directories, you MUST create a worker agent for that exact action and require it to use available tools.
    For a single filesystem change request, create one worker that inspects, reads, and mutates files sequentially. Do not split exploration and file mutation into parallel workers unless the worker specs include explicit depends_on ordering.
    Do not use direct mode for filesystem create, write, edit, delete, or rename requests.
    Preserve exact user-provided patch, command, path, and file content text in worker input when delegating.
    Do not claim side effects happened unless tool_results confirm them.
    Do not call tools yourself. You are only planning and delegating.
    """
    |> String.trim()
  end

  defp finalizer_instructions do
    """
    Create the final user-facing answer from the completed run context.
    If the planner decision mode is "direct", return the planner output as the final answer.
    If the planner decision mode is "delegate", use worker outputs and tool_results to create the final answer.
    Use worker outputs when they exist. Do not delegate follow-up agents.
    Only report side effects that are present in prior results or tool_results.
    Do not call tools. Summarize only the run context.
    """
    |> String.trim()
  end
end
