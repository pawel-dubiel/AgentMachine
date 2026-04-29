defmodule AgentMachine.WorkflowRouterTest do
  use ExUnit.Case, async: true

  alias AgentMachine.{RunSpec, WorkflowRouter}

  test "routes auto chat intent to chat without exposing configured tools" do
    route =
      route!(%{
        task: "explain what this project does",
        workflow: :auto,
        tool_harness: :local_files,
        tool_root: "/tmp/project",
        tool_timeout_ms: 100,
        tool_max_rounds: 2,
        tool_approval_mode: :read_only
      })

    assert route == %{
             requested: "auto",
             selected: "chat",
             reason: "no_tool_or_mutation_intent_detected",
             tool_intent: "none",
             tools_exposed: false
           }
  end

  test "routes auto local read intent to basic with a filesystem harness" do
    route =
      route!(%{
        task: "read README.md",
        workflow: :auto,
        tool_harness: :local_files,
        tool_root: "/tmp/project",
        tool_timeout_ms: 100,
        tool_max_rounds: 2,
        tool_approval_mode: :read_only
      })

    assert route.selected == "basic"
    assert route.tool_intent == "file_read"
    assert route.tools_exposed
  end

  test "routes auto project check intent to basic with a filesystem harness" do
    route =
      route!(%{
        task: "Hi check in home folder Project1 and if thats app works",
        workflow: :auto,
        tool_harness: :local_files,
        tool_root: "/tmp/home",
        tool_timeout_ms: 100,
        tool_max_rounds: 6,
        tool_approval_mode: :read_only
      })

    assert route.selected == "basic"
    assert route.tool_intent == "file_read"
    assert route.tools_exposed
  end

  test "routes auto time intent to basic with demo harness" do
    route =
      route!(%{
        task: "what time is it?",
        workflow: :auto,
        tool_harness: :demo,
        tool_timeout_ms: 100,
        tool_max_rounds: 2,
        tool_approval_mode: :read_only
      })

    assert route.selected == "basic"
    assert route.tool_intent == "time"
  end

  test "routes auto filesystem mutation to agentic with local files" do
    route =
      route!(%{
        task: "create hello.md",
        workflow: :auto,
        tool_harness: :local_files,
        tool_root: "/tmp/project",
        tool_timeout_ms: 100,
        tool_max_rounds: 2,
        tool_approval_mode: :auto_approved_safe
      })

    assert route.selected == "agentic"
    assert route.tool_intent == "file_mutation"
    assert route.reason == "filesystem_mutation_intent_with_local_files_harness"
  end

  test "routes auto code patch to agentic only with code edit" do
    route =
      route!(%{
        task: "patch lib/foo.ex",
        workflow: :auto,
        tool_harness: :code_edit,
        tool_root: "/tmp/project",
        tool_timeout_ms: 100,
        tool_max_rounds: 2,
        tool_approval_mode: :full_access
      })

    assert route.selected == "agentic"
    assert route.tool_intent == "code_mutation"
  end

  test "routes auto test command intent only with code edit full access and allowlist" do
    route =
      route!(%{
        task: "run mix test",
        workflow: :auto,
        tool_harness: :code_edit,
        tool_root: "/tmp/project",
        tool_timeout_ms: 100,
        tool_max_rounds: 2,
        tool_approval_mode: :full_access,
        test_commands: ["mix test"]
      })

    assert route.selected == "agentic"
    assert route.tool_intent == "test_command"
  end

  test "routes explicit delegation intent to agentic" do
    route = route!(%{task: "use agents to review this project", workflow: :auto})

    assert route.selected == "agentic"
    assert route.tool_intent == "delegation"
    refute route.tools_exposed
  end

  test "uses pending action for affirmative follow-up routing" do
    route =
      WorkflowRouter.route!(%WorkflowRouter{
        requested_workflow: :auto,
        task: "yes, do it",
        pending_action: "create hello.md",
        recent_context: nil,
        tool_harnesses: [:local_files],
        approval_mode: :auto_approved_safe,
        test_commands: []
      })

    assert route.selected == "agentic"
    assert route.tool_intent == "file_mutation"
  end

  test "fails fast for mutation intent without write-capable harness" do
    assert_raise ArgumentError, ~r/mutation intent/, fn ->
      route!(%{task: "create hello.md", workflow: :auto})
    end
  end

  test "fails fast for code patch without code-edit harness" do
    assert_raise ArgumentError, ~r/code mutation intent/, fn ->
      route!(%{
        task: "patch lib/foo.ex",
        workflow: :auto,
        tool_harness: :local_files,
        tool_root: "/tmp/project",
        tool_timeout_ms: 100,
        tool_max_rounds: 2,
        tool_approval_mode: :auto_approved_safe
      })
    end
  end

  test "fails fast for test intent without allowlisted commands" do
    assert_raise ArgumentError, ~r/no allowlisted :test_commands/, fn ->
      route!(%{
        task: "run mix test",
        workflow: :auto,
        tool_harness: :code_edit,
        tool_root: "/tmp/project",
        tool_timeout_ms: 100,
        tool_max_rounds: 2,
        tool_approval_mode: :full_access
      })
    end
  end

  test "fails fast when explicit chat receives tool options" do
    assert_raise ArgumentError, ~r/workflow :chat does not accept tool harness options/, fn ->
      route!(%{
        task: "hello",
        workflow: :chat,
        tool_harness: :local_files,
        tool_root: "/tmp/project",
        tool_timeout_ms: 100,
        tool_max_rounds: 2,
        tool_approval_mode: :read_only
      })
    end
  end

  defp route!(attrs) do
    attrs
    |> Map.merge(%{
      provider: :echo,
      timeout_ms: 1_000,
      max_steps: 6,
      max_attempts: 1
    })
    |> RunSpec.new!()
    |> WorkflowRouter.route!()
  end
end
