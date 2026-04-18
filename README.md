# AgentMachine

AgentMachine is a small Elixir/OTP runtime for running AI agents concurrently, collecting their answers in an orchestrator, and tracking token usage plus estimated cost.

It is intentionally compact. The project is not trying to be a giant agent framework. It gives you the useful core:

- Spawn multiple agents at once on the BEAM.
- Let OTP supervise the agent tasks.
- Get all results back through one orchestrator run.
- Record usage and estimated cost per agent.
- Keep node-wide usage totals in a simple ledger.
- Plug in model providers through a tiny `complete/2` contract.
- Let an agent delegate explicit follow-up agents for the next step.
- Share run-scoped artifacts with later delegated agents.
- Fail fast when required configuration is missing.

## Why This Is Interesting

The BEAM is a natural fit for agent orchestration. Agents are independent units of work, and Elixir already gives us lightweight processes, supervision, message passing, and fault isolation.

AgentMachine uses those strengths directly:

- Each agent runs as a supervised task.
- Slow or failed agents do not block other agents from finishing.
- The orchestrator owns the run state and collects task messages.
- Usage and cost accounting happen in one normalized path.

That means you can start with a local echo provider, swap in the OpenAI Responses provider, and later add more providers without changing orchestration code.

The current agentic layer is deliberately small: an agent can return follow-up
agent specs through `next_agents`, write run-scoped `artifacts`, and read prior
results through `:run_context`. This gives the project a real planner-to-workers
loop without adding durable memory, tools, retries, or a large framework.

## Project Shape

```text
lib/
  agent_machine/
    application.ex                  # OTP supervision tree
    client_runner.ex                # high-level runner for CLI/TUI clients
    orchestrator.ex                 # starts runs, spawns agents, collects results
    agent_runner.ex                 # executes one agent through its provider
    agent.ex                        # strict agent spec validation
    run_spec.ex                     # high-level client run spec validation
    provider.ex                     # provider behaviour
    tool.ex                         # tool behaviour
    usage.ex                        # normalized usage and cost entry
    usage_ledger.ex                 # in-memory node-wide usage ledger
    pricing.ex                      # explicit per-million-token cost calculation
    json.ex                         # small JSON codec for dependency-free OpenAI calls
    providers/
      echo.ex                       # local provider for development/tests
      openai_responses.ex           # OpenAI Responses API provider
    workflows/
      basic.ex                      # simple client workflow
  mix/tasks/
    agent_machine.run.ex            # CLI boundary for clients
tui/
  main.go                           # Bubble Tea TUI client
test/
  agent_machine/
```

## Requirements

- Elixir `1.19.5`
- Erlang/OTP `28`
- Go `1.24.2` for the Bubble Tea TUI

If you are on macOS with Homebrew:

```sh
brew install elixir
```

Check the install:

```sh
elixir --version
mix --version
erl -eval 'erlang:display(erlang:system_info(otp_release)), halt().' -noshell
```

## Run The Tests

```sh
mix test
```

Expected result:

```text
27 tests, 0 failures
```

## Quality Checks

Run the full local quality gate:

```sh
mix quality
```

That alias runs:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix test
```

## Start An IEx Session

```sh
iex -S mix
```

Now you can run agents from the shell.

## Simple CLI Client

Use the high-level CLI when you want to run a task without building agent maps by
hand:

```sh
mix agent_machine.run \
  --provider echo \
  --timeout-ms 5000 \
  --max-steps 2 \
  --max-attempts 1 \
  "Review this project and summarize the next step"
```

For machine-readable output, add `--json`:

```sh
mix agent_machine.run \
  --provider echo \
  --timeout-ms 5000 \
  --max-steps 2 \
  --max-attempts 1 \
  --json \
  "Review this project and summarize the next step"
```

The command uses `AgentMachine.RunSpec` plus the basic workflow. The local Echo
profile runs an assistant agent and then a finalizer.

## Bubble Tea TUI

Run the terminal UI:

```sh
cd tui
go run .
```

The TUI asks for a task, runs the local Echo workflow through
`mix agent_machine.run --json`, and shows the final output, usage, status, and
events.

Current TUI controls:

- `Enter`: run the task
- `Esc`: start a new task after a run
- `q`: quit after a run
- `Ctrl+C`: quit anytime

The TUI currently uses the local Echo profile. OpenAI provider selection is
tracked in `plan.md` as a deferred client feature.

## Quick Demo With Local Agents

The echo provider does not call an external model. It is useful for proving that orchestration, result collection, and accounting work.

```elixir
agents = [
  %{
    id: "planner",
    provider: AgentMachine.Providers.Echo,
    model: "echo",
    input: "Draft a short implementation plan.",
    pricing: %{input_per_million: 0.0, output_per_million: 0.0}
  },
  %{
    id: "reviewer",
    provider: AgentMachine.Providers.Echo,
    model: "echo",
    input: "Review the plan for missing risks.",
    pricing: %{input_per_million: 0.0, output_per_million: 0.0}
  }
]

