.PHONY: help deps test test-openrouter-paid test-openrouter-playwright-mcp test-openrouter-swarm-e2e quality format format-check compile build install run start tui tui-test tui-build run-echo run-echo-json run-echo-jsonl run-agentic-echo-jsonl run-openrouter-jsonl run-agentic-openrouter-jsonl clean

.DEFAULT_GOAL := run

TUI_DIR := tui
TUI_BIN := $(TUI_DIR)/agent-machine-tui
PROJECT_ROOT := $(CURDIR)
INSTALL_BIN_DIR ?= $(HOME)/.local/bin
INSTALLED_TUI_BIN := $(INSTALL_BIN_DIR)/agent-machine-tui-bin
INSTALLED_TUI_LAUNCHER := $(INSTALL_BIN_DIR)/agent-machine-tui
INSTALLED_LAUNCHER := $(INSTALL_BIN_DIR)/agent-machine

help:
	@printf '%s\n' 'AgentMachine targets:'
	@printf '%s\n' '  make deps                         Fetch Elixir and Go dependencies'
	@printf '%s\n' '  make test                         Run Elixir tests'
	@printf '%s\n' '  make test-openrouter-paid         Run paid OpenRouter tests'
	@printf '%s\n' '  make test-openrouter-playwright-mcp Run paid OpenRouter + Playwright MCP test'
	@printf '%s\n' '  make test-openrouter-swarm-e2e    Run paid OpenRouter swarm model e2e eval'
	@printf '%s\n' '  make quality                      Run full Elixir quality gate'
	@printf '%s\n' '  make format                       Format Elixir and Go code'
	@printf '%s\n' '  make format-check                 Check Elixir formatting'
	@printf '%s\n' '  make run / make start             Compile backend/UI and start TUI'
	@printf '%s\n' '  make build                        Compile backend and UI artifacts'
	@printf '%s\n' '  make install                      Install agent-machine launcher and TUI binary'
	@printf '%s\n' '  make tui                          Start the Bubble Tea TUI (no precompile)'
	@printf '%s\n' '  make tui-test                     Run Go TUI tests'
	@printf '%s\n' '  make tui-build                    Build the Go TUI binary'
	@printf '%s\n' '  make run-echo TASK="..."          Run local Echo provider'
	@printf '%s\n' '  make run-echo-json TASK="..."     Run local Echo provider with JSON output'
	@printf '%s\n' '  make run-echo-jsonl TASK="..."    Run local Echo provider with JSONL streaming'
	@printf '%s\n' '  make run-agentic-echo-jsonl TASK="..."'
	@printf '%s\n' '  make run-openrouter-jsonl TASK="..." MODEL="..." INPUT_PRICE_PER_MILLION="..." OUTPUT_PRICE_PER_MILLION="..."'
	@printf '%s\n' '  make run-agentic-openrouter-jsonl TASK="..." MODEL="..." INPUT_PRICE_PER_MILLION="..." OUTPUT_PRICE_PER_MILLION="..."'
	@printf '%s\n' ''
	@printf '%s\n' 'Run targets fail fast when required variables are missing.'

deps:
	mix deps.get
	cd $(TUI_DIR) && go mod download

test:
	mix test

test-openrouter-paid:
	@test -n "$$OPENROUTER_API_KEY" || (printf '%s\n' 'OPENROUTER_API_KEY is required in the environment.' >&2; exit 2)
	@if [ "$${AGENT_MACHINE_PAID_OPENROUTER_MODEL+x}" = "x" ] && [ -z "$$AGENT_MACHINE_PAID_OPENROUTER_MODEL" ]; then printf '%s\n' 'AGENT_MACHINE_PAID_OPENROUTER_MODEL must be non-empty when set.' >&2; exit 2; fi
	@printf 'Running paid OpenRouter tests with model=%s\n' "$${AGENT_MACHINE_PAID_OPENROUTER_MODEL:-moonshotai/kimi-k2.6}"
	mix test --only paid_openrouter --timeout 180000
	cd $(TUI_DIR) && AGENT_MACHINE_PAID_OPENROUTER=1 go test ./... -run '^TestPaidOpenRouter' -count=1 -v

