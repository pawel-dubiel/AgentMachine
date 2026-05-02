# AgentMachine

AgentMachine is a terminal-first AI workbench for running useful AI tasks on
local projects with explicit permissions, visible progress, and auditable logs.

It is built for people who want more than a chat box, but still want the system
to stay understandable. You can ask a normal question, inspect files, edit code,
run allowlisted checks, use MCP tools such as Playwright, and review what
happened afterward from structured logs.

The product goal is simple: make AI-assisted project work feel practical and
controlled. The model should only receive the capabilities the current request
needs, and the user should always be able to see what was selected, what tools
were available, which agents ran, and what changed.

## What It Can Do

- Answer normal questions without exposing tools.
- Inspect local folders and files under an explicit root.
- Create and edit files when write tools are approved.
- Apply code patches and keep rollback checkpoints for code-edit operations.
- Run exact allowlisted test commands when full access is enabled.
- Use MCP servers, including a managed Playwright preset for browser work.
- Load reusable skills that add task-specific instructions and references.
- Route simple requests through a fast path and larger tasks through agentic
  planner/worker flows, using a local zero-shot intent model when installed.
- Create controlled swarm runs for explicit multiple-variant requests, with
  isolated variant workspaces and evaluator comparison.
- Compact long conversations manually and compact run context automatically
  when explicit context limits are configured.
- Write JSONL logs for runs and TUI sessions so behavior can be debugged later.
- Redact sensitive-looking values from logs, summaries, and tool results.

## How It Feels To Use

In the TUI you type a request such as:

```text
Explain what this project does.
```

or:

```text
Read README.md and tell me what is missing.
```

or:

```text
Fix the typo in docs/intro.md.
```

AgentMachine chooses the smallest execution path that fits the request. A plain
conversation stays as chat. Read-only work can use read-only tools. Write or
test work requires an approved write-capable harness. Larger delegated work can
use planner and worker agents.

That routing is intentionally visible. The TUI shows the requested mode, the
selected route, the active tools, a compact work checklist, and the log path
for the run. Tool activity is summarized in plain language so read/search/write
steps are easier to follow without exposing full file contents in the activity
feed.

## Core Concepts

**Smart auto mode**

Normal TUI messages use smart automatic routing. The app chooses a small,
practical path for each request:

- plain chat for normal conversation.
- fast read-only tool use for inspection and lookup.
- agentic planner/worker execution for delegated, write, code-edit, test, or
  browser work.

By default, auto mode asks the selected provider/model to classify the request
through a strict JSON router prompt before any workflow starts. Deterministic
rules still guard obvious tool intents, and `/router deterministic` or
`/router local <model-dir>` can select the older explicit router modes.
Local router model installs are pinned to an immutable Hugging Face revision and
verify SHA-256 hashes for every downloaded artifact before use.

**Tools are capabilities, not defaults**

Configured tools are not automatically exposed to every prompt. Tool access is
selected per run and constrained by intent, root path, approval mode, and tool
risk. Missing required configuration fails fast with an explicit error.

**Agentic work is visible**

When a task needs delegation, the runtime can create a planner and worker
agents. The TUI shows each agent's status, parent, elapsed time, recent events,
tool activity, streamed provider text, and final output when available. Planner
delegation responses are strict JSON and fail fast when the provider returns
malformed JSON. Assistant responses and agent final output render basic
Markdown formatting such as bold text, headings, inline code, links, lists, and
blockquotes.

**Swarm strategy**

When the request explicitly asks for a swarm, variants, competing solutions, or
several approaches, auto routing selects the agentic workflow with a visible
`swarm` strategy. The planner creates isolated variant workers, normally
`minimal`, `robust`, and `experimental`, followed by an evaluator that compares
the variants. Variants use separate workspaces such as
`.agent_machine/swarm/<run_id>/<variant_id>` under the configured tool root.
For swarm variants, filesystem and code-edit tools are rooted at the variant
workspace, not the original project root. The planner can propose workers and
metadata, but tool permissions still come only from runtime options and
approval callbacks. The runtime validates the graph, enforces step/depth
limits, records variant metadata on events, and does not auto-merge a winning
variant back into the original project.

**Everything important is logged**

Runs can produce JSON or JSONL output. The TUI runs one long-lived Elixir
session daemon per conversation and writes session-level JSONL logs that include
route decisions, provider calls, tool calls, agent lifecycle events, MCP
activity, heartbeats, timeout events, sidechain agent notifications, and final
summaries.

## Requirements

- Elixir `1.19.5`
- Erlang/OTP `28`
- Go `1.24.2` for the terminal UI
- `rg` (`ripgrep`) for local file search tools
- Node.js 20 or newer only when using Playwright MCP

On macOS with Homebrew:

