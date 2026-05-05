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
- Prefer proven, maintained libraries for standard formats and protocols such
  as JSON, HTTP, YAML, and tokenization. Keep custom implementations only when
  there is a narrow, documented project reason, and prefer a local wrapper
  boundary when it protects the rest of the codebase from dependency details.
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
- Public runtime strategy selection belongs in `AgentMachine.ExecutionPlanner`:
  choose `direct`, `tool`, `planned`, or `swarm` for a validated high-level
  client run. `AgentMachine.Workflows.*` modules are private strategy builders;
  they must stay small and must not duplicate orchestrator scheduling logic.
- Provider modules belong at the model/API boundary only: translate an agent and
  options into an external/local provider call, then return the provider payload.
  Providers must not spawn agents, manage run state, or know about TUI behavior.
- Provider setup metadata belongs in `AgentMachine.ProviderCatalog`: supported
  provider IDs, labels, required secret fields, required non-secret fields,
  model metadata, pricing metadata, and provider capability metadata.
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
  belongs in Elixir. The TUI may manage terminal state, local key storage,
  provider-keyed settings, model/pricing metadata loaded through the Elixir
  provider catalog boundary, command history, and live event display, but it
  must not reimplement orchestration, dependency scheduling, retries, execution
  strategy selection, delegation parsing, tool execution, usage aggregation,
  run context, or provider contracts.
- TUI code should keep a clean internal split: Bubble Tea model/update/view code,
  CLI process adapter, config persistence, provider model/pricing lookup, and
  rendering helpers should stay separate enough that the TUI remains easy to
  audit as a wrapper.
- `Makefile` targets are local developer conveniences. They must call public
  commands and keep required runtime values explicit.

## Drift Checks

- Do not track generated binaries or build artifacts.
- Do not add a generic framework layer when one explicit runtime strategy or
  helper will solve the current problem.
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
- TUI per-run stream logs use timestamp-only names such as
  `20260429T154940.063674000Z.jsonl`; session-level collector logs use
  `session-*.jsonl`.
- The TUI setup screen shows the exact `session log` path for the active
  session.
- CLI runs write logs only when explicit paths are passed with `--log-file` or
  `--event-log-file`.
- Treat log contents as redacted runtime evidence for execution strategy
  selection, agent lifecycle, provider activity, tool calls, skills, and final
  summaries.
- Session/TUI streaming runtime events are best-effort observability and may be
  written asynchronously; final summaries and required control decisions must
  remain synchronous.

## Current Architecture

- `AgentMachine.Orchestrator` is the public run facade. It validates run input,
  starts one supervised run subtree, and delegates snapshots/awaiting to the
  per-run process.
- `AgentMachine.RunServer` owns one run's state, task spawning, result
  aggregation, dynamic delegation, run artifacts, and usage totals.
- `AgentMachine.RunRegistry` names run-scoped processes by `{type, run_id}`;
  each run subtree includes a run event collector, per-run task supervisor, tool
  session supervisor, and run server.
- `AgentMachine.RunSpec`, `AgentMachine.ExecutionPlanner`, and
  `AgentMachine.ClientRunner` form the high-level client boundary.
- `AgentMachine.Workflows.Chat`, `AgentMachine.Workflows.Tool`,
  `AgentMachine.Workflows.Basic`, and `AgentMachine.Workflows.Agentic` are
  private strategy builders used after execution strategy selection.
- `AgentMachine.AgentRunner` executes one validated agent through its provider and normalizes provider output.
- `AgentMachine.DelegationResponse` parses opt-in structured planner output into delegated worker specs.
- `AgentMachine.RunContextPrompt` formats prior results and artifacts for remote provider prompts.
- `AgentMachine.RunContextPrompt` also includes compact runtime facts such as
  current UTC date/time, local timezone, and execution strategy; keep these
  facts factual and small. `workflow_route` is a temporary compatibility alias
  for the same strategy facts.
- `AgentMachine.ToolHarness` maps explicit tool harnesses to allowed tools and
  adapts tool definitions/calls for provider-native tool calling.
- `AgentMachine.ProviderCatalog` is the source of truth for supported provider
  IDs, setup fields, model metadata, pricing metadata, and capability metadata.
- Providers implement `AgentMachine.Provider.complete/2`.
- Built-in providers are Echo for local/offline tests and
  `AgentMachine.Providers.ReqLLM` for every remote provider.
- Tools implement `AgentMachine.Tool.run/2`.
- Tools may implement `AgentMachine.Tool.definition/0` when they should be
  exposed to provider-native tool calling.
- Agents may return `next_agents` for dynamic delegation.
- Agents may return `artifacts` for run-scoped memory.
- Agents may return `tool_calls` for explicit tool execution.
- Initial agents may use `depends_on` for dependency-ordered execution.
- Runs may use `finalizer` to synthesize a final result after all other work.
- Runs expose one public runtime: `agentic`. External clients may omit workflow
  or pass `agentic`; `chat`, `basic`, and `auto` are not public workflow values.
- `AgentMachine.ExecutionPlanner` selects the internal execution strategy:
  `direct` for one assistant without tools, `tool` for one assistant with a
  narrow tool set, `planned` for planner/worker/finalizer orchestration, or
  `swarm` for planner-created variants plus evaluator.
- Runs may use `max_attempts` for explicit retry attempts.
- Runs collect in-memory `events` for lightweight observability and emit
  `:telemetry` events for run, agent, tool, MCP call, and execution-strategy
  activity alongside JSONL logs. `workflow_route` remains only as a temporary
  compatibility alias for `execution_strategy`.
- High-level client runs treat `--timeout-ms` as an idle lease, derive a 3x hard
  cap, emit heartbeat/lease/timeout events, and cancel active agent/tool work on
  timeout.
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
- MCP sessions are supervised under the per-run tool session supervisor and are
  kept alive per agent attempt so stateful MCP servers such as Playwright can
  handle multi-step tool loops.
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
- The TUI may persist selected provider, selected model per provider,
  provider-keyed secret fields, provider-keyed non-secret option fields, and
  tool harness setup in its local config file. It must not persist workflow as
  part of the active design. It may inject saved provider secrets into the `mix`
  child process environment.
- The TUI loads provider/model metadata through the Elixir provider catalog
  tasks, not through direct OpenAI/OpenRouter HTTP APIs. It may cache returned
  model and pricing metadata and pass explicit pricing to the CLI when required;
  do not expose token price fields as normal user inputs.

## Deferred Direction

Use `plan.md` as the source of postponed work. Do not implement all deferred items at once. Pick the next smallest useful iteration and keep the implementation understandable.
