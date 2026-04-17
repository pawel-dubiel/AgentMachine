# Changelog

Add the newest changes at the top of the list. Keep each entry short and concrete.

## Latest Changes

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
