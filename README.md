# AgentMachine

AgentMachine runs task prompts from the command line or a terminal UI. The
fastest way to try it is with the local `echo` provider, which does not call an
external API.

## Requirements

- Elixir `1.19.5`
- Erlang/OTP `28`
- Go `1.24.2` for the terminal UI
- `rg` (`ripgrep`) when using local file search tools

On macOS with Homebrew:

```sh
brew install elixir ripgrep
```

Check your local versions:

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

Run a local task:

```sh
make run-echo TASK="Summarize what this project can do"
```

Start the terminal UI:

```sh
make run
```

Run the full quality gate:

```sh
make quality
```

For a linked overview of the complete feature set, see
[FEATURES.md](FEATURES.md).

## Common Commands

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

The `make run-*` commands require the values they need and fail with an explicit
error when something is missing.

```sh
make run-echo TASK="Review this project"
make run-echo-json TASK="Review this project"
make run-echo-jsonl TASK="Review this project"
make run-agentic-echo-jsonl TASK="Review this project"
```

## CLI Usage

Use `mix agent_machine.run` when you want direct control over a run:

```sh
mix agent_machine.run \
  --workflow basic \
  --provider echo \
  --timeout-ms 30000 \
  --max-steps 2 \
  --max-attempts 1 \
  "Review this project and summarize the next step"
```

Use JSON output for scripts:

```sh
mix agent_machine.run \
  --workflow basic \
  --provider echo \
  --timeout-ms 30000 \
  --max-steps 2 \
  --max-attempts 1 \
  --json \
  "Review this project and summarize the next step"
```

Use JSONL output for streaming progress:

```sh
mix agent_machine.run \
  --workflow basic \
  --provider echo \
  --timeout-ms 30000 \
  --max-steps 2 \
  --max-attempts 1 \
  --jsonl \
  "Review this project and summarize the next step"
```

Write the run log to a file:

```sh
mix agent_machine.run \
  --workflow basic \
  --provider echo \
  --timeout-ms 30000 \
  --max-steps 2 \
  --max-attempts 1 \
  --log-file ./agent-machine-run.jsonl \
  "Review this project and summarize the next step"
```

JSON, JSONL, text summaries, and run log files are redacted before output.
The redactor masks common API keys, bearer tokens, authorization headers,
GitHub tokens, AWS access key IDs, private key blocks, and secret-looking
`KEY=value` or JSON fields. Redacted payloads include redaction metadata when a
value was masked.

## Workflows

Choose one workflow for each run:

- `basic`: runs a straightforward assistant task and returns a final answer.
- `agentic`: asks a planner to split the work before returning a final answer.

Examples:

```sh
mix agent_machine.run \
  --workflow basic \
  --provider echo \
  --timeout-ms 30000 \
  --max-steps 2 \
  --max-attempts 1 \
  "Write a short release note"
```

```sh
mix agent_machine.run \
  --workflow agentic \
  --provider echo \
  --timeout-ms 30000 \
  --max-steps 6 \
  --max-attempts 1 \
  --jsonl \
  "Review this project and suggest the next change"
```

## Providers

Available providers:

- `echo`: local provider for testing commands without an API key.
- `openai`: OpenAI Responses API.
- `openrouter`: OpenRouter Chat Completions API.

Remote provider runs require explicit model, timeout, and pricing values. Prices
are not guessed.

### OpenAI

Set your key:

```sh
export OPENAI_API_KEY="sk-..."
```

Run:

```sh
mix agent_machine.run \
  --workflow basic \
  --provider openai \
  --model "YOUR_OPENAI_MODEL" \
  --timeout-ms 30000 \
  --http-timeout-ms 120000 \
  --max-steps 2 \
  --max-attempts 1 \
  --input-price-per-million 0.25 \
  --output-price-per-million 2.00 \
  --json \
  "Review this project and summarize the next step"
```

### OpenRouter

Set your key:

```sh
export OPENROUTER_API_KEY="..."
```