{:ok, run} = AgentMachine.Orchestrator.run(agents, timeout: 5_000)
```

Inspect the run:

```elixir
run.status
run.results["planner"].output
run.results["reviewer"].output
run.usage
```

Inspect node-wide totals:

```elixir
AgentMachine.UsageLedger.totals()
AgentMachine.UsageLedger.all()
```

## Dynamic Delegation

A provider may return `next_agents` together with its normal output and usage.
Those delegated agents are validated with the same strict contract as initial
agents. The orchestrator starts them only after the parent result is collected.

Because dynamic delegation can otherwise grow without a bound, any run that
actually delegates work must pass an explicit `:max_steps` value. Missing or
exceeded limits fail the run with a clear error instead of silently falling back
to a default.

```elixir
defmodule MyPlannerProvider do
  @behaviour AgentMachine.Provider

  def complete(agent, _opts) do
    {:ok,
     %{
       output: "Created two follow-up tasks.",
       usage: %{input_tokens: 10, output_tokens: 6, total_tokens: 16},
       next_agents: [
         %{
           id: "worker-a",
           provider: AgentMachine.Providers.Echo,
           model: "echo",
           input: "Handle part A.",
           pricing: agent.pricing
         },
         %{
           id: "worker-b",
           provider: AgentMachine.Providers.Echo,
           model: "echo",
           input: "Handle part B.",
           pricing: agent.pricing
         }
       ]
     }}
  end
end

agents = [
  %{
    id: "planner",
    provider: MyPlannerProvider,
    model: "planner",
    input: "Split this task.",
    pricing: %{input_per_million: 0.0, output_per_million: 0.0}
  }
]

{:ok, run} = AgentMachine.Orchestrator.run(agents, timeout: 5_000, max_steps: 3)
run.agent_order
run.results["worker-a"].output
```

## Run Context And Artifacts

Every provider receives a `:run_context` option. The context is a snapshot taken
when the agent task is started:

```elixir
%{
  run_id: "run-1",
  agent_id: "worker-a",
  parent_agent_id: "planner",
  results: %{
    "planner" => %{
      status: :ok,
      output: "Created follow-up tasks.",
      error: nil,
      artifacts: %{plan: "shared plan"}
    }
  },
  artifacts: %{plan: "shared plan"}
}
```

Providers may return `artifacts` to store shared state for later delegated
agents:

```elixir
def complete(agent, opts) do
  context = Keyword.fetch!(opts, :run_context)
  plan = Map.fetch!(context.artifacts, :plan)

  {:ok,
   %{
     output: "Used #{plan}.",
     artifacts: %{worker_summary: "Finished part A."},
     usage: %{input_tokens: 5, output_tokens: 4, total_tokens: 9}
   }}
end
```

Artifact keys are not overwritten. If two agents return the same artifact key,
the run fails with an explicit error.

## Agent Dependencies

Initial agents may declare dependencies on other initial agents:

```elixir
agents = [
  %{
    id: "planner",
    provider: AgentMachine.Providers.Echo,
    model: "echo",
    input: "Make a plan.",
    pricing: %{input_per_million: 0.0, output_per_million: 0.0}
  },
  %{
    id: "reviewer",
    provider: AgentMachine.Providers.Echo,
    model: "echo",
    input: "Review the plan.",
    depends_on: ["planner"],
    pricing: %{input_per_million: 0.0, output_per_million: 0.0}
  }
]
```

The orchestrator starts agents whose dependencies are already satisfied and
keeps the rest pending. A dependency is satisfied when the prerequisite agent has
a result, whether that result is `:ok` or `:error`.

Missing dependencies, duplicate dependency entries, self-dependencies, and
cycles fail before the run starts.

## Finalizer

Pass a `:finalizer` agent when a run should produce one synthesized output after
all normal and delegated agents finish:

```elixir
finalizer = %{
  id: "finalizer",
  provider: MyFinalizerProvider,
  model: "finalizer-model",
  input: "Combine worker outputs into the final answer.",
  pricing: %{input_per_million: 0.0, output_per_million: 0.0}
}

