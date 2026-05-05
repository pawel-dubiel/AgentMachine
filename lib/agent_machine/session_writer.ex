defmodule AgentMachine.SessionWriter do
  @moduledoc false

  use GenServer

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def write_line(pid, line) when is_pid(pid) and is_binary(line) do
    GenServer.call(pid, {:write_line, line})
  end

  def write_line_async(pid, line) when is_pid(pid) and is_binary(line) do
    GenServer.cast(pid, {:write_line, line})
  end

  @impl true
  def init(opts) do
    output = Keyword.fetch!(opts, :output)
    log_io = Keyword.get(opts, :log_io)
    {:ok, %{output: output, log_io: log_io}}
  end

  @impl true
  def handle_call({:write_line, line}, _from, state) do
    write_line!(state, line)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:write_line, line}, state) do
    write_line!(state, line)
    {:noreply, state}
  end

  defp write_line!(state, line) do
    IO.puts(state.output, line)

    if state.log_io do
      IO.write(state.log_io, [line, ?\n])
    end
  end
end