Run:

```sh
mix agent_machine.run \
  --workflow basic \
  --provider openrouter \
  --model "YOUR_OPENROUTER_MODEL" \
  --timeout-ms 30000 \
  --http-timeout-ms 120000 \
  --max-steps 2 \
  --max-attempts 1 \
  --input-price-per-million 0.15 \
  --output-price-per-million 0.60 \
  --json \
  "Review this project and summarize the next step"
```

The Makefile also has OpenRouter helpers:

```sh
make run-openrouter-jsonl \
  TASK="Review this project" \
  MODEL="YOUR_OPENROUTER_MODEL" \
  INPUT_PRICE_PER_MILLION="0.15" \
  OUTPUT_PRICE_PER_MILLION="0.60"
```

## Tools

Tools are off unless you enable a harness and provide the required limits.
The TUI shows the active tool state in the run banner so it is visible whether
a model can actually perform local file actions.

The `demo` harness exposes a clock tool:

```sh
mix agent_machine.run \
  --workflow basic \
  --provider openrouter \
  --model "YOUR_OPENROUTER_MODEL" \
  --timeout-ms 30000 \
  --http-timeout-ms 120000 \
  --max-steps 2 \
  --max-attempts 1 \
  --input-price-per-million 0.15 \
  --output-price-per-million 0.60 \
  --tool-harness demo \
  --tool-timeout-ms 1000 \
  --tool-max-rounds 2 \
  --tool-approval-mode read-only \
  --json \
  "What time is it now?"
```

The `local-files` harness can work only under an explicit existing root. It can
create directories, inspect file metadata, list files, read files, search files,
write files, append to files, and replace exact text in files.

```sh
mix agent_machine.run \
  --workflow basic \
  --provider openrouter \
  --model "YOUR_OPENROUTER_MODEL" \
  --timeout-ms 30000 \
  --http-timeout-ms 120000 \
  --max-steps 2 \
  --max-attempts 1 \
  --input-price-per-million 0.15 \
  --output-price-per-million 0.60 \
  --tool-harness local-files \
  --tool-root /Users/pawel/mywiki \
  --tool-timeout-ms 1000 \
  --tool-max-rounds 2 \
  --tool-approval-mode auto-approved-safe \
  --json \
  "Create hello_world.md with Hello World"
```

The `code-edit` harness is a separate opt-in harness for code changes under an
explicit existing root. It can inspect, list, read, and search files, then apply
structured edits or unified diff patches. Patch application is implemented in
Elixir and does not shell out. Every successful code-edit mutation creates a
root-local checkpoint before writing. When explicit `--test-command` values are
provided with `full-access`, code-edit agents can also run those exact commands
through `run_test_command`.

```sh
mix agent_machine.run \
  --workflow basic \
  --provider openrouter \
  --model "YOUR_OPENROUTER_MODEL" \
  --timeout-ms 30000 \
  --http-timeout-ms 120000 \
  --max-steps 2 \
  --max-attempts 1 \
  --input-price-per-million 0.15 \
  --output-price-per-million 0.60 \
  --tool-harness code-edit \
  --tool-root /Users/pawel/project \
  --tool-timeout-ms 1000 \
  --tool-max-rounds 2 \
  --tool-approval-mode full-access \
  --test-command "mix test" \
  --json \
  "Update the README using a minimal patch"
```

Harnesses may be repeated. The runtime merges their allowed tools and policies,
then fails fast if two tools expose the same provider-visible name.

MCP tools are enabled with the `mcp` harness and an explicit config file. Tool
names exposed to the model are namespaced as `mcp_<server_id>_<tool_name>`.
MCP credentials must be environment-variable references; inline secret values
are rejected.

```json
{
  "servers": [
    {
      "id": "docs",
      "transport": "streamable_http",
      "url": "https://example.com/mcp",
      "headers": {"Authorization": "env:DOCS_MCP_AUTH"},
      "tools": [
        {"name": "search", "permission": "mcp_docs_search", "risk": "network"}
      ]
    }
  ]
}
```

