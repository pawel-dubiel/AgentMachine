defmodule AgentMachine.UsageLedger do
  @moduledoc """
  In-memory usage ledger for the current BEAM node.

  This is intentionally simple for the MVP. Persist it later if the node restart
  boundary matters.
  """

  use GenServer

  alias AgentMachine.Usage

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{records: []}, name: __MODULE__)
  end

  def record!(%Usage{} = usage) do
    GenServer.call(__MODULE__, {:record, usage})
  end

  def all do
    GenServer.call(__MODULE__, :all)
  end

  def by_run(run_id) when is_binary(run_id) do
    GenServer.call(__MODULE__, {:by_run, run_id})
  end

  def totals do
    GenServer.call(__MODULE__, :totals)
  end

  def reset! do
    GenServer.call(__MODULE__, :reset)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:record, usage}, _from, state) do
    {:reply, :ok, %{state | records: [usage | state.records]}}
  end

  def handle_call(:all, _from, state) do
    {:reply, Enum.reverse(state.records), state}
  end

  def handle_call({:by_run, run_id}, _from, state) do
    records =
      state.records
      |> Enum.filter(&(&1.run_id == run_id))
      |> Enum.reverse()

    {:reply, records, state}
  end

  def handle_call(:totals, _from, state) do
    {:reply, aggregate(state.records), state}
  end

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %{records: []}}
  end

  defp aggregate(records) do
    Enum.reduce(
      records,
      %{
        agents: 0,
        input_tokens: 0,
        output_tokens: 0,
        total_tokens: 0,
        cost_usd: 0.0
      },
      fn usage, acc ->
        %{
          agents: acc.agents + 1,
          input_tokens: acc.input_tokens + usage.input_tokens,
          output_tokens: acc.output_tokens + usage.output_tokens,
          total_tokens: acc.total_tokens + usage.total_tokens,
          cost_usd: acc.cost_usd + usage.cost_usd
        }
      end
    )
  end
end
