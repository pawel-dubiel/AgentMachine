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

      {"swarm", ids} ->
        swarm = validate_swarm_agents!(next_agents)

        %{
          mode: "swarm",
          reason: reason,
          delegated_agent_ids: ids,
          variant_agent_ids: swarm.variant_agent_ids,
          evaluator_agent_id: swarm.evaluator_agent_id,
          swarm_id: swarm.swarm_id
        }

      {other, _ids} ->
        raise ArgumentError,
              "agent_machine delegation response decision mode must be direct, delegate, or swarm, got: #{inspect(other)}"
    end
  end

  defp validate_swarm_agents!(next_agents) do
    reject_duplicate_agent_ids!(next_agents)

    variants =
      Enum.filter(
        next_agents,
        &(metadata_string(&1.metadata, "agent_machine_role") == "swarm_variant")
      )

    evaluators =
      Enum.filter(
        next_agents,
        &(metadata_string(&1.metadata, "agent_machine_role") == "swarm_evaluator")
      )

    other_agents =
      Enum.reject(next_agents, fn agent ->
        metadata_string(agent.metadata, "agent_machine_role") in [
          "swarm_variant",
          "swarm_evaluator"
        ]
      end)

    cond do
      other_agents != [] ->
        raise ArgumentError,
              "agent_machine delegation response swarm decision only accepts variant and evaluator agents"

      length(variants) < 2 or length(variants) > 5 ->
        raise ArgumentError,
              "agent_machine delegation response swarm decision requires 2 to 5 variant agents"

      length(evaluators) != 1 ->
        raise ArgumentError,
              "agent_machine delegation response swarm decision requires exactly one evaluator agent"

      true ->
        validate_swarm_variants!(variants)
        evaluator = hd(evaluators)
        validate_swarm_evaluator!(evaluator, variants)

        swarm_ids =
          (variants ++ [evaluator])
          |> Enum.map(&metadata_string!(&1.metadata, "swarm_id", "swarm agent"))
          |> Enum.uniq()

        if length(swarm_ids) != 1 do
          raise ArgumentError,
                "agent_machine delegation response swarm agents must share one swarm_id"
        end

        %{
          swarm_id: hd(swarm_ids),
          variant_agent_ids: Enum.map(variants, & &1.id),
          evaluator_agent_id: evaluator.id
        }
    end
  end

  defp reject_duplicate_agent_ids!(agents) do
    duplicates =
      agents
      |> Enum.map(& &1.id)
      |> duplicates()

    if duplicates != [] do
      raise ArgumentError,
            "agent_machine delegation response swarm agent ids must be unique, duplicates: #{inspect(duplicates)}"
    end
  end

  defp validate_swarm_variants!(variants) do
    variant_ids =
      Enum.map(variants, fn agent ->
        metadata_string!(agent.metadata, "swarm_id", "swarm variant")
        variant_id = metadata_string!(agent.metadata, "variant_id", "swarm variant")
        workspace = metadata_string!(agent.metadata, "workspace", "swarm variant")
        validate_workspace!(workspace)

        if agent.depends_on != [] do
          raise ArgumentError,
                "agent_machine delegation response swarm variant agents must not depend on other agents"
        end

        variant_id
      end)

    case duplicates(variant_ids) do
      [] ->
        :ok

      duplicates ->
        raise ArgumentError,
              "agent_machine delegation response swarm variant_id values must be unique, duplicates: #{inspect(duplicates)}"
    end
  end

  defp validate_swarm_evaluator!(evaluator, variants) do
    metadata_string!(evaluator.metadata, "swarm_id", "swarm evaluator")
    variant_agent_ids = Enum.map(variants, & &1.id)

    if Enum.sort(evaluator.depends_on) != Enum.sort(variant_agent_ids) do
      raise ArgumentError,
            "agent_machine delegation response swarm evaluator must depend on all variant agents"
    end
  end

  defp metadata_string!(metadata, key, label) do
    case metadata_string(metadata, key) do
      value when is_binary(value) and byte_size(value) > 0 ->
        value

      _other ->
        raise ArgumentError,
              "agent_machine delegation response #{label} metadata #{key} must be a non-empty string"
    end
  end

  defp metadata_string(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(metadata, key)
  end

  defp metadata_string(_metadata, _key), do: nil

  defp validate_workspace!(workspace) do
    invalid? =
      Path.type(workspace) != :relative or
        workspace in [".", ".."] or
        Enum.any?(Path.split(workspace), &(&1 in ["..", ""]))

    if invalid? do
      raise ArgumentError,
            "agent_machine delegation response swarm variant workspace must be a relative path without parent traversal"
    end
  end

  defp duplicates(values) do
    values
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(fn {value, _count} -> value end)
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
      instructions: worker_instructions!(agent, optional_string!(spec, "instructions")),
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

  defp worker_instructions!(%Agent{metadata: metadata}, planner_instructions)
       when is_map(metadata) do
    case Map.get(metadata, :agent_machine_worker_instructions) ||
           Map.get(metadata, "agent_machine_worker_instructions") do
      nil ->
        planner_instructions

      runtime_instructions
      when is_binary(runtime_instructions) and byte_size(runtime_instructions) > 0 ->
        [runtime_instructions, planner_instructions]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n\n")

      invalid ->
        raise ArgumentError,
              "agent_machine_worker_instructions metadata must be a non-empty string, got: #{inspect(invalid)}"
    end
  end

  defp worker_instructions!(_agent, planner_instructions), do: planner_instructions

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
