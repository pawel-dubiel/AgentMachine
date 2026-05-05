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
  defp summary(%{type: :run_timed_out, reason: reason}), do: "Run timed out: #{reason}"
  defp summary(%{type: :run_lease_extended}), do: "Run lease extended"

  defp summary(%{type: :workflow_routed, selected: selected}),
    do: "Workflow routed to #{selected}"

  defp summary(%{type: :execution_strategy_selected, selected: selected}),
    do: "Execution strategy selected: #{selected}"

  defp summary(%{type: :event_log_configured}), do: "Event log configured"

  defp summary(%{type: :skills_loaded, count: count}), do: "Loaded #{count} skill(s)"
  defp summary(%{type: :skills_selected, count: count}), do: "Selected #{count} skill(s)"

  defp summary(%{type: :agent_started, agent_id: agent_id, attempt: attempt}) do
    "#{agent_id} started attempt #{attempt}"
  end

  defp summary(%{type: :agent_finished, agent_id: agent_id, status: status} = event) do
    duration = duration_text(event)
    "#{agent_id} finished with #{status}#{duration}"
  end

  defp summary(%{type: :agent_heartbeat, agent_id: agent_id}), do: "#{agent_id} heartbeat"

  defp summary(%{type: :agent_retry_scheduled, agent_id: agent_id, next_attempt: attempt}) do
    "#{agent_id} scheduled retry attempt #{attempt}"
  end

  defp summary(%{type: :agent_delegation_scheduled, agent_id: agent_id, count: count}) do
    "#{agent_id} scheduled #{count} delegated agent(s)"
  end

  defp summary(%{type: :agentic_review_decided, reviewer_id: reviewer_id, mode: mode}) do
    "#{reviewer_id} decided agentic review #{mode}"
  end

  defp summary(%{type: :planner_review_requested, planner_id: planner_id, count: count}) do
    "#{planner_id} requested review for #{count} delegated agent(s)"
  end

  defp summary(%{type: :planner_review_requested, planner_id: planner_id}) do
    "#{planner_id} requested planner review"
  end

  defp summary(%{type: :planner_review_decided, planner_id: planner_id, decision: decision}) do
    "#{planner_id} planner review #{decision}"
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

  defp summary(%{type: :context_budget, agent_id: agent_id, status: "unknown"} = event) do
    reason = Map.get(event, :reason)
    "#{agent_id} context budget unknown#{if(is_nil(reason), do: "", else: " #{reason}")}"
  end

  defp summary(%{type: :context_budget, agent_id: agent_id, status: status} = event) do
    used = Map.get(event, :used_percent)
    "#{agent_id} context budget #{status}#{if(is_nil(used), do: "", else: " used=#{used}%")}"
  end

  defp summary(%{type: :run_context_compaction_started, count: count}) do
    "Run context compaction started for #{count} item(s)"
  end

  defp summary(%{type: :run_context_compaction_finished, count: count}) do
    "Run context compaction finished for #{count} item(s)"
  end

  defp summary(%{type: :run_context_compaction_failed, reason: reason}) do
    "Run context compaction failed: #{reason}"
  end

  defp summary(%{type: :run_context_compaction_skipped, reason: reason}) do
    "Run context compaction skipped: #{reason}"
  end

  defp summary(%{type: :assistant_delta, agent_id: agent_id}), do: "#{agent_id} streamed text"

  defp summary(%{type: :assistant_done, agent_id: agent_id}),
    do: "#{agent_id} finished streaming text"

  defp summary(%{type: :tool_call_started, agent_id: agent_id, tool: tool} = event) do
    "#{agent_id} started #{tool_started_text(tool, Map.get(event, :input_summary))}"
  end

  defp summary(%{type: :tool_call_finished, agent_id: agent_id, tool: tool} = event) do
    "#{agent_id} #{tool_finished_text(tool, Map.get(event, :result_summary))}#{duration_text(event)}"
  end

  defp summary(%{type: :tool_call_failed, agent_id: agent_id, tool: tool, reason: reason}) do
    "#{agent_id} failed #{tool}: #{reason}"
  end

  defp summary(%{type: :permission_requested, agent_id: agent_id, kind: kind, tool: tool}) do
    "#{agent_id} requested #{kind} permission for #{tool}"
  end

  defp summary(%{type: :permission_decided, agent_id: agent_id, decision: decision, tool: tool}) do
    "#{agent_id} permission #{decision} for #{tool}"
  end

  defp summary(%{type: :permission_cancelled, agent_id: agent_id, tool: tool, reason: reason}) do
    "#{agent_id} permission cancelled for #{tool}: #{reason}"
  end

  defp summary(%{type: :progress_commentary, commentary: commentary})
       when is_binary(commentary) do
    commentary
  end

  defp summary(%{type: type}), do: Atom.to_string(type)

  defp details(event) do
    event
    |> Map.take([
      :agent_id,
      :reviewer_id,
      :planner_id,
      :parent_agent_id,
      :attempt,
      :next_attempt,
      :round,
      :continue_count,
      :revision_count,
      :max_revisions,
      :mode,
      :completion_evidence_count,
      :completion_evidence,
      :tool_call_id,
      :request_id,
      :kind,
      :tool,
      :status,
      :decision,
      :duration_ms,
      :idle_timeout_ms,
      :hard_timeout_ms,
      :elapsed_ms,
      :remaining_idle_ms,
      :remaining_hard_ms,
      :reason,
      :permission,
      :approval_risk,
      :approval_mode,
      :capability,
      :requested_root,
      :requested_tool,
      :requested_command,
      :input_summary,
      :result_summary,
      :delegated_agent_ids,
      :proposed_agents,
      :planner_output,
      :provider,
      :count,
      :requested,
      :selected,
      :strategy,
      :tool_intent,
      :tools_exposed,
      :classifier,
      :classifier_model,
      :classified_intent,
      :work_shape,
      :route_hint,
      :confidence,
      :active_harnesses,
      :agent_machine_role,
      :swarm_id,
      :variant_id,
      :workspace,
      :spawn_depth,
      :delegated_agents,
      :path,
      :session_id,
      :model,
      :measurement,
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :used_tokens,
      :context_window_tokens,
      :reserved_output_tokens,
      :available_tokens,
      :used_percent,
      :remaining_percent,
      :warning_percent,
      :breakdown,
      :covered_items,
      :compaction_count,
      :commentary,
      :source,
      :evidence_count,
      :agent_ids,
      :tool_call_ids
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

  defp tool_started_text(tool, input_summary) do
    case path_from(input_summary) do
      nil -> tool
      path -> "#{tool} #{path}"
    end
  end

  defp tool_finished_text("now", result_summary) do
    case value_from(result_summary, :utc) do
      nil -> "checked time"
      utc -> "checked time utc=#{utc}"
    end
  end

  defp tool_finished_text("file_info", result_summary) do
    path = path_from(result_summary) || "path"
    type = value_from(result_summary, :type)
    size = value_from(result_summary, :size)
    compact_parts("inspected #{path}", [{"type", type}, {"size", size}])
  end

  defp tool_finished_text("list_files", result_summary) do
    path = path_from(result_summary) || "path"
    count = value_from(result_summary, :entry_count)
    compact_parts("listed #{path}", [{"entries", count}])
  end

  defp tool_finished_text("read_file", result_summary) do
    path = path_from(result_summary) || "file"
    bytes = value_from(result_summary, :bytes)
    lines = value_from(result_summary, :line_count)
    compact_parts("read #{path}", [{"bytes", bytes}, {"lines", lines}])
  end

  defp tool_finished_text("search_files", result_summary) do
    path = path_from(result_summary) || "path"
    count = value_from(result_summary, :match_count)
    compact_parts("searched #{path}", [{"matches", count}])
  end

  defp tool_finished_text("create_dir", result_summary) do
    path = first_changed_path(result_summary) || path_from(result_summary) || "directory"
    status = value_from(result_summary, :status)

    if status == "unchanged" do
      "kept dir #{path}"
    else
      "created dir #{path}"
    end
  end

  defp tool_finished_text("write_file", result_summary),
    do: changed_tool_text("wrote", result_summary)

  defp tool_finished_text("append_file", result_summary),
    do: changed_tool_text("appended", result_summary)

  defp tool_finished_text("replace_in_file", result_summary),
    do: changed_tool_text("replaced", result_summary)

  defp tool_finished_text("apply_edits", result_summary),
    do: changed_tool_text("edited", result_summary)

  defp tool_finished_text("apply_patch", result_summary),
    do: changed_tool_text("patched", result_summary)

  defp tool_finished_text(tool, result_summary) do
    path = path_from(result_summary)
    count = value_from(result_summary, :changed_count)
    compact_parts("finished #{tool}", [{"path", path}, {"changed", count}])
  end

  defp changed_tool_text(verb, result_summary) do
    path = first_changed_path(result_summary) || path_from(result_summary)
    changed = value_from(result_summary, :changed_count)
    compact_parts(verb <> if(path, do: " #{path}", else: ""), [{"changed", changed}])
  end

  defp compact_parts(base, parts) do
    suffix =
      parts
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{value}" end)

    if suffix == "", do: base, else: base <> " " <> suffix
  end

  defp path_from(map), do: value_from(map, :path)

  defp first_changed_path(map) do
    case value_from(map, :changed_paths) || value_from(map, :changed_files) do
      [%{path: path} | _] -> path
      [%{"path" => path} | _] -> path
      _other -> nil
    end
  end

  defp value_from(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp value_from(_map, _key), do: nil
end
