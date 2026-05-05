defmodule AgentMachine.OpenRouterPaidTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AgentMachine.{Agent, ClientRunner, JSON, Orchestrator}
  alias AgentMachine.Providers.ReqLLM, as: ReqLLMProvider
  alias Mix.Tasks.AgentMachine.Run
  alias Mix.Tasks.AgentMachine.Skills, as: SkillsTask

  @moduletag :paid_openrouter
  @moduletag timeout: 180_000
  @default_model "moonshotai/kimi-k2.6"
  @pricing %{input_per_million: 0.0, output_per_million: 0.0}

  setup_all do
    model = paid_model()

    case System.fetch_env("OPENROUTER_API_KEY") do
      {:ok, key} when byte_size(key) > 0 ->
        IO.puts("Running paid OpenRouter tests with model=#{model}")
        :ok

      _missing ->
        flunk("OPENROUTER_API_KEY is required for paid OpenRouter integration tests")
    end
  end

  test "OpenRouter paid model returns a provider response" do
    model = paid_model()

    agent =
      Agent.new!(%{
        id: "openrouter-paid-provider",
        provider: ReqLLMProvider,
        model: openrouter_model(model),
        pricing: @pricing,
        instructions:
          "Reply with one short sentence. Do not call tools. Include the word AgentMachine.",
        input: "Say that this paid OpenRouter integration test is working."
      })

    assert {:ok, payload} =
             ReqLLMProvider.complete(agent,
               http_timeout_ms: 120_000,
               run_context: empty_run_context()
             )

    assert is_binary(payload.output)
    assert String.trim(payload.output) != ""
    assert payload.usage.total_tokens > 0
    assert payload.usage.input_tokens > 0
  end

  @tag :openrouter_stream_probe
  test "OpenRouter paid model streams directly without workflow runtime" do
    model = paid_model()
    parent = self()

    agent =
      Agent.new!(%{
        id: "openrouter-paid-direct-stream",
        provider: ReqLLMProvider,
        model: openrouter_model(model),
        pricing: @pricing,
        instructions:
          "Reply with one short sentence. Do not call tools. Include the word AgentMachine.",
        input: "Say that this direct OpenRouter streaming probe is working."
      })

    started_ms = System.monotonic_time(:millisecond)

    result =
      ReqLLMProvider.stream_complete(agent,
        http_timeout_ms: 120_000,
        run_context: empty_run_context(agent.id),
        stream_context: %{
          run_id: "paid-openrouter-direct-stream",
          agent_id: agent.id,
          attempt: 1
        },
        stream_event_sink: fn event ->
          send(parent, {:openrouter_stream_event, event, System.monotonic_time(:millisecond)})
        end
      )

    finished_ms = System.monotonic_time(:millisecond)
    events = drain_openrouter_stream_events([])
    delta_events = Enum.filter(events, fn {event, _ms} -> event.type == :assistant_delta end)
    first_delta_ms = first_delta_elapsed_ms(delta_events, started_ms)

    IO.puts(
      "OpenRouter direct stream probe model=#{model} " <>
        "status=#{stream_status(result)} " <>
        "time_to_first_delta_ms=#{inspect(first_delta_ms)} " <>
        "duration_ms=#{finished_ms - started_ms} " <>
        "delta_count=#{length(delta_events)}"
    )

    assert {:ok, payload} = result
    assert is_integer(first_delta_ms)
    assert first_delta_ms >= 0
    assert delta_events != []
    assert is_binary(payload.output)
    assert String.trim(payload.output) != ""
    assert payload.usage.total_tokens > 0
  end

  test "ClientRunner completes a direct run through the OpenRouter paid model" do
    summary =
      ClientRunner.run!(%{
        task: "Reply with one concise sentence that includes AgentMachine.",
        workflow: :agentic,
        provider: "openrouter",
        model: paid_model(),
        timeout_ms: 120_000,
        max_steps: 2,
        max_attempts: 1,
        http_timeout_ms: 120_000,
        pricing: @pricing
      })

    assert summary.status == "completed"
    assert is_binary(summary.final_output)
    assert String.trim(summary.final_output) != ""
    assert summary.usage.total_tokens > 0
    assert Enum.any?(summary.events, &(&1.type == "run_completed"))
  end

  test "mix agent_machine.skills generate creates and lists an OpenRouter-authored skill" do
    root = paid_tmp_root!("skills-generate")
    skills_dir = Path.join(root, "skills")

    on_exit(fn -> File.rm_rf(root) end)

    Mix.Task.reenable("agent_machine.skills")

    generate_output =
      capture_io(fn ->
        SkillsTask.run([
          "generate",
          "paid-docs-helper",
          "--skills-dir",
          skills_dir,
          "--description",
          "Helps produce concise release note documentation from implementation notes",
          "--provider",
          "openrouter",
          "--model",
          paid_model(),
          "--http-timeout-ms",
          "120000",
          "--input-price-per-million",
          "0",
          "--output-price-per-million",
          "0",
          "--json"
        ])
      end)

    assert %{"created" => %{"name" => "paid-docs-helper"}} =
             JSON.decode!(String.trim(generate_output))

    Mix.Task.reenable("agent_machine.skills")

    list_output =
      capture_io(fn ->
        SkillsTask.run(["list", "--skills-dir", skills_dir, "--json"])
      end)

    assert %{"skills" => [%{"name" => "paid-docs-helper"}]} =
             JSON.decode!(String.trim(list_output))

    summary =
      ClientRunner.run!(%{
        task: "Use paid-docs-helper to draft release note documentation",
        workflow: :agentic,
        provider: :echo,
        timeout_ms: 1_000,
        max_steps: 6,
        max_attempts: 1,
        skills_mode: :auto,
        skills_dir: skills_dir
      })

    assert [%{name: "paid-docs-helper"}] = summary.skills
  end

  test "mix agent_machine.run streams a completed OpenRouter JSONL run" do
    Mix.Task.reenable("agent_machine.run")
    model = paid_model()

    output =
      capture_io(fn ->
        Run.run([
          "--workflow",
          "agentic",
          "--provider",
          "openrouter",
          "--model",
          model,
          "--timeout-ms",
          "120000",
          "--http-timeout-ms",
          "120000",
          "--max-steps",
          "2",
          "--max-attempts",
          "1",
          "--input-price-per-million",
          "0",
          "--output-price-per-million",
          "0",
          "--jsonl",
          "Reply with one concise sentence that includes AgentMachine and Mix."
        ])
      end)

    envelopes =
      output
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "{"))
      |> Enum.map(&JSON.decode!/1)

    assert Enum.any?(envelopes, &(Map.get(&1, "type") == "event"))
    assert %{"type" => "summary", "summary" => summary} = List.last(envelopes)
    assert summary["status"] == "completed"
    assert is_binary(summary["final_output"])
    assert String.trim(summary["final_output"]) != ""
    assert get_in(summary, ["usage", "total_tokens"]) > 0

    event_types = Enum.map(summary["events"], & &1["type"])
    assert "run_started" in event_types
    assert "run_completed" in event_types
  end

  test "ClientRunner lets OpenRouter call an allowlisted MCP stdio tool" do
    marker = "MCP_PAID_TOOL_RESULT_42"
    script = fake_mcp_stdio_server!(marker)
    config_path = mcp_config_file!(script)

    summary =
      ClientRunner.run!(%{
        task:
          "You have access to an MCP tool named mcp_paid_lookup. Call that tool once with arguments {\"query\":\"agent-machine\"}. Then answer with the exact marker returned by the tool. Do not answer without using the tool.",
        workflow: :agentic,
        provider: "openrouter",
        model: paid_model(),
        timeout_ms: 120_000,
        max_steps: 2,
        max_attempts: 1,
        http_timeout_ms: 120_000,
        pricing: @pricing,
        tool_harnesses: [:mcp],
        tool_timeout_ms: 30_000,
        tool_max_rounds: 4,
        tool_approval_mode: :read_only,
        mcp_config_path: config_path
      })

    assert summary.status == "completed"
    assert summary.final_output =~ marker
    assert summary.usage.total_tokens > 0
    assert Enum.any?(summary.events, &(&1.type == "tool_call_finished"))
    assert event_with?(summary.events, :tool, "mcp_paid_lookup")

    assistant = Map.fetch!(summary.results, "assistant")
    assert assistant.status == "ok"
    assert assistant.tool_results != %{}
  end

  @tag :openrouter_auto_web_browse_mcp_paid
  test "web browse strategy delegates to an MCP browser worker through OpenRouter" do
    marker = "POLAND_NEWS_PAID_MARKER_42"
    script = fake_playwright_mcp_stdio_server!(marker)
    config_path = playwright_mcp_config_file!(script)

    summary =
      ClientRunner.run!(%{
        task:
          "research me in google the latest news in poland. If the browser results contain an uppercase marker string, include it exactly in your answer.",
        workflow: :agentic,
        provider: "openrouter",
        model: paid_model(),
        timeout_ms: 180_000,
        max_steps: 6,
        max_attempts: 1,
        http_timeout_ms: 120_000,
        pricing: @pricing,
        tool_harnesses: [:mcp],
        tool_timeout_ms: 30_000,
        tool_max_rounds: 6,
        tool_approval_mode: :full_access,
        mcp_config_path: config_path
      })

    assert summary.status == "completed"
    assert summary.execution_strategy.selected == "planned"
    assert summary.execution_strategy.tool_intent == "web_browse"
    assert summary.execution_strategy.reason == "web_browse_intent_with_mcp_browser"
    assert summary.final_output =~ marker
    assert event_with?(summary.events, :tool, "mcp_playwright_browser_navigate")
    assert event_with?(summary.events, :tool, "mcp_playwright_browser_snapshot")

    planner = Map.fetch!(summary.results, "planner")
    assert planner.decision.mode == "delegate"
    assert planner.decision.delegated_agent_ids != []
  end

  @tag :openrouter_swarm_paid
  @tag timeout: 600_000
  test "swarm variants write isolated sorting implementations and run approved checks" do
    root = paid_tmp_root!("swarm-sort-approved")
    parent = self()
    run_id = "paid-swarm-sort-#{System.unique_integer([:positive])}"
    test_commands = ["elixir sort_check.exs"]

    on_exit(fn -> File.rm_rf(root) end)

    callback = fn context ->
      send(parent, {:swarm_approval_context, context})

      if swarm_variant_approval_context?(context) do
        :approved
      else
        {:denied, "paid swarm test only approves variant tool requests"}
      end
    end

    agents = [
      %{
        id: "planner",
        provider: __MODULE__.PaidSwarmPlanner,
        model: paid_model(),
        input: "plan paid OpenRouter sorting swarm",
        pricing: @pricing
      }
    ]

    assert {:ok, run} =
             Orchestrator.run(agents,
               run_id: run_id,
               timeout: 360_000,
               max_steps: 5,
               http_timeout_ms: 180_000,
               allowed_tools:
                 AgentMachine.ToolHarness.builtin_many!([:code_edit],
                   test_commands: test_commands
                 ),
               tool_policy:
                 AgentMachine.ToolHarness.builtin_policy_many!([:code_edit],
                   test_commands: test_commands
                 ),
               tool_root: root,
               test_commands: test_commands,
               tool_timeout_ms: 60_000,
               tool_max_rounds: 6,
               tool_approval_mode: :ask_before_write,
               tool_approval_callback: callback,
               execution_strategy: %{
                 selected: "swarm",
                 strategy: "swarm",
                 reason: "paid_swarm_integration_test"
               },
               workflow_route: %{
                 selected: "swarm",
                 strategy: "swarm",
                 reason: "paid_swarm_integration_test"
               }
             )

    approval_contexts = drain_swarm_approval_contexts([])

    variant_events =
      Enum.filter(
        run.events,
        &(&1.type == :agent_started and &1[:agent_machine_role] == "swarm_variant")
      )

    assert run.status == :completed
    assert run.opts[:execution_strategy].selected == "swarm"
    assert run.opts[:workflow_route].strategy == "swarm"
    assert run.results["planner"].status == :ok
    assert run.results["variant-minimal"].status == :ok
    assert run.results["variant-robust"].status == :ok
    assert run.results["variant-experimental"].status == :ok
    assert run.results["swarm-evaluator"].status == :ok
    assert Enum.map(variant_events, & &1[:variant_id]) |> Enum.sort() == variant_ids()
    assert Enum.all?(approval_contexts, &swarm_variant_approval_context?/1)
    assert approved_tool?(approval_contexts, AgentMachine.Tools.ApplyPatch)
    assert approved_tool?(approval_contexts, AgentMachine.Tools.RunTestCommand)

    assert Enum.count(run.events, fn event ->
             event[:type] == :tool_call_finished and event[:tool] == "run_test_command" and
               event[:agent_machine_role] == "swarm_variant"
           end) >= 3

    assert Enum.any?(run.events, fn event ->
             event[:type] == :agent_started and event[:agent_machine_role] == "swarm_evaluator"
           end)

    assert root_entries_without_swarm_state(root) == []

    Enum.each(variant_ids(), fn variant_id ->
      pattern =
        Path.join(root, ".agent-machine/swarm/#{run.id}/#{variant_id}/**/sort_check.exs")

      assert Path.wildcard(pattern) != []
    end)

    evaluator_output = String.downcase(run.results["swarm-evaluator"].output || "")
    assert evaluator_output =~ "minimal"
    assert evaluator_output =~ "robust"
    assert evaluator_output =~ "experimental"
    assert evaluator_output =~ "recommend"
  end

  @tag :playwright_mcp
  @tag timeout: 300_000
  test "ClientRunner lets OpenRouter drive Playwright MCP against a local page" do
    if System.get_env("AGENT_MACHINE_PAID_PLAYWRIGHT_MCP") == "1" do
      if is_nil(System.find_executable("npx")) do
        flunk("npx is required for the Playwright MCP paid integration test")
      end

      marker = "PLAYWRIGHT_MCP_PAID_MARKER_42"
      url = marker_page_url!(marker)
      config_path = playwright_mcp_config_file!()

      summary =
        ClientRunner.run!(%{
          task:
            "Use the MCP tools mcp_playwright_browser_navigate and mcp_playwright_browser_snapshot. First call mcp_playwright_browser_navigate with arguments {\"arguments\":{\"url\":\"#{url}\"}}. Then call mcp_playwright_browser_snapshot with arguments {\"arguments\":{}}. Reply with the exact marker text from the page and nothing else.",
          workflow: :agentic,
          provider: "openrouter",
          model: paid_model(),
          timeout_ms: 240_000,
          max_steps: 2,
          max_attempts: 1,
          http_timeout_ms: 120_000,
          pricing: @pricing,
          tool_harnesses: [:mcp],
          tool_timeout_ms: 120_000,
          tool_max_rounds: 6,
          tool_approval_mode: :full_access,
          mcp_config_path: config_path
        })

      assert summary.status == "completed"
      assert summary.final_output =~ marker
      assert event_with?(summary.events, :tool, "mcp_playwright_browser_navigate")
      assert event_with?(summary.events, :tool, "mcp_playwright_browser_snapshot")
    else
      IO.puts(
        "Skipping Playwright MCP paid integration test; set AGENT_MACHINE_PAID_PLAYWRIGHT_MCP=1"
      )
    end
  end

  defmodule PaidSwarmPlanner do
    @behaviour AgentMachine.Provider

    alias AgentMachine.Agent
    alias AgentMachine.Providers.ReqLLM, as: ReqLLMProvider

    @variants ["minimal", "robust", "experimental"]

    @impl true
    def complete(%Agent{id: "planner"} = agent, opts) do
      run_id = opts |> Keyword.fetch!(:run_context) |> Map.fetch!(:run_id)
      output = "planned paid OpenRouter swarm"

      {:ok,
       %{
         output: output,
         usage: usage(agent, output),
         next_agents:
           Enum.map(@variants, &variant(&1, run_id, agent)) ++
             [
               %{
                 id: "swarm-evaluator",
                 provider: ReqLLMProvider,
                 model: AgentMachine.OpenRouterPaidTest.openrouter_model(agent.model),
                 instructions:
                   "Compare the variant outputs. Do not call tools. Recommend one variant and explain correctness, simplicity, maintainability, testability, and risk.",
                 input:
                   "Evaluate the minimal, robust, and experimental sorting variants from run context. Include the words minimal, robust, experimental, and recommend.",
                 pricing: agent.pricing,
                 depends_on: Enum.map(@variants, &"variant-#{&1}"),
                 metadata: %{
                   agent_machine_role: "swarm_evaluator",
                   swarm_id: "default",
                   agent_machine_disable_tools: true
                 }
               }
             ]
       }}
    end

    defp variant(variant_id, run_id, agent) do
      workspace = ".agent-machine/swarm/#{run_id}/#{variant_id}"

      %{
        id: "variant-#{variant_id}",
        provider: AgentMachine.OpenRouterPaidTest.PaidSwarmVariant,
        model: agent.model,
        input: "build #{variant_id} sorting variant in #{workspace}",
        pricing: agent.pricing,
        metadata: %{
          agent_machine_role: "swarm_variant",
          swarm_id: "default",
          variant_id: variant_id,
          workspace: workspace
        }
      }
    end

    defp usage(agent, output) do
      input_tokens = token_count(agent.input)
      output_tokens = token_count(output)

      %{
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        total_tokens: input_tokens + output_tokens
      }
    end

    defp token_count(text) do
      text
      |> String.split(~r/\s+/, trim: true)
      |> length()
    end
  end

  defmodule PaidSwarmVariant do
    @behaviour AgentMachine.Provider

    alias AgentMachine.Agent

    @impl true
    def complete(%Agent{} = agent, opts) do
      variant_id = Map.fetch!(agent.metadata, :variant_id)

      case Keyword.get(opts, :tool_continuation) do
        nil ->
          request_patch(agent, variant_id)

        %{state: %{stage: "patch"}} ->
          request_test(agent, variant_id)

        %{state: %{stage: "test"}, results: [%{result: result}]} ->
          output = "#{variant_id} completed sort_check.exs exit_status=#{result.exit_status}"
          {:ok, %{output: output, usage: usage(agent, output)}}
      end
    end

    defp request_patch(agent, variant_id) do
      output = "#{variant_id} creating sort_check.exs"

      {:ok,
       %{
         output: output,
         usage: usage(agent, output),
         tool_calls: [
           %{
             id: "#{variant_id}-patch",
             tool: AgentMachine.Tools.ApplyPatch,
             input: %{patch: sort_patch(variant_id)}
           }
         ],
         tool_state: %{stage: "patch"}
       }}
    end

    defp request_test(agent, variant_id) do
      output = "#{variant_id} running sort_check.exs"

      {:ok,
       %{
         output: output,
         usage: usage(agent, output),
         tool_calls: [
           %{
             id: "#{variant_id}-test",
             tool: AgentMachine.Tools.RunTestCommand,
             input: %{command: "elixir sort_check.exs", cwd: "."}
           }
         ],
         tool_state: %{stage: "test"}
       }}
    end

    defp sort_patch(variant_id) do
      content_lines =
        variant_id
        |> sort_check_content()
        |> String.split("\n")

      ([
         "diff --git a/sort_check.exs b/sort_check.exs",
         "new file mode 100644",
         "--- /dev/null",
         "+++ b/sort_check.exs",
         "@@ -0,0 +1,#{length(content_lines)} @@"
       ] ++ Enum.map(content_lines, &"+#{&1}"))
      |> Enum.join("\n")
    end

    defp sort_check_content("minimal") do
      """
      defmodule SortVariant do
        def sort(list), do: Enum.sort(list)
      end

      checks = [[], [1], [1, 2, 3], [3, 1, 2], [2, 1, 2, 1], [-1, 3, 0, -1]]

      Enum.each(checks, fn input ->
        expected = Enum.sort(input)
        actual = SortVariant.sort(input)
        unless actual == expected, do: raise("minimal sort failed")
      end)

      IO.puts("SORT_CHECK_OK minimal")
      """
      |> String.trim()
    end

    defp sort_check_content("robust") do
      """
      defmodule SortVariant do
        def sort(list), do: merge_sort(list)

        defp merge_sort([]), do: []
        defp merge_sort([item]), do: [item]

        defp merge_sort(list) do
          {left, right} = Enum.split(list, div(length(list), 2))
          merge(merge_sort(left), merge_sort(right))
        end

        defp merge([], right), do: right
        defp merge(left, []), do: left

        defp merge([left | left_tail] = left_items, [right | right_tail] = right_items) do
          if left <= right do
            [left | merge(left_tail, right_items)]
          else
            [right | merge(left_items, right_tail)]
          end
        end
      end

      checks = [[], [1], [1, 2, 3], [3, 1, 2], [2, 1, 2, 1], [-1, 3, 0, -1]]

      Enum.each(checks, fn input ->
        expected = Enum.sort(input)
        actual = SortVariant.sort(input)
        unless actual == expected, do: raise("robust merge sort failed")
      end)

      IO.puts("SORT_CHECK_OK robust")
      """
      |> String.trim()
    end

    defp sort_check_content("experimental") do
      """
      defmodule SortVariant do
        def sort([]), do: []

        def sort([pivot | rest]) do
          {lower, greater} = Enum.split_with(rest, &(&1 <= pivot))
          sort(lower) ++ [pivot] ++ sort(greater)
        end
      end

      checks = [[], [1], [1, 2, 3], [3, 1, 2], [2, 1, 2, 1], [-1, 3, 0, -1]]

      Enum.each(checks, fn input ->
        expected = Enum.sort(input)
        actual = SortVariant.sort(input)
        unless actual == expected, do: raise("experimental quicksort failed")
      end)

      IO.puts("SORT_CHECK_OK experimental")
      """
      |> String.trim()
    end

    defp usage(agent, output) do
      input_tokens = token_count(agent.input)
      output_tokens = token_count(output)

      %{
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        total_tokens: input_tokens + output_tokens
      }
    end

    defp token_count(text) do
      text
      |> String.split(~r/\s+/, trim: true)
      |> length()
    end
  end

  defp paid_model do
    case System.get_env("AGENT_MACHINE_PAID_OPENROUTER_MODEL") do
      nil ->
        @default_model

      model ->
        model = String.trim(model)

        if model == "" do
          flunk("AGENT_MACHINE_PAID_OPENROUTER_MODEL must be non-empty when set")
        end

        model
    end
  end

  def openrouter_model("openrouter:" <> _model = model), do: model
  def openrouter_model(model) when is_binary(model), do: "openrouter:" <> model

  defp paid_tmp_root!(prefix) do
    root =
      Path.join(
        System.tmp_dir!(),
        "agent-machine-paid-openrouter-#{prefix}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    root
  end

  defp variant_ids, do: ["experimental", "minimal", "robust"]

  defp swarm_variant_approval_context?(context) when is_map(context) do
    context.agent_machine_role == "swarm_variant" and
      context.swarm_id == "default" and
      is_binary(context.variant_id) and context.variant_id != "" and
      is_binary(context.workspace) and
      String.contains?(context.workspace, ".agent-machine/swarm/") and
      context.risk in [:write, :command]
  end

  defp approved_tool?(contexts, tool) do
    Enum.any?(contexts, &(&1.tool == tool))
  end

  defp drain_swarm_approval_contexts(acc) do
    receive do
      {:swarm_approval_context, context} ->
        drain_swarm_approval_contexts([context | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp root_entries_without_swarm_state(root) do
    root
    |> File.ls!()
    |> Enum.reject(&(&1 == ".agent-machine"))
    |> Enum.sort()
  end

  defp empty_run_context do
    empty_run_context("openrouter-paid-provider")
  end

  defp empty_run_context(agent_id) do
    %{
      run_id: "paid-openrouter-test",
      agent_id: agent_id,
      parent_agent_id: nil,
      attempt: 1,
      results: %{},
      artifacts: %{}
    }
  end

  defp drain_openrouter_stream_events(acc) do
    receive do
      {:openrouter_stream_event, event, received_ms} ->
        drain_openrouter_stream_events([{event, received_ms} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp first_delta_elapsed_ms([], _started_ms), do: nil

  defp first_delta_elapsed_ms([{_event, received_ms} | _events], started_ms) do
    received_ms - started_ms
  end

  defp stream_status({:ok, _payload}), do: "ok"
  defp stream_status({:error, reason}), do: "error:#{inspect(reason)}"

  defp event_with?(events, key, value) do
    Enum.any?(events, &(Map.get(&1, key) == value))
  end

  defp mcp_config_file!(script) do
    path =
      Path.join(
        System.tmp_dir!(),
        "agent-machine-paid-openrouter-#{System.unique_integer([:positive])}.mcp.json"
      )

    File.write!(
      path,
      JSON.encode!(%{
        "servers" => [
          %{
            "id" => "paid",
            "transport" => "stdio",
            "command" => script,
            "args" => [],
            "env" => %{},
            "tools" => [
              %{
                "name" => "lookup",
                "permission" => "mcp_paid_lookup",
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

  defp playwright_mcp_config_file!(script) do
    path =
      Path.join(
        System.tmp_dir!(),
        "agent-machine-paid-fake-playwright-mcp-#{System.unique_integer([:positive])}.json"
      )

    File.write!(
      path,
      JSON.encode!(%{
        "servers" => [
          %{
            "id" => "playwright",
            "transport" => "stdio",
            "command" => script,
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
    )

    path
  end

  defp playwright_mcp_config_file! do
    path =
      Path.join(
        System.tmp_dir!(),
        "agent-machine-paid-playwright-mcp-#{System.unique_integer([:positive])}.json"
      )

    cache_dir =
      Path.join(
        System.tmp_dir!(),
        "agent-machine-playwright-npm-cache-#{System.unique_integer([:positive])}"
      )

    File.write!(
      path,
      JSON.encode!(%{
        "servers" => [
          %{
            "id" => "playwright",
            "transport" => "stdio",
            "command" => "npx",
            "args" => ["--yes", "--cache", cache_dir, "@playwright/mcp@latest", "--headless"],
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
    )

    path
  end

  defp marker_page_url!(marker) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)

    task =
      Task.async(fn ->
        serve_marker_page(listener, marker)
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      Task.shutdown(task, :brutal_kill)
    end)

    "http://127.0.0.1:#{port}/"
  end

  defp serve_marker_page(listener, marker) do
    case :gen_tcp.accept(listener, 240_000) do
      {:ok, socket} ->
        _request = :gen_tcp.recv(socket, 0, 1_000)

        body =
          "<!doctype html><html><head><title>AgentMachine MCP</title></head><body><main><h1>#{marker}</h1></main></body></html>"

        response =
          "HTTP/1.1 200 OK\r\ncontent-type: text/html\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"

        :ok = :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        serve_marker_page(listener, marker)

      {:error, _reason} ->
        :ok
    end
  end

  defp fake_mcp_stdio_server!(marker) do
    path =
      Path.join(
        System.tmp_dir!(),
        "agent-machine-paid-mcp-#{System.unique_integer([:positive])}.sh"
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
          printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"lookup","inputSchema":{"type":"object"}}]}}\\n' "$id"
          ;;
        *'"method":"tools/call"'*)
          printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"%s"}],"structuredContent":{"marker":"%s"}}}\\n' "$id" "#{marker}" "#{marker}"
          ;;
      esac
    done
    """

    File.write!(path, script)
    File.chmod!(path, 0o700)
    path
  end

  defp fake_playwright_mcp_stdio_server!(marker) do
    path =
      Path.join(
        System.tmp_dir!(),
        "agent-machine-paid-fake-playwright-#{System.unique_integer([:positive])}.sh"
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
          printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"browser_navigate","inputSchema":{"type":"object"}},{"name":"browser_snapshot","inputSchema":{"type":"object"}}]}}\\n' "$id"
          ;;
        *'"method":"tools/call"'*'"name":"browser_navigate"'*)
          printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"navigated to Google news search for Poland"}],"structuredContent":{"status":"navigated"}}}\\n' "$id"
          ;;
        *'"method":"tools/call"'*'"name":"browser_snapshot"'*)
          printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"Google results snapshot. Latest Poland headline marker: %s"}],"structuredContent":{"marker":"%s","headline":"Latest Poland headline marker: %s"}}}\\n' "$id" "#{marker}" "#{marker}" "#{marker}"
          ;;
      esac
    done
    """

    File.write!(path, script)
    File.chmod!(path, 0o700)
    path
  end
end
