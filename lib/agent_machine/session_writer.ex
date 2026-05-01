defmodule AgentMachine.SessionWriter do
  @moduledoc false

  use GenServer

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def write_line(pid, line) when is_pid(pid) and is_binary(line) do
    GenServer.call(pid, {:write_line, line})
  end

  @impl true
  def init(opts) do
    output = Keyword.fetch!(opts, :output)
    log_io = Keyword.get(opts, :log_io)
    {:ok, %{output: output, log_io: log_io}}
  end

  @impl true
  def handle_call({:write_line, line}, _from, state) do
    IO.puts(state.output, line)

    if state.log_io do
      IO.write(state.log_io, [line, ?\n])
    end

    {:reply, :ok, state}
  end
end
