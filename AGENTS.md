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
- `AgentMachine.AgentRunner` executes one validated agent through its provider and normalizes provider output.
- Providers implement `AgentMachine.Provider.complete/2`.
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

## Deferred Direction

Use `plan.md` as the source of postponed work. Do not implement all deferred items at once. Pick the next smallest useful iteration and keep the implementation understandable.
