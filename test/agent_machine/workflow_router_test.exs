defmodule AgentMachine.WorkflowRouterTest do
  use ExUnit.Case, async: true

  alias AgentMachine.{RunSpec, WorkflowRouter}

  defmodule LocalCodeMutationClassifier do
    def classify!(_input) do
      %{
        intent: :code_mutation,
        classified_intent: :code_mutation,
        classifier: "local",
        classifier_model: AgentMachine.LocalIntentClassifier.model_id(),
        confidence: 0.91,
        reason: "test_classifier"
      }
    end
  end

  defmodule LocalLowConfidenceClassifier do
    def classify!(_input) do
      %{
        intent: :none,
        classified_intent: :code_mutation,
        classifier: "local",
        classifier_model: AgentMachine.LocalIntentClassifier.model_id(),
        confidence: 0.30,
        reason: "local_classifier_below_confidence_threshold"
      }
    end
  end

  defmodule LocalMalformedClassifier do
    def classify!(_input), do: %{intent: :not_real}
  end

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
             tools_exposed: false,
             classifier: "deterministic",
             classifier_model: nil,
             confidence: nil,
             classified_intent: "none"
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

  test "routes auto time intent to basic with time harness" do
    route =
      route!(%{
        task: "what time is it?",
        workflow: :auto,
        tool_harness: :time,
        tool_timeout_ms: 100,
        tool_max_rounds: 2,
        tool_approval_mode: :read_only
      })

    assert route.selected == "basic"
    assert route.tool_intent == "time"
    assert route.reason == "time_intent_with_time_harness"
  end

  test "routes auto time intent to basic with auto time harness when other tools are configured" do
    route =
      route!(%{
        task: "what time is it?",
        workflow: :auto,
        tool_harness: :code_edit,
        tool_root: "/tmp/project",
        tool_timeout_ms: 100,
        tool_max_rounds: 2,
        tool_approval_mode: :auto_approved_safe
      })

    assert route.selected == "basic"
    assert route.tool_intent == "time"
    assert route.reason == "time_intent_with_auto_time_harness"
    assert route.tools_exposed
  end

  test "routes auto time intent to chat without time harness" do
    route =
      route!(%{
        task: "what time is it?",
        workflow: :auto
      })

    assert route.selected == "chat"
    assert route.tool_intent == "time"
    assert route.reason == "time_intent_without_time_harness"
    refute route.tools_exposed
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

  test "routes local classifier code mutation to agentic with code-edit harness" do
    route =
      WorkflowRouter.route!(%WorkflowRouter{
        requested_workflow: :auto,
        task: "napraw aplikacje",
        pending_action: nil,
        recent_context: nil,
        tool_harnesses: [:code_edit],
        approval_mode: :auto_approved_safe,
        test_commands: [],
        router_mode: :local,
        router_model_dir: "/tmp/router-model",
        router_timeout_ms: 100,
        router_confidence_threshold: 0.5,
        classifier_module: LocalCodeMutationClassifier
      })

    assert route.selected == "agentic"
    assert route.tool_intent == "code_mutation"
    assert route.classifier == "local"
    assert route.classified_intent == "code_mutation"
    assert route.confidence == 0.91
  end

  test "local classifier code mutation fails fast without code-edit harness" do
    assert_raise ArgumentError, ~r/code mutation intent/, fn ->
      WorkflowRouter.route!(%WorkflowRouter{
        requested_workflow: :auto,
        task: "napraw aplikacje",
        pending_action: nil,
        recent_context: nil,
        tool_harnesses: [:local_files],
        approval_mode: :auto_approved_safe,
        test_commands: [],
        router_mode: :local,
        router_model_dir: "/tmp/router-model",
        router_timeout_ms: 100,
        router_confidence_threshold: 0.5,
        classifier_module: LocalCodeMutationClassifier
      })
    end
  end

  test "local classifier low confidence falls back to chat" do
    route =
      WorkflowRouter.route!(%WorkflowRouter{
        requested_workflow: :auto,
        task: "explain this",
        pending_action: nil,
        recent_context: nil,
        tool_harnesses: [:code_edit],
        approval_mode: :auto_approved_safe,
        test_commands: [],
        router_mode: :local,
        router_model_dir: "/tmp/router-model",
        router_timeout_ms: 100,
        router_confidence_threshold: 0.5,
        classifier_module: LocalLowConfidenceClassifier
      })

    assert route.selected == "chat"
    assert route.tool_intent == "none"
    assert route.classifier == "local"
    assert route.classified_intent == "code_mutation"
    assert route.reason == "local_classifier_below_confidence_threshold"
  end

  test "malformed local classifier output fails fast" do
    assert_raise ArgumentError, ~r/invalid intent/, fn ->
      WorkflowRouter.route!(%WorkflowRouter{
        requested_workflow: :auto,
        task: "anything",
        pending_action: nil,
        recent_context: nil,
        tool_harnesses: [],
        approval_mode: nil,
        test_commands: [],
        router_mode: :local,
        router_model_dir: "/tmp/router-model",
        router_timeout_ms: 100,
        router_confidence_threshold: 0.5,
        classifier_module: LocalMalformedClassifier
      })
    end
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
