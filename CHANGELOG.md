# Changelog

Add the newest changes at the top of the list. Keep each entry short and concrete.

## Latest Changes

- Added JSONL stdio permission control for interactive `ask-before-write` runs,
  including runtime permission request, decision, and cancellation events.
- Added current-attempt `request_capability` negotiation for local-files,
  code-edit, MCP tools, and exact allowlisted test commands.
- Changed the TUI to prefer interactive `ask-before-write` for local tools and
  MCP browser runs, with inline approve/deny actions for runtime permissions.
- Added provider-backed skill generation through `mix agent_machine.skills
  generate` and TUI `/skills generate <name> <description>`.
- Slowed Matrix-themed TUI work phrase rotation while keeping a moving green
  gradient sweep across the active phrase.
- Fixed Matrix-themed TUI Markdown code blocks so Chroma receives valid hex
  colors instead of ANSI palette numbers.
- Added selectable TUI themes with `/theme classic|matrix`, including a
  Matrix-inspired green palette and themed running activity signals.
- Added basic Markdown rendering for TUI assistant and agent final output, with
  bold text, bold colored headings, inline code, links, lists, and blockquotes.
- Changed TUI `/mcp-config` to require an explicit timeout, max rounds, and
  approval mode instead of inheriting a previously saved tool budget.
- Tightened the agentic planner prompt with explicit strict JSON rules to reduce
  malformed delegation responses.
- Changed TUI agent detail views to show each agent's exact streamed text
  separately from the final normalized output, while compacting repeated stream
  activity rows.
- Changed provider SSE streaming to close locally on terminal stream events such
  as OpenRouter `[DONE]` and OpenAI `response.completed`.
- Changed `ClientRunner` to fail fast when `ask-before-write` exposes write,
  delete, command, or network-risk tools without an approval callback.
- Changed TUI work checklist markers so pending/running rows render as `[-]`,
  completed rows render as `[v]`, and failed/timeout rows render as `[x]`.
- Added an opt-in paid OpenRouter swarm end-to-end eval target that runs Kimi
  K2.6, GPT OSS 120B, and Step 3.5 Flash through the same
  planner-to-variants-to-evaluator tool workflow.
- Changed the default paid OpenRouter integration-test model to
  `moonshotai/kimi-k2.6`.
- Added paid OpenRouter swarm integration coverage and high-level
  `ClientRunner` approval callbacks so swarm variant writes and allowlisted
  test commands can be verified under runtime-owned permissions.
- Added an agentic swarm strategy for explicit multiple-variant requests, with
  validated variant/evaluator graphs, per-variant workspace roots, and
  evaluator/finalizer prompt support.
- Reworked context budget monitoring to measure provider request bodies with an
  explicit tokenizer path, added reserved-output configuration, TUI status-line
  rendering, and budget-gated run-context compaction skips when measurement is
  unknown.
- Added explicit conversation and run-context compaction with a compact CLI,
  TUI `/compact` and `/context` commands, context budget events, and
  opt-in automatic run-context compaction.
- Converted web-browse full-access router failures in the TUI into an MCP
  browser approval selector that retries with MCP-only full-access settings.
- Routed Google/news research wording through Playwright MCP web browsing,
  strengthened agentic web-browse delegation prompts, omitted assistant
  refusals from TUI conversation context, and added a paid OpenRouter MCP
  browser worker test for the auto route.
- Added broader local intent classifier and router permission matrix tests with
  complex multilingual prompts, follow-up context, false-positive guards, and an
  opt-in real ONNX classifier scenario table.
- Improved agentic planner/worker/finalizer prompts, added safe tool-specific
  display summaries, and introduced a runtime-derived work checklist for clearer
  TUI progress on long runs.
- Preserved partial tool results on agent errors such as `tool_max_rounds`
  exhaustion so finalizers and agent detail views can report confirmed side
  effects instead of treating them as invisible.
- Kept router details out of the README and taught the TUI to use the installed
  standard zero-shot router model automatically when its files are present.
