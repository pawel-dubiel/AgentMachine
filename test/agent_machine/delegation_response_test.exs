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
    assert_raise ArgumentError, ~r/decision mode must be direct or delegate/, fn ->
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
