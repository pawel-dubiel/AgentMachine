defmodule AgentMachine.MCPIntegrationTest do
  use ExUnit.Case, async: false

  alias AgentMachine.{
    JSON,
    MCP.Client,
    MCP.Config,
    MCP.Session,
    MCP.ToolFactory,
    Orchestrator,
    RunSpec,
    ToolHarness,
    ToolPolicy
  }

  alias Mix.Tasks.AgentMachine.Run

  test "MCP config validates explicit allowlists and rejects inline secrets" do
    config =
      Config.from_map!(%{
        "servers" => [
          %{
            "id" => "docs",
            "transport" => "streamable_http",
            "url" => "http://127.0.0.1:9999/mcp",
            "headers" => %{"Authorization" => "env:DOCS_MCP_AUTH"},
            "tools" => [
              %{
                "name" => "search",
                "permission" => "mcp_docs_search",
                "risk" => "network",
                "inputSchema" => %{
                  "type" => "object",
                  "required" => ["query"],
                  "properties" => %{"query" => %{"type" => "string"}}
                }
              }
            ]
          }
        ]
      })

    assert [
             %{
               provider_name: "mcp_docs_search",
               permission: :mcp_docs_search,
               risk: :network,
               input_schema: %{
                 "type" => "object",
                 "required" => ["query"],
                 "properties" => %{"query" => %{"type" => "string"}}
               }
             }
           ] = config.tools

    assert_raise ArgumentError, ~r/MCP tool must include explicit inputSchema object/, fn ->
      Config.from_map!(%{
        "servers" => [
          %{
            "id" => "docs",
            "transport" => "stdio",
            "command" => "mcp-docs",
            "args" => [],
            "env" => %{},
            "tools" => [
              %{"name" => "search", "permission" => "mcp_docs_search", "risk" => "read"}
            ]
          }
        ]
      })
    end

    assert_raise ArgumentError, ~r/env:NAME/, fn ->
      Config.from_map!(%{
        "servers" => [
          %{
            "id" => "docs",
            "transport" => "streamable_http",
            "url" => "http://127.0.0.1:9999/mcp",
            "headers" => %{"Authorization" => "Bearer secret"},
            "tools" => [
              %{
                "name" => "search",
                "permission" => "mcp_docs_search",
                "risk" => "network",
                "inputSchema" => %{"type" => "object"}
              }
            ]
          }
        ]
      })
    end
  end

  test "multi-harness merges tools and policies" do
    config =
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
                "risk" => "read",
                "inputSchema" => %{"type" => "object"}
              }
            ]
          }
        ]
      })

    tools = ToolHarness.builtin_many!([:demo, :mcp], mcp_config: config)
    names = tools |> ToolHarness.definitions!() |> Enum.map(& &1.name)
    assert "now" in names
    assert "mcp_docs_search" in names

    policy = ToolHarness.builtin_policy_many!([:demo, :mcp], mcp_config: config)
    assert MapSet.member?(policy.permissions, :time_read)
    assert MapSet.member?(policy.permissions, :mcp_docs_search)
    assert policy.harness == [:demo, :mcp]
  end

  test "duplicate provider-visible tool names fail fast" do
    assert_raise ArgumentError, ~r/tool name/, fn ->
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
                "risk" => "read",
                "inputSchema" => %{"type" => "object"}
              },
              %{
                "name" => "search",
                "permission" => "mcp_docs_search2",
                "risk" => "read",
                "inputSchema" => %{"type" => "object"}
              }
            ]
          }
        ]
      })
    end
  end

  test "stdio MCP client initializes, lists tools, and calls an allowed tool" do
    script = fake_stdio_server!()

    server = %Config.Server{
      id: "docs",
      transport: :stdio,
      command: script,
      args: [],
      env: %{},
      tools: []
    }

    response = Client.call_tool(server, "search", %{"query" => "beam"}, 1_000)
    assert get_in(response, ["result", "content", Access.at(0), "text"]) == "result for beam"
  end

  test "stdio MCP client reads JSON-RPC responses larger than one port chunk" do
    script = large_stdio_server!(90_000)

    server = %Config.Server{
      id: "docs",
      transport: :stdio,
      command: script,
      args: [],
      env: %{},
      tools: []
    }

    response = Client.call_tool(server, "snapshot", %{}, 1_000)
    text = get_in(response, ["result", "content", Access.at(0), "text"])

    assert byte_size(text) == 90_000
  end

  test "streamable HTTP MCP client sends session header on continuation requests" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    parent = self()

    task =
      Task.async(fn ->
        for index <- 1..3 do
          {:ok, socket} = :gen_tcp.accept(listener)
          request = recv_http!(socket)
          send(parent, {:http_request, index, request})
          id = request |> request_body!() |> JSON.decode!() |> Map.fetch!("id")

          result =
            case index do
              1 -> %{"protocolVersion" => "2025-06-18"}
              2 -> %{"tools" => [%{"name" => "search", "inputSchema" => %{}}]}
              3 -> %{"content" => [%{"type" => "text", "text" => "ok"}]}
            end

          response = JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
          headers = if index == 1, do: "mcp-session-id: session-1\r\n", else: ""

          :ok =
            :gen_tcp.send(
              socket,
              "HTTP/1.1 200 OK\r\n#{headers}content-type: application/json\r\ncontent-length: #{byte_size(response)}\r\n\r\n#{response}"
            )

          :gen_tcp.close(socket)
        end
      end)

    server = %Config.Server{
      id: "docs",
      transport: :streamable_http,
      url: "http://127.0.0.1:#{port}/mcp",
      headers: %{},
      tools: []
    }

    assert %{"result" => %{"content" => [%{"text" => "ok"}]}} =
             Client.call_tool(server, "search", %{}, 1_000)

    assert_receive {:http_request, 1, first}
    assert_receive {:http_request, 2, second}
    assert_receive {:http_request, 3, third}
    assert first =~ ~s("clientInfo")
    assert first =~ ~s("name":"agent-machine")
    refute first =~ "mcp-session-id: session-1"
    assert second =~ "mcp-session-id: session-1"
    assert third =~ "mcp-session-id: session-1"

    Task.await(task)
    :gen_tcp.close(listener)
  end

  test "MCP tool runner redacts bounded results" do
    script = fake_stdio_server!("sk-abcdefghijklmnopqrstuvwxyz123456")

    config =
      Config.from_map!(%{
        "servers" => [
          %{
            "id" => "docs",
            "transport" => "stdio",
            "command" => script,
            "args" => [],
            "env" => %{},
            "tools" => [
              %{
                "name" => "search",
                "permission" => "mcp_docs_search",
                "risk" => "read",
                "inputSchema" => %{"type" => "object"}
              }
            ]
          }
        ]
      })

    [tool] = ToolFactory.tools!(config)
    assert :mcp_docs_search = tool.permission()

    assert {:ok, result} =
             tool.run(%{"arguments" => %{"query" => "beam"}},
               mcp_config: config,
               tool_timeout_ms: 1_000
             )

    assert result.redacted == true
    assert JSON.encode!(result) =~ "[REDACTED"
    refute JSON.encode!(result) =~ "sk-abcdefghijklmnopqrstuvwxyz123456"
  end

  test "MCP session reuses one stdio server across tool calls" do
    script = counting_stdio_server!()

    config =
      Config.from_map!(%{
        "servers" => [
          %{
            "id" => "browser",
            "transport" => "stdio",
            "command" => script,
            "args" => [],
            "env" => %{},
            "tools" => [
              %{
                "name" => "snapshot",
                "permission" => "mcp_browser_snapshot",
                "risk" => "read",
                "inputSchema" => %{"type" => "object"}
              }
            ]
          }
        ]
      })

    [tool] = ToolFactory.tools!(config)
    {:ok, session} = Session.start_link(config)

    opts = [mcp_config: config, mcp_session: session, tool_timeout_ms: 1_000]

    assert {:ok, first} = tool.run(%{"arguments" => %{}}, opts)
    assert get_in(first, [:result, "content", Access.at(0), "text"]) == "call 1"

    assert {:ok, second} = tool.run(%{"arguments" => %{}}, opts)
    assert get_in(second, [:result, "content", Access.at(0), "text"]) == "call 2"

    GenServer.stop(session)
  end

  test "MCP stdio session reads large JSON-RPC tool responses across port chunks" do
    script = large_stdio_server!(90_000)

    config =
      Config.from_map!(%{
        "servers" => [
          %{
            "id" => "browser",
            "transport" => "stdio",
            "command" => script,
            "args" => [],
            "env" => %{},
            "tools" => [
              %{
                "name" => "snapshot",
                "permission" => "mcp_browser_snapshot",
                "risk" => "read",
                "inputSchema" => %{"type" => "object"}
              }
            ]
          }
        ]
      })

    {:ok, session} = Session.start_link(config)

    assert %{"result" => %{"content" => [%{"text" => text}]}} =
             Session.call_tool(session, "browser", "snapshot", %{}, 1_000)

    assert byte_size(text) == 90_000
    GenServer.stop(session)
  end

  test "agent MCP tool use starts and stops a supervised MCP session" do
    parent = self()
    handler_id = {:mcp_integration_test, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:agent_machine, :mcp, :call, :start],
          [:agent_machine, :mcp, :call, :stop]
        ],
        &AgentMachine.TestTelemetryForwarder.handle/4,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    script = fake_stdio_server!()

    config =
      Config.from_map!(%{
        "servers" => [
          %{
            "id" => "docs",
            "transport" => "stdio",
            "command" => script,
            "args" => [],
            "env" => %{},
            "tools" => [
              %{
                "name" => "search",
                "permission" => "mcp_docs_search",
                "risk" => "read",
                "inputSchema" => %{"type" => "object"}
              }
            ]
          }
        ]
      })

    agents = [
      %{
        id: "mcp-user",
        provider: AgentMachine.TestProviders.MCPToolUsing,
        model: "test",
        input: "beam",
        pricing: %{input_per_million: 0.0, output_per_million: 0.0}
      }
    ]

    assert {:ok, run} =
             Orchestrator.run(agents,
               timeout: 1_000,
               allowed_tools: ToolHarness.builtin!(:mcp, mcp_config: config),
               tool_policy: ToolHarness.builtin_policy!(:mcp, mcp_config: config),
               mcp_config: config,
               tool_timeout_ms: 1_000,
               tool_max_rounds: 1,
               tool_approval_mode: :read_only
             )

    assert run.results["mcp-user"].output == "supervised mcp: result for beam"

    assert [{tool_session_supervisor, _}] =
             Registry.lookup(AgentMachine.RunRegistry, {:tool_session_supervisor, run.id})

    assert DynamicSupervisor.which_children(tool_session_supervisor) == []

    events = flush_telemetry([])

    assert Enum.any?(
             events,
             &match?({[:agent_machine, :mcp, :call, :start], _, %{mcp_server_id: "docs"}}, &1)
           )

    assert Enum.any?(
             events,
             &match?(
               {[:agent_machine, :mcp, :call, :stop], %{duration: _}, %{mcp_tool: "search"}},
               &1
             )
           )
  end

  test "MCP stdio session resolves env refs into the child process env" do
    script = env_stdio_server!()
    System.put_env("AGENT_MACHINE_MCP_ENV_TEST_TOKEN", "env-token-42")
    on_exit(fn -> System.delete_env("AGENT_MACHINE_MCP_ENV_TEST_TOKEN") end)

    config =
      Config.from_map!(%{
        "servers" => [
          %{
            "id" => "env",
            "transport" => "stdio",
            "command" => script,
            "args" => [],
            "env" => %{
              "AGENT_MACHINE_CHILD_TOKEN" => "env:AGENT_MACHINE_MCP_ENV_TEST_TOKEN"
            },
            "tools" => [
              %{
                "name" => "read_env",
                "permission" => "mcp_env_read_env",
                "risk" => "read",
                "inputSchema" => %{"type" => "object"}
              }
            ]
          }
        ]
      })

    [tool] = ToolFactory.tools!(config)
    {:ok, session} = Session.start_link(config)

    assert {:ok, result} =
             tool.run(%{"arguments" => %{}},
               mcp_config: config,
               mcp_session: session,
               tool_timeout_ms: 1_000
             )

    assert get_in(result, [:result, "content", Access.at(0), "text"]) == "env-token-42"
    GenServer.stop(session)
  end

  test "RunSpec accepts repeated tool harnesses and loads MCP config" do
    config_path = mcp_config_file!()

    spec =
      RunSpec.new!(%{
        task: "hello",
        workflow: :basic,
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 2,
        max_attempts: 1,
        tool_harnesses: [:demo, :mcp],
        tool_timeout_ms: 100,
        tool_max_rounds: 2,
        tool_approval_mode: :read_only,
        mcp_config_path: config_path
      })

    assert spec.tool_harness == :demo
    assert spec.tool_harnesses == [:demo, :mcp]
    assert %Config{} = spec.mcp_config
  end

  test "mix agent_machine.run accepts repeated tool harness and mcp config" do
    Mix.Task.reenable("agent_machine.run")
    config_path = mcp_config_file!()

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        Run.run([
          "--workflow",
          "basic",
          "--provider",
          "echo",
          "--timeout-ms",
          "1000",
          "--max-steps",
          "2",
          "--max-attempts",
          "1",
          "--tool-harness",
          "demo",
          "--tool-harness",
          "mcp",
          "--tool-timeout-ms",
          "100",
          "--tool-max-rounds",
          "2",
          "--tool-approval-mode",
          "read-only",
          "--mcp-config",
          config_path,
          "--json",
          "hello"
        ])
      end)

    assert output =~ ~s("status":"completed")
  end

  defp mcp_config_file! do
    path =
      Path.join(System.tmp_dir!(), "agent-machine-#{System.unique_integer([:positive])}.mcp.json")

    File.write!(
      path,
      JSON.encode!(%{
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
                "risk" => "read",
                "inputSchema" => %{"type" => "object"}
              }
            ]
          }
        ]
      })
    )

    path
  end

  defp fake_stdio_server!(text \\ "result for beam") do
    path =
      Path.join(System.tmp_dir!(), "agent-machine-mcp-#{System.unique_integer([:positive])}.sh")

    script = """
    #!/bin/sh
    while IFS= read -r line; do
      id=$(printf '%s\\n' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      case "$line" in
        *'"method":"initialize"'*)
          printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-06-18"}}\\n' "$id"
          ;;
        *'"method":"tools/list"'*)
          printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"search","inputSchema":{}}]}}\\n' "$id"
          ;;
        *'"method":"tools/call"'*)
          printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"%s"}]}}\\n' "$id" "#{text}"
          ;;
      esac
    done
    """

    File.write!(path, script)
    File.chmod!(path, 0o700)
    path
  end

  defp counting_stdio_server! do
    path =
      Path.join(
        System.tmp_dir!(),
        "agent-machine-counting-mcp-#{System.unique_integer([:positive])}.sh"
      )

    script = """
    #!/bin/sh
    count=0
    while IFS= read -r line; do
      id=$(printf '%s\\n' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      case "$line" in
        *'"method":"initialize"'*)
          printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-06-18"}}\\n' "$id"
          ;;
        *'"method":"tools/list"'*)
          printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"snapshot","inputSchema":{"type":"object"}}]}}\\n' "$id"
          ;;
        *'"method":"tools/call"'*)
          count=$((count + 1))
          printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"call %s"}]}}\\n' "$id" "$count"
          ;;
      esac
    done
    """

    File.write!(path, script)
    File.chmod!(path, 0o700)
    path
  end

  defp large_stdio_server!(bytes) do
    path =
      Path.join(
        System.tmp_dir!(),
        "agent-machine-large-mcp-#{System.unique_integer([:positive])}.sh"
      )

    script = """
    #!/bin/sh
    while IFS= read -r line; do
      id=$(printf '%s\\n' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      case "$line" in
        *'"method":"initialize"'*)
          printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-06-18"}}\\n' "$id"
          ;;
        *'"method":"tools/list"'*)
          printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"snapshot","inputSchema":{"type":"object"}}]}}\\n' "$id"
          ;;
        *'"method":"tools/call"'*)
          printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"' "$id"
          awk 'BEGIN { for (i = 0; i < #{bytes}; i++) printf "a" }'
          printf '"}]}}\\n'
          ;;
      esac
    done
    """

    File.write!(path, script)
    File.chmod!(path, 0o700)
    path
  end

  defp env_stdio_server! do
    path =
      Path.join(
        System.tmp_dir!(),
        "agent-machine-env-mcp-#{System.unique_integer([:positive])}.sh"
      )

    script = """
    #!/bin/sh
    while IFS= read -r line; do
      id=$(printf '%s\\n' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
      case "$line" in
        *'"method":"initialize"'*)
          printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-06-18"}}\\n' "$id"
          ;;
        *'"method":"tools/list"'*)
          printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"read_env","inputSchema":{"type":"object"}}]}}\\n' "$id"
          ;;
        *'"method":"tools/call"'*)
          printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"%s"}]}}\\n' "$id" "$AGENT_MACHINE_CHILD_TOKEN"
          ;;
      esac
    done
    """

    File.write!(path, script)
    File.chmod!(path, 0o700)
    path
  end

  defp recv_http!(socket) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 1_000)
    recv_http!(socket, data)
  end

  defp recv_http!(socket, data) do
    if complete_http?(data) do
      data
    else
      {:ok, more} = :gen_tcp.recv(socket, 0, 1_000)
      recv_http!(socket, data <> more)
    end
  end

  defp complete_http?(data) do
    case String.split(data, "\r\n\r\n", parts: 2) do
      [_headers, body] -> byte_size(body) > 0
      _other -> false
    end
  end

  defp request_body!(request) do
    [_headers, body] = String.split(request, "\r\n\r\n", parts: 2)
    body
  end

  defp flush_telemetry(acc) do
    receive do
      {:telemetry, event, measurements, metadata} ->
        flush_telemetry([{event, measurements, metadata} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end
end

defmodule AgentMachine.TestProviders.MCPToolUsing do
  @behaviour AgentMachine.Provider

  alias AgentMachine.Agent

  @impl true
  def complete(%Agent{} = agent, opts) do
    case Keyword.get(opts, :tool_continuation) do
      %{state: %{supervised: true}, results: [%{result: result}]} ->
        text = get_in(result, [:result, "content", Access.at(0), "text"])
        final_response("supervised mcp: #{text}")

      nil ->
        tool_request(agent, opts)
    end
  end

  defp tool_request(agent, opts) do
    [tool | _rest] = Keyword.fetch!(opts, :allowed_tools)
    session = Keyword.fetch!(opts, :mcp_session)
    supervisor = Keyword.fetch!(opts, :tool_session_supervisor)

    supervised? =
      supervisor
      |> DynamicSupervisor.which_children()
      |> Enum.any?(fn {_id, pid, _type, _modules} -> pid == session end)

    {:ok,
     %{
       output: "called mcp tool",
       tool_calls: [
         %{
           id: "mcp-search",
           tool: tool,
           input: %{arguments: %{"query" => agent.input}}
         }
       ],
       tool_state: %{supervised: supervised?},
       usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}
     }}
  end

  defp final_response(output) do
    {:ok,
     %{
       output: output,
       usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}
     }}
  end
end
