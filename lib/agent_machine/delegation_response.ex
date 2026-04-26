defmodule AgentMachine.DelegationResponse do
  @moduledoc false

  alias AgentMachine.{Agent, JSON}

  def normalize_payload!(%Agent{} = agent, payload) do
    if structured_delegation_response?(agent) do
      parsed = payload.output |> delegation_json_text!() |> JSON.decode!()
      require_object!(parsed)
      reject_unknown_keys!(parsed, ["decision", "output", "next_agents"], "delegation response")

      output = fetch_required_string!(parsed, "output")
      next_agents = fetch_required_next_agents!(parsed)
      normalized_next_agents = normalize_delegated_specs!(agent, next_agents)
      decision = parsed |> fetch_decision!() |> normalize_decision!(normalized_next_agents)

      payload
      |> Map.put(:output, output)
      |> Map.put(:decision, decision)
      |> Map.put(:next_agents, normalized_next_agents)
    else
      payload
    end
  end

  defp structured_delegation_response?(%Agent{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, :agent_machine_response) == "delegation" ||
      Map.get(metadata, "agent_machine_response") == "delegation"
  end

  defp structured_delegation_response?(_agent), do: false

  defp delegation_json_text!(output) when is_binary(output) do
    output
    |> String.trim()
    |> strip_markdown_json_fence()
  end

  defp delegation_json_text!(output) do
    raise ArgumentError,
          "agent_machine delegation response output must be a binary, got: #{inspect(output)}"
  end

  defp strip_markdown_json_fence("```json\n" <> rest), do: strip_closing_fence(rest)
  defp strip_markdown_json_fence("```\n" <> rest), do: strip_closing_fence(rest)
  defp strip_markdown_json_fence(text), do: text

  defp strip_closing_fence(text) do
    text
    |> String.trim()
    |> String.trim_trailing("```")
    |> String.trim()
  end

  defp require_object!(value) when is_map(value), do: :ok

  defp require_object!(_value) do
    raise ArgumentError, "agent_machine delegation response must be a JSON object"
  end

  defp reject_unknown_keys!(map, allowed_keys, label) do
    unknown_keys = map |> Map.keys() |> Enum.reject(&(&1 in allowed_keys))

    if unknown_keys != [] do
      raise ArgumentError, "#{label} contains unsupported key(s): #{inspect(unknown_keys)}"
    end
  end

  defp fetch_decision!(map) do
    case Map.fetch(map, "decision") do
      {:ok, value} when is_map(value) ->
        reject_unknown_keys!(value, ["mode", "reason"], "delegation response decision")
        value

      {:ok, value} ->
        raise ArgumentError,
              "agent_machine delegation response decision must be an object, got: #{inspect(value)}"

      :error ->
        raise ArgumentError,
              "agent_machine delegation response is missing required decision field"
    end
  end

  defp normalize_decision!(decision, next_agents) do
    mode = fetch_required_string!(decision, "mode")
    reason = fetch_required_string!(decision, "reason")
    delegated_agent_ids = Enum.map(next_agents, & &1.id)

    case {mode, delegated_agent_ids} do
      {"direct", []} ->
        %{mode: "direct", reason: reason, delegated_agent_ids: []}

      {"direct", ids} ->
        raise ArgumentError,
              "agent_machine delegation response direct decision must not include next_agents, got: #{inspect(ids)}"

      {"delegate", []} ->
        raise ArgumentError,
              "agent_machine delegation response delegate decision requires at least one next_agent"

      {"delegate", ids} ->
        %{mode: "delegate", reason: reason, delegated_agent_ids: ids}

      {other, _ids} ->
        raise ArgumentError,
              "agent_machine delegation response decision mode must be direct or delegate, got: #{inspect(other)}"
    end
  end

  defp fetch_required_string!(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 ->
        value

      {:ok, value} ->
        raise ArgumentError,
              "agent_machine delegation response #{key} must be a non-empty string, got: #{inspect(value)}"

      :error ->
        raise ArgumentError, "agent_machine delegation response is missing required #{key} field"
    end
  end

  defp fetch_required_next_agents!(map) do
    case Map.fetch(map, "next_agents") do
      {:ok, value} ->
        value

      :error ->
        raise ArgumentError,
              "agent_machine delegation response is missing required next_agents field"
    end
  end

  defp normalize_delegated_specs!(_agent, next_agents) when next_agents == [], do: []

  defp normalize_delegated_specs!(agent, next_agents) when is_list(next_agents) do
    Enum.map(next_agents, &normalize_delegated_spec!(agent, &1))
  end

  defp normalize_delegated_specs!(_agent, next_agents) do
    raise ArgumentError,
          "agent_machine delegation response next_agents must be a list, got: #{inspect(next_agents)}"
  end

  defp normalize_delegated_spec!(agent, spec) when is_map(spec) do
    allowed_keys = ["id", "input", "instructions", "metadata", "depends_on"]
    unknown_keys = spec |> Map.keys() |> Enum.reject(&(&1 in allowed_keys))

    if unknown_keys != [] do
      raise ArgumentError,
            "delegated worker spec contains unsupported key(s): #{inspect(unknown_keys)}"
    end

    %{
      id: fetch_required_string!(spec, "id"),
      provider: agent.provider,
      model: agent.model,
      input: fetch_required_string!(spec, "input"),
      pricing: agent.pricing,
      instructions: optional_string!(spec, "instructions"),
      metadata: optional_map!(spec, "metadata"),
      depends_on: optional_string_list!(spec, "depends_on")
    }
  end

  defp normalize_delegated_spec!(_agent, spec) do
    raise ArgumentError, "delegated worker spec must be a JSON object, got: #{inspect(spec)}"
  end

  defp optional_string!(map, key) do
    case Map.fetch(map, key) do
      :error ->
        nil

      {:ok, nil} ->
        nil

      {:ok, value} when is_binary(value) and byte_size(value) > 0 ->
        value

      {:ok, value} ->
        raise ArgumentError,
              "delegated worker #{key} must be a non-empty string, got: #{inspect(value)}"
    end
  end

  defp optional_map!(map, key) do
    case Map.fetch(map, key) do
      :error ->
        nil

      {:ok, nil} ->
        nil

      {:ok, value} when is_map(value) ->
        value

      {:ok, value} ->
        raise ArgumentError, "delegated worker #{key} must be an object, got: #{inspect(value)}"
    end
  end

  defp optional_string_list!(map, key) do
    case Map.fetch(map, key) do
      :error ->
        []

      {:ok, value} when is_list(value) ->
        validate_string_list!(value, key)
        value

      {:ok, value} ->
        raise ArgumentError,
              "delegated worker #{key} must be a list of strings, got: #{inspect(value)}"
    end
  end

  defp validate_string_list!(value, key) do
    if Enum.all?(value, &(is_binary(&1) and byte_size(&1) > 0)) do
      :ok
    else
      raise ArgumentError,
            "delegated worker #{key} must contain only non-empty strings, got: #{inspect(value)}"
    end
  end
end
