defmodule AgentMachine.IntentTest do
  use ExUnit.Case, async: true

  alias AgentMachine.Intent

  test "exposes the canonical workflow intent list" do
    assert Intent.intents() == [
             :none,
             :file_read,
             :file_mutation,
             :code_mutation,
             :test_command,
             :time,
             :web_browse,
             :tool_use,
             :delegation
           ]
  end

  test "validates and normalizes known intent atoms" do
    assert Intent.valid?(:code_mutation)
    assert Intent.normalize!(:web_browse, :intent) == :web_browse
  end

  test "fails fast for invalid intents" do
    assert_raise ArgumentError, ~r/invalid intent: :unknown/, fn ->
      Intent.normalize!(:unknown, :intent)
    end
  end
end
