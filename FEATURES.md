# Features

This is a linked index of the current AgentMachine feature set. It points to
the public docs and the main implementation boundaries for each area.

## Runtime

- [High-level client runner](README.md#cli-usage) through
  [`AgentMachine.ClientRunner`](lib/agent_machine/client_runner.ex), used by the
  CLI and TUI.
- [Explicit run specs](README.md#required-values) through
  [`AgentMachine.RunSpec`](lib/agent_machine/run_spec.ex), with fail-fast
  validation for required workflow, provider, timeout, step, attempt, model,
  pricing, tool, and MCP values.
- [Orchestrated agent runs](lib/agent_machine/orchestrator.ex) with run state,
  task spawning, dependency scheduling, retries, finalizers, event recording,
  delegation, artifacts, and usage aggregation.
- [Usage tracking](lib/agent_machine/usage.ex) and
  [usage aggregation](lib/agent_machine/usage_ledger.ex), including token and
  cost totals in client summaries.
- [In-memory run events](README.md#cli-usage) for run start, agent start,
  retries, agent finish, run completion, and failure.
- [Redacted output](README.md#cli-usage) for text summaries, JSON output, JSONL
  events, logs, read-style tool results, and secret-looking values.

## Workflows

- [Basic workflow](README.md#workflows) through
  [`AgentMachine.Workflows.Basic`](lib/agent_machine/workflows/basic.ex), with a
  straightforward assistant plus finalizer.
- [Agentic workflow](README.md#workflows) through
  [`AgentMachine.Workflows.Agentic`](lib/agent_machine/workflows/agentic.ex),
  with a planner, delegated workers, and a finalizer.
- [Structured delegation parsing](lib/agent_machine/delegation_response.ex) for
  opt-in planner JSON that creates delegated worker specs.
- [Run context prompt formatting](lib/agent_machine/run_context_prompt.ex) so
  remote providers can receive prior results, artifacts, tool availability, and
  tool root context.
- [Dependency-ordered initial agents](lib/agent_machine/orchestrator.ex), with
  validation for missing dependencies, duplicates, self-dependencies, and
  cycles.
- [Finalizer agents](lib/agent_machine/orchestrator.ex) that synthesize the
  user-facing result after normal and delegated work completes.
- [Explicit retry attempts](README.md#required-values) through `max_attempts`
  and per-attempt provider options.
- [Run-scoped artifacts](lib/agent_machine/orchestrator.ex) for shared memory
  between delegated agents, with overwrite protection.

## Providers

- [Echo provider](README.md#providers) through
  [`AgentMachine.Providers.Echo`](lib/agent_machine/providers/echo.ex) for local
  no-API testing.
- [OpenAI Responses provider](README.md#openai) through
  [`AgentMachine.Providers.OpenAIResponses`](lib/agent_machine/providers/openai_responses.ex).
- [OpenRouter Chat Completions provider](README.md#openrouter) through
  [`AgentMachine.Providers.OpenRouterChat`](lib/agent_machine/providers/openrouter_chat.ex).
- [Provider contract](lib/agent_machine/provider.ex) that keeps providers at
  the model/API boundary.
- [Provider-native tool-call adapters](lib/agent_machine/tool_harness.ex) for
  OpenAI and OpenRouter function/tool calling.

## CLI

- [`mix agent_machine.run`](README.md#cli-usage) through
  [`Mix.Tasks.AgentMachine.Run`](lib/mix/tasks/agent_machine.run.ex), with text,
  JSON, JSONL, and JSONL log-file output.
- [`mix agent_machine.rollback`](README.md#tools) through
  [`Mix.Tasks.AgentMachine.Rollback`](lib/mix/tasks/agent_machine.rollback.ex),
  for restoring code-edit checkpoints without running a provider.
- [Makefile shortcuts](README.md#common-commands) for dependencies, tests,
  quality, local echo runs, TUI runs, and paid OpenRouter integration tests.
- [Manual paid OpenRouter integration workflow](.github/workflows/openrouter-paid.yml)
  for opt-in provider, client, CLI, TUI, MCP, local-files, and code-edit checks.

## Tool Harnesses

- [Tool harness adapter](README.md#tools) through
  [`AgentMachine.ToolHarness`](lib/agent_machine/tool_harness.ex), including
  repeated harness merging and duplicate provider-visible name checks.
- [Tool policy enforcement](lib/agent_machine/tool_policy.ex) with explicit
  permissions, approval modes, and approval risk metadata.
- [Provider-native continuation loop](lib/agent_machine/agent_runner.ex), which
  runs allowed tool calls until a final provider response or `tool_max_rounds`
  is reached.
- [Demo harness](README.md#tools) with the
  [`now`](lib/agent_machine/tools/now.ex) tool.
- [Local-files harness](README.md#tools) with constrained directory creation,
  metadata, listing, reading, searching, writing, appending, and exact text
  replacement under an explicit root.
- [Code-edit harness](README.md#tools) with file inspection, listing, reading,
  search, structured edits, unified patch application, checkpoints, rollback,
  and optional allowlisted test commands.
- [MCP harness](README.md#tools) with explicitly allowlisted, namespaced MCP
  tools over stdio or Streamable HTTP.

## File And Code Tools

- [Path guard](lib/agent_machine/tools/path_guard.ex) that requires an existing
  root, rejects root escapes, and protects against symlink write targets.
- [File metadata](lib/agent_machine/tools/file_info.ex), file listing
  ([`list_files`](lib/agent_machine/tools/list_files.ex)), file reading
  ([`read_file`](lib/agent_machine/tools/read_file.ex)), and ripgrep-based
  search ([`search_files`](lib/agent_machine/tools/search_files.ex)).
- [Directory creation](lib/agent_machine/tools/create_dir.ex), file writing
  ([`write_file`](lib/agent_machine/tools/write_file.ex)), appending
  ([`append_file`](lib/agent_machine/tools/append_file.ex)), and exact
  replacement ([`replace_in_file`](lib/agent_machine/tools/replace_in_file.ex)).
- [Structured edits](lib/agent_machine/tools/apply_edits.ex) and
  [Elixir-native patch application](lib/agent_machine/tools/apply_patch.ex).
- [Code-edit checkpoints](lib/agent_machine/tools/code_edit_checkpoint.ex) and
  [rollback](lib/agent_machine/tools/rollback_checkpoint.ex).
- [Allowlisted test command execution](lib/agent_machine/tools/run_test_command.ex)
  without shells, under the explicit tool root, with bounded redacted output.
- [Mutation result summaries](lib/agent_machine/tools/tool_result_summary.ex)
  with relative paths, hashes, byte counts, compact diff stats, and checkpoint
  IDs.

## MCP

- [MCP config parsing](lib/agent_machine/mcp/config.ex) with explicit server
  IDs, tool allowlists, permissions, risk, transport config, and env-secret
  references.
- [MCP client](lib/agent_machine/mcp/client.ex) for stdio and Streamable HTTP
  JSON-RPC calls.
- [MCP tool factory](lib/agent_machine/mcp/tool_factory.ex) that exposes
  namespaced provider-visible tool names.
- [MCP tool runner](lib/agent_machine/mcp/tool_runner.ex) that normalizes and
  bounds tool results.

## Terminal UI

- [Bubble Tea TUI](README.md#terminal-ui) in [`tui/`](tui/) with setup, chat,
  agents, agent detail, and help views.
- [CLI process adapter](tui/agent_machine_cli.go) that calls the stable
  `mix agent_machine.run` boundary.
- [Config persistence](tui/config.go) for workflow, provider, selected models,
  API keys, tool setup, MCP config path, and command/test-command state.
- [Provider model and pricing lookup](tui/provider_models.go) for OpenAI and
  OpenRouter.
- [Slash commands](README.md#terminal-ui) for workflow, provider, API key,
  model loading/selection, tool harness setup, test commands, MCP config,
  settings, agent inspection, history, and clearing/quitting.
- [Filesystem-write permission preflight](README.md#terminal-ui) with
  `/allow-tools`, `/yolo-tools`, and `/deny-tools`.
- [Per-run JSONL logs](README.md#terminal-ui) written next to the TUI config.

## Quality And Tests

- [Full quality gate](README.md#development) through `mix quality`, covering
  formatting checks, warnings-as-errors compilation, Credo strict mode, and
  tests.
- [Elixir test suite](test/) for orchestration, workflows, client summaries,
  provider tool continuation, tool policy, MCP integration, redaction, JSON, and
  individual tools.
- [Go TUI test suite](tui/) for the terminal client, config, CLI adapter, and
  paid OpenRouter integration paths.
- [Paid OpenRouter integration tests](README.md#development) gated behind
  `OPENROUTER_API_KEY` and an optional `AGENT_MACHINE_PAID_OPENROUTER_MODEL`.

## Deferred Work

- [Planned future work](plan.md) is tracked separately and is not part of the
  current shipped feature set.
