defmodule AgentMachine.AgenticReviewResponse do
  @moduledoc false

  alias AgentMachine.{Agent, DelegatedAgentSpec, JSON}

  def applies?(%Agent{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, :agent_machine_response) == "agentic_review" ||
      Map.get(metadata, "agent_machine_response") == "agentic_review"
  end

  def applies?(_agent), do: false

  def normalize_payload!(%Agent{} = agent, payload) do
    parsed = payload.output |> review_json_text!() |> JSON.decode!()
    require_object!(parsed)
    reject_unknown_keys!(parsed, ["decision", "output", "next_agents"], "agentic review response")

    output = fetch_required_string!(parsed, "output")
    next_agents = fetch_required_next_agents!(parsed)
    normalized_next_agents = normalize_follow_up_specs!(agent, next_agents)
    decision = parsed |> fetch_decision!() |> normalize_decision!(normalized_next_agents)

    payload
    |> Map.put(:output, output)
    |> Map.put(:decision, decision)
    |> Map.put(:next_agents, normalized_next_agents)
  end

  defp review_json_text!(output) when is_binary(output), do: String.trim(output)

  defp review_json_text!(output) do
    raise ArgumentError,
          "agent_machine agentic review response output must be a binary, got: #{inspect(output)}"
  end

  defp require_object!(value) when is_map(value), do: :ok

  defp require_object!(_value) do
    raise ArgumentError, "agent_machine agentic review response must be a JSON object"
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
        reject_unknown_keys!(value, ["mode", "reason"], "agentic review response decision")
        value

      {:ok, value} ->
        raise ArgumentError,
              "agent_machine agentic review response decision must be an object, got: #{inspect(value)}"

      :error ->
        raise ArgumentError,
              "agent_machine agentic review response is missing required decision field"
    end
  end

  defp normalize_decision!(decision, next_agents) do
    mode = fetch_required_string!(decision, "mode")
    reason = fetch_required_string!(decision, "reason")
    delegated_agent_ids = Enum.map(next_agents, & &1.id)

    case {mode, delegated_agent_ids} do
      {"complete", []} ->
        %{mode: "complete", reason: reason, delegated_agent_ids: []}

      {"complete", ids} ->
        raise ArgumentError,
              "agent_machine agentic review response complete decision must not include next_agents, got: #{inspect(ids)}"

      {"continue", []} ->
        raise ArgumentError,
              "agent_machine agentic review response continue decision requires at least one next_agent"

      {"continue", ids} ->
        %{mode: "continue", reason: reason, delegated_agent_ids: ids}

      {other, _ids} ->
        raise ArgumentError,
              "agent_machine agentic review response decision mode must be complete or continue, got: #{inspect(other)}"
    end
  end

  defp fetch_required_string!(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 ->
        value

      {:ok, value} ->
        raise ArgumentError,
              "agent_machine agentic review response #{key} must be a non-empty string, got: #{inspect(value)}"

      :error ->
        raise ArgumentError,
              "agent_machine agentic review response is missing required #{key} field"
    end
  end

  defp fetch_required_next_agents!(map) do
    case Map.fetch(map, "next_agents") do
      {:ok, value} ->
        value

      :error ->
        raise ArgumentError,
              "agent_machine agentic review response is missing required next_agents field"
    end
  end

  defp normalize_follow_up_specs!(_agent, next_agents) when next_agents == [], do: []

  defp normalize_follow_up_specs!(agent, next_agents),
    do:
      DelegatedAgentSpec.normalize_specs!(
        agent,
        next_agents,
        "agent_machine agentic review response"
      )
end
