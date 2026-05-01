defmodule AgentMachine.WorkflowRouterTest do
  use ExUnit.Case, async: true

  alias AgentMachine.{CapabilityRequired, MCP.Config, RunSpec, WorkflowRouter}

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

  defmodule LocalToolUseClassifier do
    def classify!(_input) do
      %{
        intent: :tool_use,
        classified_intent: :tool_use,
        classifier: "local",
        classifier_model: AgentMachine.LocalIntentClassifier.model_id(),
        confidence: 0.58,
        reason: "test_classifier"
      }
    end
  end

  defmodule LocalWebBrowseClassifier do
    def classify!(_input) do
      %{
        intent: :web_browse,
        classified_intent: :web_browse,
        classifier: "local",
        classifier_model: AgentMachine.LocalIntentClassifier.model_id(),
        confidence: 0.92,
        reason: "test_classifier"
      }
    end
  end

  defmodule LocalMalformedClassifier do
    def classify!(_input), do: %{intent: :not_real}
  end

  defmodule LocalProcessClassifier do
    def classify!(_input) do
      Process.get(:workflow_router_classifier_result) ||
        raise "missing :workflow_router_classifier_result"
    end
  end

  defmodule LLMProcessClassifier do
    def classify!(_input) do
      Process.get(:workflow_router_classifier_result) ||
        raise "missing :workflow_router_classifier_result"
    end
  end

  test "run spec defaults auto routing to llm mode" do
    spec =
      RunSpec.new!(%{
        task: "explain the project",
        workflow: :auto,
        provider: :openrouter,
        model: "openai/gpt-4o-mini",
        timeout_ms: 1_000,
        max_steps: 6,
        max_attempts: 1,
        http_timeout_ms: 1_000,
        pricing: %{input_per_million: 0.15, output_per_million: 0.60}
      })

    assert spec.router_mode == :llm
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

  test "routes auto local read intent to tool with a filesystem harness" do
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

    assert route.selected == "tool"
    assert route.tool_intent == "file_read"
    assert route.tools_exposed
  end

  test "routes auto local read intent to tool with a code-edit harness" do
    route =
      route!(%{
        task: "read file lib/foo.ex",
        workflow: :auto,
        tool_harness: :code_edit,
        tool_root: "/tmp/project",
        tool_timeout_ms: 100,
        tool_max_rounds: 2,
        tool_approval_mode: :read_only
      })

    assert route.selected == "tool"
    assert route.tool_intent == "file_read"
    assert route.tools_exposed
  end

  test "routes auto project check intent to tool with a filesystem harness" do
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

    assert route.selected == "tool"
    assert route.tool_intent == "file_read"
    assert route.tools_exposed
  end

  test "routes auto time intent to tool with demo harness" do
    route =
      route!(%{
        task: "what time is it?",
        workflow: :auto,
        tool_harness: :demo,
        tool_timeout_ms: 100,
        tool_max_rounds: 2,
        tool_approval_mode: :read_only
      })

    assert route.selected == "tool"
    assert route.tool_intent == "time"
    assert route.reason == "time_intent_with_read_only_tool"
  end

  test "routes auto time intent to tool with time harness" do
    route =
      route!(%{
        task: "what time is it?",
        workflow: :auto,
        tool_harness: :time,
        tool_timeout_ms: 100,
        tool_max_rounds: 2,
        tool_approval_mode: :read_only
      })

    assert route.selected == "tool"
    assert route.tool_intent == "time"
    assert route.reason == "time_intent_with_read_only_tool"
  end

  test "routes auto time intent to tool with auto time harness when other tools are configured" do
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

    assert route.selected == "tool"
    assert route.tool_intent == "time"
    assert route.reason == "time_intent_with_read_only_tool"
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

  test "routes auto Next.js project creation as code mutation" do
    route =
      route!(%{
        task: "in home folder create tt100 dir and create nextjs project",
        workflow: :auto,
        tool_harness: :code_edit,
        tool_root: "/tmp/home",
        tool_timeout_ms: 100,
        tool_max_rounds: 2,
        tool_approval_mode: :auto_approved_safe
      })

    assert route.selected == "agentic"
    assert route.tool_intent == "code_mutation"
    assert route.reason == "code_mutation_intent_with_code_edit_harness"
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

  test "routes explicit swarm language to agentic swarm strategy" do
    route =
      route!(%{
        task: "create a swarm of agents to build 3 different versions",
        workflow: :auto
      })

    assert route.selected == "agentic"
    assert route.strategy == "swarm"
    assert route.reason == "user_requested_multiple_solution_variants"
  end

  test "carries swarm strategy on explicit agentic workflow" do
    route =
      route!(%{
        task: "prototype several options for this feature",
        workflow: :agentic
      })

    assert route.selected == "agentic"
    assert route.strategy == "swarm"
    assert route.reason == "user_requested_multiple_solution_variants"
  end

  test "does not select swarm for ordinary single-agent work" do
    typo_route =
      route!(%{
        task: "fix typo in README.md",
        workflow: :auto,
        tool_harness: :local_files,
        tool_root: "/tmp/project",
        tool_timeout_ms: 100,
        tool_max_rounds: 2,
        tool_approval_mode: :auto_approved_safe
      })

    assert typo_route.selected == "agentic"
    refute Map.has_key?(typo_route, :strategy)

    delegation_route = route!(%{task: "use agents to fix this bug", workflow: :auto})
    assert delegation_route.selected == "agentic"
    assert delegation_route.tool_intent == "delegation"
    refute Map.has_key?(delegation_route, :strategy)
  end

  test "routes spawn agents intent to agentic when it names concrete work" do
    route = route!(%{task: "spawn agents to review this project", workflow: :auto})

    assert route.selected == "agentic"
    assert route.tool_intent == "delegation"
  end

  test "keeps pure agent capability questions in chat" do
    route = route!(%{task: "can you spawn some agents", workflow: :auto})

    assert route.selected == "chat"
    assert route.tool_intent == "none"

    followup =
      route!(%{task: "but when you solve problems i think you can spawn them", workflow: :auto})

    assert followup.selected == "chat"
    assert followup.tool_intent == "none"
  end

  test "routes complex read-only inspection prompt to tool without write permission" do
    route =
      route!(%{
        task:
          "Please inspect README.md and lib/agent_machine/workflow_router.ex, summarize the auto mode behavior, and do not change any files.",
        workflow: :auto,
        tool_harness: :local_files,
        tool_root: "/tmp/project",
        tool_timeout_ms: 100,
        tool_max_rounds: 2,
        tool_approval_mode: :read_only
      })

    assert route.selected == "tool"
    assert route.tool_intent == "file_read"
    assert route.tools_exposed
  end

  test "routes complex documentation write prompt to local-files mutation" do
    route =
      route!(%{
        task:
          "In the project folder create docs/router-notes.md with a short operational summary; this is documentation only.",
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

  test "routes complex app repair prompt to code mutation" do
    route =
      route!(%{
        task:
          "Projekt1 has a corrupted weather_app.py. Read it, rewrite the Python code so the app can run, and keep configuration placeholders.",
        workflow: :auto,
        tool_harness: :code_edit,
        tool_root: "/tmp/project",
        tool_timeout_ms: 100,
        tool_max_rounds: 2,
        tool_approval_mode: :auto_approved_safe
      })

    assert route.selected == "agentic"
    assert route.tool_intent == "code_mutation"
  end

  test "routes complex explicit multi-agent request to delegation" do
    route =
      route!(%{
        task:
          "Use agents for this: one worker should inspect router behavior, another should inspect TUI progress rendering, then summarize risks.",
        workflow: :auto
      })

    assert route.selected == "agentic"
    assert route.tool_intent == "delegation"
  end

  test "routes generic tool intent to tool with read-risk MCP tool" do
    route =
      WorkflowRouter.route!(%WorkflowRouter{
        requested_workflow: :auto,
        task: "use tool with mcp to search docs",
        pending_action: nil,
        recent_context: nil,
        tool_harnesses: [:mcp],
        approval_mode: :read_only,
        test_commands: [],
        mcp_config: mcp_config("read")
      })

    assert route.selected == "tool"
    assert route.tool_intent == "tool_use"
  end

  test "routes web browse intent to agentic with Playwright MCP browser tool" do
    route =
      WorkflowRouter.route!(%WorkflowRouter{
        requested_workflow: :auto,
        task: "access example.com website",
        pending_action: nil,
        recent_context: nil,
        tool_harnesses: [:mcp],
        approval_mode: :full_access,
        test_commands: [],
        mcp_config: playwright_mcp_config()
      })

    assert route.selected == "agentic"
    assert route.tool_intent == "web_browse"
    assert route.reason == "web_browse_intent_with_mcp_browser"
    assert route.tools_exposed
  end

  test "routes Google news research wording to web browse with Playwright MCP" do
    route =
      WorkflowRouter.route!(%WorkflowRouter{
        requested_workflow: :auto,
        task: "research me in google the latest news in poland",
        pending_action: nil,
        recent_context: nil,
        tool_harnesses: [:mcp],
        approval_mode: :full_access,
        test_commands: [],
        mcp_config: playwright_mcp_config()
      })

    assert route.selected == "agentic"
    assert route.tool_intent == "web_browse"
    assert route.reason == "web_browse_intent_with_mcp_browser"
    assert route.tools_exposed
  end

  test "fails fast for web browse intent without Playwright MCP browser tool" do
    exception =
      assert_raise CapabilityRequired, fn ->
        WorkflowRouter.route!(%WorkflowRouter{
          requested_workflow: :auto,
          task: "open https://example.com",
          pending_action: nil,
          recent_context: nil,
          tool_harnesses: [:mcp],
          approval_mode: :full_access,
          test_commands: [],
          mcp_config: mcp_config("read")
        })
      end

    assert exception.reason == :missing_browser_mcp
    assert CapabilityRequired.to_map(exception).required_mcp_tool == "browser_navigate"
  end

  test "fails fast for web browse intent without full access approval" do
    exception =
      assert_raise CapabilityRequired, fn ->
        WorkflowRouter.route!(%WorkflowRouter{
          requested_workflow: :auto,
          task: "open https://example.com",
          pending_action: nil,
          recent_context: nil,
          tool_harnesses: [:mcp],
          approval_mode: :read_only,
          test_commands: [],
          mcp_config: playwright_mcp_config()
        })
      end

    assert exception.reason == :missing_browser_approval

    assert CapabilityRequired.to_map(exception).required_approval_modes == [
             "full-access",
             "ask-before-write"
           ]
  end

  test "fails fast for generic tool intent without read-risk tools" do
    exception =
      assert_raise CapabilityRequired, fn ->
        WorkflowRouter.route!(%WorkflowRouter{
          requested_workflow: :auto,
          task: "use tool with mcp to update docs",
          pending_action: nil,
          recent_context: nil,
          tool_harnesses: [:mcp],
          approval_mode: :read_only,
          test_commands: [],
          mcp_config: mcp_config("write")
        })
      end

    assert exception.reason == :missing_read_only_tool_capability
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
    exception =
      assert_raise CapabilityRequired, fn ->
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

    assert exception.reason == :missing_code_edit_harness
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

  test "local router uses deterministic guard when classifier is low confidence" do
    route =
      WorkflowRouter.route!(%WorkflowRouter{
        requested_workflow: :auto,
        task: "create hello.md",
        pending_action: nil,
        recent_context: nil,
        tool_harnesses: [:local_files],
        approval_mode: :auto_approved_safe,
        test_commands: [],
        router_mode: :local,
        router_model_dir: "/tmp/router-model",
        router_timeout_ms: 100,
        router_confidence_threshold: 0.5,
        classifier_module: LocalLowConfidenceClassifier
      })

    assert route.selected == "agentic"
    assert route.tool_intent == "file_mutation"
    assert route.classifier == "local"
    assert route.classified_intent == "code_mutation"
  end

  test "local router deterministic guard prevents mutation from becoming generic tool use" do
    route =
      WorkflowRouter.route!(%WorkflowRouter{
        requested_workflow: :auto,
        task: "in home folder create tt100 dir and create nextjs project",
        pending_action: nil,
        recent_context: nil,
        tool_harnesses: [:code_edit],
        approval_mode: :auto_approved_safe,
        test_commands: [],
        router_mode: :local,
        router_model_dir: "/tmp/router-model",
        router_timeout_ms: 100,
        router_confidence_threshold: 0.5,
        classifier_module: LocalToolUseClassifier
      })

    assert route.selected == "agentic"
    assert route.tool_intent == "code_mutation"
    assert route.classifier == "local"
    assert route.classified_intent == "tool_use"
  end

  test "local router does not escalate web browse without a web target" do
    route =
      WorkflowRouter.route!(%WorkflowRouter{
        requested_workflow: :auto,
        task: "hello",
        pending_action: nil,
        recent_context: nil,
        tool_harnesses: [:mcp],
        approval_mode: :read_only,
        test_commands: [],
        mcp_config: playwright_mcp_config(),
        router_mode: :local,
        router_model_dir: "/tmp/router-model",
        router_timeout_ms: 100,
        router_confidence_threshold: 0.5,
        classifier_module: LocalWebBrowseClassifier
      })

    assert route.selected == "chat"
    assert route.tool_intent == "none"
    assert route.reason == "local_classifier_web_browse_without_web_target"
    assert route.classifier == "local"
    assert route.classified_intent == "web_browse"
  end

  test "local router allows web browse when a web target is present" do
    route =
      WorkflowRouter.route!(%WorkflowRouter{
        requested_workflow: :auto,
        task: "sprawdz example.com",
        pending_action: nil,
        recent_context: nil,
        tool_harnesses: [:mcp],
        approval_mode: :full_access,
        test_commands: [],
        mcp_config: playwright_mcp_config(),
        router_mode: :local,
        router_model_dir: "/tmp/router-model",
        router_timeout_ms: 100,
        router_confidence_threshold: 0.5,
        classifier_module: LocalWebBrowseClassifier
      })

    assert route.selected == "agentic"
    assert route.tool_intent == "web_browse"
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

  test "llm router mode feeds intent into existing capability routing" do
    route =
      llm_route!(:file_mutation,
        task: "stwórz mi w home folder gg1 i daj tam prostą stronę",
        tool_harnesses: [:local_files],
        approval_mode: :auto_approved_safe
      )

    assert route.selected == "agentic"
    assert route.tool_intent == "file_mutation"
    assert route.classifier == "llm"
    assert route.classified_intent == "file_mutation"
  end

  test "llm router mode fails fast through existing capability checks" do
    exception =
      assert_raise CapabilityRequired, fn ->
        llm_route!(:code_mutation,
          task: "create a react app file src/main.js with hello world",
          tool_harnesses: [:local_files],
          approval_mode: :auto_approved_safe
        )
      end

    assert exception.reason == :missing_code_edit_harness
  end

  test "llm router deterministic guard preserves classified intent for auditability" do
    route =
      llm_route!(:web_browse,
        task: "create lib/router_example.ex with a simple module",
        tool_harnesses: [:code_edit],
        approval_mode: :auto_approved_safe
      )

    assert route.selected == "agentic"
    assert route.tool_intent == "code_mutation"
    assert route.classifier == "llm"
    assert route.classified_intent == "web_browse"
  end

  describe "local classifier permission and routing matrix" do
    test "none intent stays chat even when tools are configured" do
      route =
        local_route!(:none,
          tool_harnesses: [:code_edit],
          approval_mode: :auto_approved_safe
        )

      assert route.selected == "chat"
      assert route.tool_intent == "none"
      refute route.tools_exposed
      assert route.classified_intent == "none"
    end

    test "file_read needs a read-capable filesystem harness" do
      for harnesses <- [[:local_files], [:code_edit]] do
        route = local_route!(:file_read, tool_harnesses: harnesses, approval_mode: :read_only)

        assert route.selected == "tool"
        assert route.tool_intent == "file_read"
        assert route.tools_exposed
      end

      exception = assert_raise CapabilityRequired, fn -> local_route!(:file_read) end
      assert exception.reason == :missing_read_harness

      assert CapabilityRequired.to_map(exception).required_harnesses == [
               "local-files",
               "code-edit"
             ]
    end

    test "file_mutation asks for a write-capable filesystem harness" do
      for harnesses <- [[:local_files], [:code_edit]] do
        route =
          local_route!(:file_mutation,
            tool_harnesses: harnesses,
            approval_mode: :auto_approved_safe
          )

        assert route.selected == "agentic"
        assert route.tool_intent == "file_mutation"
        assert route.tools_exposed
      end

      exception = assert_raise CapabilityRequired, fn -> local_route!(:file_mutation) end
      assert exception.reason == :missing_write_harness
      assert CapabilityRequired.to_map(exception).required_harness == "local-files"
    end

    test "code_mutation asks specifically for code-edit" do
      route =
        local_route!(:code_mutation,
          tool_harnesses: [:code_edit],
          approval_mode: :auto_approved_safe
        )

      assert route.selected == "agentic"
      assert route.tool_intent == "code_mutation"
      assert route.tools_exposed

      exception =
        assert_raise CapabilityRequired, fn ->
          local_route!(:code_mutation,
            tool_harnesses: [:local_files],
            approval_mode: :auto_approved_safe
          )
        end

      assert exception.reason == :missing_code_edit_harness
      assert CapabilityRequired.to_map(exception).required_harness == "code-edit"
    end

    test "test_command requires code-edit and command-capable approval" do
      route =
        local_route!(:test_command,
          tool_harnesses: [:code_edit],
          approval_mode: :full_access,
          test_commands: ["mix test"]
        )

      assert route.selected == "agentic"
      assert route.tool_intent == "test_command"
      assert route.tools_exposed

      exception =
        assert_raise CapabilityRequired, fn ->
          local_route!(:test_command,
            tool_harnesses: [:local_files],
            approval_mode: :full_access,
            test_commands: ["mix test"]
          )
        end

      assert exception.reason == :missing_test_code_edit_harness

      exception =
        assert_raise CapabilityRequired, fn ->
          local_route!(:test_command,
            tool_harnesses: [:code_edit],
            approval_mode: :auto_approved_safe,
            test_commands: ["mix test"]
          )
        end

      assert exception.reason == :missing_test_approval

      assert CapabilityRequired.to_map(exception).required_approval_modes == [
               "full-access",
               "ask-before-write"
             ]

      route =
        local_route!(:test_command,
          tool_harnesses: [:code_edit],
          approval_mode: :full_access,
          test_commands: []
        )

      assert route.selected == "agentic"
      assert route.reason == "test_intent_with_code_edit_shell"
    end

    test "time intent uses a read-only tool when any tool harness is configured" do
      route =
        local_route!(:time,
          tool_harnesses: [:local_files],
          approval_mode: :read_only
        )

      assert route.selected == "tool"
      assert route.tool_intent == "time"
      assert route.reason == "time_intent_with_read_only_tool"

      no_tool_route = local_route!(:time)
      assert no_tool_route.selected == "chat"
      assert no_tool_route.reason == "time_intent_without_time_harness"
      refute no_tool_route.tools_exposed
    end

    test "tool_use needs at least one read-risk tool" do
      route =
        local_route!(:tool_use,
          tool_harnesses: [:mcp],
          approval_mode: :read_only,
          mcp_config: mcp_config("read")
        )

      assert route.selected == "tool"
      assert route.tool_intent == "tool_use"

      exception = assert_raise CapabilityRequired, fn -> local_route!(:tool_use) end
      assert exception.reason == :missing_tool_harness

      exception =
        assert_raise CapabilityRequired, fn ->
          local_route!(:tool_use,
            tool_harnesses: [:mcp],
            approval_mode: :read_only,
            mcp_config: mcp_config("write")
          )
        end

      assert exception.reason == :missing_read_only_tool_capability
    end

    test "web_browse needs Playwright MCP browser tool and full access" do
      route =
        local_route!(:web_browse,
          task: "open https://example.com",
          tool_harnesses: [:mcp],
          approval_mode: :full_access,
          mcp_config: playwright_mcp_config()
        )

      assert route.selected == "agentic"
      assert route.tool_intent == "web_browse"

      exception =
        assert_raise CapabilityRequired, fn ->
          local_route!(:web_browse,
            task: "open https://example.com",
            tool_harnesses: [:mcp],
            approval_mode: :full_access,
            mcp_config: mcp_config("read")
          )
        end

      assert exception.reason == :missing_browser_mcp

      exception =
        assert_raise CapabilityRequired, fn ->
          local_route!(:web_browse,
            task: "open https://example.com",
            tool_harnesses: [:mcp],
            approval_mode: :read_only,
            mcp_config: playwright_mcp_config()
          )
        end

      assert exception.reason == :missing_browser_approval
    end

    test "web_browse from local classifier does not ask permission without a concrete target" do
      route =
        local_route!(:web_browse,
          task: "hello",
          tool_harnesses: [:mcp],
          approval_mode: :full_access,
          mcp_config: playwright_mcp_config()
        )

      assert route.selected == "chat"
      assert route.tool_intent == "none"
      assert route.reason == "local_classifier_web_browse_without_web_target"
      refute route.tools_exposed
    end

    test "delegation routes to agentic without requiring tools" do
      route = local_route!(:delegation)

      assert route.selected == "agentic"
      assert route.tool_intent == "delegation"
      refute route.tools_exposed
    end

    test "deterministic guard prevents a local false-positive code mutation permission prompt" do
      route =
        local_route!(:code_mutation,
          task:
            "Please read README.md and explain why the instructions are confusing. Do not change anything.",
          tool_harnesses: [:local_files],
          approval_mode: :read_only
        )

      assert route.selected == "tool"
      assert route.tool_intent == "file_read"
      assert route.classified_intent == "code_mutation"
      assert route.reason == "read_intent_with_read_only_tool"
    end

    test "deterministic guard escalates complex mutation even if local classifier says none" do
      route =
        local_route!(:none,
          task:
            "Create a polished Next.js dashboard in the project with package.json, app page, and styles.",
          tool_harnesses: [:code_edit],
          approval_mode: :auto_approved_safe,
          classified_intent: :none
        )

      assert route.selected == "agentic"
      assert route.tool_intent == "code_mutation"
      assert route.classified_intent == "none"
      assert route.reason == "code_mutation_intent_with_code_edit_harness"
    end

    test "affirmative follow-up uses pending action instead of the short reply" do
      route =
        local_route!(:none,
          task: "yes, do it",
          pending_action: "Repair the corrupted weather_app.py Python script.",
          tool_harnesses: [:code_edit],
          approval_mode: :auto_approved_safe,
          classified_intent: :none
        )

      assert route.selected == "agentic"
      assert route.tool_intent == "code_mutation"
      assert route.classified_intent == "none"
    end
  end

  test "fails fast for mutation intent without write-capable harness" do
    exception =
      assert_raise CapabilityRequired, fn ->
        route!(%{task: "create hello.md", workflow: :auto})
      end

    assert exception.reason == :missing_write_harness
  end

  test "fails fast for code patch without code-edit harness" do
    exception =
      assert_raise CapabilityRequired, fn ->
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

    assert exception.reason == :missing_code_edit_harness
    assert CapabilityRequired.to_map(exception).requested_root == "/tmp/project"
  end

  test "fails fast for Next.js project creation without code-edit harness" do
    exception =
      assert_raise CapabilityRequired, fn ->
        route!(%{
          task: "in home folder create tt100 dir and create nextjs project",
          workflow: :auto,
          tool_harness: :local_files,
          tool_root: "/tmp/home",
          tool_timeout_ms: 100,
          tool_max_rounds: 2,
          tool_approval_mode: :auto_approved_safe
        })
      end

    assert exception.reason == :missing_code_edit_harness
    assert CapabilityRequired.to_map(exception).requested_root == "/tmp/home"
  end

  test "routes test intent through code-edit shell when no allowlisted test command exists" do
    route =
      route!(%{
        task: "run mix test",
        workflow: :auto,
        tool_harness: :code_edit,
        tool_root: "/tmp/project",
        tool_timeout_ms: 100,
        tool_max_rounds: 2,
        tool_approval_mode: :full_access
      })

    assert route.selected == "agentic"
    assert route.reason == "test_intent_with_code_edit_shell"
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
    %{
      provider: :echo,
      timeout_ms: 1_000,
      max_steps: 6,
      max_attempts: 1,
      router_mode: :deterministic
    }
    |> Map.merge(attrs)
    |> RunSpec.new!()
    |> WorkflowRouter.route!()
  end

  defp llm_route!(intent, attrs) do
    Process.put(:workflow_router_classifier_result, classifier_result(intent, attrs, "llm"))

    %WorkflowRouter{
      requested_workflow: :auto,
      task: Keyword.get(attrs, :task, "please handle this request"),
      pending_action: Keyword.get(attrs, :pending_action),
      recent_context: Keyword.get(attrs, :recent_context),
      tool_harnesses: Keyword.get(attrs, :tool_harnesses, []),
      approval_mode: Keyword.get(attrs, :approval_mode),
      test_commands: Keyword.get(attrs, :test_commands, []),
      mcp_config: Keyword.get(attrs, :mcp_config),
      router_mode: :llm,
      provider: :openrouter,
      model: "openai/gpt-4o-mini",
      pricing: %{input_per_million: 0.15, output_per_million: 0.60},
      http_timeout_ms: 1_000,
      llm_router_module: LLMProcessClassifier
    }
    |> WorkflowRouter.route!()
  after
    Process.delete(:workflow_router_classifier_result)
  end

  defp local_route!(intent, attrs \\ []) do
    Process.put(:workflow_router_classifier_result, classifier_result(intent, attrs))

    %WorkflowRouter{
      requested_workflow: :auto,
      task: Keyword.get(attrs, :task, "please handle this request"),
      pending_action: Keyword.get(attrs, :pending_action),
      recent_context: Keyword.get(attrs, :recent_context),
      tool_harnesses: Keyword.get(attrs, :tool_harnesses, []),
      approval_mode: Keyword.get(attrs, :approval_mode),
      test_commands: Keyword.get(attrs, :test_commands, []),
      mcp_config: Keyword.get(attrs, :mcp_config),
      router_mode: :local,
      router_model_dir: "/tmp/router-model",
      router_timeout_ms: 100,
      router_confidence_threshold: 0.5,
      classifier_module: LocalProcessClassifier
    }
    |> WorkflowRouter.route!()
  after
    Process.delete(:workflow_router_classifier_result)
  end

  defp classifier_result(intent, attrs, classifier \\ "local") do
    classified_intent = Keyword.get(attrs, :classified_intent, intent)

    %{
      intent: intent,
      classified_intent: classified_intent,
      classifier: classifier,
      classifier_model: classifier_model(classifier),
      confidence: Keyword.get(attrs, :confidence, 0.91),
      reason: "test_classifier_#{intent}"
    }
  end

  defp classifier_model("local"), do: AgentMachine.LocalIntentClassifier.model_id()
  defp classifier_model("llm"), do: "openai/gpt-4o-mini"

  defp mcp_config(risk) do
    Config.from_map!(%{
      "servers" => [
        %{
          "id" => "docs",
          "transport" => "stdio",
          "command" => "mcp-docs",
          "args" => [],
          "env" => %{},
          "tools" => [
            %{
              "name" => "search",
              "permission" => "mcp_docs_search",
              "risk" => risk,
              "inputSchema" => %{"type" => "object"}
            }
          ]
        }
      ]
    })
  end

  defp playwright_mcp_config do
    Config.from_map!(%{
      "servers" => [
        %{
          "id" => "playwright",
          "transport" => "stdio",
          "command" => "npx",
          "args" => ["--yes", "@playwright/mcp@latest", "--headless"],
          "env" => %{},
          "tools" => [
            %{
              "name" => "browser_navigate",
              "permission" => "mcp_playwright_browser_navigate",
              "risk" => "network",
              "inputSchema" => %{
                "type" => "object",
                "required" => ["url"],
                "properties" => %{"url" => %{"type" => "string"}},
                "additionalProperties" => false
              }
            },
            %{
              "name" => "browser_snapshot",
              "permission" => "mcp_playwright_browser_snapshot",
              "risk" => "read",
              "inputSchema" => %{"type" => "object"}
            }
          ]
        }
      ]
    })
  end
end
