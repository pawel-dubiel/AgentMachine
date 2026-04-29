# AGENTS.md

Guidance for agents working in this repository.

## Project Intent

This project should stay small, explicit, and easy to understand. It is evolving from a simple orchestrator-with-workers into a real agent runtime one iteration at a time.

Prefer small changes that move the architecture forward without turning the project into a large framework.

## Engineering Rules

- Fail fast when required input, configuration, or state is missing.
- Do not add silent defaults for missing required values.
- Keep provider and orchestrator contracts explicit.
- Keep code simple before adding abstractions.
- Prefer clear data structures over implicit behavior.
- Preserve OTP supervision and task isolation.
- Avoid broad rewrites unless they are necessary for the requested change.
- Treat tests as a first-class design tool. Prefer TDD for new behavior: write
  or update the smallest meaningful failing test, implement the behavior, then
  run the relevant focused tests before the full quality gate.
- Do not merge behavior changes without automated coverage unless the change is
  documentation-only or explicitly not testable; say so clearly.
- Use a security-first approach for all tool/runtime changes: deny by default,
  require explicit permissions, log security-relevant decisions, and prefer
  narrow capability over broad convenience.

## Feature Workflow

- For every new nontrivial feature, first produce a decision-complete plan.
- Implement only after the user explicitly asks to implement that plan.
- Keep each `plan.md` backlog item as its own iteration unless the user
  explicitly groups items.
- For each implementation, prefer TDD: write or update the smallest meaningful
  failing focused test, implement the behavior, then run the relevant focused
  tests before the full quality gate.

## Responsibility Boundaries

Keep these ownership lines explicit. If a change does not fit one of these
boundaries, pause and simplify the design before adding code.

- Orchestration belongs in `AgentMachine.Orchestrator`: run state, task spawning,
  dependency scheduling, retries, finalizers, event recording, dynamic
  delegation, artifacts, and usage aggregation.
- Agent execution belongs in `AgentMachine.AgentRunner`: call exactly one
  validated provider, normalize its payload, run explicitly allowed tools, and
  return an `AgentResult`.
- Client workflow shape belongs in `AgentMachine.Workflows.*`: choose the initial
  agents and finalizer for a high-level client run. Workflows must stay small and
  must not duplicate orchestrator scheduling logic.
- Provider modules belong at the model/API boundary only: translate an agent and
  options into an external/local provider call, then return the provider payload.
  Providers must not spawn agents, manage run state, or know about TUI behavior.
- Structured model-output adapters belong in small runtime modules such as
  `AgentMachine.DelegationResponse`, not inside providers or the TUI.
- Tool schema and provider tool-call adapters belong in `AgentMachine.ToolHarness`.
  Providers may use that adapter at the model/API boundary, but tool execution
  remains in `AgentMachine.AgentRunner`.
- MCP config parsing, protocol clients, namespacing, permissions, transport
  security, and result normalization belong in Elixir runtime modules. The TUI
  may only persist/pass an MCP config path and render events/results.
- Prompt/context formatting belongs in small helpers such as
  `AgentMachine.RunContextPrompt` when shared by providers.
- CLI code in `mix agent_machine.run` is the stable client boundary: parse flags,
  fail fast on missing required options, call `AgentMachine.ClientRunner`, print
  redacted text/JSON/JSONL output, and write explicit redacted run log files
  when requested.
- `tui/` is only a thin Go client over the CLI boundary. All agent runtime logic
  belongs in Elixir. The TUI may manage terminal state, local key storage, model
  lists, pricing lookup, command history, and display live events, but it must
  not reimplement orchestration, dependency scheduling, retries, workflow
  behavior, delegation parsing, tool execution, usage aggregation, run context,
  or provider contracts.
- TUI code should keep a clean internal split: Bubble Tea model/update/view code,
  CLI process adapter, config persistence, provider model/pricing lookup, and
  rendering helpers should stay separate enough that the TUI remains easy to
  audit as a wrapper.
- `Makefile` targets are local developer conveniences. They must call public
  commands and keep required runtime values explicit.

## Drift Checks

- Do not track generated binaries or build artifacts.
- Do not add a generic framework layer when one explicit workflow or helper will
  solve the current problem.
- Do not let UI convenience create hidden runtime defaults.
- Do not put runtime behavior into the TUI to avoid adding an Elixir API or CLI
  option. Add the explicit runtime boundary instead.
- Do not add provider-specific behavior to shared orchestration paths unless the
  provider contract actually changed.
- Prefer adding one narrow module over growing a central module with unrelated
  responsibilities.
- If a file starts accumulating unrelated responsibilities, split it before
  adding more behavior.

## Documentation Rules

- Update `CHANGELOG.md` for every completed change.
- Keep `CHANGELOG.md` entries in English.
- Add the newest changelog entries at the top of the list.
- Update `plan.md` when work is intentionally deferred.
- Every `plan.md` item must include the date it was added.
- Keep `plan.md` entries in English.
- Update `README.md` when behavior, commands, provider contracts, or public examples change.

## Quality Gate

Run the full local quality gate after code changes:

```sh
mix quality
```

The quality gate runs formatting checks, warnings-as-errors compilation, Credo in strict mode, and tests.

For documentation-only changes, running tests is optional. Say explicitly when tests were not run because the change was documentation-only.

## Debugging Logs

- For TUI debugging, inspect JSONL logs under
  `$HOME/Library/Application Support/agent-machine/logs/`.
- TUI per-run stream logs use `run-*.jsonl`; session-level collector logs use
  `session-*.jsonl`.
