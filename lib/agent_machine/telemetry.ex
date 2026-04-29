defmodule AgentMachine.Telemetry do
  @moduledoc false

  def execute(event_name, measurements, metadata)
      when is_list(event_name) and is_map(measurements) and is_map(metadata) do
    :telemetry.execute(event_name, measurements, metadata)
  end

  def start_time do
    System.monotonic_time()
  end

  def duration_since(start_time) when is_integer(start_time) do
    System.monotonic_time() - start_time
  end

  def system_time do
    System.system_time()
  end
end
