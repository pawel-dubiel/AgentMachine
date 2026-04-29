defmodule AgentMachine.RunEventCollector do
  @moduledoc false

  use GenServer

  alias AgentMachine.Telemetry

  def start_link({run_id, event_sink, opts})
      when is_binary(run_id) and (is_nil(event_sink) or is_function(event_sink, 1)) and
             is_list(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, {run_id, event_sink}, name: name)
  end

  def emit(collector, event) when is_map(event) do
    GenServer.call(collector, {:emit, event})
  end

  @impl true
  def init({run_id, event_sink}) do
    {:ok,
     %{
       run_id: run_id,
       event_sink: event_sink,
       run_started_at: nil,
       agents_started_at: %{},
       tools_started_at: %{}
     }}
  end

  @impl true
  def handle_call({:emit, event}, _from, state) do
    state = emit_telemetry(event, state)
    AgentMachine.RunServer.record_runtime_health(state.run_id, event)

    if is_function(state.event_sink, 1) do
      state.event_sink.(event)
    end

    {:reply, :ok, state}
  end

  defp emit_telemetry(%{type: :run_started, run_id: run_id}, state) do
    started_at = Telemetry.start_time()

    Telemetry.execute([:agent_machine, :run, :start], %{system_time: Telemetry.system_time()}, %{
      run_id: run_id
    })

    %{state | run_started_at: started_at}
  end

  defp emit_telemetry(%{type: :run_completed, run_id: run_id}, state) do
    measurements = stop_measurements(state.run_started_at)
    Telemetry.execute([:agent_machine, :run, :stop], measurements, %{run_id: run_id})
    state
  end

  defp emit_telemetry(%{type: :run_failed, run_id: run_id, reason: reason}, state) do
    measurements = stop_measurements(state.run_started_at)

    Telemetry.execute([:agent_machine, :run, :exception], measurements, %{
      run_id: run_id,
      reason: reason
    })

    state
  end

  defp emit_telemetry(%{type: :run_timed_out, run_id: run_id, reason: reason}, state) do
    measurements = stop_measurements(state.run_started_at)

    Telemetry.execute([:agent_machine, :run, :exception], measurements, %{
      run_id: run_id,
      reason: reason
    })

    state
  end

  defp emit_telemetry(%{type: :agent_started} = event, state) do
    started_at = Telemetry.start_time()

    Telemetry.execute(
      [:agent_machine, :agent, :start],
      %{system_time: Telemetry.system_time()},
      %{
        run_id: event.run_id,
        agent_id: event.agent_id,
        attempt: event.attempt,
        parent_agent_id: event.parent_agent_id
      }
    )

    %{state | agents_started_at: Map.put(state.agents_started_at, agent_key(event), started_at)}
  end

  defp emit_telemetry(%{type: :agent_finished} = event, state) do
    {started_at, agents_started_at} = Map.pop(state.agents_started_at, agent_key(event))

    telemetry_event =
      if event.status == :ok do
        [:agent_machine, :agent, :stop]
      else
        [:agent_machine, :agent, :exception]
      end

    metadata = %{
      run_id: event.run_id,
      agent_id: event.agent_id,
      attempt: event.attempt,
      status: event.status
    }

    Telemetry.execute(telemetry_event, stop_measurements(started_at), metadata)
    %{state | agents_started_at: agents_started_at}
  end

  defp emit_telemetry(%{type: :tool_call_started} = event, state) do
    started_at = Telemetry.start_time()

    Telemetry.execute([:agent_machine, :tool, :start], %{system_time: Telemetry.system_time()}, %{
      run_id: event.run_id,
      agent_id: event.agent_id,
      attempt: event.attempt,
      tool: event.tool,
      tool_call_id: event.tool_call_id
    })

    %{state | tools_started_at: Map.put(state.tools_started_at, tool_key(event), started_at)}
  end

  defp emit_telemetry(%{type: :tool_call_finished} = event, state) do
    {started_at, tools_started_at} = Map.pop(state.tools_started_at, tool_key(event))

    Telemetry.execute([:agent_machine, :tool, :stop], stop_measurements(started_at), %{
      run_id: event.run_id,
      agent_id: event.agent_id,
      attempt: event.attempt,
      tool: event.tool,
      tool_call_id: event.tool_call_id
    })

    %{state | tools_started_at: tools_started_at}
  end

  defp emit_telemetry(%{type: :tool_call_failed} = event, state) do
    {started_at, tools_started_at} = Map.pop(state.tools_started_at, tool_key(event))

    Telemetry.execute([:agent_machine, :tool, :exception], stop_measurements(started_at), %{
      run_id: event.run_id,
      agent_id: event.agent_id,
      attempt: event.attempt,
      tool: event.tool,
      tool_call_id: event.tool_call_id,
      reason: event.reason
    })

    %{state | tools_started_at: tools_started_at}
  end

  defp emit_telemetry(_event, state), do: state

  defp stop_measurements(nil), do: %{duration: 0}
  defp stop_measurements(started_at), do: %{duration: Telemetry.duration_since(started_at)}

  defp agent_key(event), do: {event.agent_id, event.attempt}
  defp tool_key(event), do: {event.agent_id, event.attempt, event.tool_call_id}
end
