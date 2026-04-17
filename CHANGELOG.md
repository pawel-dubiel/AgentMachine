# Changelog

Add the newest changes at the top of the list. Keep each entry short and concrete.

## Latest Changes

- Added dynamic work delegation through `next_agents`, so an agent can schedule follow-up workers in the same run.
- Added an explicit `:max_steps` limit for dynamic delegation, failing the run when the limit is missing or exceeded.
- Added unique agent ID validation for initial and delegated agents.
- Extended the provider contract and agent result with optional `next_agents`.
- Added tests for successful delegation, missing `:max_steps`, and exceeded limits.
- Documented dynamic delegation in `README.md`.
