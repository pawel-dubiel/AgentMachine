defmodule AgentMachine.DelegatedAgentSpec do
  @moduledoc false

  alias AgentMachine.Agent

  def normalize_specs!(_agent, next_agents, _label) when next_agents == [], do: []

  def normalize_specs!(%Agent{} = agent, next_agents, label)
      when is_list(next_agents) and is_binary(label) do
    Enum.map(next_agents, &normalize_spec!(agent, &1, label))
  end

  def normalize_specs!(_agent, next_agents, label) when is_binary(label) do
    raise ArgumentError,
          "#{label} next_agents must be a list, got: #{inspect(next_agents)}"
  end

  defp normalize_spec!(%Agent{} = agent, spec, label) when is_map(spec) do
    allowed_keys = ["id", "input", "instructions", "metadata", "depends_on"]
    unknown_keys = spec |> Map.keys() |> Enum.reject(&(&1 in allowed_keys))

    if unknown_keys != [] do
      raise ArgumentError,
            "#{label} worker spec contains unsupported key(s): #{inspect(unknown_keys)}"
    end

    %{
      id: fetch_required_string!(spec, "id", label),
      provider: agent.provider,
      model: agent.model,
      input: fetch_required_string!(spec, "input", label),
      pricing: agent.pricing,
      instructions: worker_instructions!(agent, optional_string!(spec, "instructions", label)),
      metadata: optional_map!(spec, "metadata", label),
      depends_on: optional_string_list!(spec, "depends_on", label)
    }
  end

  defp normalize_spec!(_agent, spec, label) do
    raise ArgumentError, "#{label} worker spec must be a JSON object, got: #{inspect(spec)}"
  end

  def fetch_required_string!(map, key, label) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 ->
        value

      {:ok, value} ->
        raise ArgumentError,
              "#{label} #{key} must be a non-empty string, got: #{inspect(value)}"

      :error ->
        raise ArgumentError, "#{label} is missing required #{key} field"
    end
  end

  defp optional_string!(map, key, label) do
    case Map.fetch(map, key) do
      :error ->
        nil

      {:ok, nil} ->
        nil

      {:ok, value} when is_binary(value) and byte_size(value) > 0 ->
        value

      {:ok, value} ->
        raise ArgumentError,
              "#{label} worker #{key} must be a non-empty string, got: #{inspect(value)}"
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

  defp optional_map!(map, key, label) do
    case Map.fetch(map, key) do
      :error ->
        nil

      {:ok, nil} ->
        nil

      {:ok, value} when is_map(value) ->
        value

      {:ok, value} ->
        raise ArgumentError, "#{label} worker #{key} must be an object, got: #{inspect(value)}"
    end
  end

  defp optional_string_list!(map, key, label) do
    case Map.fetch(map, key) do
      :error ->
        []

      {:ok, value} when is_list(value) ->
        validate_string_list!(value, key, label)
        value

      {:ok, value} ->
        raise ArgumentError,
              "#{label} worker #{key} must be a list of strings, got: #{inspect(value)}"
    end
  end

  defp validate_string_list!(value, key, label) do
    if Enum.all?(value, &(is_binary(&1) and byte_size(&1) > 0)) do
      :ok
    else
      raise ArgumentError,
            "#{label} worker #{key} must contain only non-empty strings, got: #{inspect(value)}"
    end
  end
end