test-openrouter-playwright-mcp:
	@test -n "$$OPENROUTER_API_KEY" || (printf '%s\n' 'OPENROUTER_API_KEY is required in the environment.' >&2; exit 2)
	@command -v npx >/dev/null || (printf '%s\n' 'npx is required for the Playwright MCP paid integration test.' >&2; exit 2)
	@if [ "$${AGENT_MACHINE_PAID_OPENROUTER_MODEL+x}" = "x" ] && [ -z "$$AGENT_MACHINE_PAID_OPENROUTER_MODEL" ]; then printf '%s\n' 'AGENT_MACHINE_PAID_OPENROUTER_MODEL must be non-empty when set.' >&2; exit 2; fi
	@printf 'Running paid OpenRouter Playwright MCP test with model=%s\n' "$${AGENT_MACHINE_PAID_OPENROUTER_MODEL:-moonshotai/kimi-k2.6}"
	AGENT_MACHINE_PAID_PLAYWRIGHT_MCP=1 mix test test/agent_machine/openrouter_paid_test.exs --include paid_openrouter --only playwright_mcp --timeout 300000

test-openrouter-swarm-e2e:
	@test -n "$$OPENROUTER_API_KEY" || (printf '%s\n' 'OPENROUTER_API_KEY is required in the environment.' >&2; exit 2)
	@printf '%s\n' 'Running paid OpenRouter swarm e2e eval for model matrix.'
	AGENT_MACHINE_PAID_SWARM_E2E=1 mix test test/agent_machine/evals/openrouter_swarm_e2e_eval_test.exs --only paid_openrouter_swarm_e2e_eval --timeout 3600000

quality:
	mix quality

