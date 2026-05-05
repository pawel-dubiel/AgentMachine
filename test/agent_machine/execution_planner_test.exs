defmodule AgentMachine.ExecutionPlannerTest do
  use ExUnit.Case, async: true

  alias AgentMachine.{ExecutionPlanner, RunSpec}

  test "simple prompt selects direct strategy" do
    assert %{requested: "agentic", selected: "direct", strategy: "direct"} =
             plan!(%{task: "explain the project"})
  end

  test "read-only time request with configured harness selects tool strategy" do
    assert %{selected: "tool", strategy: "tool", tool_intent: "time"} =
             plan!(%{
               task: "what time is it?",
               tool_harness: :time,
               tool_timeout_ms: 100,
               tool_max_rounds: 2,
               tool_approval_mode: :read_only
             })
  end

  test "file mutation with code-edit harness selects planned strategy" do
    assert %{selected: "planned", strategy: "planned", tool_intent: "code_mutation"} =
             plan!(%{
               task: "edit lib/foo.ex",
               tool_harness: :code_edit,
               tool_root: "/tmp/project",
               tool_timeout_ms: 100,
               tool_max_rounds: 2,
               tool_approval_mode: :full_access
             })
  end

  test "multi-variant request selects swarm strategy" do
    assert %{selected: "swarm", strategy: "swarm"} =
             plan!(%{task: "create multiple versions of a concise answer"})
  end

  test "planner review forces planned strategy" do
    assert %{selected: "planned", strategy: "planned", reason: reason} =
             plan!(%{
               task: "explain the project",
               planner_review_mode: :jsonl_stdio,
               planner_review_max_revisions: 1
             })

    assert reason == "planner_review_requires_planned_strategy"
  end

  test "recent context does not turn an independent current request into stale work" do
    assert %{selected: "direct", strategy: "direct"} =
             plan!(%{
               task: "hello",
               recent_context: "user: in home folder create mdp1 folder"
             })
  end

  test "pending action is actionable only for affirmative follow-up" do
    assert %{selected: "planned", strategy: "planned", tool_intent: "file_mutation"} =
             plan!(%{
               task: "yes do it",
               pending_action: "create reports directory",
               tool_harness: :local_files,
               tool_root: "/tmp/home",
               tool_timeout_ms: 100,
               tool_max_rounds: 2,
               tool_approval_mode: :auto_approved_safe
             })
  end

  defp plan!(attrs) do
    %{
      provider: :echo,
      timeout_ms: 1_000,
      max_steps: 6,
      max_attempts: 1,
      router_mode: :deterministic
    }
    |> Map.merge(attrs)
    |> RunSpec.new!()
    |> ExecutionPlanner.plan!()
  end
end
