defmodule AgentMachine.ToolPolicyTest do
  use ExUnit.Case, async: true

  alias AgentMachine.ToolPolicy

  test "permits tools with granted permissions" do
    policy = ToolPolicy.new!(permissions: [:demo_time])

    assert :ok = ToolPolicy.permit!(policy, AgentMachine.Tools.Now)
  end

  test "rejects tools without granted permissions" do
    policy = ToolPolicy.new!(permissions: [:local_files_read])

    assert_raise ArgumentError, ~r/requires permission :demo_time/, fn ->
      ToolPolicy.permit!(policy, AgentMachine.Tools.Now)
    end
  end

  test "rejects code edit tools without code edit permission" do
    policy = ToolPolicy.new!(permissions: [:local_files_read])

    assert_raise ArgumentError, ~r/requires permission :code_edit_apply_edits/, fn ->
      ToolPolicy.permit!(policy, AgentMachine.Tools.ApplyEdits)
    end
  end

  test "rejects rollback without rollback permission" do
    policy = ToolPolicy.new!(permissions: [:code_edit_apply_edits])

    assert_raise ArgumentError, ~r/requires permission :code_edit_rollback_checkpoint/, fn ->
      ToolPolicy.permit!(policy, AgentMachine.Tools.RollbackCheckpoint)
    end
  end

  test "reads tool approval risks" do
    assert ToolPolicy.approval_risk!(AgentMachine.Tools.Now) == :read
    assert ToolPolicy.approval_risk!(AgentMachine.Tools.ReadFile) == :read
    assert ToolPolicy.approval_risk!(AgentMachine.Tools.WriteFile) == :write
    assert ToolPolicy.approval_risk!(AgentMachine.Tools.ApplyPatch) == :write
    assert ToolPolicy.approval_risk!(AgentMachine.Tools.RollbackCheckpoint) == :write
  end
end
