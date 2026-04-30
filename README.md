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

When the local zero-shot classifier model is installed in the standard TUI
model directory, the TUI uses it for intent detection. If it is not installed,
the runtime still stays conservative and explicit.

**Tools are capabilities, not defaults**

Configured tools are not automatically exposed to every prompt. Tool access is
selected per run and constrained by intent, root path, approval mode, and tool
risk. Missing required configuration fails fast with an explicit error.

**Agentic work is visible**

When a task needs delegation, the runtime can create a planner and worker
agents. The TUI shows each agent's status, parent, elapsed time, recent events,
tool activity, and final output when available.

**Everything important is logged**

Runs can produce JSON or JSONL output. The TUI also writes session-level JSONL
logs that include route decisions, provider calls, tool calls, agent lifecycle
events, MCP activity, heartbeats, timeout events, and final summaries.

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
/key <api-key>
/models reload
/model
/tools off
/tools local-files <root> <timeout-ms> <max-rounds> <approval-mode>
/tools code-edit <root> <timeout-ms> <max-rounds> <approval-mode>
/mcp add playwright npx @playwright/mcp@latest
/agents
/agent <id>
```

The TUI keeps saved settings in a local user config file with `0600`
permissions. Override the location with `AGENT_MACHINE_TUI_CONFIG`.

Default config paths:

```text
macOS: ~/Library/Application Support/agent-machine/tui-config.json
Linux: ~/.config/agent-machine/tui-config.json
```

Session logs are written under the same config area in `logs/*.jsonl`.

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
  --timeout-ms 30000 \
  --max-steps 6 \
  --max-attempts 1 \
  --log-file ./agent-machine-run.jsonl \
  "Review this project"
```

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
Write operations require an approval mode that permits the requested risk. The
TUI asks before enabling broader filesystem permissions and lets you allow safe
writes, allow full access, or deny the request.

Approval modes:

- `read-only`
- `ask-before-write`
- `auto-approved-safe`
- `full-access`

Test commands are intentionally narrow. A model can run tests only through
`code-edit`, only with `full-access`, and only when the exact command was
allowlisted with `--test-command`.

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

Browser navigation is a network-capable action, so it requires the appropriate
approval level. A prompt should clearly request browser/MCP work, for example:

```text
Use agents and Playwright MCP to open https://example.com and report the page title.
```

Auto mode also treats Google/search/news-style research prompts as browser work
when the Playwright MCP browser tools are configured.
If browser work is detected while approval is too narrow, the TUI prompts for
MCP browser full-access and retries as an MCP-only run.

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
- Tool errors are returned to the model as tool results when safe, so it can try
  another approach within the configured round limit.
- The TUI stops before model execution when a request obviously needs broader
  filesystem permission.

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
