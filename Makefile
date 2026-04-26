.PHONY: help deps test test-openrouter-paid quality format format-check compile build run start tui tui-test tui-build run-echo run-echo-json run-echo-jsonl run-agentic-echo-jsonl run-openrouter-jsonl run-agentic-openrouter-jsonl clean

.DEFAULT_GOAL := run

TUI_DIR := tui
TUI_BIN := $(TUI_DIR)/agent-machine-tui

help:
	@printf '%s\n' 'AgentMachine targets:'
	@printf '%s\n' '  make deps                         Fetch Elixir and Go dependencies'
	@printf '%s\n' '  make test                         Run Elixir tests'
	@printf '%s\n' '  make test-openrouter-paid         Run paid OpenRouter Step 3.5 Flash tests'
	@printf '%s\n' '  make quality                      Run full Elixir quality gate'
	@printf '%s\n' '  make format                       Format Elixir and Go code'
	@printf '%s\n' '  make format-check                 Check Elixir formatting'
	@printf '%s\n' '  make run / make start             Compile backend/UI and start TUI'
	@printf '%s\n' '  make build                        Compile backend and UI artifacts'
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
	mix test --only paid_openrouter

quality:
	mix quality

format:
	mix format
	gofmt -w tui/main.go tui/main_test.go

format-check:
	mix format --check-formatted

compile:
	mix compile --warnings-as-errors

build: compile tui-build

run: start

start: build
	cd $(TUI_DIR) && ./$(notdir $(TUI_BIN))

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
