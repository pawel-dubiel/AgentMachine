defmodule AgentMachine.ContextCompactor do
  @moduledoc false

  alias AgentMachine.{Agent, JSON, Usage}

  @compactor_id "__context_compactor__"
  @conversation_roles MapSet.new(["user", "assistant", "summary"])

  def compact_conversation!(messages, opts) when is_list(messages) and is_list(opts) do
    messages = validate_messages!(messages)

    payload = %{
      type: "conversation",
      messages: messages
    }

    compact!(conversation_agent!(opts), payload, opts, covered_item_limit(messages))
  end

  def compact_run_context!(run_context, %Agent{} = source_agent, opts)
      when is_map(run_context) and is_list(opts) do
    results = fetch_map!(run_context, :results)
    artifacts = fetch_map!(run_context, :artifacts)
    compacted_context = Map.get(run_context, :compacted_context)
    allowed_covered_items = Keyword.fetch!(opts, :allowed_covered_items)

    if allowed_covered_items == [] do
      raise ArgumentError, "run context compaction requires at least one uncovered result"
    end

    payload =
      %{
        type: "run_context",
        results: results,
        artifacts: artifacts
      }
      |> maybe_put_compacted_context(compacted_context)

    source_agent
    |> compaction_agent_from_source()
    |> compact!(payload, opts, MapSet.new(allowed_covered_items))
  end

  def usage_summary(%Usage{} = usage) do
    %{
      agent_id: usage.agent_id,
      provider: Atom.to_string(usage.provider),
      model: usage.model,
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      total_tokens: usage.total_tokens,
      cost_usd: usage.cost_usd,
      recorded_at: DateTime.to_iso8601(usage.recorded_at)
    }
  end

  defp compact!(%Agent{} = agent, payload, opts, allowed_covered_items) do
    provider_opts = provider_opts(agent.provider, opts)

    case agent.provider.complete(agent_with_input(agent, payload), provider_opts) do
      {:ok, %{output: output, usage: provider_usage}} when is_binary(output) ->
        parsed = parse_compaction_output!(output, allowed_covered_items)

        usage =
          Usage.from_provider!(
            agent,
            Keyword.get(opts, :run_id, "context-compaction"),
            provider_usage
          )

        parsed
        |> Map.put(:usage, usage)
        |> Map.put(:usage_summary, usage_summary(usage))

      {:ok, payload} ->
        raise ArgumentError, "compaction provider returned invalid payload: #{inspect(payload)}"

      {:error, reason} ->
        raise ArgumentError, "compaction provider failed: #{inspect(reason)}"
    end
  end

  defp agent_with_input(%Agent{} = agent, payload) do
    input = JSON.encode!(payload)

    %Agent{
      agent
      | input: input,
        instructions: compaction_instructions(Map.fetch!(payload, :type)),
        metadata: Map.put(agent.metadata || %{}, :agent_machine_response, "compaction")
    }
  end

  defp conversation_agent!(opts) do
    provider = provider_module!(Keyword.fetch!(opts, :provider))
    provider_id = Keyword.fetch!(opts, :provider)
    model = model!(provider_id, Keyword.fetch!(opts, :model))
    pricing = Keyword.fetch!(opts, :pricing)

    Agent.new!(%{
      id: @compactor_id,
      provider: provider,
      model: model,
      input: "placeholder",
      pricing: pricing
    })
  end

  defp compaction_agent_from_source(%Agent{} = source_agent) do
    Agent.new!(%{
      id: @compactor_id,
      provider: source_agent.provider,
      model: source_agent.model,
      input: "placeholder",
      pricing: source_agent.pricing
    })
  end

  defp provider_opts(provider, opts) do
    [
      run_context: %{results: %{}, artifacts: %{}},
      runtime_facts: false
    ]
    |> maybe_put_http_timeout(provider, opts)
    |> maybe_put_provider_options(provider, opts)
  end

  defp maybe_put_http_timeout(opts, AgentMachine.Providers.ReqLLM, source_opts) do
    Keyword.put(opts, :http_timeout_ms, Keyword.fetch!(source_opts, :http_timeout_ms))
  end

  defp maybe_put_http_timeout(opts, _provider, _source_opts), do: opts

  defp maybe_put_provider_options(opts, AgentMachine.Providers.ReqLLM, source_opts) do
    Keyword.put(opts, :provider_options, Keyword.get(source_opts, :provider_options, %{}))
  end

  defp maybe_put_provider_options(opts, _provider, _source_opts), do: opts

  defp compaction_instructions("conversation") do
    """
    Summarize the conversation for future context.
    Return only strict JSON with this exact shape:
    {"summary":"non-empty compact summary","covered_items":["1","2"]}
    Include durable user goals, decisions, constraints, unresolved questions, and important facts.
    Do not include markdown fences or explanatory text outside the JSON object.
    """
    |> String.trim()
  end

  defp compaction_instructions("run_context") do
    """
    Summarize the run context for future worker/finalizer agents.
    Return only strict JSON with this exact shape:
    {"summary":"non-empty compact summary","covered_items":["agent-id"]}
    Preserve completed work, decisions, tool-confirmed side effects, failures, artifacts, and unresolved constraints.
    Do not include markdown fences or explanatory text outside the JSON object.
    """
    |> String.trim()
  end

  defp parse_compaction_output!(output, allowed_covered_items) do
    decoded =
      case JSON.decode!(String.trim(output)) do
        map when is_map(map) ->
          map

        other ->
          raise ArgumentError, "compaction output must be a JSON object, got: #{inspect(other)}"
      end

    summary = decoded |> Map.fetch!("summary") |> require_non_empty_binary!(:summary)
    covered_items = decoded |> Map.fetch!("covered_items") |> validate_covered_items!()

    validate_allowed_covered_items!(covered_items, allowed_covered_items)

    %{
      summary: summary,
      covered_items: covered_items
    }
  rescue
    exception in [Jason.DecodeError, KeyError, ArgumentError] ->
      reraise ArgumentError,
              [message: "invalid compaction output: #{Exception.message(exception)}"],
              __STACKTRACE__
  end

  defp validate_covered_items!(items) when is_list(items) do
    Enum.map(items, &require_non_empty_binary!(&1, :covered_items))
  end

  defp validate_covered_items!(items) do
    raise ArgumentError, "compaction covered_items must be a list, got: #{inspect(items)}"
  end

  defp validate_allowed_covered_items!(items, %MapSet{} = allowed) do
    unknown = Enum.reject(items, &MapSet.member?(allowed, &1))

    cond do
      items == [] ->
        raise ArgumentError, "compaction covered_items must not be empty"

      unknown != [] ->
        raise ArgumentError,
              "compaction covered_items contain unknown item(s): #{inspect(unknown)}"

      true ->
        :ok
    end
  end

  defp validate_messages!([]),
    do: raise(ArgumentError, "conversation compaction requires messages")

  defp validate_messages!(messages) do
    messages
    |> Enum.with_index(1)
    |> Enum.map(fn {message, index} -> validate_message!(message, index) end)
  end

  defp validate_message!(message, index) when is_map(message) do
    role = Map.get(message, :role) || Map.get(message, "role")
    text = Map.get(message, :text) || Map.get(message, "text")

    unless is_binary(role) and MapSet.member?(@conversation_roles, role) do
      raise ArgumentError,
            "conversation message #{index} role must be user, assistant, or summary, got: #{inspect(role)}"
    end

    %{
      role: role,
      text: require_non_empty_binary!(text, :text)
    }
  end

  defp validate_message!(message, index) do
    raise ArgumentError, "conversation message #{index} must be a map, got: #{inspect(message)}"
  end

  defp covered_item_limit(messages) do
    messages
    |> length()
    |> then(fn count -> 1..count end)
    |> Enum.map(&Integer.to_string/1)
    |> MapSet.new()
  end

  defp fetch_map!(map, key) do
    value = Map.get(map, key) || Map.get(map, Atom.to_string(key))

    if is_map(value) do
      value
    else
      raise ArgumentError, "run context #{inspect(key)} must be a map, got: #{inspect(value)}"
    end
  end

  defp maybe_put_compacted_context(payload, nil), do: payload

  defp maybe_put_compacted_context(payload, context) when is_map(context),
    do: Map.put(payload, :compacted_context, context)

  defp maybe_put_compacted_context(_payload, context) do
    raise ArgumentError,
          "run context :compacted_context must be a map or nil, got: #{inspect(context)}"
  end

  defp provider_module!(:echo), do: AgentMachine.Providers.Echo

  defp provider_module!(provider) when is_binary(provider) do
    AgentMachine.ProviderCatalog.fetch!(provider)
    AgentMachine.Providers.ReqLLM
  end

  defp provider_module!(provider) do
    raise ArgumentError, "unsupported compaction provider: #{inspect(provider)}"
  end

  defp model!(:echo, model), do: require_non_empty_binary!(model, :model)

  defp model!(provider, model) when is_binary(provider) do
    provider <> ":" <> require_non_empty_binary!(model, :model)
  end

  defp require_non_empty_binary!(value, _field) when is_binary(value) and byte_size(value) > 0,
    do: value

  defp require_non_empty_binary!(value, field) do
    raise ArgumentError, "#{inspect(field)} must be a non-empty binary, got: #{inspect(value)}"
  end
end
