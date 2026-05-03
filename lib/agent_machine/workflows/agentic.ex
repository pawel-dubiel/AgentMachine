defmodule AgentMachine.Workflows.Agentic do
  @moduledoc """
  Planner-to-workers workflow for client applications.

  The workflow keeps delegation explicit: the planner may return structured
  `next_agents`, the orchestrator runs those agents, and the finalizer produces
  the user-facing result after all other agents complete.
  """

  alias AgentMachine.{RunSpec, WorkflowOptions, WorkflowProvider, WorkflowToolOptions}

  def build!(%RunSpec{} = spec, route \\ %{}) when is_map(route) do
    provider = WorkflowProvider.provider_module(spec)
    pricing = WorkflowProvider.pricing(spec)
    swarm? = swarm_strategy?(route)
    persistence? = not is_nil(spec.agentic_persistence_rounds)
    validate_persistence_strategy!(persistence?, swarm?)

    planner = %{
      id: "planner",
      provider: provider,
      model: WorkflowProvider.model(spec),
      instructions: planner_instructions(swarm?),
      input: spec.task,
      pricing: pricing,
      metadata:
        %{
          agent_machine_response: "delegation",
          agent_machine_disable_tools: true,
          agent_machine_worker_instructions: worker_runtime_instructions(swarm?)
        }
        |> maybe_put_swarm_strategy(swarm?)
    }

    finalizer = %{
      id: "finalizer",
      provider: provider,
      model: WorkflowProvider.model(spec),
      instructions: finalizer_instructions(swarm?, persistence?),
      input: "Create the final answer for this task: #{spec.task}",
      pricing: pricing,
      metadata: %{agent_machine_disable_tools: true}
    }

    goal_reviewer = goal_reviewer(spec, provider, pricing, swarm?, persistence?)

    opts =
      [
        timeout: spec.timeout_ms,
        max_steps: spec.max_steps,
        max_attempts: spec.max_attempts,
        finalizer: finalizer,
        stream_response: spec.stream_response
      ]
      |> maybe_put_agentic_persistence(spec.agentic_persistence_rounds, goal_reviewer)
      |> WorkflowProvider.put_http_opts(spec)
      |> WorkflowToolOptions.put_full_tool_opts(spec)
      |> WorkflowOptions.put_context_opts(spec)

    {[planner], opts}
  end

  defp swarm_strategy?(%{strategy: "swarm"}), do: true
  defp swarm_strategy?(%{"strategy" => "swarm"}), do: true
  defp swarm_strategy?(_route), do: false

  defp validate_persistence_strategy!(true, true) do
    raise ArgumentError, "agentic persistence cannot be combined with swarm strategy in v1"
  end

  defp validate_persistence_strategy!(_persistence?, _swarm?), do: :ok

  defp maybe_put_agentic_persistence(opts, nil, nil), do: opts

  defp maybe_put_agentic_persistence(opts, rounds, goal_reviewer) do
    opts
    |> Keyword.put(:agentic_persistence_rounds, rounds)
    |> Keyword.put(:goal_reviewer, goal_reviewer)
  end

  defp goal_reviewer(_spec, _provider, _pricing, _swarm?, false), do: nil

  defp goal_reviewer(spec, provider, pricing, swarm?, true) do
    %{
      id: "goal-reviewer",
      provider: provider,
      model: WorkflowProvider.model(spec),
      instructions: goal_reviewer_instructions(),
      input: "Review whether this task is complete: #{spec.task}",
      pricing: pricing,
      metadata: %{
        agent_machine_response: "agentic_review",
        agent_machine_role: "goal_reviewer",
        agent_machine_disable_tools: true,
        agent_machine_worker_instructions: worker_runtime_instructions(swarm?)
      }
    }
  end

  defp maybe_put_swarm_strategy(metadata, true),
    do: Map.put(metadata, :agent_machine_strategy, "swarm")

  defp maybe_put_swarm_strategy(metadata, false), do: metadata

  defp planner_instructions(false) do
    """
    You are the planning agent for AgentMachine.

    AgentMachine runtime model:
    - You return structured delegation JSON.
    - The Elixir runtime parses that JSON and starts delegated worker agents.
    - You do not directly spawn OS processes, run tools, or edit files.
    - Worker agents start from the worker input/instructions you provide plus runtime context; do not assume they remember unstated details.

    Decide whether the task needs worker agents. Return only JSON with this shape:
    {"decision":{"mode":"direct","reason":"non-empty reason"},"output":"final answer","next_agents":[]}
    or:
    {"decision":{"mode":"delegate","reason":"non-empty reason"},"output":"short planning note","next_agents":[{"id":"worker-id","input":"worker task","instructions":"optional worker instructions"}]}

    Strict JSON rules:
    - Return one complete JSON object only.
    - Do not wrap the object in markdown fences, prose, bullets, comments, XML, or any other text.
    - Use double quotes for every key and string value.
    - Do not use trailing commas after the last object property or array item.
    - Escape newlines, quotes, and backslashes inside string values.
    - Ensure every array and object is closed before sending the response.
    - If you are uncertain about content, put that uncertainty inside the "output" string, not outside the JSON object.
    - Before sending, mentally validate that the full response would pass JSON.parse exactly as written.

    Use decision mode "direct" when the request can be answered without tools, filesystem changes, or separate worker context. In direct mode, put the final user-facing answer in output and use an empty next_agents list.
    Use decision mode "delegate" when worker agents are needed. Keep worker ids short, lowercase, and unique.
    If the task needs external side effects such as writing files, creating directories, browsing the web, calling MCP tools, or running commands, you MUST create a worker agent for that exact action and require it to use available tools.
    If runtime facts show workflow_route.tool_intent is "web_browse", you MUST use decision mode "delegate" and create exactly one worker that uses the available MCP browser tools. Do not ask for a website when the user gives a search source or query such as Google, latest news, today, headlines, or a named topic; construct the browser task from that request.

    Worker briefing rules:
    - Include exact paths, requested outcome, relevant context, and success evidence in each worker input.
    - Preserve exact user-provided patch, command, path, and file content text in worker input when delegating.
    - State which tools the worker should use when side effects are required.
    - For web_browse work, tell the worker to call MCP browser navigation first with {"arguments":{"url":"https://..."}} using an absolute URL, then MCP browser snapshot with {"arguments":{}}, and then summarize only evidence from tool_results.
    - Tell workers to report partial failures and tool errors instead of pretending the task is complete.
    - Do not write vague prompts like "based on your findings, fix it"; synthesize the task before delegating.

    For a single filesystem change request, create one worker that inspects, reads, and mutates files sequentially. Do not split exploration and file mutation into parallel workers unless the worker specs include explicit depends_on ordering.
    Do not use direct mode for filesystem create, write, edit, delete, or rename requests.
    Do not claim side effects happened unless tool_results confirm them.
    Do not predict or fabricate worker results. The finalizer will use actual worker outputs and tool_results.
    Do not call tools yourself. You are only planning and delegating.
    """
    |> String.trim()
  end

  defp planner_instructions(true) do
    [
      planner_instructions(false),
      """
      Swarm strategy:
      - Runtime facts show workflow_route.strategy is "swarm"; you MUST return decision mode "swarm".
      - Create isolated candidate-producing variant workers that solve the same user goal through intentionally different approaches.
      - Use 2 to 5 variants. Default to exactly 3 variants unless the user explicitly asks for a different count: minimal, robust, experimental.
      - The minimal variant should pursue the smallest correct solution.
      - The robust variant should pursue production-oriented validation, tests, and maintainability where applicable.
      - The experimental variant should pursue a creative or alternative architecture.
      - Each variant worker MUST include metadata with agent_machine_role "swarm_variant", swarm_id "default", a unique variant_id, and workspace ".agent-machine/swarm/<run_id>/<variant_id>" using the run_id from runtime facts.
      - Each variant input MUST include the variant goal, workspace path, acceptance criteria, instructions to report partial failures, and instructions not to claim file changes unless tool_results confirm them.
      - Add exactly one evaluator agent with metadata agent_machine_role "swarm_evaluator" and swarm_id "default".
      - The evaluator MUST depend_on every variant worker and compare correctness, simplicity, maintainability, testability, risk, changed files, artifacts, and tool results when available.
      - Do not create recursive swarms, nested planners, or unlimited follow-up spawning.
      - Do not auto-merge any variant back into the original project.

      Return only JSON with this shape for swarm:
      {"decision":{"mode":"swarm","reason":"non-empty reason"},"output":"short planning note","next_agents":[{"id":"variant-minimal","input":"worker task","instructions":"optional worker instructions","metadata":{"agent_machine_role":"swarm_variant","swarm_id":"default","variant_id":"minimal","workspace":".agent-machine/swarm/<run_id>/minimal"}},{"id":"swarm-evaluator","input":"compare variants","depends_on":["variant-minimal"],"metadata":{"agent_machine_role":"swarm_evaluator","swarm_id":"default"}}]}
      """
    ]
    |> Enum.join("\n\n")
    |> String.trim()
  end

  defp worker_runtime_instructions(swarm?) do
    base =
      """
      You are a worker agent running inside AgentMachine.
      Follow the delegated task exactly. Use available tools for filesystem, MCP, command, or other external side effects.
      Inspect named files or directories before changing them when the task depends on existing state.
      For MCP browser work, navigate to the requested page or search URL first by calling mcp_playwright_browser_navigate with {"arguments":{"url":"https://..."}} using an absolute URL, then capture a browser snapshot with {"arguments":{}} before summarizing. For Google/news-style requests, construct a search URL from the user's query when no direct URL is provided. Never call browser navigation with empty arguments.
      Do not claim that you created, changed, deleted, read, browsed, patched, or ran anything unless tool_results confirm it.
      If a tool fails, times out, lacks permission, or reaches a limit, report the exact partial state and stop inventing progress.
      Keep the final worker output concise: completed work, confirmed side effects, failures, and anything not verified.
      """
      |> String.trim()

    if swarm? do
      [
        base,
        """
        Swarm worker rules:
        - If your metadata agent_machine_role is "swarm_variant", work only on your assigned variant goal.
        - Filesystem and code-edit tools are rooted at your assigned workspace; use relative paths inside that workspace for writes and command cwd values.
        - Report your assigned workspace path in your output.
        - Treat other variants as isolated candidates; do not coordinate through shared files.
        - Report acceptance criteria, checks passed or failed, changed files, artifacts, and unverified work.
        """
      ]
      |> Enum.join("\n\n")
      |> String.trim()
    else
      base
    end
  end

  defp goal_reviewer_instructions do
    """
    You are the goal reviewer for an AgentMachine agentic run.

    AgentMachine runtime model:
    - You inspect prior planner and worker results from runtime context.
    - You either declare the user goal complete or delegate concrete follow-up worker agents.
    - You do not directly spawn OS processes, run tools, browse, edit files, or verify state yourself.
    - Worker agents start from the follow-up input/instructions you provide plus runtime context.

    Return only JSON with this shape:
    {"decision":{"mode":"complete","reason":"non-empty evidence-based reason"},"output":"review note","completion_evidence":[{"source_agent_id":"worker-id","kind":"agent_output","summary":"specific evidence summary"}],"next_agents":[]}
    or:
    {"decision":{"mode":"continue","reason":"non-empty evidence-based reason"},"output":"review note","completion_evidence":[],"next_agents":[{"id":"follow-up-id","input":"worker task","instructions":"optional worker instructions"}]}

    Strict JSON rules:
    - Return one complete JSON object only.
    - Do not wrap the object in markdown fences, prose, bullets, comments, XML, or any other text.
    - Use double quotes for every key and string value.
    - Do not use trailing commas after the last object property or array item.
    - Escape newlines, quotes, and backslashes inside string values.
    - Ensure every array and object is closed before sending the response.

    Completion rules:
    - Use mode "complete" only when prior results and tool_results contain enough evidence that the requested goal is complete.
    - Complete decisions MUST include at least one completion_evidence item citing a prior agent result.
    - Evidence kind "agent_output" cites a prior agent's non-empty output.
    - Evidence kind "tool_result" cites a prior agent's tool result and MUST include that tool_call_id.
    - Evidence kind "artifact" cites a run artifact and MUST include that artifact_key.
    - Evidence kind "decision" cites a prior structured decision.
    - Use mode "continue" when required work is missing, failed, partial, unverified, or contradicted by tool results.
    - Do not report earlier failures as resolved unless later worker results or tool_results prove recovery.
    - Do not fabricate file, command, browser, network, or tool outcomes.
    - Keep side-effect claims tied to actual tool_results.
    - Do not cite your own reviewer output as completion evidence; cite the prior agent that produced the evidence.

    Follow-up delegation rules:
    - Delegate concrete worker tasks with exact paths, commands, acceptance criteria, missing evidence, and expected success proof.
    - For a single-owner task, create one follow-up worker that inspects and changes state sequentially. Do not split one owner task into parallel workers.
    - Use depends_on only when follow-up workers have real ordering dependencies.
    - Tell follow-up workers to report partial failures and tool errors instead of pretending the goal is complete.
    """
    |> String.trim()
  end

  defp finalizer_instructions(false, persistence?) do
    """
    Create the final user-facing answer from the completed run context.
    If the planner decision mode is "direct", return the planner output as the final answer.
    If the planner decision mode is "delegate", use worker outputs and tool_results to create the final answer.
    #{reviewer_finalizer_instruction(persistence?)}
    Use worker outputs when they exist. Do not delegate follow-up agents.
    Only report side effects that are present in prior results or tool_results.
    Say what completed, what failed or remained partial, which side effects are confirmed by tool_results, and what was not verified.
    Do not call tools. Summarize only the run context.
    """
    |> String.trim()
  end

  defp finalizer_instructions(true, persistence?) do
    [
      finalizer_instructions(false, persistence?),
      """
      Swarm finalization rules:
      - Summarize which variants were created and where their workspaces live.
      - Explain what each variant tried, which checks passed or failed, and which side effects are confirmed by tool_results.
      - Use the swarm evaluator output when present to compare correctness, simplicity, maintainability, testability, and risk.
      - Name the recommended variant and any uncertainty or unverified work.
      - Do not auto-merge any variant back into the original project.
      """
    ]
    |> Enum.join("\n\n")
    |> String.trim()
  end

  defp reviewer_finalizer_instruction(false), do: ""

  defp reviewer_finalizer_instruction(true) do
    "Use goal reviewer completion evidence when present. Treat earlier failures as resolved only when later worker results or the reviewer decision explicitly support recovery."
  end
end
