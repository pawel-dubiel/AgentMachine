# Plan

Keep postponed work here. Add new items at the top of the list and include the date when the item was added.

## Deferred Work

- [2026-04-18] Add tool execution so agents can call approved project actions instead of only returning text.
- [2026-04-18] Add durable run state so runs can be resumed after a node restart or crash.
- [2026-04-18] Add retry and checkpoint handling for failed agent steps, with explicit idempotency rules.
- [2026-04-18] Add step-level observability: structured logs, timing, usage, cost, and decision traces per agent step.
- [2026-04-18] Add security and policy controls for tool permissions, sandbox boundaries, and approval flow.
- [2026-04-18] Add richer dependency graphs so agents can depend on specific prior agents, not only parent-to-child delegation.
- [2026-04-18] Add long-term memory after the run-scoped artifact model is stable.
- [2026-04-18] Add dynamic role discovery so the system can choose or generate worker roles from the task instead of requiring all roles up front.
- [2026-04-18] Add a finalizer/synthesizer step that can explicitly combine worker outputs into one final run result.