```sh
brew install elixir ripgrep
```

Check local versions:

```sh
elixir --version
mix --version
erl -eval 'erlang:display(erlang:system_info(otp_release)), halt().' -noshell
go version
```

## Quick Start

Install dependencies:

```sh
make deps
```

Run a local smoke test without any external model provider:

```sh
make run-echo TASK="Summarize what AgentMachine can do"
```

Start the terminal UI:

```sh
make run
```

Run the quality gate:

```sh
make quality
```

For a deeper feature checklist, see [FEATURES.md](FEATURES.md). For a runtime
flow diagram, see [docs/agent-runtime-flow.puml](docs/agent-runtime-flow.puml).

## Terminal UI

Start the TUI:

```sh
make tui
```

or:

```sh
cd tui
go run .
```

Useful first commands:

```text
/setup
/provider echo|openai|openrouter
/theme classic|matrix
/key <api-key>
/models reload
/model
/router llm
/router deterministic
/router local <model-dir>
/compact
/context status
/context window <tokens> [warning-percent]
/context tokenizer <path>
/context reserve <tokens>
/context run-compaction on <compact-percent> <max-compactions>
/tools off
/tools local-files <root> <timeout-ms> <max-rounds> <approval-mode>
/tools code-edit <root> <timeout-ms> <max-rounds> <approval-mode>
/mcp add playwright npx @playwright/mcp@latest
/mcp-config <path> <timeout-ms> <max-rounds> <approval-mode>
/agents
/agent <id>
/send-agent <agent-id> <message>
/read-agent <agent-id>
```

Agent detail views show streamed provider text separately from the final
normalized output, decision, errors, and compacted event history. The TUI also
supports `classic` and Matrix-inspired `matrix` themes through `/theme`.

The TUI keeps saved user settings in `~/.agent-machine/tui-config.json` with
`0600` permissions. Override the exact config path with
`AGENT_MACHINE_TUI_CONFIG`.

Config precedence:

```text
AGENT_MACHINE_TUI_CONFIG
nearest ./.agent-machine/tui-config.json or ./.agentMachine/tui-config.json
~/.agent-machine/tui-config.json
legacy OS config dir fallback, such as ~/Library/Application Support/agent-machine/tui-config.json
```

Project config files may override non-secret settings. Provider API keys must
stay in the user config, project `full-access` tool approval is rejected, and
project path settings must stay inside the project root. Session logs are
written under the user config area in `logs/*.jsonl`.
Sidechain agent transcripts are stored under `logs/sessions/<session-id>/`.

The TUI talks to the runtime through:

```sh
mix agent_machine.session --jsonl-stdio --session-id <id> --session-dir <path>
```

That daemon accepts JSONL commands such as `user_message`,
`send_agent_message`, `read_agent_output`, `cancel_agent`, `shutdown`, and
`permission_decision`. Normal one-shot CLI usage remains
`mix agent_machine.run`.

## Providers

AgentMachine currently supports:

- `echo`: local provider for smoke tests and examples.
- `openai`: OpenAI Responses API.
- `openrouter`: OpenRouter Chat Completions API.

Remote provider runs require an API key, model id, HTTP timeout, and explicit
pricing values. Pricing is not guessed because cost reporting should be
intentional.

OpenAI:

```sh
export OPENAI_API_KEY="sk-..."
```

OpenRouter:

```sh
export OPENROUTER_API_KEY="..."
```

The TUI can save provider keys locally so you do not need to export them for
every run.

## CLI Usage

Use the CLI when you want scriptable runs or exact control over flags:

```sh
mix agent_machine.run \
  --workflow auto \
  --provider echo \
  --router-mode deterministic \
  --timeout-ms 30000 \
  --max-steps 6 \
  --max-attempts 1 \
  --json \
  "Review this project and summarize the next step"
```

Use JSONL for live progress and machine-readable event streams:

```sh
mix agent_machine.run \
  --workflow auto \
  --provider echo \
  --router-mode deterministic \
  --timeout-ms 30000 \
  --max-steps 6 \
  --max-attempts 1 \
  --jsonl \
  --stream-response \
  "Explain the current README"
```

Write a run log:

```sh
mix agent_machine.run \
  --workflow auto \
  --provider echo \
  --router-mode deterministic \
  --timeout-ms 30000 \
  --max-steps 6 \
  --max-attempts 1 \
  --log-file ./agent-machine-run.jsonl \
  "Review this project"
```

Compact the current conversation history through the selected provider/model:

```sh
mix agent_machine.compact \
  --provider echo \
  --model echo \
  --http-timeout-ms 30000 \
  --input-price-per-million 0 \
  --output-price-per-million 0 \
  --input-file ./conversation.json \
  --json
```

The input file must contain:

```json
{"type":"conversation","messages":[{"role":"user","text":"..."}]}
```

The compact command requires strict JSON output from the model and fails on
missing provider/model/pricing/timeout options, invalid input, invalid provider
JSON, or an empty summary.

Context budget and run-context compaction options are explicit:

```sh
mix agent_machine.run \
  --workflow agentic \
  --provider echo \
  --timeout-ms 30000 \
  --max-steps 6 \
  --max-attempts 1 \
  --context-window-tokens 128000 \
  --context-warning-percent 80 \
  --context-tokenizer-path ./tokenizer.json \
  --reserved-output-tokens 4096 \
  --run-context-compaction on \
  --run-context-compact-percent 90 \
  --max-context-compactions 2 \
  --json \
  "Plan and execute the task"
```

Context budgets are separate from cumulative run usage. The runtime emits
`context_budget` events before provider requests by measuring the exact request
body with `--context-tokenizer-path`. Unknown model context windows and missing
tokenizers are not guessed; the event reports `status: "unknown"` with an
explicit reason. If `--reserved-output-tokens` is omitted, available-token math
stays unknown instead of assuming zero. Automatic run-context compaction only
runs when enabled with a context window, compact threshold, maximum compaction
count, and a known budget measurement; otherwise it emits a skipped event.
The TUI mirrors the latest budget event in the status line.

Common Make targets:

```sh
make help
make deps
make test
make quality
make run
make tui
make tui-test
make tui-build
```

## Tools And Permissions

Tools are off until you enable a harness and provide the required limits. The
most common harnesses are:

| Harness | What it is for |
| --- | --- |
| `time` | Safe current time/date lookup. |
| `local-files` | Local file and folder reading plus simple file writes under an explicit root. |
| `code-edit` | Code-focused patch/edit operations with checkpoints and optional allowlisted tests. |
| `mcp` | Explicitly configured Model Context Protocol tools. |
| `skills` | Selected skill references and assets. |

Local file and code tools require `--tool-root`. Paths outside that root fail.
Tool permissions have two layers:

- Capability grants decide which narrow tools are visible to the current agent
  attempt, such as `code-edit` under one root, selected MCP tools from the
  already loaded MCP config, or exact allowlisted test commands.
- Execution approvals decide whether one concrete risky tool call may run, such
  as one write, delete, command, or network call.

The runtime enforces both layers. The TUI only displays permission requests and
sends approve/deny decisions back to the CLI.
When auto routing detects that a request needs a missing harness, broader
approval, allowlisted test command, or MCP browser capability, the Elixir
runtime returns a structured `capability_required` summary/event. The TUI
renders that runtime-owned requirement; it does not classify filesystem,
code-edit, test, or browser intent itself.

Session-control tools are a separate internal layer in TUI daemon runs. The
coordinator may use `spawn_agent`, `send_agent_message`, `read_agent_output`,
and `list_session_agents` to manage session sidechain agents. These tools do not
grant filesystem, MCP, command, or network capability; worker agents still need
the normal tool harness, root, MCP config, exact command allowlist, and
permission approvals.

Approval modes:

- `read-only`
- `ask-before-write`
- `auto-approved-safe`
- `full-access`

Interactive permission control is available only for JSONL runs:

```sh
mix agent_machine.run \
  --jsonl \
  --permission-control jsonl-stdio \
  --tool-harness code-edit \
  --tool-root /path/to/project \
  --tool-timeout-ms 30000 \
  --tool-max-rounds 6 \
  --tool-approval-mode ask-before-write \
  "fix the failing tests"
```

In interactive runs, `ask-before-write` exposes a safe `request_capability`
negotiation tool so a worker can ask for a current-attempt grant mid-run. Grants
are run-local, are not inherited by sibling workers, and are not persisted.
`full-access` bypasses approval prompts for already allowed risk classes, but it
does not bypass tool allowlists, MCP config allowlists, or path guards.

Test commands are intentionally narrow. A model can run tests only through
`code-edit` and only when the exact command was allowlisted with
`--test-command` when using the dedicated `run_test_command` tool.

When `code-edit` runs with `ask-before-write` or `full-access`, it also exposes
foreground and background shell-command tools for project work. Shell commands
must provide an explicit `cwd` under `--tool-root` and an explicit `timeout_ms`
no greater than `--tool-timeout-ms`. They run through a POSIX shell, do not
support interactive stdin, return bounded redacted combined output, and create
code-edit rollback checkpoints for tracked text-file changes under the tool
root.
Background commands can be started, read, listed, and stopped within the owning
run. This is a broad command capability; commands may still access the host
environment according to the operating system account that runs AgentMachine.

`ask-before-write` requires an approval callback, or
`--permission-control jsonl-stdio` in a JSONL CLI/TUI run, whenever exposed tools
include write, delete, command, or network risk.

