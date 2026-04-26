defmodule AgentMachine.EventSummary do
  @moduledoc false

  def enrich(event) when is_map(event) do
    event
    |> Map.put_new(:summary, summary(event))
    |> Map.put_new(:details, details(event))
  end

  defp summary(%{type: :run_started}), do: "Run started"
  defp summary(%{type: :run_completed}), do: "Run completed"
  defp summary(%{type: :run_failed, reason: reason}), do: "Run failed: #{reason}"

  defp summary(%{type: :skills_loaded, count: count}), do: "Loaded #{count} skill(s)"
  defp summary(%{type: :skills_selected, count: count}), do: "Selected #{count} skill(s)"

  defp summary(%{type: :agent_started, agent_id: agent_id, attempt: attempt}) do
    "#{agent_id} started attempt #{attempt}"
  end

  defp summary(%{type: :agent_finished, agent_id: agent_id, status: status} = event) do
    duration = duration_text(event)
    "#{agent_id} finished with #{status}#{duration}"
  end

  defp summary(%{type: :agent_retry_scheduled, agent_id: agent_id, next_attempt: attempt}) do
    "#{agent_id} scheduled retry attempt #{attempt}"
  end

  defp summary(%{type: :agent_delegation_scheduled, agent_id: agent_id, count: count}) do
    "#{agent_id} scheduled #{count} delegated agent(s)"
  end

  defp summary(%{type: :provider_request_started, agent_id: agent_id}) do
    "#{agent_id} sent provider request"
  end

  defp summary(%{type: :provider_request_finished, agent_id: agent_id} = event) do
    "#{agent_id} provider request finished#{duration_text(event)}"
  end

  defp summary(%{type: :provider_request_failed, agent_id: agent_id, reason: reason}) do
    "#{agent_id} provider request failed: #{reason}"
  end

  defp summary(%{type: :assistant_delta, agent_id: agent_id}), do: "#{agent_id} streamed text"

  defp summary(%{type: :assistant_done, agent_id: agent_id}),
    do: "#{agent_id} finished streaming text"

  defp summary(%{type: :tool_call_started, agent_id: agent_id, tool: tool}) do
    "#{agent_id} started #{tool}"
  end

  defp summary(%{type: :tool_call_finished, agent_id: agent_id, tool: tool} = event) do
    "#{agent_id} finished #{tool}#{duration_text(event)}"
  end

  defp summary(%{type: :tool_call_failed, agent_id: agent_id, tool: tool, reason: reason}) do
    "#{agent_id} failed #{tool}: #{reason}"
  end

  defp summary(%{type: type}), do: Atom.to_string(type)

  defp details(event) do
    event
    |> Map.take([
      :agent_id,
      :parent_agent_id,
      :attempt,
      :next_attempt,
      :round,
      :tool_call_id,
      :tool,
      :status,
      :duration_ms,
      :reason,
      :permission,
      :approval_risk,
      :approval_mode,
      :input_summary,
      :result_summary,
      :delegated_agent_ids,
      :count,
      :provider
    ])
    |> reject_empty_values()
  end

  defp reject_empty_values(map) do
    Map.reject(map, fn
      {_key, nil} -> true
      {_key, ""} -> true
      {_key, []} -> true
      {_key, %{}} -> true
      _other -> false
    end)
  end

  defp duration_text(%{duration_ms: duration_ms}) when is_integer(duration_ms) do
    " in #{duration_ms}ms"
  end

  defp duration_text(_event), do: ""
end
