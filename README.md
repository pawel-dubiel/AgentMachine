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
  --http-timeout-ms 25000 \
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
  --http-timeout-ms 25000 \
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

The `demo` harness exposes a clock tool:

```sh
mix agent_machine.run \
  --workflow basic \
  --provider openrouter \
  --model "YOUR_OPENROUTER_MODEL" \
  --timeout-ms 30000 \
  --http-timeout-ms 25000 \
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
  --http-timeout-ms 25000 \
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
Elixir and does not shell out.

```sh
mix agent_machine.run \
  --workflow basic \
  --provider openrouter \
  --model "YOUR_OPENROUTER_MODEL" \
  --timeout-ms 30000 \
  --http-timeout-ms 25000 \
  --max-steps 2 \
  --max-attempts 1 \
  --input-price-per-million 0.15 \
  --output-price-per-million 0.60 \
  --tool-harness code-edit \
  --tool-root /Users/pawel/project \
  --tool-timeout-ms 1000 \
  --tool-max-rounds 2 \
  --tool-approval-mode full-access \
  --json \
  "Update the README using a minimal patch"
```

Local file tool rules:

- `--tool-root` must already exist.
- Paths outside `--tool-root` fail.
- Search requires `rg` in `PATH`.
- Writes require the parent directory to exist.
- Append and replace require existing regular files.
- Symlink write targets are rejected.
- Code edit tools validate all requested changes before writing.
- `--tool-timeout-ms`, `--tool-max-rounds`, and `--tool-approval-mode` are required when a harness is enabled.
- Approval modes are `read-only`, `ask-before-write`, `auto-approved-safe`, and `full-access`.

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

In the UI, set a workflow and provider before sending normal messages.

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

## Development

Run focused tests while working:

```sh
mix test
```

Run the full local gate before merging code changes:

```sh
mix quality
```

That checks formatting, compiles with warnings as errors, runs Credo in strict
mode, and runs tests.