{:ok, run} =
  AgentMachine.Orchestrator.run(agents,
    timeout: 5_000,
    max_steps: 4,
    finalizer: finalizer
  )

run.results["finalizer"].output
run.artifacts.final_output
```

The finalizer receives the same `:run_context` shape as delegated agents, with
all prior results and artifacts. If `:max_steps` is provided, the finalizer
counts as one step. A finalizer must not return `next_agents`.

## Retry Attempts

Pass `:max_attempts` when failed agent attempts should be retried:

```elixir
{:ok, run} =
  AgentMachine.Orchestrator.run(agents,
    timeout: 5_000,
    max_attempts: 2
  )
```

Providers receive the current attempt number:

```elixir
def complete(agent, opts) do
  attempt = Keyword.fetch!(opts, :attempt)
  # attempt starts at 1
end
```

Missing `:max_attempts` means no retry. If provided, it must be a positive
integer. Exhausted retries store the final error result for that agent.

## Tools

Providers may return explicit `tool_calls`. The runner validates and executes
each tool module, then stores results in `AgentResult.tool_results`:

```elixir
defmodule UppercaseTool do
  @behaviour AgentMachine.Tool

  def run(input, opts) do
    value = Map.fetch!(input, :value)
    attempt = Keyword.fetch!(opts, :attempt)

    {:ok, %{value: String.upcase(value), attempt: attempt}}
  end
end

def complete(agent, _opts) do
  {:ok,
   %{
     output: "Called a tool.",
     usage: %{input_tokens: 3, output_tokens: 3, total_tokens: 6},
     tool_calls: [
       %{
         id: "uppercase",
         tool: UppercaseTool,
         input: %{value: agent.input}
       }
     ]
   }}
end
```

Tool calls must include:

- `:id` as a non-empty binary
- `:tool` as a loaded module exporting `run/2`
- `:input` as a map

Tools must return `{:ok, map()}` or `{:error, reason}`. Tool failures turn the
agent attempt into an error result. Later agents can read prior tool results
from `:run_context.results[agent_id].tool_results`.

Runs that execute tools must explicitly allow them:

```elixir
{:ok, run} =
  AgentMachine.Orchestrator.run(agents,
    timeout: 5_000,
    allowed_tools: [UppercaseTool],
    tool_timeout_ms: 1_000
  )
```

If a provider requests a tool that is not in `:allowed_tools`, that agent attempt
fails with an explicit error. If a tool does not finish within
`:tool_timeout_ms`, that agent attempt also fails with an explicit error.

## Run Events

Every run records simple in-memory events in `run.events`:

```elixir
run.events
```

Events include:

```elixir
%{type: :run_started, run_id: "run-1", at: ~U[...]}
%{type: :agent_started, run_id: "run-1", agent_id: "planner", parent_agent_id: nil, attempt: 1, at: ~U[...]}
%{type: :agent_finished, run_id: "run-1", agent_id: "planner", status: :ok, attempt: 1, duration_ms: 12, at: ~U[...]}
%{type: :agent_retry_scheduled, run_id: "run-1", agent_id: "planner", next_attempt: 2, reason: "error", at: ~U[...]}
%{type: :run_completed, run_id: "run-1", at: ~U[...]}
%{type: :run_failed, run_id: "run-1", reason: "explicit error", at: ~U[...]}
```

This is intentionally local and lightweight. Durable traces and external
telemetry can be added later without changing provider contracts.

## Async Orchestration

Use `run/2` when you want to block until a run completes. Use `start_run/2` plus `await_run/2` when you want to start a run and monitor it separately.

```elixir
{:ok, run_id} = AgentMachine.Orchestrator.start_run(agents)

AgentMachine.Orchestrator.get_run(run_id)

{:ok, run} = AgentMachine.Orchestrator.await_run(run_id, 5_000)
```

If the wait limit is reached, the orchestrator returns the current run state:

```elixir
{:error, {:timeout, partial_run}} =
  AgentMachine.Orchestrator.await_run(run_id, 1)
