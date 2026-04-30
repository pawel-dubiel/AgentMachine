defmodule AgentMachine.RunChecklist do
  @moduledoc false

  alias AgentMachine.EventSummary

  def from_events(events) when is_list(events) do
    state = Enum.reduce(events, %{items: %{}, order: []}, &apply_event/2)

    state.order
    |> Enum.map(&Map.get(state.items, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp apply_event(%{type: :agent_delegation_scheduled} = event, state) do
    event
    |> Map.get(:delegated_agent_ids, [])
    |> Enum.reduce(state, fn agent_id, acc ->
      upsert(acc, "agent:#{agent_id}", %{
        id: "agent:#{agent_id}",
        kind: "agent",
        label: agent_id,
        parent_id: agent_parent_id(event),
        status: "pending",
        latest_summary: EventSummary.enrich(event).summary
      })
    end)
  end

  defp apply_event(%{type: :agent_started, agent_id: agent_id} = event, state) do
    upsert(state, "agent:#{agent_id}", %{
      id: "agent:#{agent_id}",
      kind: "agent",
      label: agent_id,
      parent_id: agent_parent_id(event),
      status: "running",
      started_at: iso8601(Map.get(event, :at)),
      latest_summary: EventSummary.enrich(event).summary
    })
  end

  defp apply_event(%{type: :agent_finished, agent_id: agent_id} = event, state) do
    upsert(state, "agent:#{agent_id}", %{
      id: "agent:#{agent_id}",
      kind: "agent",
      label: agent_id,
      status: finished_status(Map.get(event, :status)),
      finished_at: iso8601(Map.get(event, :at)),
      duration_ms: Map.get(event, :duration_ms),
      latest_summary: EventSummary.enrich(event).summary
    })
  end

  defp apply_event(
         %{type: :tool_call_started, agent_id: agent_id, tool_call_id: call_id} = event,
         state
       ) do
    id = tool_item_id(agent_id, call_id)

    upsert(state, id, %{
      id: id,
      kind: "tool",
      label: tool_label(event),
      parent_id: "agent:#{agent_id}",
      status: "running",
      started_at: iso8601(Map.get(event, :at)),
      latest_summary: EventSummary.enrich(event).summary
    })
  end

  defp apply_event(
         %{type: :tool_call_finished, agent_id: agent_id, tool_call_id: call_id} = event,
         state
       ) do
    id = tool_item_id(agent_id, call_id)

    upsert(state, id, %{
      id: id,
      kind: "tool",
      label: tool_label(event),
      parent_id: "agent:#{agent_id}",
      status: "done",
      finished_at: iso8601(Map.get(event, :at)),
      duration_ms: Map.get(event, :duration_ms),
      latest_summary: EventSummary.enrich(event).summary
    })
  end

  defp apply_event(
         %{type: :tool_call_failed, agent_id: agent_id, tool_call_id: call_id} = event,
         state
       ) do
    id = tool_item_id(agent_id, call_id)

    upsert(state, id, %{
      id: id,
      kind: "tool",
      label: tool_label(event),
      parent_id: "agent:#{agent_id}",
      status: "error",
      finished_at: iso8601(Map.get(event, :at)),
      duration_ms: Map.get(event, :duration_ms),
      latest_summary: EventSummary.enrich(event).summary
    })
  end

  defp apply_event(%{type: :run_timed_out} = event, state) do
    reason = EventSummary.enrich(event).summary

    items =
      Map.new(state.items, fn {id, item} ->
        if item.status in ["pending", "running"] do
          {id,
           %{
             item
             | status: "timeout",
               finished_at: iso8601(Map.get(event, :at)),
               latest_summary: reason
           }}
        else
          {id, item}
        end
      end)

    %{state | items: items}
  end

  defp apply_event(_event, state), do: state

  defp upsert(state, id, fields) do
    item =
      state.items
      |> Map.get(id, base_item(id))
      |> Map.merge(reject_nil(fields))

    order = if Map.has_key?(state.items, id), do: state.order, else: state.order ++ [id]

    %{state | items: Map.put(state.items, id, item), order: order}
  end

  defp base_item(id) do
    %{
      id: id,
      kind: "agent",
      label: id,
      parent_id: nil,
      status: "pending",
      started_at: nil,
      finished_at: nil,
      duration_ms: nil,
      latest_summary: nil
    }
  end

  defp reject_nil(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp finished_status(:ok), do: "done"
  defp finished_status("ok"), do: "done"
  defp finished_status(_other), do: "error"

  defp agent_parent_id(%{parent_agent_id: parent}) when is_binary(parent) and parent != "",
    do: "agent:#{parent}"

  defp agent_parent_id(_event), do: nil

  defp tool_item_id(agent_id, call_id), do: "tool:#{agent_id}:#{call_id}"

  defp tool_label(event) do
    enriched = EventSummary.enrich(event)
    Map.get(enriched, :summary) || "#{event.tool} #{event.tool_call_id}"
  end

  defp iso8601(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso8601(at) when is_binary(at), do: at
  defp iso8601(_at), do: nil
end
