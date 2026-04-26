defmodule AgentMachine.RunContextPromptTest do
  use ExUnit.Case, async: true

  alias AgentMachine.{JSON, RunContextPrompt}

  test "returns empty text for empty run context" do
    assert RunContextPrompt.text(run_context: %{results: %{}, artifacts: %{}}) == ""
  end

  test "includes explicit tool context when tools are available" do
    text =
      RunContextPrompt.text(
        run_context: %{results: %{}, artifacts: %{}},
        allowed_tools: [AgentMachine.Tools.CreateDir, AgentMachine.Tools.WriteFile],
        tool_policy: AgentMachine.ToolHarness.builtin_policy!(:local_files),
        tool_root: "/Users/pawel",
        tool_approval_mode: :auto_approved_safe
      )

    assert %{
             "tools" => %{
               "harness" => "local_files",
               "root" => "/Users/pawel",
               "approval_mode" => "auto_approved_safe",
               "available_tools" => tools,
               "instruction" => instruction
             }
           } = JSON.decode!(text)

    assert "create_dir" in tools
    assert "write_file" in tools
    assert instruction =~ "Do not claim file or directory changes unless tool_results confirm"
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
