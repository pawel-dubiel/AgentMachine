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

## Current Architecture

- `AgentMachine.Orchestrator` owns run state, task spawning, result aggregation, dynamic delegation, run artifacts, and usage totals.
- `AgentMachine.RunSpec`, `AgentMachine.Workflows.Basic`, and `AgentMachine.ClientRunner` form the high-level client boundary.
- `AgentMachine.AgentRunner` executes one validated agent through its provider and normalizes provider output.
- Providers implement `AgentMachine.Provider.complete/2`.
- Built-in providers are Echo, OpenAI Responses, and OpenRouter Chat.
- Tools implement `AgentMachine.Tool.run/2`.
- Agents may return `next_agents` for dynamic delegation.
- Agents may return `artifacts` for run-scoped memory.
- Agents may return `tool_calls` for explicit tool execution.
- Initial agents may use `depends_on` for dependency-ordered execution.
- Runs may use `finalizer` to synthesize a final result after all other work.
- Runs may use `max_attempts` for explicit retry attempts.
- Runs collect in-memory `events` for lightweight observability.
- Delegated agents receive `:run_context` with prior results and accumulated artifacts.
- Tool calls require `allowed_tools` and `tool_timeout_ms`.
- `mix agent_machine.run` is the stable CLI boundary for clients.
- `tui/` contains the Go Bubble Tea conversation client with slash commands and should call the CLI boundary instead of reimplementing orchestration.
- The TUI may persist remote provider API keys in its local config file and inject them into the `mix` child process environment.
- The TUI resolves remote-provider pricing itself before calling the CLI; do not expose token price fields as normal user inputs.
- The TUI loads remote provider model lists from OpenAI/OpenRouter and should keep model selection provider-specific.

## Deferred Direction

Use `plan.md` as the source of postponed work. Do not implement all deferred items at once. Pick the next smallest useful iteration and keep the implementation understandable.
