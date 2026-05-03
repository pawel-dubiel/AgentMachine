defmodule AgentMachine.DelegationResponseTest do
  use ExUnit.Case, async: true

  alias AgentMachine.{Agent, DelegationResponse, JSON}

  test "accepts a direct planner decision without delegated agents" do
    payload =
      normalize(%{
        "decision" => %{"mode" => "direct", "reason" => "No worker is needed."},
        "output" => "Direct answer.",
        "next_agents" => []
      })

    assert payload.output == "Direct answer."
    assert payload.next_agents == []

    assert payload.decision == %{
             mode: "direct",
             reason: "No worker is needed.",
             delegated_agent_ids: []
           }
  end

  test "accepts a delegate planner decision with delegated agents" do
    payload =
      normalize(%{
        "decision" => %{"mode" => "delegate", "reason" => "A worker should edit files."},
        "output" => "Delegating one worker.",
        "next_agents" => [
          %{"id" => "worker", "input" => "Edit the file.", "instructions" => "Use tools."}
        ]
      })

    assert payload.output == "Delegating one worker."

    assert [%{id: "worker", input: "Edit the file.", instructions: "Use tools."}] =
             payload.next_agents

    assert payload.decision == %{
             mode: "delegate",
             reason: "A worker should edit files.",
             delegated_agent_ids: ["worker"]
           }
  end

  test "prepends runtime worker instructions while preserving planner instructions" do
    payload =
      normalize(
        %{
          "decision" => %{"mode" => "delegate", "reason" => "A worker should edit files."},
          "output" => "Delegating one worker.",
          "next_agents" => [
            %{"id" => "worker", "input" => "Edit the file.", "instructions" => "Use tools."}
          ]
        },
        %{agent_machine_worker_instructions: "Runtime worker rules."}
      )

    assert [%{instructions: instructions}] = payload.next_agents
    assert instructions == "Runtime worker rules.\n\nUse tools."
  end

  test "uses runtime worker instructions when planner omits worker instructions" do
    payload =
      normalize(
        %{
          "decision" => %{"mode" => "delegate", "reason" => "A worker should edit files."},
          "output" => "Delegating one worker.",
          "next_agents" => [%{"id" => "worker", "input" => "Edit the file."}]
        },
        %{agent_machine_worker_instructions: "Runtime worker rules."}
      )

    assert [%{instructions: "Runtime worker rules."}] = payload.next_agents
  end

  test "accepts a swarm planner decision with variants and evaluator" do
    payload =
      normalize(%{
        "decision" => %{"mode" => "swarm", "reason" => "Compare variants."},
        "output" => "Planning variants.",
        "next_agents" => swarm_agents()
      })

    assert payload.decision == %{
             mode: "swarm",
             reason: "Compare variants.",
             delegated_agent_ids: ["variant-minimal", "variant-robust", "evaluator"],
             variant_agent_ids: ["variant-minimal", "variant-robust"],
             evaluator_agent_id: "evaluator",
             swarm_id: "default"
           }

    assert [%{metadata: %{"agent_machine_role" => "swarm_variant"}} | _] =
             payload.next_agents
  end

  test "rejects swarm decisions without at least two variants" do
    assert_raise ArgumentError, ~r/swarm decision requires 2 to 5 variant agents/, fn ->
      normalize(%{
        "decision" => %{"mode" => "swarm", "reason" => "invalid"},
        "output" => "Planning variants.",
        "next_agents" => Enum.take(swarm_agents(), 1) ++ [List.last(swarm_agents())]
      })
    end
  end

  test "rejects swarm evaluator dependency mismatches" do
    agents =
      swarm_agents()
      |> List.update_at(2, &Map.put(&1, "depends_on", ["variant-minimal"]))

    assert_raise ArgumentError, ~r/swarm evaluator must depend on all variant agents/, fn ->
      normalize(%{
        "decision" => %{"mode" => "swarm", "reason" => "invalid"},
        "output" => "Planning variants.",
        "next_agents" => agents
      })
    end
  end

  test "rejects swarm variant workspaces that escape the swarm root" do
    agents =
      swarm_agents()
      |> List.update_at(0, fn agent ->
        put_in(agent, ["metadata", "workspace"], "../outside")
      end)

    assert_raise ArgumentError, ~r/swarm variant workspace must be a relative path/, fn ->
      normalize(%{
        "decision" => %{"mode" => "swarm", "reason" => "invalid"},
        "output" => "Planning variants.",
        "next_agents" => agents
      })
    end
  end

  test "rejects invalid runtime worker instruction metadata" do
    assert_raise ArgumentError, ~r/agent_machine_worker_instructions metadata/, fn ->
      normalize(
        %{
          "decision" => %{"mode" => "delegate", "reason" => "A worker should edit files."},
          "output" => "Delegating one worker.",
          "next_agents" => [%{"id" => "worker", "input" => "Edit the file."}]
        },
        %{agent_machine_worker_instructions: ""}
      )
    end
  end

  test "rejects missing decision" do
    assert_raise ArgumentError, ~r/missing required decision/, fn ->
      normalize(%{"output" => "answer", "next_agents" => []})
    end
  end

  test "rejects missing next_agents" do
    assert_raise ArgumentError, ~r/missing required next_agents/, fn ->
      normalize(%{
        "decision" => %{"mode" => "direct", "reason" => "No worker is needed."},
        "output" => "answer"
      })
    end
  end

  test "rejects unknown decision mode" do
    assert_raise ArgumentError, ~r/decision mode must be direct, delegate, or swarm/, fn ->
      normalize(%{
        "decision" => %{"mode" => "maybe", "reason" => "invalid"},
        "output" => "answer",
        "next_agents" => []
      })
    end
  end

  test "rejects missing decision mode" do
    assert_raise ArgumentError, ~r/mode field/, fn ->
      normalize(%{
        "decision" => %{"reason" => "invalid"},
        "output" => "answer",
        "next_agents" => []
      })
    end
  end

  test "rejects empty decision reason" do
    assert_raise ArgumentError, ~r/reason must be a non-empty string/, fn ->
      normalize(%{
        "decision" => %{"mode" => "direct", "reason" => ""},
        "output" => "answer",
        "next_agents" => []
      })
    end
  end

  test "rejects direct decisions with delegated agents" do
    assert_raise ArgumentError, ~r/direct decision must not include next_agents/, fn ->
      normalize(%{
        "decision" => %{"mode" => "direct", "reason" => "invalid"},
        "output" => "answer",
        "next_agents" => [%{"id" => "worker", "input" => "work"}]
      })
    end
  end

  test "rejects delegate decisions without delegated agents" do
    assert_raise ArgumentError, ~r/delegate decision requires at least one next_agent/, fn ->
      normalize(%{
        "decision" => %{"mode" => "delegate", "reason" => "invalid"},
        "output" => "plan",
        "next_agents" => []
      })
    end
  end

  test "rejects unknown decision fields" do
    assert_raise ArgumentError, ~r/decision contains unsupported key/, fn ->
      normalize(%{
        "decision" => %{"mode" => "direct", "reason" => "ok", "extra" => "bad"},
        "output" => "answer",
        "next_agents" => []
      })
    end
  end

  defp normalize(body, metadata \\ %{}) do
    DelegationResponse.normalize_payload!(agent(metadata), %{output: JSON.encode!(body)})
  end

  defp swarm_agents do
    [
      %{
        "id" => "variant-minimal",
        "input" => "Build the minimal variant.",
        "metadata" => %{
          "agent_machine_role" => "swarm_variant",
          "swarm_id" => "default",
          "variant_id" => "minimal",
          "workspace" => ".agent-machine/swarm/run-1/minimal"
        }
      },
      %{
        "id" => "variant-robust",
        "input" => "Build the robust variant.",
        "metadata" => %{
          "agent_machine_role" => "swarm_variant",
          "swarm_id" => "default",
          "variant_id" => "robust",
          "workspace" => ".agent-machine/swarm/run-1/robust"
        }
      },
      %{
        "id" => "evaluator",
        "input" => "Compare the variants.",
        "depends_on" => ["variant-minimal", "variant-robust"],
        "metadata" => %{
          "agent_machine_role" => "swarm_evaluator",
          "swarm_id" => "default"
        }
      }
    ]
  end

  defp agent(metadata) do
    %Agent{
      id: "planner",
      provider: AgentMachine.Providers.Echo,
      model: "echo",
      input: "do work",
      pricing: %{input_per_million: 0.0, output_per_million: 0.0},
      metadata: Map.merge(%{agent_machine_response: "delegation"}, metadata)
    }
  end
end
