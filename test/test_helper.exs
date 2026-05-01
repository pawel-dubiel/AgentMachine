Application.ensure_all_started(:agent_machine)

defmodule AgentMachine.TestTelemetryForwarder do
  @moduledoc false

  def handle(event, measurements, metadata, parent) do
    send(parent, {:telemetry, event, measurements, metadata})
  end
end

ExUnit.configure(exclude: [paid_openrouter: true, paid_openrouter_swarm_e2e_eval: true])
ExUnit.start()
