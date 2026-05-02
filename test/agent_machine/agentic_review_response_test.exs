defmodule AgentMachine.AgenticReviewResponseTest do
  use ExUnit.Case, async: true

  alias AgentMachine.{Agent, AgenticReviewResponse, JSON}

  test "accepts a complete review decision without follow-up agents" do
    payload =
      normalize(%{
        "decision" => %{"mode" => "complete", "reason" => "Worker evidence is sufficient."},
        "output" => "The task is complete.",
        "completion_evidence" => [
          %{
            "source_agent_id" => "worker-a",
            "kind" => "agent_output",
            "summary" => "worker-a reported that the task is complete."
          }
        ],
        "next_agents" => []
      })

    assert payload.output == "The task is complete."
    assert payload.next_agents == []

    assert payload.decision == %{
             mode: "complete",
             reason: "Worker evidence is sufficient.",
             completion_evidence: [
               %{
                 source_agent_id: "worker-a",
                 kind: "agent_output",
                 summary: "worker-a reported that the task is complete."
               }
             ],
             delegated_agent_ids: []
           }
  end

  test "accepts a continue review decision with inherited worker settings" do
    payload =
      normalize(
        %{
          "decision" => %{"mode" => "continue", "reason" => "Missing verification."},
          "output" => "Need one follow-up.",
          "completion_evidence" => [],
          "next_agents" => [
            %{
              "id" => "follow-up",
              "input" => "Verify the result.",
              "instructions" => "Run checks."
            }
          ]
        },
        %{agent_machine_worker_instructions: "Runtime worker rules."}
      )

    assert payload.decision == %{
             mode: "continue",
             reason: "Missing verification.",
             completion_evidence: [],
             delegated_agent_ids: ["follow-up"]
           }

    assert [
             %{
               id: "follow-up",
               provider: AgentMachine.Providers.Echo,
               model: "echo",
               input: "Verify the result.",
               instructions: "Runtime worker rules.\n\nRun checks.",
               pricing: pricing
             }
           ] = payload.next_agents

    assert pricing == %{input_per_million: 0.0, output_per_million: 0.0}
  end

  test "rejects unknown top-level keys" do
    assert_raise ArgumentError, ~r/unsupported key/, fn ->
      normalize(%{
        "decision" => %{"mode" => "complete", "reason" => "done"},
        "output" => "done",
        "completion_evidence" => [
          %{
            "source_agent_id" => "worker-a",
            "kind" => "agent_output",
            "summary" => "worker-a completed the task."
          }
        ],
        "next_agents" => [],
        "extra" => true
      })
    end
  end

  test "rejects complete decisions without concrete completion evidence" do
    assert_raise ArgumentError, ~r/missing required completion_evidence field/, fn ->
      normalize(%{
        "decision" => %{"mode" => "complete", "reason" => "done"},
        "output" => "done",
        "next_agents" => []
      })
    end

    assert_raise ArgumentError,
                 ~r/complete decision requires at least one completion_evidence item/,
                 fn ->
                   normalize(%{
                     "decision" => %{"mode" => "complete", "reason" => "done"},
                     "output" => "done",
                     "completion_evidence" => [],
                     "next_agents" => []
                   })
                 end
  end

  test "rejects malformed completion evidence items" do
    assert_raise ArgumentError, ~r/completion_evidence item contains unsupported key/, fn ->
      normalize(%{
        "decision" => %{"mode" => "complete", "reason" => "done"},
        "output" => "done",
        "completion_evidence" => [
          %{
            "source_agent_id" => "worker-a",
            "kind" => "agent_output",
            "summary" => "done",
            "extra" => true
          }
        ],
        "next_agents" => []
      })
    end

    assert_raise ArgumentError, ~r/completion_evidence kind must be one of/, fn ->
      normalize(%{
        "decision" => %{"mode" => "complete", "reason" => "done"},
        "output" => "done",
        "completion_evidence" => [
          %{"source_agent_id" => "worker-a", "kind" => "guess", "summary" => "done"}
        ],
        "next_agents" => []
      })
    end

    assert_raise ArgumentError, ~r/tool_result evidence requires tool_call_id/, fn ->
      normalize(%{
        "decision" => %{"mode" => "complete", "reason" => "done"},
        "output" => "done",
        "completion_evidence" => [
          %{"source_agent_id" => "worker-a", "kind" => "tool_result", "summary" => "done"}
        ],
        "next_agents" => []
      })
    end

    assert_raise ArgumentError, ~r/artifact evidence requires artifact_key/, fn ->
      normalize(%{
        "decision" => %{"mode" => "complete", "reason" => "done"},
        "output" => "done",
        "completion_evidence" => [
          %{"source_agent_id" => "worker-a", "kind" => "artifact", "summary" => "done"}
        ],
        "next_agents" => []
      })
    end
  end

  test "rejects empty reason and output strings" do
    assert_raise ArgumentError, ~r/reason must be a non-empty string/, fn ->
      normalize(%{
        "decision" => %{"mode" => "complete", "reason" => ""},
        "output" => "done",
        "completion_evidence" => [
          %{
            "source_agent_id" => "worker-a",
            "kind" => "agent_output",
            "summary" => "worker-a completed the task."
          }
        ],
        "next_agents" => []
      })
    end

    assert_raise ArgumentError, ~r/output must be a non-empty string/, fn ->
      normalize(%{
        "decision" => %{"mode" => "complete", "reason" => "done"},
        "output" => "",
        "completion_evidence" => [
          %{
            "source_agent_id" => "worker-a",
            "kind" => "agent_output",
            "summary" => "worker-a completed the task."
          }
        ],
        "next_agents" => []
      })
    end
  end

  test "rejects invalid review decision mode" do
    assert_raise ArgumentError, ~r/decision mode must be complete or continue/, fn ->
      normalize(%{
        "decision" => %{"mode" => "maybe", "reason" => "invalid"},
        "output" => "review",
        "completion_evidence" => [],
        "next_agents" => []
      })
    end
  end

  test "rejects complete decisions with follow-up agents" do
    assert_raise ArgumentError, ~r/complete decision must not include next_agents/, fn ->
      normalize(%{
        "decision" => %{"mode" => "complete", "reason" => "invalid"},
        "output" => "review",
        "completion_evidence" => [
          %{
            "source_agent_id" => "worker-a",
            "kind" => "agent_output",
            "summary" => "worker-a completed the task."
          }
        ],
        "next_agents" => [%{"id" => "worker", "input" => "work"}]
      })
    end
  end

  test "rejects continue decisions without follow-up agents" do
    assert_raise ArgumentError, ~r/continue decision requires at least one next_agent/, fn ->
      normalize(%{
        "decision" => %{"mode" => "continue", "reason" => "invalid"},
        "output" => "review",
        "completion_evidence" => [],
        "next_agents" => []
      })
    end
  end

  test "rejects malformed follow-up specs" do
    assert_raise ArgumentError, ~r/id must be a non-empty string/, fn ->
      normalize(%{
        "decision" => %{"mode" => "continue", "reason" => "invalid"},
        "output" => "review",
        "completion_evidence" => [],
        "next_agents" => [%{"id" => "", "input" => "work"}]
      })
    end
  end

  defp normalize(body, metadata \\ %{}) do
    AgenticReviewResponse.normalize_payload!(agent(metadata), %{output: JSON.encode!(body)})
  end

  defp agent(metadata) do
    %Agent{
      id: "goal-reviewer-1",
      provider: AgentMachine.Providers.Echo,
      model: "echo",
      input: "review",
      pricing: %{input_per_million: 0.0, output_per_million: 0.0},
      metadata: Map.merge(%{agent_machine_response: "agentic_review"}, metadata)
    }
  end
end
