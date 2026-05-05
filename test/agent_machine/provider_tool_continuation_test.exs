defmodule AgentMachine.ProviderToolContinuationTest do
  use ExUnit.Case, async: false

  alias AgentMachine.Agent
  alias AgentMachine.Providers.ReqLLM, as: ReqLLMProvider

  defmodule FakeReqLLMClient do
    def generate_text(model, context, opts) do
      send(self(), {:req_llm_generate_text, model, context, opts})

      {:ok,
       %ReqLLM.Response{
         id: "resp-1",
         model: inspect(model),
         context: context,
         usage: %{input_tokens: 3, output_tokens: 2, total_tokens: 5},
         finish_reason: :tool_calls
       }}
    end

    def stream_text(model, context, opts) do
      send(self(), {:req_llm_stream_text, model, context, opts})
      {:ok, %{model: model, context: context}}
    end

    def process_stream(stream_response, opts) do
      Keyword.fetch!(opts, :on_result).("hel")
      Keyword.fetch!(opts, :on_result).("lo")

      {:ok,
       %ReqLLM.Response{
         id: "resp-stream",
         model: inspect(stream_response.model),
         context: stream_response.context,
         usage: %{input_tokens: 4, output_tokens: 2, total_tokens: 6},
         finish_reason: :stop
       }}
    end

    def classify_response(%ReqLLM.Response{id: "resp-1"}) do
      %{
        text: "",
        tool_calls: [%{id: "call-1", name: "now", arguments: %{}}],
        finish_reason: :tool_calls
      }
    end

    def classify_response(%ReqLLM.Response{id: "resp-stream"}) do
      %{
        text: "",
        tool_calls: [],
        finish_reason: :stop
      }
    end
  end

  setup do
    original_openrouter = System.get_env("OPENROUTER_API_KEY")
    System.put_env("OPENROUTER_API_KEY", "test-openrouter-key")

    on_exit(fn ->
      restore_env("OPENROUTER_API_KEY", original_openrouter)
    end)

    :ok
  end

  test "ReqLLM completion maps normalized tool calls without executing callbacks" do
    assert {:ok, payload} =
             ReqLLMProvider.complete(
               agent(),
               Keyword.merge(
                 [
                   req_llm_client: FakeReqLLMClient,
                   http_timeout_ms: 1_000,
                   allowed_tools: [AgentMachine.Tools.Now],
                   run_context: run_context(),
                   runtime_facts: false
                 ],
                 time_tool_opts()
               )
             )

    assert_receive {:req_llm_generate_text, "openrouter:test-model", context, opts}
    assert %ReqLLM.Context{} = context
    assert Keyword.fetch!(opts, :api_key) == "test-openrouter-key"
    assert Keyword.fetch!(opts, :receive_timeout) == 1_000
    refute Keyword.has_key?(opts, :stream_receive_timeout)
    refute Keyword.has_key?(opts, :metadata_timeout)
    refute Keyword.has_key?(opts, :response_format)
    assert [%ReqLLM.Tool{name: "now"} = req_llm_tool] = Keyword.fetch!(opts, :tools)

    assert {:error, "AgentMachine executes tools outside ReqLLM"} =
             ReqLLM.Tool.execute(req_llm_tool, %{})

    assert payload.output == "requested 1 ReqLLM tool call(s)"
    assert payload.tool_calls == [%{id: "call-1", tool: AgentMachine.Tools.Now, input: %{}}]
    assert payload.usage == %{input_tokens: 3, output_tokens: 2, total_tokens: 5}
    assert %{context: ^context, calls_by_id: %{"call-1" => "now"}} = payload.tool_state
  end

  test "ReqLLM continuation appends tool result messages and resends schemas" do
    state = %{
      context:
        ReqLLM.Context.new([
          ReqLLM.Context.system("Use tools when needed."),
          ReqLLM.Context.user("what time is it?")
        ]),
      calls_by_id: %{"call-1" => "now"}
    }

    context =
      ReqLLMProvider.context_for_test!(agent(),
        tool_continuation: %{
          state: state,
          results: [%{id: "call-1", result: %{ok: true}}]
        }
      )

    assert %ReqLLM.Message{role: :tool, name: "now", tool_call_id: "call-1"} =
             context.messages |> List.last()

    assert [%ReqLLM.Tool{name: "now"}] =
             ReqLLMProvider.request_opts_for_test!(agent(),
               http_timeout_ms: 1_000,
               allowed_tools: [AgentMachine.Tools.Now]
             )
             |> Keyword.fetch!(:tools)
  end

  test "ReqLLM budget request separates prompt, tools, and continuation context" do
    opts =
      [
        http_timeout_ms: 1_000,
        allowed_tools: [AgentMachine.Tools.Now],
        run_context: run_context(),
        runtime_facts: false
      ]
      |> Keyword.merge(time_tool_opts())

    assert {:ok, budget} = ReqLLMProvider.context_budget_request(agent(), opts)
    assert budget.provider == :req_llm
    assert budget.request.model == "\"openrouter:test-model\""
    assert budget.request.opts[:receive_timeout] == 1_000
    refute Keyword.has_key?(budget.request.opts, :stream_receive_timeout)
    refute Keyword.has_key?(budget.request.opts, :metadata_timeout)
    refute Keyword.has_key?(budget.request.opts, :response_format)
    refute Keyword.has_key?(budget.request.opts, :api_key)
    assert budget.breakdown.instructions == "Use tools when needed."
    assert budget.breakdown.task_input == "write a file"
    assert budget.breakdown.run_context =~ "plan output"
    assert [%{"name" => "now"}] = budget.breakdown.tools
    assert budget.breakdown.mcp_tools == []
  end

  test "ReqLLM streaming emits assistant deltas and uses deltas when final text is empty" do
    parent = self()

    assert {:ok, payload} =
             ReqLLMProvider.stream_complete(agent(),
               req_llm_client: FakeReqLLMClient,
               http_timeout_ms: 1_000,
               run_context: run_context(),
               runtime_facts: false,
               stream_context: %{run_id: "run-provider-budget", agent_id: "assistant", attempt: 1},
               stream_event_sink: fn event -> send(parent, {:stream_event, event}) end
             )

    assert_receive {:req_llm_stream_text, "openrouter:test-model", %ReqLLM.Context{}, opts}
    assert Keyword.fetch!(opts, :api_key) == "test-openrouter-key"
    assert Keyword.fetch!(opts, :receive_timeout) == 1_000
    refute Keyword.has_key?(opts, :stream_receive_timeout)
    refute Keyword.has_key?(opts, :metadata_timeout)
    refute Keyword.has_key?(opts, :response_format)
    assert_receive {:stream_event, %{type: :assistant_delta, delta: "hel"}}
    assert_receive {:stream_event, %{type: :assistant_delta, delta: "lo"}}
    assert_receive {:stream_event, %{type: :assistant_done, run_id: "run-provider-budget"}}
    assert payload.output == "hello"
    assert payload.usage.total_tokens == 6
  end

  defp agent do
    Agent.new!(%{
      id: "assistant",
      provider: ReqLLMProvider,
      model: "openrouter:test-model",
      instructions: "Use tools when needed.",
      input: "write a file",
      pricing: %{input_per_million: 0.0, output_per_million: 0.0}
    })
  end

  defp run_context do
    %{
      run_id: "run-provider-budget",
      agent_id: "assistant",
      results: %{"planner" => %{status: :ok, output: "plan output"}},
      artifacts: %{plan: "artifact"}
    }
  end

  defp time_tool_opts do
    [
      tool_policy: AgentMachine.ToolHarness.builtin_policy!(:time),
      tool_approval_mode: :read_only,
      tool_timeout_ms: 1_000,
      tool_max_rounds: 2
    ]
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
