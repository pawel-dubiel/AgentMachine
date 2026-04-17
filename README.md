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
agent specs through `next_agents`, and the orchestrator decides whether to
schedule them. This gives the project a real planner-to-workers loop without
adding durable memory, tools, retries, or a large framework.

## Project Shape

```text
lib/
  agent_machine/
    application.ex                  # OTP supervision tree
    orchestrator.ex                 # starts runs, spawns agents, collects results
    agent_runner.ex                 # executes one agent through its provider
    agent.ex                        # strict agent spec validation
    provider.ex                     # provider behaviour
    usage.ex                        # normalized usage and cost entry
    usage_ledger.ex                 # in-memory node-wide usage ledger
    pricing.ex                      # explicit per-million-token cost calculation
    json.ex                         # small JSON codec for dependency-free OpenAI calls
    providers/
      echo.ex                       # local provider for development/tests
      openai_responses.ex           # OpenAI Responses API provider
test/
  agent_machine/
```

## Requirements

- Elixir `1.19.5`
- Erlang/OTP `28`

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
8 tests, 0 failures
```

## Start An IEx Session

```sh
iex -S mix
```

Now you can run agents from the shell.

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
  metadata: %{optional: "provider metadata"},
  pricing: %{
    input_per_million: 0.0,
    output_per_million: 0.0
  }
}
```

Only `:instructions` and `:metadata` are optional.

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
  next_agents: [%{id: "worker", provider: MyProvider, model: "model", input: "...", pricing: %{...}}]
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
