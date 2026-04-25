defmodule AgentMachine.RunContextPromptTest do
  use ExUnit.Case, async: true

  alias AgentMachine.{JSON, RunContextPrompt}

  test "returns empty text for empty run context" do
    assert RunContextPrompt.text(run_context: %{results: %{}, artifacts: %{}}) == ""
  end

  test "encodes run context with atom keys and atom status values" do
    text =
      RunContextPrompt.text(
        run_context: %{
          results: %{
            "worker" => %{
              status: :ok,
              output: "done",
              error: nil,
              artifacts: %{kind: :summary},
              tool_results: %{}
            }
          },
          artifacts: %{plan: "split task"}
        }
      )

    assert %{
             "results" => %{
               "worker" => %{
                 "status" => "ok",
                 "artifacts" => %{"kind" => "summary"}
               }
             },
             "artifacts" => %{"plan" => "split task"}
           } = JSON.decode!(text)
  end
end