format:
	mix format
	gofmt -w tui/*.go

format-check:
	mix format --check-formatted

compile:
	mix compile --warnings-as-errors

build: compile tui-build

install: build
	@test -n "$(HOME)" || (printf '%s\n' 'HOME is required to derive the default INSTALL_BIN_DIR.' >&2; exit 2)
	@test -n "$(INSTALL_BIN_DIR)" || (printf '%s\n' 'INSTALL_BIN_DIR is required.' >&2; exit 2)
	@case "$(INSTALL_BIN_DIR)" in /*) : ;; *) printf '%s\n' 'INSTALL_BIN_DIR must be an absolute path.' >&2; exit 2 ;; esac
	@test -f "$(PROJECT_ROOT)/mix.exs" || (printf '%s\n' 'PROJECT_ROOT must point to the AgentMachine repository containing mix.exs.' >&2; exit 2)
	@command -v mix >/dev/null || (printf '%s\n' 'mix is required on PATH for the installed AgentMachine launcher.' >&2; exit 2)
	@install -d -m 0755 "$(INSTALL_BIN_DIR)"
	@install -m 0755 "$(TUI_BIN)" "$(INSTALLED_TUI_BIN)"
	@{ \
		printf '%s\n' '#!/bin/sh'; \
		printf '%s\n' 'set -eu'; \
		printf '%s\n' ''; \
		printf '%s\n' 'AGENT_MACHINE_ROOT="$(PROJECT_ROOT)"'; \
		printf '%s\n' 'AGENT_MACHINE_TUI="$(INSTALLED_TUI_BIN)"'; \
		printf '%s\n' ''; \
		printf '%s\n' 'if [ ! -f "$$AGENT_MACHINE_ROOT/mix.exs" ]; then'; \
		printf '%s\n' '  printf "%s\n" "AgentMachine repository is missing mix.exs at $$AGENT_MACHINE_ROOT." >&2'; \
		printf '%s\n' '  exit 2'; \
		printf '%s\n' 'fi'; \
		printf '%s\n' ''; \
		printf '%s\n' 'if ! command -v mix >/dev/null 2>&1; then'; \
		printf '%s\n' '  printf "%s\n" "mix is required on PATH for AgentMachine." >&2'; \
		printf '%s\n' '  exit 2'; \
		printf '%s\n' 'fi'; \
		printf '%s\n' ''; \
		printf '%s\n' 'if [ ! -x "$$AGENT_MACHINE_TUI" ]; then'; \
		printf '%s\n' '  printf "%s\n" "AgentMachine TUI binary is missing or not executable at $$AGENT_MACHINE_TUI." >&2'; \
		printf '%s\n' '  exit 2'; \
		printf '%s\n' 'fi'; \
		printf '%s\n' ''; \
		printf '%s\n' 'export AGENT_MACHINE_ROOT'; \
		printf '%s\n' 'exec "$$AGENT_MACHINE_TUI" "$$@"'; \
	} > "$(INSTALLED_LAUNCHER)"
	@cp "$(INSTALLED_LAUNCHER)" "$(INSTALLED_TUI_LAUNCHER)"
	@chmod 0755 "$(INSTALLED_LAUNCHER)" "$(INSTALLED_TUI_LAUNCHER)"
	@printf 'Installed AgentMachine launcher: %s\n' "$(INSTALLED_LAUNCHER)"
	@printf 'Installed AgentMachine TUI launcher: %s\n' "$(INSTALLED_TUI_LAUNCHER)"
	@printf 'Installed AgentMachine TUI binary: %s\n' "$(INSTALLED_TUI_BIN)"

run: start

start: build
	./$(TUI_BIN)

credo:
	mix credo --strict

tui:
	cd $(TUI_DIR) && go run .

tui-test:
	cd $(TUI_DIR) && go test ./...

tui-build:
	cd $(TUI_DIR) && go build -o $(notdir $(TUI_BIN)) .

run-echo:
	@test -n "$(TASK)" || (printf '%s\n' 'TASK is required. Example: make run-echo TASK="Review this project"' >&2; exit 2)
	mix agent_machine.run --workflow basic --provider echo --timeout-ms 30000 --max-steps 2 --max-attempts 1 "$(TASK)"

run-echo-json:
	@test -n "$(TASK)" || (printf '%s\n' 'TASK is required. Example: make run-echo-json TASK="Review this project"' >&2; exit 2)
	mix agent_machine.run --workflow basic --provider echo --timeout-ms 30000 --max-steps 2 --max-attempts 1 --json "$(TASK)"

run-echo-jsonl:
	@test -n "$(TASK)" || (printf '%s\n' 'TASK is required. Example: make run-echo-jsonl TASK="Review this project"' >&2; exit 2)
	mix agent_machine.run --workflow basic --provider echo --timeout-ms 30000 --max-steps 2 --max-attempts 1 --jsonl "$(TASK)"

run-agentic-echo-jsonl:
	@test -n "$(TASK)" || (printf '%s\n' 'TASK is required. Example: make run-agentic-echo-jsonl TASK="Review this project"' >&2; exit 2)
	mix agent_machine.run --workflow agentic --provider echo --timeout-ms 30000 --max-steps 6 --max-attempts 1 --jsonl "$(TASK)"

run-openrouter-jsonl:
	@test -n "$(TASK)" || (printf '%s\n' 'TASK is required.' >&2; exit 2)
	@test -n "$(MODEL)" || (printf '%s\n' 'MODEL is required.' >&2; exit 2)
	@test -n "$(INPUT_PRICE_PER_MILLION)" || (printf '%s\n' 'INPUT_PRICE_PER_MILLION is required.' >&2; exit 2)
	@test -n "$(OUTPUT_PRICE_PER_MILLION)" || (printf '%s\n' 'OUTPUT_PRICE_PER_MILLION is required.' >&2; exit 2)
	@test -n "$$OPENROUTER_API_KEY" || (printf '%s\n' 'OPENROUTER_API_KEY is required in the environment.' >&2; exit 2)
	mix agent_machine.run --workflow basic --provider openrouter --model "$(MODEL)" --timeout-ms 30000 --http-timeout-ms 25000 --max-steps 2 --max-attempts 1 --input-price-per-million "$(INPUT_PRICE_PER_MILLION)" --output-price-per-million "$(OUTPUT_PRICE_PER_MILLION)" --jsonl "$(TASK)"

run-agentic-openrouter-jsonl:
	@test -n "$(TASK)" || (printf '%s\n' 'TASK is required.' >&2; exit 2)
	@test -n "$(MODEL)" || (printf '%s\n' 'MODEL is required.' >&2; exit 2)
	@test -n "$(INPUT_PRICE_PER_MILLION)" || (printf '%s\n' 'INPUT_PRICE_PER_MILLION is required.' >&2; exit 2)
	@test -n "$(OUTPUT_PRICE_PER_MILLION)" || (printf '%s\n' 'OUTPUT_PRICE_PER_MILLION is required.' >&2; exit 2)
	@test -n "$$OPENROUTER_API_KEY" || (printf '%s\n' 'OPENROUTER_API_KEY is required in the environment.' >&2; exit 2)
	mix agent_machine.run --workflow agentic --provider openrouter --model "$(MODEL)" --timeout-ms 30000 --http-timeout-ms 25000 --max-steps 6 --max-attempts 1 --input-price-per-million "$(INPUT_PRICE_PER_MILLION)" --output-price-per-million "$(OUTPUT_PRICE_PER_MILLION)" --jsonl "$(TASK)"

clean:
	mix clean
	rm -f $(TUI_BIN)
