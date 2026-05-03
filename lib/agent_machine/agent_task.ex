defmodule AgentMachine.AgentTask do
  @moduledoc """
  Executes one continuation attempt for a long-lived session sidechain agent.
  """

  alias AgentMachine.{
    ClientRunner,
    PermissionControl,
    SessionProtocol,
    SessionRunLog,
    SessionTranscript,
    SessionWriter
  }

  def run(context) when is_map(context) do
    required!(context, [:session_id, :session_dir, :agent_id, :attrs, :message, :writer])

    append_agent(context, %{
      type: "user_message",
      message: context.message,
      attempt: Map.get(context, :attempt, 1)
    })

    summary = ClientRunner.run!(context.attrs, runner_opts(context))
    SessionRunLog.write_summary(Map.get(context, :log_file), summary)

    append_agent(context, %{
      type: "assistant_message",
      output: Map.get(summary, :final_output) || Map.get(summary, "final_output"),
      attempt: Map.get(context, :attempt, 1)
    })

    append_agent(context, %{type: "summary", summary: summary})
    {:ok, summary}
  rescue
    exception ->
      reason = Exception.format(:error, exception, __STACKTRACE__)
      SessionRunLog.write_summary(Map.get(context, :log_file), failed_summary(reason))

      append_agent(context, %{
        type: "error",
        error: reason,
        attempt: Map.get(context, :attempt, 1)
      })

      {:error, reason}
  end

  defp event_sink(context) do
    fn event ->
      maybe_append_tool_record(context, event)
      SessionRunLog.write_event(Map.get(context, :log_file), event)
      SessionWriter.write_line(context.writer, SessionProtocol.event_line!(event))
    end
  end

  defp failed_summary(reason) do
    %{status: "failed", error: reason, final_output: nil, results: %{}, events: []}
  end

  defp runner_opts(%{permission_control: control} = context) when is_pid(control) do
    [
      event_sink: event_sink(context),
      permission_control: control,
      tool_approval_callback: approval_callback(context),
      planner_review_callback: runtime_control_callback(context)
    ]
  end

  defp runner_opts(context), do: [event_sink: event_sink(context)]

  defp approval_callback(%{permission_control: control}) when is_pid(control) do
    fn request -> PermissionControl.request(control, request) end
  end

  defp approval_callback(_context),
    do: fn _request -> {:cancelled, "permission control unavailable"} end

  defp runtime_control_callback(%{permission_control: control}) when is_pid(control) do
    fn request -> PermissionControl.request(control, request) end
  end

  defp maybe_append_tool_record(context, %{type: :tool_call_started} = event) do
    append_agent(context, %{type: "tool_call", event: event})
  end

  defp maybe_append_tool_record(context, %{type: :tool_call_finished} = event) do
    append_agent(context, %{type: "tool_result", event: event})
  end

  defp maybe_append_tool_record(_context, _event), do: :ok

  defp append_agent(context, record) do
    SessionTranscript.append_agent!(
      context.session_dir,
      context.session_id,
      context.agent_id,
      record
    )
  end

  defp required!(map, keys) do
    Enum.each(keys, fn key ->
      unless Map.has_key?(map, key) do
        raise ArgumentError, "agent task context missing required key #{inspect(key)}"
      end
    end)
  end
end