Rollback for code-edit checkpoints:

```sh
mix agent_machine.rollback \
  --tool-root /path/to/project \
  --checkpoint-id <checkpoint-id>
```

## MCP And Browser Work

MCP support lets AgentMachine use external tool servers through explicit config.
The TUI includes a convenient Playwright preset:

```text
/mcp add playwright npx @playwright/mcp@latest
```

That writes a managed MCP config, allowlists browser navigation and page
snapshot tools, and keeps the setup visible in `/setup` and run banners.
When using a standalone MCP config, pass an explicit tool budget with
`/mcp-config <path> <timeout-ms> <max-rounds> <approval-mode>`.
MCP tool entries must include an explicit `inputSchema` object. AgentMachine
exposes that schema under the provider-visible `arguments` property and
validates arguments before any MCP transport call. Repeated identical malformed
MCP calls fail early instead of consuming every configured tool round.
Streamable HTTP MCP servers must use HTTPS unless they target loopback, and
environment-sourced HTTP headers are rejected on plain HTTP.

Browser navigation is a network-capable action, so it requires either
interactive `ask-before-write` permission control or explicit `full-access`. A
prompt should clearly request browser/MCP work, for example:

```text
Use agents and Playwright MCP to open https://example.com and report the page title.
```

Auto mode also treats Google/search/news-style research prompts as browser work
when the Playwright MCP browser tools are configured.
If browser work is detected while approval is too narrow, the runtime returns a
structured `capability_required` response and the TUI can prompt for interactive
approval or full-access before retrying as an MCP-only run.

For a standalone example config, see [examples/playwright.mcp.json](examples/playwright.mcp.json).

## Skills

Skills are reusable instruction bundles. They are useful when you want the same
style, policy, or reference material applied across runs.

A skill lives in a folder with a `SKILL.md` file. Optional references, assets,
scripts, and agent hints can be included, but script execution is off unless you
explicitly enable it.

Common commands:

```sh
mix agent_machine.skills create docs-helper \
  --skills-dir ~/.agent_machine/skills \
  --description "Helps write concise project documentation"

mix agent_machine.skills generate docs-helper \
  --skills-dir ~/.agent_machine/skills \
  --description "Helps write concise project documentation" \
  --provider openrouter \
  --model <model-id> \
  --http-timeout-ms 120000 \
  --input-price-per-million <input-price> \
  --output-price-per-million <output-price>

mix agent_machine.skills list --skills-dir ~/.agent_machine/skills
mix agent_machine.skills install docs-helper --skills-dir ~/.agent_machine/skills
```

More detail is in [docs/skills.md](docs/skills.md).

## Reliability And Observability

AgentMachine is built on OTP supervision. Each run has isolated runtime
processes for orchestration, agent tasks, event collection, and tool sessions.
From a user perspective this means long runs can be tracked, timed out, and
cleaned up without leaving hidden background work.

High-level CLI/TUI timeouts use an idle lease. Runtime activity such as provider
events, tool calls, stream deltas, and agent heartbeats keeps the run alive, but
only up to a hard cap. Timeout events are logged.

Logs and summaries are redacted before output. The redactor masks common API
keys, bearer tokens, authorization headers, GitHub tokens, AWS access key IDs,
private key blocks, and secret-looking fields.

## Safety Model

AgentMachine prefers explicit errors over hidden defaults:

- Required inputs are not guessed.
- Tools are denied by default.
- Roots, budgets, and approval modes must be explicit.
- MCP secrets must come from environment references, not inline config values.
- MCP HTTP configs do not send environment-sourced headers over plain HTTP.
- Tool errors are returned to the model as tool results when safe, so it can try
  another approach within the configured round limit.
- The runtime stops before model execution when auto routing needs a missing
  capability and returns a structured `capability_required` response.

## Development

Run focused tests while working:

```sh
mix test
```

Run the full local quality gate:

```sh
mix quality
```

That checks formatting, compiles with warnings as errors, runs Credo in strict
mode, and runs tests.

Run TUI tests:

```sh
make tui-test
```

Paid OpenRouter integration tests are excluded from normal local gates. They
require `OPENROUTER_API_KEY`:

```sh
OPENROUTER_API_KEY="..." make test-openrouter-paid
```

The Playwright MCP paid test additionally requires `npx` and Node.js 20 or
newer:

```sh
OPENROUTER_API_KEY="..." make test-openrouter-playwright-mcp
```

The paid swarm end-to-end eval is intentionally separate from normal paid
regression tests. It runs a three-model OpenRouter matrix through planner,
variant workers, tool calls, evaluator, and finalizer:

```sh
OPENROUTER_API_KEY="..." make test-openrouter-swarm-e2e
```
