defmodule AgentMachine.ContextBudget do
  @moduledoc false

  alias AgentMachine.{Agent, JSON}
  alias Tokenizers.{Encoding, Tokenizer}

  @missing_tokenizer "missing_context_tokenizer_path"
  @missing_window "missing_context_window_tokens"
  @missing_reserved "missing_reserved_output_tokens"

  def event(%Agent{} = agent, context, opts) when is_map(context) and is_list(opts) do
    agent
    |> measure(opts)
    |> event_from_measurement(agent, context, opts)
  end

  def measure(%Agent{} = agent, opts) when is_list(opts) do
    provider_request =
      if function_exported?(agent.provider, :context_budget_request, 2) do
        agent.provider.context_budget_request(agent, opts)
      else
        {:unknown, "provider_context_budget_not_supported"}
      end

    case provider_request do
      {:ok, %{provider: provider, request: request, breakdown: breakdown}}
      when is_atom(provider) and is_map(request) and is_map(breakdown) ->
        measure_request(agent, opts, provider, request, breakdown)

      {:unknown, reason} when is_binary(reason) and byte_size(reason) > 0 ->
        unknown_measurement(agent, opts, reason)

      other ->
        raise ArgumentError,
              "provider context_budget_request/2 must return {:ok, %{provider: atom, request: map, breakdown: map}} or {:unknown, reason}, got: #{inspect(other)}"
    end
  end

  def threshold_reached?(%{status: status, used_percent: used_percent}, percent)
      when status in ["ok", "warning"] and is_number(used_percent) and is_integer(percent) and
             percent >= 1 and percent <= 100 do
    used_percent >= percent
  end

  def threshold_reached?(%{status: "unknown"}, percent)
      when is_integer(percent) and percent >= 1 and percent <= 100,
      do: false

  def threshold_reached?(measurement, percent) do
    raise ArgumentError,
          "context threshold requires a context budget measurement and percent 1..100, got: #{inspect({measurement, percent})}"
  end

  def validate_tokenizer_path!(nil), do: nil

  def validate_tokenizer_path!(path) when is_binary(path) and byte_size(path) > 0 do
    expanded = Path.expand(path)
    require_file!(expanded)

    case Tokenizer.from_file(expanded) do
      {:ok, _tokenizer} ->
        expanded

      {:error, reason} ->
        raise ArgumentError, "failed to load context tokenizer #{expanded}: #{inspect(reason)}"
    end
  end

  def validate_tokenizer_path!(path) do
    raise ArgumentError,
          ":context_tokenizer_path must be a non-empty binary when supplied, got: #{inspect(path)}"
  end

  defp measure_request(%Agent{} = agent, opts, provider, request, breakdown) do
    case Keyword.get(opts, :context_tokenizer_path) do
      nil ->
        unknown_measurement(agent, opts, @missing_tokenizer)

      path ->
        tokenizer = tokenizer!(path)
        request_tokens = count_value!(tokenizer, request)
        component_tokens = count_breakdown!(tokenizer, breakdown)
        component_total = component_tokens |> Map.values() |> Enum.sum()

        component_tokens =
          Map.put(
            component_tokens,
            :provider_overhead_estimate,
            max(request_tokens - component_total, 0)
          )

        known_or_window_unknown(agent, opts, provider, request_tokens, component_tokens)
    end
  end

  defp known_or_window_unknown(%Agent{} = agent, opts, provider, used_tokens, breakdown) do
    measurement = %{
      measurement: "tokenizer_estimate",
      status: "unknown",
      provider: provider,
      agent_id: agent.id,
      model: agent.model,
      used_tokens: used_tokens,
      breakdown: breakdown
    }

    case context_window_tokens!(opts) do
      nil ->
        Map.put(measurement, :reason, @missing_window)

      context_window_tokens ->
        used_percent = percent(used_tokens, context_window_tokens)
        warning_percent = Keyword.get(opts, :context_warning_percent)

        measurement
        |> Map.merge(%{
          status: status(used_percent, warning_percent),
          context_window_tokens: context_window_tokens,
          used_percent: used_percent,
          remaining_percent: max(0.0, Float.round(100.0 - used_percent, 1))
        })
        |> maybe_put_warning_percent(warning_percent)
        |> maybe_put_reserved_output(opts)
    end
  end

  defp unknown_measurement(%Agent{} = agent, opts, reason) do
    %{
      measurement: "unknown",
      status: "unknown",
      agent_id: agent.id,
      model: agent.model,
      reason: reason
    }
    |> maybe_put_context_window(opts)
    |> maybe_put_reserved_output_value(opts)
  end

  defp event_from_measurement(measurement, %Agent{} = agent, context, opts) do
    measurement
    |> Map.merge(%{
      type: :context_budget,
      run_id: Map.fetch!(context, :run_id),
      agent_id: agent.id,
      attempt: Map.fetch!(context, :attempt),
      model: agent.model,
      at: DateTime.utc_now()
    })
    |> maybe_put_provider(agent)
    |> maybe_put_context_window(opts)
    |> maybe_put_reserved_output_value(opts)
  end

  defp maybe_put_provider(event, %Agent{provider: provider}) do
    Map.put_new(event, :provider, provider |> Module.split() |> List.last())
  end

  defp maybe_put_reserved_output(event, opts) do
    case reserved_output_tokens!(opts) do
      nil ->
        Map.put(event, :reason, @missing_reserved)

      reserved_output_tokens ->
        context_window_tokens = Map.fetch!(event, :context_window_tokens)
        used_tokens = Map.fetch!(event, :used_tokens)

        event
        |> Map.put(:reserved_output_tokens, reserved_output_tokens)
        |> Map.put(
          :available_tokens,
          max(context_window_tokens - used_tokens - reserved_output_tokens, 0)
        )
    end
  end

  defp maybe_put_context_window(event, opts) do
    case context_window_tokens!(opts) do
      nil -> event
      tokens -> Map.put(event, :context_window_tokens, tokens)
    end
  end

  defp maybe_put_reserved_output_value(event, opts) do
    case reserved_output_tokens!(opts) do
      nil -> event
      tokens -> Map.put(event, :reserved_output_tokens, tokens)
    end
  end

  defp context_window_tokens!(opts) do
    case Keyword.get(opts, :context_window_tokens) do
      nil ->
        nil

      tokens when is_integer(tokens) and tokens > 0 ->
        tokens

      other ->
        raise ArgumentError,
              ":context_window_tokens must be a positive integer when supplied, got: #{inspect(other)}"
    end
  end

  defp reserved_output_tokens!(opts) do
    case Keyword.get(opts, :reserved_output_tokens) do
      nil ->
        nil

      tokens when is_integer(tokens) and tokens > 0 ->
        tokens

      other ->
        raise ArgumentError,
              ":reserved_output_tokens must be a positive integer when supplied, got: #{inspect(other)}"
    end
  end

  defp status(_used_percent, nil), do: "ok"

  defp status(used_percent, warning_percent)
       when is_integer(warning_percent) and warning_percent >= 1 and warning_percent <= 100 do
    if used_percent >= warning_percent, do: "warning", else: "ok"
  end

  defp status(_used_percent, warning_percent) do
    raise ArgumentError,
          ":context_warning_percent must be an integer between 1 and 100, got: #{inspect(warning_percent)}"
  end

  defp maybe_put_warning_percent(event, nil), do: event

  defp maybe_put_warning_percent(event, warning_percent),
    do: Map.put(event, :warning_percent, warning_percent)

  defp count_breakdown!(tokenizer, breakdown) do
    Map.new(breakdown, fn {key, value} ->
      {normalize_key!(key), count_value!(tokenizer, value)}
    end)
  end

  defp count_value!(_tokenizer, nil), do: 0
  defp count_value!(_tokenizer, ""), do: 0
  defp count_value!(_tokenizer, []), do: 0
  defp count_value!(_tokenizer, %{} = map) when map_size(map) == 0, do: 0

  defp count_value!(tokenizer, value) do
    serialized = JSON.encode!(value)

    case Tokenizer.encode(tokenizer, serialized) do
      {:ok, encoding} ->
        encoding |> Encoding.get_ids() |> length()

      {:error, reason} ->
        raise ArgumentError, "failed to tokenize context budget component: #{inspect(reason)}"
    end
  end

  defp tokenizer!(path) do
    expanded = validate_tokenizer_path!(path)
    key = {__MODULE__, :tokenizer, expanded}

    case :persistent_term.get(key, :missing) do
      :missing ->
        tokenizer =
          case Tokenizer.from_file(expanded) do
            {:ok, tokenizer} ->
              tokenizer

            {:error, reason} ->
              raise ArgumentError,
                    "failed to load context tokenizer #{expanded}: #{inspect(reason)}"
          end

        :persistent_term.put(key, tokenizer)
        tokenizer

      tokenizer ->
        tokenizer
    end
  end

  defp require_file!(path) do
    unless File.regular?(path) do
      raise ArgumentError, "context tokenizer file does not exist: #{path}"
    end
  end

  defp percent(tokens, context_window_tokens) do
    tokens
    |> Kernel.*(100)
    |> Kernel./(context_window_tokens)
    |> Float.round(1)
  end

  defp normalize_key!(key) when is_atom(key), do: key
  defp normalize_key!(key) when is_binary(key), do: key

  defp normalize_key!(key) do
    raise ArgumentError,
          "context budget breakdown keys must be atoms or strings, got: #{inspect(key)}"
  end
end
