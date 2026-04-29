defmodule AgentMachine.EventLog do
  @moduledoc false

  use GenServer

  alias AgentMachine.{EventSummary, JSON}
  alias AgentMachine.Secrets.Redactor

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{io: nil, path: nil, metadata: %{}}, name: __MODULE__)
  end

  def configure!(path, metadata \\ %{})

  def configure!(path, metadata) when is_binary(path) and byte_size(path) > 0 do
    GenServer.call(__MODULE__, {:configure, path, metadata})
  end

  def configure!(path, _metadata) do
    raise ArgumentError, "event log path must be a non-empty binary, got: #{inspect(path)}"
  end

  def configured? do
    GenServer.call(__MODULE__, :configured?)
  end

  def write_event(event) when is_map(event) do
    GenServer.call(__MODULE__, {:write_event, event})
  end

  def write_summary(summary) when is_map(summary) do
    GenServer.call(__MODULE__, {:write_summary, summary})
  end

  def close do
    GenServer.call(__MODULE__, :close)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:configure, path, metadata}, _from, state) do
    close_io(state)
    path = Path.expand(path)
    File.mkdir_p!(Path.dirname(path))

    case File.open(path, [:append, :utf8]) do
      {:ok, io} ->
        next_state = %{io: io, path: path, metadata: normalize_metadata!(metadata)}
        write_line!(next_state, event_line(configured_event(next_state)))
        {:reply, :ok, next_state}

      {:error, reason} ->
        raise ArgumentError, "failed to open event log #{inspect(path)}: #{inspect(reason)}"
    end
  end

  def handle_call(:configured?, _from, state) do
    {:reply, not is_nil(state.io), state}
  end

  def handle_call({:write_event, _event}, _from, %{io: nil} = state) do
    {:reply, :ok, state}
  end

  def handle_call({:write_event, event}, _from, state) do
    write_line!(state, event_line(event))
    {:reply, :ok, state}
  end

  def handle_call({:write_summary, _summary}, _from, %{io: nil} = state) do
    {:reply, :ok, state}
  end

  def handle_call({:write_summary, summary}, _from, state) do
    write_line!(state, summary_line(summary))
    {:reply, :ok, state}
  end

  def handle_call(:close, _from, state) do
    {:reply, :ok, close_io(state)}
  end

  @impl true
  def terminate(_reason, state), do: close_io(state)

  defp configured_event(%{path: path, metadata: metadata}) do
    metadata
    |> Map.put(:type, :event_log_configured)
    |> Map.put(:path, path)
    |> Map.put(:at, DateTime.utc_now())
  end

  defp event_line(event) do
    event =
      event
      |> EventSummary.enrich()
      |> Redactor.redact_output()
      |> Map.fetch!(:value)
      |> normalize_json_value()

    JSON.encode!(%{type: "event", event: event})
  end

  defp summary_line(summary) do
    summary =
      summary
      |> Redactor.redact_output()
      |> Map.fetch!(:value)
      |> normalize_json_value()

    JSON.encode!(%{type: "summary", summary: summary})
  end

  defp write_line!(%{io: io}, line) when is_binary(line) do
    IO.write(io, line)
    IO.write(io, "\n")
  end

  defp close_io(%{io: nil} = state), do: state

  defp close_io(%{io: io} = state) do
    File.close(io)
    %{state | io: nil}
  end

  defp normalize_metadata!(metadata) when is_map(metadata), do: metadata

  defp normalize_metadata!(metadata) do
    raise ArgumentError, "event log metadata must be a map, got: #{inspect(metadata)}"
  end

  defp normalize_json_value(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp normalize_json_value(value) when is_boolean(value), do: value

  defp normalize_json_value(value) when is_atom(value) and not is_nil(value) do
    Atom.to_string(value)
  end

  defp normalize_json_value(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {key, normalize_json_value(item)} end)
  end

  defp normalize_json_value(value) when is_list(value) do
    Enum.map(value, &normalize_json_value/1)
  end

  defp normalize_json_value(value), do: value
end