```sh
mix agent_machine.run \
  --workflow basic \
  --provider openrouter \
  --model "YOUR_OPENROUTER_MODEL" \
  --timeout-ms 30000 \
  --http-timeout-ms 120000 \
  --max-steps 2 \
  --max-attempts 1 \
  --input-price-per-million 0.15 \
  --output-price-per-million 0.60 \
  --tool-harness local-files \
  --tool-harness mcp \
  --tool-root /Users/pawel/mywiki \
  --tool-timeout-ms 1000 \
  --tool-max-rounds 4 \
  --tool-approval-mode full-access \
  --mcp-config ./agent-machine.mcp.json \
  --json \
  "Search docs and update a local note"
```

Local file tool rules:

- `--tool-root` must already exist.
- Paths outside `--tool-root` fail.
- Models receive the explicit `tool_root` in runtime context and should use
  relative paths under that root for local file tools.
- In the `agentic` workflow, planner and finalizer agents do not receive tools;
  filesystem actions should be delegated to worker agents and reported only from
  worker `tool_results`.
- Planner and finalizer prompts still receive tool availability and `tool_root`
  as context, but they cannot call tools directly.
- Search requires `rg` in `PATH`.
- Writes require the parent directory to exist.
- Append and replace require existing regular files.
- Symlink write targets are rejected.
- Code edit tools validate all requested changes before writing.
- Code edit checkpoints are stored under
  `<tool-root>/.agent_machine/checkpoints/<checkpoint-id>/`.
- Code edit operations cannot modify `.agent_machine/checkpoints/**`.
- Rollback fails without writing if any affected file changed after the
  checkpoint.
- `--tool-timeout-ms`, `--tool-max-rounds`, and `--tool-approval-mode` are required when a harness is enabled.
- Approval modes are `read-only`, `ask-before-write`, `auto-approved-safe`, and `full-access`.
- `--test-command <command>` may be repeated only with `code-edit` and
  `full-access`; the model must use the exact allowlisted command string.
- Test commands run without a shell, under `--tool-root`, with `MIX_ENV=test`,
  the existing tool timeout, bounded output, and redaction on returned output.
- `--mcp-config <path>` requires `--tool-harness mcp`.
- MCP v1 supports stdio and Streamable HTTP only. It does not support legacy
  HTTP+SSE, resources, prompts, sampling, subscriptions, or server-initiated
  requests.
- MCP stdio servers are launched without a shell from the configured executable
  and args. MCP Streamable HTTP calls use JSON-RPC POST requests with the
  explicit tool timeout.

Read-style tools redact sensitive-looking text before returning file contents or
search match lines to the provider. Mutation tools still apply the exact
requested content; redaction is only for returned output and serialized logs.

Mutation tools return compact summaries for agents, logs, and clients. File
paths in summaries are relative to `--tool-root`; full file contents and full
diffs are not returned.

```json
{
  "summary": {
    "tool": "apply_patch",
    "status": "changed",
    "changed_count": 1,
    "created_count": 0,
    "updated_count": 1,
    "deleted_count": 0,
    "renamed_count": 0
  },
  "changed_files": [
    {
      "path": "lib/example.ex",
      "action": "updated",
      "before_sha256": "...",
      "after_sha256": "...",
      "before_bytes": 120,
      "after_bytes": 150,
      "diff_summary": {"added_lines": 3, "removed_lines": 1}
    }
  ],
  "checkpoint": {
    "id": "20260426T120000Z-1",
    "path": "/Users/pawel/project/.agent_machine/checkpoints/20260426T120000Z-1"
  }
}
```

Rollback a checkpoint directly from the CLI without running a provider:

```sh
mix agent_machine.rollback \
  --tool-root /Users/pawel/project \
  --checkpoint-id 20260426T120000Z-1
```

Use `--json` for script-friendly rollback output.

