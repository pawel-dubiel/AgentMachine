# Changelog

Add the newest changes at the top of the list. Keep each entry short and concrete.

## Latest Changes

- Added `AgentMachine.RunSpec`, `AgentMachine.Workflows.Basic`, and `AgentMachine.ClientRunner` as a high-level client boundary.
- Added `mix agent_machine.run` with text and JSON output.
- Added a Go Bubble Tea TUI client in `tui/`.
- Added Go TUI tests and Elixir client runner tests.
- Updated `AGENTS.md` with the current finalizer, retry, dependency, events, and tool architecture.
- Added explicit `:tool_timeout_ms` enforcement for provider tool calls.
- Added a test for tool timeout failures.
- Added explicit `:allowed_tools` enforcement for provider tool calls.
- Added a test for rejecting tool calls outside the allowlist.
- Added `AgentMachine.Tool` and provider `tool_calls` execution.
- Added `tool_results` to agent results and run context.
- Added tool execution tests for success and failure.
- Added optional `depends_on` support for initial agent dependency graphs.
- Added dependency graph validation for missing dependencies, duplicate dependency entries, self-dependencies, and cycles.
- Added tests for dependency scheduling and invalid dependency graphs.
- Added explicit `:max_attempts` retry support for failed agent attempts.
- Added `:attempt` provider option and retry events.
- Added retry tests for eventual success and exhausted attempts.
- Added in-memory run events for run start, agent start, agent finish, run completion, and run failure.
- Added event tests for finalized runs and failed runs.
- Added optional finalizer agents that run after normal and delegated agents finish.
- Added finalizer tests for synthesis, duplicate IDs, and `:max_steps` enforcement.
- Added `AGENTS.md` with repository guidance for future agents.
- Added `plan.md` to track postponed work with dates.
- Added Credo as a dev/test linter dependency.
- Added a `mix quality` alias for format checks, warnings-as-errors compilation, Credo strict mode, and tests.
- Added a `.credo.exs` configuration file.
- Added run-scoped `artifacts` so agents can write shared state for later delegated agents.
- Added `:run_context` for providers with the current run ID, agent ID, parent agent ID, prior results, and accumulated artifacts.
- Added artifact overwrite protection so conflicting artifact keys fail the run explicitly.
- Added tests for passing artifacts and previous results to delegated agents, plus artifact overwrite failures.
- Added dynamic work delegation through `next_agents`, so an agent can schedule follow-up workers in the same run.
- Added an explicit `:max_steps` limit for dynamic delegation, failing the run when the limit is missing or exceeded.
- Added unique agent ID validation for initial and delegated agents.
- Extended the provider contract and agent result with optional `next_agents`.
- Added tests for successful delegation, missing `:max_steps`, and exceeded limits.
- Documented dynamic delegation in `README.md`.