- Rewrote the README as a product-oriented overview with concise setup,
  feature, safety, tooling, MCP, skills, and observability sections.
- Prevented local router false-positive web-browse classifications such as
  `hello` from requiring MCP browser/full-access unless the prompt contains a
  concrete web target.
- Wrapped long TUI chat/status lines to the terminal width so long router/model
  paths remain visible instead of being cut off.
- Switched local router ONNX scoring to the standard zero-shot
  entailment-versus-contradiction probability and guarded local classifier
  output with deterministic capability rules for recognized higher-risk
  intents.
- Routed Next.js/front-end project creation as code mutation so the TUI asks
  for `code-edit` instead of using only local-files permissions.
- Fixed Mix CLI parsing for repeated `--tool-harness`, `--test-command`, and
  `--skill` flags so combined harnesses such as local-files plus MCP are not
  reduced to only the last flag.
- Replaced the custom JSON parser/encoder with a Jason-backed
  `AgentMachine.JSON` wrapper and documented when to prefer proven libraries.
- Fixed JSON decoding for exponent-only numbers like `8e-7` returned by some
  OpenRouter models.
- Tuned Gun SSE client options with explicit DNS/connect/TLS timeouts,
  disabled hidden retries, TCP no-delay/keepalive, and HTTP/2 keepalive.
- Switched provider SSE streaming from `:httpc` to Gun with HTTP/2 preferred
  by default, HTTP/1.1 fallback/configuration, and local SSE transport coverage.
- Added paid OpenRouter direct streaming probe tests for the provider SSE path
  and a raw `:gun` path, measuring time-to-first-delta without
  ClientRunner, workflows, tools, or the TUI.
- Improved the TUI agent detail view with running-state placeholders,
  sanitized stream activity, elapsed duration, and compact heartbeat rendering.
- Converted auto-router write-capability failures in the TUI into the same
  interactive filesystem permission selector instead of showing a raw Mix
  stacktrace, and retry approved write requests through `agentic` to avoid
  re-entering the router permission loop.
- Added soft-lease timeouts for high-level client runs: `--timeout-ms` is now
  the idle lease, a 3x hard cap cancels stuck runs, heartbeat/lease/timeout
  events are logged, and the TUI shows an agent checklist with timeout state.
- Added an interactive TUI selector for pending filesystem tool permissions so
  users can approve safe writes, full access, or deny without typing commands.
- Added compact AgentMachine capability facts to runtime prompt context and
  taught chat mode how to answer agent-spawning meta questions accurately.
- Moved run execution into supervised per-run OTP subtrees with registry names,
  per-run task/tool-session supervisors, supervised MCP sessions, and telemetry
  events alongside existing JSONL logs.
