defmodule AgentMachine.WorkflowToolOptionsTest do
  use ExUnit.Case, async: true

  alias AgentMachine.MCP.Config
  alias AgentMachine.{RunSpec, ToolPolicy, WorkflowToolOptions}

  test "leaves options unchanged when no tool harness is configured" do
    spec =
      RunSpec.new!(%{
        task: "hello",
        workflow: :agentic,
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 1,
        max_attempts: 1
      })

    assert WorkflowToolOptions.put_full_tool_opts([timeout: 1_000], spec) == [timeout: 1_000]
  end

  test "builds full tool options from explicit local file harness" do
    spec =
      RunSpec.new!(%{
        task: "read README.md",
        workflow: :agentic,
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 2,
        max_attempts: 1,
        tool_harness: :local_files,
        tool_root: "/tmp/project",
        tool_timeout_ms: 500,
        tool_max_rounds: 3,
        tool_approval_mode: :read_only
      })

    opts = WorkflowToolOptions.put_full_tool_opts([timeout: 1_000], spec)

    assert Keyword.fetch!(opts, :tool_root) == "/tmp/project"
    assert Keyword.fetch!(opts, :tool_timeout_ms) == 500
    assert Keyword.fetch!(opts, :tool_max_rounds) == 3
    assert Keyword.fetch!(opts, :tool_approval_mode) == :read_only
    assert AgentMachine.Tools.ReadFile in Keyword.fetch!(opts, :allowed_tools)
    assert %ToolPolicy{harness: :local_files} = Keyword.fetch!(opts, :tool_policy)
  end

  test "builds read-only tool options for file-read intent" do
    spec =
      RunSpec.new!(%{
        task: "read README.md",
        workflow: :agentic,
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 2,
        max_attempts: 1,
        tool_harness: :code_edit,
        tool_root: "/tmp/project",
        tool_timeout_ms: 500,
        tool_max_rounds: 3,
        tool_approval_mode: :read_only
      })

    opts = WorkflowToolOptions.put_read_only_tool_opts([timeout: 1_000], spec, "file_read")

    assert Keyword.fetch!(opts, :allowed_tools) == [
             AgentMachine.Tools.FileInfo,
             AgentMachine.Tools.ListFiles,
             AgentMachine.Tools.ReadFile,
             AgentMachine.Tools.SearchFiles
           ]

    assert %ToolPolicy{harness: :code_edit} = Keyword.fetch!(opts, :tool_policy)
    assert Keyword.fetch!(opts, :tool_root) == "/tmp/project"
  end

  test "builds agentic web browse options from only the MCP harness" do
    spec =
      RunSpec.new!(%{
        task: "research latest AI news",
        workflow: :agentic,
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 6,
        max_attempts: 1,
        tool_harnesses: [:code_edit, :mcp],
        tool_root: "/tmp/project",
        tool_timeout_ms: 1_000,
        tool_max_rounds: 16,
        tool_approval_mode: :full_access,
        mcp_config_path: "test-mcp.json",
        mcp_config: playwright_mcp_config()
      })

    opts =
      WorkflowToolOptions.put_agentic_tool_opts([timeout: 1_000], spec, %{
        tool_intent: "web_browse",
        tools_exposed: true
      })

    tools = Keyword.fetch!(opts, :allowed_tools)
    refute AgentMachine.Tools.RunShellCommand in tools
    refute AgentMachine.Tools.ReadFile in tools
    refute Keyword.has_key?(opts, :tool_root)

    assert %ToolPolicy{harness: :mcp} = Keyword.fetch!(opts, :tool_policy)

    assert MapSet.member?(
             Keyword.fetch!(opts, :tool_policy).permissions,
             :mcp_playwright_browser_navigate
           )

    assert length(tools) == 2
  end

  test "fails fast when read-only tool options are requested without harnesses" do
    spec =
      RunSpec.new!(%{
        task: "read README.md",
        workflow: :agentic,
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 2,
        max_attempts: 1
      })

    assert_raise ArgumentError, ~r/tool workflow requires tool harnesses/, fn ->
      WorkflowToolOptions.put_read_only_tool_opts([], spec, :file_read)
    end
  end

  test "fails fast for invalid input" do
    assert_raise ArgumentError,
                 ~r/workflow tool options require keyword opts and a RunSpec/,
                 fn ->
                   WorkflowToolOptions.put_full_tool_opts([], %{})
                 end
  end

  defp playwright_mcp_config do
    Config.from_map!(%{
      "servers" => [
        %{
          "id" => "playwright",
          "transport" => "stdio",
          "command" => "mcp-browser",
          "args" => [],
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