- The TUI setup screen shows the exact `session log` path for the active
  session.
- CLI runs write logs only when explicit paths are passed with `--log-file` or
  `--event-log-file`.
- Treat log contents as redacted runtime evidence for workflow routing, agent
  lifecycle, provider activity, tool calls, skills, and final summaries.

## Current Architecture

- `AgentMachine.Orchestrator` owns run state, task spawning, result aggregation, dynamic delegation, run artifacts, and usage totals.
- `AgentMachine.RunSpec`, `AgentMachine.Workflows.Basic`, `AgentMachine.Workflows.Agentic`, and `AgentMachine.ClientRunner` form the high-level client boundary.
- `AgentMachine.AgentRunner` executes one validated agent through its provider and normalizes provider output.
- `AgentMachine.DelegationResponse` parses opt-in structured planner output into delegated worker specs.
- `AgentMachine.RunContextPrompt` formats prior results and artifacts for remote provider prompts.
- `AgentMachine.ToolHarness` maps explicit tool harnesses to allowed tools and
  adapts tool definitions/calls for provider-native tool calling.
- Providers implement `AgentMachine.Provider.complete/2`.
- Built-in providers are Echo, OpenAI Responses, and OpenRouter Chat.
- Tools implement `AgentMachine.Tool.run/2`.
- Tools may implement `AgentMachine.Tool.definition/0` when they should be
  exposed to provider-native tool calling.
- Agents may return `next_agents` for dynamic delegation.
- Agents may return `artifacts` for run-scoped memory.
- Agents may return `tool_calls` for explicit tool execution.
- Initial agents may use `depends_on` for dependency-ordered execution.
- Runs may use `finalizer` to synthesize a final result after all other work.
- Runs choose an explicit client `workflow`; `basic` starts an assistant plus finalizer, and `agentic` starts a planner that may delegate workers plus finalizer.
- Runs may use `max_attempts` for explicit retry attempts.
- Runs collect in-memory `events` for lightweight observability.
- Delegated agents receive `:run_context` with prior results and accumulated artifacts.
- Tool calls require `allowed_tools`, `tool_policy`, `tool_timeout_ms`,
  `tool_max_rounds`, and `tool_approval_mode`.
- Provider-native tool calls continue within the same agent attempt: the runtime
  executes allowed tools, sends JSON-encoded results back to the provider, and
  stops only when the provider returns a final response or `tool_max_rounds` is
  exceeded.
- Every executable tool must expose a narrow `permission/0` and
  `approval_risk/0`; execution must check both permission and approval mode.
- `mix agent_machine.run --tool-harness demo --tool-timeout-ms <ms>
  --tool-max-rounds <n> --tool-approval-mode <mode>` exposes the safe built-in
  demo harness through the high-level client boundary.
- `mix agent_machine.run --tool-harness local-files --tool-root <path>
  --tool-timeout-ms <ms> --tool-max-rounds <n> --tool-approval-mode <mode>`
  exposes constrained local directory creation, file metadata, listing,
  reading, search, writing, appending, and exact text replacement under the
  explicit root. File search uses `rg`.
- `mix agent_machine.run --tool-harness code-edit --tool-root <path>
  --tool-timeout-ms <ms> --tool-max-rounds <n> --tool-approval-mode <mode>`
  exposes constrained code edit tools for structured edits and unified patches.
  Patch application must stay in Elixir and must not shell out.
- `mix agent_machine.run` may receive repeated `--tool-harness` flags. The
  runtime merges allowed tools and policies, and fails fast on duplicate
  provider-visible tool names.
- `mix agent_machine.run --tool-harness mcp --mcp-config <path>` exposes
  explicitly allowlisted MCP tools through namespaced provider-visible names.
  MCP stdio and Streamable HTTP protocol, env-secret resolution, permissions,
  transport calls, redaction, and result bounding belong in Elixir.
- Repeated `--test-command <command>` values may extend `code-edit` with
  `run_test_command` only under `full-access`. Command execution must stay in
  Elixir, use exact allowlist matching, avoid shells, keep cwd inside
  `tool_root`, and return bounded redacted output.
- Code-edit checkpoint and rollback logic belongs in Elixir tools/helpers.
  The TUI may display checkpoint IDs or call CLI commands, but it must not
  create, inspect, apply, or roll back checkpoints itself.
- `mix agent_machine.rollback --tool-root <path> --checkpoint-id <id>` restores
  a code-edit checkpoint through the same Elixir rollback helper used by the
  `rollback_checkpoint` tool.
- `mix agent_machine.run` is the stable CLI boundary for clients.
- `mix agent_machine.run --log-file <path>` writes Elixir-side JSONL run events
  plus the final summary to an explicit file path. Serialized logs, summaries,
  JSONL events, and read-style tool results must pass through
  `AgentMachine.Secrets.Redactor`; the TUI must not duplicate redaction logic.
- `tui/` contains the Go Bubble Tea conversation client with slash commands and should call the CLI boundary instead of reimplementing orchestration.
- The TUI may persist workflow, provider, provider-specific selected model, tool
  harness setup, and remote provider API keys in its local config file. It may
  inject saved API keys into the `mix` child process environment.
- The TUI resolves remote-provider pricing itself before calling the CLI; do not expose token price fields as normal user inputs.
- The TUI loads remote provider model lists from OpenAI/OpenRouter and should keep model selection provider-specific.

## Deferred Direction

Use `plan.md` as the source of postponed work. Do not implement all deferred items at once. Pick the next smallest useful iteration and keep the implementation understandable.