```

## Run With OpenAI

The OpenAI provider uses the Responses API through Erlang `:httpc`. It does not pull extra Hex dependencies.

Set the required environment variables:

```sh
export OPENAI_API_KEY="sk-..."
export OPENAI_INPUT_PRICE_PER_MILLION="0.25"
export OPENAI_OUTPUT_PRICE_PER_MILLION="2.00"
```

The pricing values are explicit on purpose. Model prices change, and this project should not silently guess cost.

In `iex -S mix`:

```elixir
input_price_per_million =
  System.fetch_env!("OPENAI_INPUT_PRICE_PER_MILLION") |> String.to_float()

output_price_per_million =
  System.fetch_env!("OPENAI_OUTPUT_PRICE_PER_MILLION") |> String.to_float()

agents = [
  %{
    id: "researcher",
    provider: AgentMachine.Providers.OpenAIResponses,
    model: "YOUR_MODEL",
    instructions: "Return concise, actionable notes.",
    input: "Find the riskiest part of this architecture.",
    pricing: %{
      input_per_million: input_price_per_million,
      output_per_million: output_price_per_million
    }
  },
  %{
    id: "critic",
    provider: AgentMachine.Providers.OpenAIResponses,
    model: "YOUR_MODEL",
    instructions: "Be direct. Focus on failure modes.",
    input: "Review the same architecture for operational risks.",
    pricing: %{
      input_per_million: input_price_per_million,
      output_per_million: output_price_per_million
    }
  }
]

{:ok, run} =
  AgentMachine.Orchestrator.run(agents,
    timeout: 30_000,
    http_timeout_ms: 25_000
  )

run.results
run.usage
```

Required fields are deliberately strict:

- `:id`
- `:provider`
- `:model`
- `:input`
- `:pricing`
- `:timeout` for `Orchestrator.run/2`
- `:http_timeout_ms` when using `AgentMachine.Providers.OpenAIResponses`
- `OPENAI_API_KEY` when using `AgentMachine.Providers.OpenAIResponses`

Missing values raise explicit errors instead of falling back to hidden defaults.

## Agent Spec

An agent is a map or keyword list with this shape:

```elixir
%{
  id: "agent-id",
  provider: AgentMachine.Providers.Echo,
  model: "model-name",
  instructions: "Optional provider instructions.",
  input: "The task for this agent.",
  depends_on: ["another-agent-id"],
  metadata: %{optional: "provider metadata"},
  pricing: %{
    input_per_million: 0.0,
    output_per_million: 0.0
  }
}
```

Only `:instructions`, `:metadata`, and `:depends_on` are optional.

## Provider Contract

Providers implement `AgentMachine.Provider`:

```elixir
@callback complete(AgentMachine.Agent.t(), keyword()) ::
            {:ok, %{output: binary(), usage: map()}}
            | {:error, term()}
```

Successful provider payloads may also include:

```elixir
%{
  next_agents: [
    %{id: "worker", provider: MyProvider, model: "model", input: "...", pricing: %{...}}
  ],
  artifacts: %{plan: "shared plan"},
  tool_calls: [
    %{id: "call-id", tool: MyTool, input: %{value: "..."}}
  ]
}
```

The returned usage must include:

```elixir
%{
  input_tokens: non_neg_integer(),
  output_tokens: non_neg_integer(),
  total_tokens: non_neg_integer()
}
```

That is enough for the runner to normalize cost and record usage.

## Cost Tracking

Each successful agent result includes a normalized `AgentMachine.Usage` struct:

```elixir
result = run.results["planner"]
result.usage.input_tokens
result.usage.output_tokens
result.usage.total_tokens
result.usage.cost_usd
```

The completed run also has aggregate usage:

```elixir
run.usage
```

The node-wide ledger can be queried independently:

```elixir
AgentMachine.UsageLedger.by_run(run.id)
AgentMachine.UsageLedger.totals()
```

The ledger is in memory for the MVP. If the BEAM node restarts, the ledger resets.

## What This MVP Does Not Do Yet

The current version keeps the core small. It does not include:

- Persistent storage.
- Agent-to-agent messaging.
- Tool calling.
- Retries.
- Streaming.
- Web UI.
- Distributed multi-node orchestration.

Those can be added later without changing the basic split between orchestrator, runner, provider, and usage ledger.

## Design Principle

AgentMachine prefers explicit failure over surprising defaults.

If a required agent field, timeout, provider option, environment variable, or usage field is missing, the project raises a clear error. That keeps agent runs predictable and cost accounting honest.
