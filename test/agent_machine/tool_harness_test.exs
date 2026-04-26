defmodule AgentMachine.ToolHarnessTest do
  use ExUnit.Case, async: true

  alias AgentMachine.ToolHarness

  test "builds OpenAI tool definitions from allowed tools" do
    body =
      ToolHarness.put_openai_tools!(%{"model" => "test"}, allowed_tools: [AgentMachine.Tools.Now])

    assert %{
             "tools" => [
               %{
                 "type" => "function",
                 "name" => "now",
                 "description" => _description,
                 "parameters" => %{"type" => "object"}
               }
             ]
           } = body
  end

  test "built-in local files harness exposes constrained file tools" do
    assert ToolHarness.builtin!(:local_files) == [
             AgentMachine.Tools.AppendFile,
             AgentMachine.Tools.CreateDir,
             AgentMachine.Tools.FileInfo,
             AgentMachine.Tools.ListFiles,
             AgentMachine.Tools.ReadFile,
             AgentMachine.Tools.ReplaceInFile,
             AgentMachine.Tools.SearchFiles,
             AgentMachine.Tools.WriteFile
           ]
  end

  test "built-in code edit harness exposes patch tools and read-only context tools" do
    assert ToolHarness.builtin!(:code_edit) == [
             AgentMachine.Tools.ApplyEdits,
             AgentMachine.Tools.ApplyPatch,
             AgentMachine.Tools.FileInfo,
             AgentMachine.Tools.ListFiles,
             AgentMachine.Tools.RollbackCheckpoint,
             AgentMachine.Tools.ReadFile,
             AgentMachine.Tools.SearchFiles
           ]
  end

  test "built-in code edit harness exposes test command tool only when configured" do
    refute AgentMachine.Tools.RunTestCommand in ToolHarness.builtin!(:code_edit)

    assert AgentMachine.Tools.RunTestCommand in ToolHarness.builtin!(:code_edit,
             test_commands: ["mix test"]
           )

    refute MapSet.member?(
             ToolHarness.builtin_policy!(:code_edit).permissions,
             :test_command_run
           )

    assert MapSet.member?(
             ToolHarness.builtin_policy!(:code_edit, test_commands: ["mix test"]).permissions,
             :test_command_run
           )
  end

  test "built-in harnesses expose explicit tool policies" do
    assert %AgentMachine.ToolPolicy{harness: :demo, permissions: demo_permissions} =
             ToolHarness.builtin_policy!(:demo)

    assert MapSet.member?(demo_permissions, :demo_time)

    assert %AgentMachine.ToolPolicy{harness: :local_files, permissions: local_permissions} =
             ToolHarness.builtin_policy!(:local_files)

    assert MapSet.subset?(
             MapSet.new([
               :local_files_append,
               :local_files_create_dir,
               :local_files_info,
               :local_files_list,
               :local_files_read,
               :local_files_replace,
               :local_files_search,
               :local_files_write
             ]),
             local_permissions
           )

    assert %AgentMachine.ToolPolicy{harness: :code_edit, permissions: code_edit_permissions} =
             ToolHarness.builtin_policy!(:code_edit)

    assert MapSet.subset?(
             MapSet.new([
               :code_edit_apply_edits,
               :code_edit_apply_patch,
               :code_edit_rollback_checkpoint,
               :local_files_info,
               :local_files_list,
               :local_files_read,
               :local_files_search
             ]),
             code_edit_permissions
           )
  end

  test "all built-in harness tools expose approval risks" do
    for harness <- [:demo, :local_files, :code_edit],
        tool <- ToolHarness.builtin!(harness) do
      assert AgentMachine.ToolPolicy.approval_risk!(tool) in [
               :read,
               :write,
               :delete,
               :command,
               :network
             ]
    end
  end

  test "builds OpenRouter tool definitions from allowed tools" do
    body =
      ToolHarness.put_openrouter_tools!(%{"model" => "test"},
        allowed_tools: [AgentMachine.Tools.Now]
      )

    assert %{
             "tools" => [
               %{
                 "type" => "function",
                 "function" => %{
                   "name" => "now",
                   "description" => _description,
                   "parameters" => %{"type" => "object"}
                 }
               }
             ]
           } = body
  end

  test "parses OpenAI Responses function calls into runtime tool calls" do
    response = %{
      "output" => [
        %{
          "type" => "function_call",
          "call_id" => "call-1",
          "name" => "now",
          "arguments" => "{}"
        }
      ]
    }

    assert [
             %{id: "call-1", tool: AgentMachine.Tools.Now, input: %{}}
           ] = ToolHarness.openai_tool_calls!(response, allowed_tools: [AgentMachine.Tools.Now])
  end

  test "parses OpenRouter chat tool calls into runtime tool calls" do
    message = %{
      "tool_calls" => [
        %{
          "id" => "call-1",
          "function" => %{"name" => "now", "arguments" => "{}"}
        }
      ]
    }

    assert [
             %{id: "call-1", tool: AgentMachine.Tools.Now, input: %{}}
           ] =
             ToolHarness.openrouter_tool_calls!(message, allowed_tools: [AgentMachine.Tools.Now])
  end

  test "fails fast when a provider asks for an unknown tool" do
    response = %{
      "output" => [
        %{
          "type" => "function_call",
          "call_id" => "call-1",
          "name" => "missing",
          "arguments" => "{}"
        }
      ]
    }

    assert_raise ArgumentError, ~r/provider requested unknown tool/, fn ->
      ToolHarness.openai_tool_calls!(response, allowed_tools: [AgentMachine.Tools.Now])
    end
  end
end
