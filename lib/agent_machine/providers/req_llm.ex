defmodule AgentMachine.Providers.ReqLLM do
  @moduledoc """
  ReqLLM-backed remote provider boundary.
  """

  @behaviour AgentMachine.Provider

  alias AgentMachine.{Agent, ProviderCatalog, RunContextPrompt, ToolHarness}

  @impl true
  def complete(%Agent{} = agent, opts) do
    client = req_llm_client!(opts)
    context = context(agent, opts)
    model = model_spec!(agent, opts)
    request_opts = request_opts!(agent, opts)

    with {:ok, response} <- client.generate_text(model, context, request_opts) do
      response_payload(agent, opts, response, client.classify_response(response))
    end
  end

  @impl true
  def stream_complete(%Agent{} = agent, opts) do
    client = req_llm_client!(opts)
    context = context(agent, opts)
    model = model_spec!(agent, opts)
    request_opts = request_opts!(agent, opts)
    {:ok, stream_collector} = Elixir.Agent.start_link(fn -> [] end)

    try do
      with {:ok, stream_response} <- client.stream_text(model, context, request_opts),
           {:ok, response} <-
             client.process_stream(stream_response,
               on_result: &handle_stream_result(opts, stream_collector, &1)
             ) do
        emit_done(opts)

        response_payload(
          agent,
          opts,
          response,
          client.classify_response(response),
          stream_text(stream_collector)
        )
      end
    after
      Elixir.Agent.stop(stream_collector)
    end
  end

  @impl true
  def context_budget_request(%Agent{} = agent, opts) do
    {:ok,
     %{
       provider: :req_llm,
       request: budget_request(agent, opts),
       breakdown: budget_breakdown(agent, opts)
     }}
  end

  if Mix.env() == :test do
    def context_for_test!(%Agent{} = agent, opts), do: context(agent, opts)
    def request_opts_for_test!(%Agent{} = agent, opts), do: request_opts!(agent, opts)
    def model_spec_for_test!(%Agent{} = agent, opts), do: model_spec!(agent, opts)
  end

  defp response_payload(_agent, opts, response, classification, stream_text \\ nil)

  defp response_payload(%Agent{} = _agent, opts, response, classification, stream_text)
       when is_map(classification) do
    tool_calls = ToolHarness.req_llm_tool_calls!(Map.get(classification, :tool_calls, []), opts)
    output = output_text!(classification, response, tool_calls, stream_text)

    {:ok,
     %{
       output: output,
       tool_calls: tool_calls,
       tool_state: tool_state(response, classification),
       usage: usage!(response)
     }}
  end

  defp output_text!(classification, response, tool_calls, stream_text) do
    text =
      [
        Map.get(classification, :text),
        Map.get(classification, "text"),
        ReqLLM.Response.text(response),
        stream_text
      ]
      |> Enum.find(&present_text?/1)

    cond do
      is_binary(text) ->
        text

      tool_calls != [] ->
        "requested #{length(tool_calls)} ReqLLM tool call(s)"

      true ->
        raise ArgumentError, "ReqLLM response did not contain output text"
    end
  end

  defp present_text?(text), do: is_binary(text) and String.trim(text) != ""

  defp tool_state(_response, []), do: nil

  defp tool_state(response, classification) do
    calls_by_id =
      classification
      |> Map.get(:tool_calls, [])
      |> Map.new(fn call ->
        id = Map.get(call, :id) || Map.get(call, "id")
        name = Map.get(call, :name) || Map.get(call, "name")
        {id, name}
      end)

    %{context: Map.fetch!(response, :context), calls_by_id: calls_by_id}
  end

  defp usage!(response) do
    usage =
      case ReqLLM.Response.usage(response) do
        usage when is_map(usage) -> usage
        nil -> %{}
      end

    %{
      input_tokens: usage_value(usage, :input_tokens),
      output_tokens: usage_value(usage, :output_tokens),
      total_tokens: usage_value(usage, :total_tokens)
    }
  end

  defp usage_value(usage, field) do
    value = Map.get(usage, field) || Map.get(usage, Atom.to_string(field)) || 0

    if is_integer(value) and value >= 0 do
      value
    else
      raise ArgumentError,
            "ReqLLM usage #{inspect(field)} must be a non-negative integer, got: #{inspect(value)}"
    end
  end

  defp context(%Agent{} = agent, opts) do
    case Keyword.fetch(opts, :tool_continuation) do
      {:ok, continuation} -> continuation_context!(continuation)
      :error -> initial_context(agent, opts)
    end
  end

  defp initial_context(%Agent{instructions: nil} = agent, opts) do
    ReqLLM.Context.new([ReqLLM.Context.user(input(agent, opts))])
  end

  defp initial_context(%Agent{instructions: instructions} = agent, opts) do
    ReqLLM.Context.new([
      ReqLLM.Context.system(instructions),
      ReqLLM.Context.user(input(agent, opts))
    ])
  end

  defp continuation_context!(%{
         state: %{context: context, calls_by_id: calls_by_id},
         results: results
       })
       when is_map(calls_by_id) and is_list(results) do
    Enum.reduce(results, context, fn result, acc ->
      ReqLLM.Context.append(acc, tool_result_message!(result, calls_by_id))
    end)
  end

  defp continuation_context!(continuation) do
    raise ArgumentError, "invalid ReqLLM tool continuation: #{inspect(continuation)}"
  end

  defp tool_result_message!(%{id: id, result: result}, calls_by_id)
       when is_binary(id) and is_map(result) do
    name = Map.get(calls_by_id, id)

    if is_binary(name) and name != "" do
      ReqLLM.Context.tool_result(id, name, result)
    else
      ReqLLM.Context.tool_result(id, result)
    end
  end

  defp tool_result_message!(result, _calls_by_id) do
    raise ArgumentError, "invalid ReqLLM tool result: #{inspect(result)}"
  end

  defp input(agent, opts) do
    case RunContextPrompt.text(opts) do
      "" -> agent.input
      context -> agent.input <> "\n\nRun context:\n" <> context
    end
  end

  defp model_spec!(%Agent{} = agent, opts) do
    provider_id = provider_id!(agent)
    provider_options = provider_options!(agent, opts)
    ProviderCatalog.model_spec!(provider_id, remote_model!(agent), provider_options)
  end

  defp request_opts!(%Agent{} = agent, opts) do
    provider_id = provider_id!(agent)
    provider_options = provider_options!(agent, opts)

    [
      receive_timeout: Keyword.fetch!(opts, :http_timeout_ms),
      tools: ToolHarness.req_llm_tools!(opts)
    ]
    |> Keyword.merge(ProviderCatalog.runtime_options!(provider_id, provider_options))
    |> reject_empty_tools()
  end

  defp reject_empty_tools(opts) do
    case Keyword.fetch(opts, :tools) do
      {:ok, []} -> Keyword.delete(opts, :tools)
      _other -> opts
    end
  end

  defp provider_id!(%Agent{metadata: metadata, model: model}) when is_map(metadata) do
    value =
      Map.get(metadata, :agent_machine_provider_id) ||
        Map.get(metadata, "agent_machine_provider_id")

    if is_binary(value) and String.trim(value) != "" do
      String.trim(value)
    else
      provider_id_from_model!(model)
    end
  end

  defp provider_id!(%Agent{} = agent), do: provider_id_from_model!(agent.model)

  defp remote_model!(%Agent{metadata: metadata, model: model}) when is_map(metadata) do
    Map.get(metadata, :agent_machine_remote_model) ||
      Map.get(metadata, "agent_machine_remote_model") ||
      remote_model_from_model!(model)
  end

  defp remote_model!(%Agent{model: model}), do: remote_model_from_model!(model)

  defp provider_id_from_model!(model) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [provider_id, _remote_model] when provider_id != "" ->
        ProviderCatalog.fetch!(provider_id)
        provider_id

      _other ->
        raise ArgumentError,
              "ReqLLM agent model must be provider-qualified as provider:model, got: #{inspect(model)}"
    end
  end

  defp provider_id_from_model!(model) do
    raise ArgumentError,
          "ReqLLM agent model must be provider-qualified as provider:model, got: #{inspect(model)}"
  end

  defp remote_model_from_model!(model) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [_provider_id, remote_model] when remote_model != "" -> remote_model
      _other -> model
    end
  end

  defp provider_options!(%Agent{metadata: metadata}, opts) do
    provider_options =
      Map.get(metadata || %{}, :agent_machine_provider_options) ||
        Map.get(metadata || %{}, "agent_machine_provider_options") ||
        Keyword.get(opts, :provider_options, %{})

    if is_map(provider_options) do
      provider_options
    else
      raise ArgumentError,
            "ReqLLM provider_options must be a map, got: #{inspect(provider_options)}"
    end
  end

  defp req_llm_client!(opts) do
    client = Keyword.get(opts, :req_llm_client, AgentMachine.ReqLLMClient)

    unless Code.ensure_loaded?(client) and function_exported?(client, :generate_text, 3) do
      raise ArgumentError, ":req_llm_client must export generate_text/3, got: #{inspect(client)}"
    end

    client
  end

  defp budget_request(agent, opts) do
    %{
      model: inspect(model_spec!(agent, opts)),
      context: context(agent, opts),
      opts:
        request_opts!(agent, opts)
        |> Keyword.drop([:api_key, :access_key_id, :secret_access_key, :access_token, :tools])
    }
  end

  defp budget_breakdown(%Agent{} = agent, opts) do
    case Keyword.fetch(opts, :tool_continuation) do
      {:ok, _continuation} ->
        %{
          instructions: nil,
          task_input: nil,
          run_context: nil,
          skills: nil,
          tools: ToolHarness.req_llm_tool_groups!(opts).tools,
          mcp_tools: ToolHarness.req_llm_tool_groups!(opts).mcp_tools,
          tool_continuation: context(agent, opts)
        }

      :error ->
        sections = RunContextPrompt.budget_sections(opts)
        tool_groups = ToolHarness.req_llm_tool_groups!(opts)

        %{
          instructions: agent.instructions,
          task_input: agent.input,
          run_context: sections.run_context,
          skills: sections.skills,
          tools: tool_groups.tools,
          mcp_tools: tool_groups.mcp_tools,
          tool_continuation: nil
        }
    end
  end

  defp handle_stream_result(opts, stream_collector, delta) do
    collect_stream_delta(stream_collector, delta)
    emit_delta(opts, delta)
  end

  defp collect_stream_delta(stream_collector, delta) when is_binary(delta) and delta != "" do
    Elixir.Agent.update(stream_collector, fn deltas -> [delta | deltas] end)
  end

  defp collect_stream_delta(_stream_collector, _delta), do: :ok

  defp stream_text(stream_collector) do
    stream_collector
    |> Elixir.Agent.get(& &1)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp emit_delta(opts, delta) when is_binary(delta) and delta != "" do
    context = Keyword.fetch!(opts, :stream_context)
    sink = Keyword.fetch!(opts, :stream_event_sink)

    sink.(%{
      type: :assistant_delta,
      run_id: context.run_id,
      agent_id: context.agent_id,
      attempt: context.attempt,
      delta: delta,
      at: DateTime.utc_now()
    })
  end

  defp emit_delta(_opts, _delta), do: :ok

  defp emit_done(opts) do
    context = Keyword.fetch!(opts, :stream_context)
    sink = Keyword.fetch!(opts, :stream_event_sink)

    sink.(%{
      type: :assistant_done,
      run_id: context.run_id,
      agent_id: context.agent_id,
      attempt: context.attempt,
      at: DateTime.utc_now()
    })
  end
end
