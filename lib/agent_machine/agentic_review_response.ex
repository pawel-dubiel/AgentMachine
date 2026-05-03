defmodule AgentMachine.AgenticReviewResponse do
  @moduledoc false

  alias AgentMachine.{Agent, DelegatedAgentSpec, ModelOutputJSON}

  @evidence_kinds ["agent_output", "tool_result", "artifact", "decision"]

  def applies?(%Agent{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, :agent_machine_response) == "agentic_review" ||
      Map.get(metadata, "agent_machine_response") == "agentic_review"
  end

  def applies?(_agent), do: false

  def normalize_payload!(%Agent{} = agent, payload) do
    parsed =
      payload.output
      |> review_json_text!()
      |> ModelOutputJSON.decode_object!("agent_machine agentic review response")

    require_object!(parsed)

    reject_unknown_keys!(
      parsed,
      ["decision", "output", "completion_evidence", "next_agents"],
      "agentic review response"
    )

    output = fetch_required_string!(parsed, "output")
    completion_evidence = fetch_completion_evidence!(parsed)
    next_agents = fetch_required_next_agents!(parsed)
    normalized_next_agents = normalize_follow_up_specs!(agent, next_agents)

    decision =
      parsed
      |> fetch_decision!()
      |> normalize_decision!(normalized_next_agents, completion_evidence)

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

  defp normalize_decision!(decision, next_agents, completion_evidence) do
    mode = fetch_required_string!(decision, "mode")
    reason = fetch_required_string!(decision, "reason")
    delegated_agent_ids = Enum.map(next_agents, & &1.id)

    case {mode, delegated_agent_ids} do
      {"complete", []} ->
        require_complete_evidence!(completion_evidence)

        %{
          mode: "complete",
          reason: reason,
          completion_evidence: completion_evidence,
          delegated_agent_ids: []
        }

      {"complete", ids} ->
        raise ArgumentError,
              "agent_machine agentic review response complete decision must not include next_agents, got: #{inspect(ids)}"

      {"continue", []} ->
        raise ArgumentError,
              "agent_machine agentic review response continue decision requires at least one next_agent"

      {"continue", ids} ->
        %{
          mode: "continue",
          reason: reason,
          completion_evidence: completion_evidence,
          delegated_agent_ids: ids
        }

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

  defp fetch_completion_evidence!(map) do
    case Map.fetch(map, "completion_evidence") do
      {:ok, value} when is_list(value) ->
        Enum.map(value, &normalize_evidence_item!/1)

      {:ok, value} ->
        raise ArgumentError,
              "agent_machine agentic review response completion_evidence must be a list, got: #{inspect(value)}"

      :error ->
        raise ArgumentError,
              "agent_machine agentic review response is missing required completion_evidence field"
    end
  end

  defp normalize_evidence_item!(item) when is_map(item) do
    reject_unknown_keys!(
      item,
      ["source_agent_id", "kind", "summary", "tool_call_id", "artifact_key"],
      "agentic review response completion_evidence item"
    )

    source_agent_id = fetch_required_string!(item, "source_agent_id")
    kind = fetch_evidence_kind!(item)
    summary = fetch_required_string!(item, "summary")

    evidence =
      %{
        source_agent_id: source_agent_id,
        kind: kind,
        summary: summary
      }

    validate_evidence_reference_keys!(kind, item)
    |> Enum.reduce(evidence, fn {key, value}, acc -> Map.put(acc, key, value) end)
  end

  defp normalize_evidence_item!(item) do
    raise ArgumentError,
          "agent_machine agentic review response completion_evidence item must be an object, got: #{inspect(item)}"
  end

  defp fetch_evidence_kind!(item) do
    kind = fetch_required_string!(item, "kind")

    if kind in @evidence_kinds do
      kind
    else
      raise ArgumentError,
            "agent_machine agentic review response completion_evidence kind must be one of #{inspect(@evidence_kinds)}, got: #{inspect(kind)}"
    end
  end

  defp validate_evidence_reference_keys!("tool_result", item) do
    tool_call_id = fetch_required_evidence_reference!(item, "tool_call_id", "tool_result")
    reject_evidence_key!(item, "artifact_key", "tool_result")
    [tool_call_id: tool_call_id]
  end

  defp validate_evidence_reference_keys!("artifact", item) do
    artifact_key = fetch_required_evidence_reference!(item, "artifact_key", "artifact")
    reject_evidence_key!(item, "tool_call_id", "artifact")
    [artifact_key: artifact_key]
  end

  defp validate_evidence_reference_keys!(kind, item) when kind in ["agent_output", "decision"] do
    reject_evidence_key!(item, "tool_call_id", kind)
    reject_evidence_key!(item, "artifact_key", kind)
    []
  end

  defp reject_evidence_key!(item, key, kind) do
    if Map.has_key?(item, key) do
      raise ArgumentError,
            "agent_machine agentic review response #{kind} evidence must not include #{key}"
    end
  end

  defp fetch_required_evidence_reference!(item, key, kind) do
    case Map.fetch(item, key) do
      {:ok, value} when is_binary(value) and byte_size(value) > 0 ->
        value

      {:ok, value} ->
        raise ArgumentError,
              "agent_machine agentic review response #{kind} evidence #{key} must be a non-empty string, got: #{inspect(value)}"

      :error ->
        raise ArgumentError,
              "agent_machine agentic review response #{kind} evidence requires #{key}"
    end
  end

  defp require_complete_evidence!([]) do
    raise ArgumentError,
          "agent_machine agentic review response complete decision requires at least one completion_evidence item"
  end

  defp require_complete_evidence!(evidence) when is_list(evidence), do: :ok

  defp normalize_follow_up_specs!(_agent, next_agents) when next_agents == [], do: []

  defp normalize_follow_up_specs!(agent, next_agents),
    do:
      DelegatedAgentSpec.normalize_specs!(
        agent,
        next_agents,
        "agent_machine agentic review response"
      )
end