- Ignored local Playwright MCP runtime artifacts and common Playwright report/output directories.
- Fixed the TUI Playwright MCP preset so `--headless` is passed to Playwright MCP instead of `npx`.
- Added per-agent persistent MCP stdio sessions, MCP `clientInfo` initialization, stdio env reference handling, TUI `/mcp add playwright` preset/config commands, web-browse routing for Playwright MCP, a self-contained Playwright MCP example config, and an opt-in paid OpenRouter Playwright MCP integration test target.
- Hide `assistant_delta` event rows in the TUI activity feed and show a content-free thinking animation while responses stream.
- Added compact runtime facts to provider prompts so models see current UTC date/time and selected workflow route without needing a tool call.
- Added an internal read-only `tool` route for `auto` so time and read-only tool requests skip the `basic` finalizer while exposing only read-risk tools.
- Documented the TUI run and session log locations in `AGENTS.md` for future debugging.
- Added a single Elixir event log collector for session-level JSONL logs, including workflow routing, runtime events, tool calls, agent activity, skills, and final summaries.
- Auto-add the safe `time` harness for `auto` time/date intent when another tool harness is already active, so time questions can use the clock tool without switching saved tools.
- Added a dedicated `time` tool harness for the clock tool while keeping `demo` as a compatibility alias.
- Routed `auto` time/date intent to no-tool `chat` when no time-capable harness is configured instead of failing before the model call.
- Added an opt-in local multilingual router classifier using Ortex, Tokenizers, and an explicit Hugging Face model install task, with CLI/TUI router settings and route confidence metadata.
- Added a PlantUML runtime flow diagram covering workflow routing, skills, MCP, tool harnesses, orchestration, and provider tool loops.
- Increased TUI auto/agentic run timeout to 240 seconds and displayed the active run timeout in the run banner.
- Emitted `run_started` before spawning initial agents so JSONL run logs start deterministically.
- Returned recoverable tool execution errors, including timeouts, to the provider as tool results so the model can choose another tool approach.
- Fixed JSON decoding of escaped UTF-16 surrogate pairs in provider tool-call arguments.
- Added progressive workflow routing with `chat`, `basic`, `agentic`, and `auto`, so simple TUI messages skip the planner while summaries report the requested and selected route.
- Kept the TUI input active during runs and added an editable local message queue that drains serially after the current run finishes.
- Added opt-in response streaming over JSONL with deterministic event summaries/details, provider request and assistant delta events, and a live scrollable TUI activity feed.
- Added ClawHub skill autodiscovery, show, install, update, zip validation, lockfile provenance, and thin TUI `/skills search/show/install/update` pass-through commands.
- Documented the skills command model, runtime flags, TUI commands, registry format, and ClawHub autodiscovery integration in `docs/skills.md`.
- Added Codex-compatible skills with strict `SKILL.md` manifests, registry install/create/list/show/remove commands, run-time auto or explicit skill selection, summary/events visibility, fixed skill resource tools, and TUI `/skills` commands.
- Skipped the finalizer for direct planner decisions so simple TUI requests complete after the planner answer.
- Changed the TUI to use planner-managed `agentic` runs, expose planner direct/delegate decisions, and ignore legacy saved workflow values.
- Fixed `apply_patch` to honor git-style `new file mode` and `deleted file mode` patches when headers use matching `a/` and `b/` paths.
- Added `FEATURES.md` as a linked index of the current project feature set.
- Added `AGENT_MACHINE_PAID_OPENROUTER_MODEL` to run paid OpenRouter tests against an explicit alternate model.
- Added opt-in paid OpenRouter Step 3.5 Flash provider, client, MCP tool-use, Mix CLI, TUI adapter, TUI agentic delegation, local-files, and code-edit tool integration tests with a separate manual pipeline.
- Added repeated tool harness support plus explicit MCP stdio/Streamable HTTP integration with allowlisted namespaced tools.
- Increased the TUI remote-provider HTTP timeout and tightened agentic filesystem planning to avoid fragile parallel read/write workers.
- Improved TUI timeout reporting, run banners, and default tool-run budget for multi-step file tasks.
- Added an explicit `run_test_command` capability for `code-edit` with allowlisted commands and thin TUI pass-through.
- Added centralized secrets redaction for read/search tool output, summaries, JSONL events, and run logs.
- Added per-run TUI JSONL log files and a fallback display for completed runs without final output.
- Preserved tool availability context for agentic planner/finalizer prompts and included recent TUI chat context in runs.
- Accepted fenced planner JSON in agentic delegation and disabled tools for planner/finalizer agents.
- Added a TUI filesystem-write permission preflight with `/allow-tools`, `/yolo-tools`, and `/deny-tools`.
- Added explicit tool-root runtime context and TUI run banners that show whether tools are active.
- Added canonical mutation tool summaries with relative changed files, hashes, byte counts, and compact diff stats.
- Added code-edit checkpoints, rollback tool support, and `mix agent_machine.rollback`.
- Added explicit tool approval modes and approval risk metadata for tool execution.
- Added a separate `code-edit` harness with structured edit and unified patch tools.
- Reworked `README.md` into a usage-first quick start without implementation details.
- Added `file_info`, `append_file`, and `replace_in_file` to the constrained `local-files` harness with explicit permissions.
- Added explicit tool execution policies, per-tool permissions, safer failed-tool events, bounded writes, and symlink-aware file listing.
- Added provider-native tool continuation loops with explicit `tool_max_rounds`, provider continuation payloads, and TUI pass-through.
- Added an explicit `create_dir` tool to the constrained `local-files` harness.
- Hardened the `local-files` path guard to require an existing root and reject symlink escapes.
- Added `read_file` and `list_files` to the constrained `local-files` tool harness.
- Added `search_files` to the `local-files` tool harness using `rg` for fast constrained file search.
- Added a constrained `local-files` tool harness, `write_file` tool, and TUI `/tools local-files <root> <timeout-ms>` setup.
- Persisted TUI workflow, provider, and provider-specific selected model settings across restarts.
- Added `mix agent_machine.run --log-file <path>` to persist Elixir-side JSONL run events and final summaries.
- Added an explicit CLI tool harness with provider-native OpenAI/OpenRouter tool-call adapters and a safe built-in `now` demo tool.
- Added searchable TUI model picker behavior for `/model`, including lazy model loading before opening the picker.
- Strengthened AGENTS.md around TUI thin-wrapper rules, TDD/testing priority, and TUI clean architecture.
- Split TUI view rendering helpers out of the Bubble Tea update/command logic.
- Split TUI provider model loading and pricing lookup out of the Bubble Tea model file.
- Split the TUI config persistence and process environment adapter out of the Bubble Tea model file.
- Split the TUI CLI/process adapter out of the Bubble Tea model file.
- Added AGENTS.md responsibility boundaries and drift checks for runtime, workflows, providers, CLI, TUI, and Makefile.
- Moved opt-in delegation response parsing out of `AgentRunner` into a dedicated module.
- Removed the generated TUI binary from source control and ignored future local builds.
- Added an explicit `agentic` workflow with planner-driven structured delegation.
- Added opt-in parsing for planner JSON output into delegated worker agents.
- Added explicit workflow selection to `RunSpec`, `mix agent_machine.run`, and the TUI setup flow.
- Added run context to remote provider prompts so finalizers can see prior agent outputs.
- Added in-memory TUI command/message history navigation with `Up` and `Down`.
- Added a root `Makefile` for common local test, quality, TUI, and explicit CLI run commands.
- Added `mix agent_machine.run --jsonl` for live event streaming plus a final summary envelope.
- Added a validated client/orchestrator event sink for live run progress consumers.
- Overhauled the Bubble Tea TUI with separate Setup, Chat, Agents, Agent Detail, and Help views.
- Added live TUI agent tree updates from streamed run events, including parent/child delegated agents.
- Added TUI navigation keys for view switching, back navigation, and agent selection while preserving common input editing shortcuts.
- Required explicit TUI provider setup before starting normal message runs.
- Converted the Bubble Tea TUI from a run form into a conversation client with slash commands.
- Added TUI commands for provider, key, model loading, settings, and last-run agent inspection.
- Marked client/TUI summaries as failed when any agent result failed and surfaced result errors.
- Added provider-specific model loading to the TUI for OpenAI and OpenRouter.
- Added TUI model cycling from loaded provider model lists.
- Removed manual price and timeout fields from the TUI remote-provider form.
- Added TUI pricing resolution from OpenAI model profiles and the OpenRouter models API.
- Added TUI run and HTTP timeout defaults for provider runs.
- Added TUI API key entry, local config persistence, and provider-specific key injection for remote runs.
- Added `AgentMachine.Providers.OpenRouterChat` with explicit `OPENROUTER_API_KEY` configuration.
- Added `openrouter` support to `AgentMachine.RunSpec`, the basic workflow, and `mix agent_machine.run`.
- Added Echo/OpenAI/OpenRouter provider selection to the Bubble Tea TUI.
- Added TUI validation for remote model, pricing, HTTP timeout, and provider API key configuration.
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