## Terminal UI

Start it:

```sh
make tui
```

Or:

```sh
cd tui
go run .
```

In the UI, set a workflow and provider before sending normal messages. Normal
messages include a short recent user/assistant conversation context so follow-up
wording like "inside this dir" can resolve from chat history.
Each TUI run writes an Elixir JSONL log next to the config file under
`logs/*.jsonl`; the run banner shows the exact log path.

Useful commands:

```text
/setup
/workflow basic|agentic
/provider echo|openai|openrouter
/key <api-key>
/models reload
/models
/model
/model <id|next|prev>
/tools local-files <root> <timeout-ms> <max-rounds> <approval-mode>
/tools code-edit <root> <timeout-ms> <max-rounds> <approval-mode>
/tools off
/test-command add <command>
/test-command list
/test-command clear
/mcp-config <path>
/mcp-config off
/allow-tools [auto-approved-safe|full-access]
/yolo-tools
/deny-tools
/settings
/agents
/agent <id>
/back
/clear
/quit
```

Useful keys:

- `Enter`: submit input.
- `Tab` / `Shift+Tab`: switch views.
- `Esc`: go back.
- `Up` / `Down`: command history, agent selection, or model selection.
- `Ctrl+C`: quit.

Saved UI settings are kept in a local config file with `0600` permissions.
Override the config path with `AGENT_MACHINE_TUI_CONFIG`.

When a message asks for a local filesystem write and tools are off or pointed at
the wrong root, the TUI stops before calling the model and asks for permission.
Use `/allow-tools` to enable `local-files` for the requested root and retry the
pending message, `/yolo-tools` to use `full-access`, or `/deny-tools` to decline.

Default config paths:

```text
macOS: ~/Library/Application Support/agent-machine/tui-config.json
Linux: ~/.config/agent-machine/tui-config.json
```

## Required Values

The project intentionally fails when required values are missing. Common required
values are:

- A non-empty task prompt.
- `--workflow basic|agentic`.
- `--provider echo|openai|openrouter`.
- `--timeout-ms`.
- `--max-steps`.
- `--max-attempts`.
- `--model`, `--http-timeout-ms`, pricing, and API key for remote providers.
- `--tool-timeout-ms`, `--tool-max-rounds`, and `--tool-approval-mode` when tools are enabled.
- `--tool-root` for `local-files` and `code-edit`.
- `--test-command` values require `code-edit` and `full-access`.
- `--mcp-config` requires repeated `--tool-harness mcp`; the TUI only passes the
  path through and Elixir owns MCP validation/execution.

## Development

Run focused tests while working:

```sh
mix test
```

Paid OpenRouter integration tests are excluded from normal test and quality
runs. By default they use the real `stepfun/step-3.5-flash` model through
provider, `ClientRunner`, MCP stdio tool calling, `mix agent_machine.run`, and
TUI CLI adapter flows including agentic delegated-worker, local-files
side-effect, and code-edit checkpoint runs. They require an API key:

```sh
OPENROUTER_API_KEY="..." make test-openrouter-paid
```

Set `AGENT_MACHINE_PAID_OPENROUTER_MODEL` to run the same paid tests against a
different OpenRouter model:

```sh
OPENROUTER_API_KEY="..." AGENT_MACHINE_PAID_OPENROUTER_MODEL="openai/gpt-4o-mini" make test-openrouter-paid
```

The paid Elixir tests use a 180 second ExUnit timeout because real OpenRouter
responses can exceed the default 60 second test timeout.
The paid TUI agentic tests pass a 240 second run timeout to the CLI adapter so
slower paid models can finish planner and worker phases.

The GitHub workflow `OpenRouter Paid Integration` is manual-only
(`workflow_dispatch`) and expects the `OPENROUTER_API_KEY` repository secret.

Run the full local gate before merging code changes:

```sh
mix quality
```

That checks formatting, compiles with warnings as errors, runs Credo in strict
mode, and runs tests.
