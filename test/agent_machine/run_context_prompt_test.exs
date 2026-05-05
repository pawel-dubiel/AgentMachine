defmodule AgentMachine.RunContextPromptTest do
  use ExUnit.Case, async: true

  alias AgentMachine.{JSON, RunContextPrompt}

  test "includes runtime facts for empty run context" do
    now = ~U[2026-04-29 16:27:30Z]

    text =
      RunContextPrompt.text(
        run_context: %{results: %{}, artifacts: %{}},
        runtime_facts: RunContextPrompt.runtime_facts(now: now)
      )

    assert %{
             "runtime" => %{
               "current_utc" => "2026-04-29T16:27:30Z",
               "utc_date" => "2026-04-29",
               "local_timezone" => timezone,
               "agent_machine" => %{
                 "role" => role,
                 "execution_model" => execution_model,
                 "execution_strategies" => strategies,
                 "instruction" => agent_machine_instruction
               },
               "instruction" => instruction
             },
             "results" => %{},
             "artifacts" => %{}
           } = JSON.decode!(text)

    assert is_binary(timezone)
    assert role == "assistant running inside AgentMachine"
    assert execution_model =~ "Elixir runtime executes tools"
    assert strategies["direct"] =~ "no tools"
    assert strategies["planned"] =~ "next_agents"
    assert agent_machine_instruction =~ "Do not claim AgentMachine lacks agents"
    assert instruction =~ "Do not invent dates or times"
  end

  test "can omit runtime facts for callers that need an empty context" do
    assert RunContextPrompt.text(
             run_context: %{results: %{}, artifacts: %{}},
             runtime_facts: false
           ) ==
             ""
  end

  test "includes execution strategy and compatibility route in runtime facts" do
    text =
      RunContextPrompt.text(
        run_context: %{results: %{}, artifacts: %{}},
        runtime_facts:
          RunContextPrompt.runtime_facts(
            now: ~U[2026-04-29 16:27:30Z],
            execution_strategy: %{
              requested: "agentic",
              selected: "tool",
              reason: "time_intent_with_read_only_tool",
              tool_intent: "time",
              strategy: "tool",
              work_shape: "generic_tool_use",
              route_hint: "tool"
            }
          )
      )

    assert %{
             "runtime" => %{
               "execution_strategy" => %{
                 "requested" => "agentic",
                 "selected" => "tool",
                 "tool_intent" => "time",
                 "strategy" => "tool",
                 "work_shape" => "generic_tool_use",
                 "route_hint" => "tool"
               },
               "workflow_route" => %{
                 "requested" => "agentic",
                 "selected" => "tool",
                 "tool_intent" => "time",
                 "strategy" => "tool",
                 "work_shape" => "generic_tool_use",
                 "route_hint" => "tool"
               }
             }
           } = JSON.decode!(text)
  end

  test "includes structured conversation context only when supplied" do
    text =
      RunContextPrompt.text(
        run_context: %{results: %{}, artifacts: %{}},
        conversation_context: %{
          recent_context: "user created mdp1; assistant confirmed completion",
          pending_action: "continue in mdp1"
        }
      )

    assert %{
             "runtime" => %{
               "conversation_context" => %{
                 "recent_context" => "user created mdp1; assistant confirmed completion",
                 "pending_action" => "continue in mdp1",
                 "instruction" => instruction
               }
             }
           } = JSON.decode!(text)

    assert instruction =~ "Current task is authoritative"
    assert instruction =~ "Do not redo prior completed work"
  end

  test "includes safe current agent facts from run context" do
    text =
      RunContextPrompt.text(
        run_context: %{
          run_id: "run-1",
          agent_id: "variant-minimal",
          parent_agent_id: "planner",
          agent: %{
            agent_machine_role: "swarm_variant",
            swarm_id: "default",
            variant_id: "minimal",
            workspace: ".agent-machine/swarm/run-1/minimal"
          },
          results: %{},
          artifacts: %{}
        }
      )

    assert %{
             "runtime" => %{
               "run_id" => "run-1",
               "current_agent" => %{
                 "agent_id" => "variant-minimal",
                 "parent_agent_id" => "planner",
                 "agent_machine_role" => "swarm_variant",
                 "variant_id" => "minimal",
                 "workspace" => ".agent-machine/swarm/run-1/minimal"
               }
             }
           } = JSON.decode!(text)
  end

  test "includes explicit tool context when tools are available" do
    text =
      RunContextPrompt.text(
        run_context: %{results: %{}, artifacts: %{}},
        allowed_tools: [AgentMachine.Tools.CreateDir, AgentMachine.Tools.WriteFile],
        tool_policy: AgentMachine.ToolHarness.builtin_policy!(:local_files),
        tool_root: "/tmp/agent-machine-home",
        tool_approval_mode: :auto_approved_safe,
        tool_timeout_ms: 120_000,
        tool_max_rounds: 16
      )

    assert %{
             "tools" => %{
               "harness" => "local_files",
               "root" => "/tmp/agent-machine-home",
               "approval_mode" => "auto_approved_safe",
               "tool_timeout_ms" => 120_000,
               "tool_max_rounds" => 16,
               "available_tools" => tools,
               "instruction" => instruction
             }
           } = JSON.decode!(text)

    assert "create_dir" in tools
    assert "write_file" in tools
    assert instruction =~ "inspect that exact relative path"
    assert instruction =~ "Use search_files only for content search under a narrow path"
    assert instruction =~ "less than or equal to tool_timeout_ms"
    assert instruction =~ "create_file needs path, content, overwrite"
    assert instruction =~ "Use MCP browser tools for web browsing"

    assert instruction =~
             "Do not claim file, directory, browser, or external changes unless tool_results confirm"
  end

  test "includes exact allowed test commands in tool context" do
    text =
      RunContextPrompt.text(
        run_context: %{results: %{}, artifacts: %{}},
        allowed_tools: [AgentMachine.Tools.RunTestCommand],
        tool_policy:
          AgentMachine.ToolHarness.builtin_policy!(:code_edit,
            test_commands: ["mix test"]
          ),
        tool_root: "/tmp/agent-machine-project",
        tool_approval_mode: :full_access,
        tool_timeout_ms: 120_000,
        tool_max_rounds: 16,
        test_commands: ["mix test"]
      )

    assert %{
             "tools" => %{
               "available_tools" => ["run_test_command"],
               "test_commands" => ["mix test"],
               "instruction" => instruction
             }
           } = JSON.decode!(text)

    assert instruction =~ "exact command from test_commands"
  end

  test "includes explicit disabled tool context" do
    text =
      RunContextPrompt.text(
        run_context: %{results: %{}, artifacts: %{}},
        tool_context: %{
          harness: "local_files",
          root: "/tmp/agent-machine-home",
          approval_mode: :auto_approved_safe,
          available_tools: ["create_dir"],
          instruction: "Tools are available to worker agents only."
        }
      )

    assert %{
             "tools" => %{
               "harness" => "local_files",
               "root" => "/tmp/agent-machine-home",
               "approval_mode" => "auto_approved_safe",
               "available_tools" => ["create_dir"],
               "instruction" => "Tools are available to worker agents only."
             }
           } = JSON.decode!(text)
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
