defmodule AgentMachine.Orchestrator do
  @moduledoc """
  Starts agent runs, spawns agent tasks, and collects results.
  """

  use GenServer

  alias AgentMachine.{Agent, AgentResult, AgentRunner}

  @poll_ms 25

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{runs: %{}}, name: __MODULE__)
  end

  def run(agent_specs, opts) when is_list(opts) do
    timeout = Keyword.fetch!(opts, :timeout)

    with {:ok, run_id} <- start_run(agent_specs, opts) do
      await_run(run_id, timeout)
    end
  end

  def start_run(agent_specs, opts \\ []) when is_list(opts) do
    agents = validate_agents!(agent_specs)
    run_id = opts |> run_id_from_opts() |> validate_run_id!()

    GenServer.call(__MODULE__, {:start_run, run_id, agents, Keyword.put(opts, :run_id, run_id)})
  end

  def get_run(run_id) when is_binary(run_id) do
    GenServer.call(__MODULE__, {:get_run, run_id})
  end

  def await_run(run_id, timeout_ms)
      when is_binary(run_id) and is_integer(timeout_ms) and timeout_ms >= 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_loop(run_id, deadline)
  end

  def await_run(run_id, timeout_ms) do
    raise ArgumentError,
          "await_run/2 requires a binary run_id and non-negative integer timeout_ms, got: #{inspect({run_id, timeout_ms})}"
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:start_run, run_id, agents, opts}, _from, state) do
    if Map.has_key?(state.runs, run_id) do
      {:reply, {:error, {:run_exists, run_id}}, state}
    else
      tasks =
        Map.new(agents, fn agent ->
          task =
            Task.Supervisor.async_nolink(AgentMachine.AgentSupervisor, AgentRunner, :run, [
              agent,
              opts
            ])

          {task.ref, %{pid: task.pid, agent_id: agent.id}}
        end)

      run = %{
        id: run_id,
        status: :running,
        agent_order: Enum.map(agents, & &1.id),
        tasks: tasks,
        results: %{},
        usage: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil
      }

      {:reply, {:ok, run_id}, put_in(state, [:runs, run_id], run)}
    end
  end

  def handle_call({:get_run, run_id}, _from, state) do
    {:reply, Map.get(state.runs, run_id), state}
  end

  @impl true
  def handle_info({ref, %AgentResult{} = result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case find_run_by_ref(state.runs, ref) do
      nil ->
        {:noreply, state}

      {run_id, run} ->
        updated_run = put_result(run, ref, result)
        {:noreply, put_in(state, [:runs, run_id], updated_run)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case find_run_by_ref(state.runs, ref) do
      nil ->
        {:noreply, state}

      {run_id, run} ->
        task = Map.fetch!(run.tasks, ref)

        result = %AgentResult{
          run_id: run_id,
          agent_id: task.agent_id,
          status: :error,
          error: "agent task exited before returning a result: #{inspect(reason)}",
          started_at: nil,
          finished_at: DateTime.utc_now()
        }

        updated_run = put_result(run, ref, result)
        {:noreply, put_in(state, [:runs, run_id], updated_run)}
    end
  end

  defp await_loop(run_id, deadline) do
    case get_run(run_id) do
      nil ->
        {:error, :not_found}

      %{status: :completed} = run ->
        {:ok, run}

      run ->
        now = System.monotonic_time(:millisecond)

        if now >= deadline do
          {:error, {:timeout, run}}
        else
          Process.sleep(min(@poll_ms, deadline - now))
          await_loop(run_id, deadline)
        end
    end
  end

  defp validate_agents!(agent_specs) when is_list(agent_specs) and length(agent_specs) > 0 do
    Enum.map(agent_specs, &Agent.new!/1)
  end

  defp validate_agents!(agent_specs) do
    raise ArgumentError, "agent_specs must be a non-empty list, got: #{inspect(agent_specs)}"
  end

  defp validate_run_id!(run_id) when is_binary(run_id) and byte_size(run_id) > 0, do: run_id

  defp validate_run_id!(run_id) do
    raise ArgumentError, "run_id must be a non-empty binary, got: #{inspect(run_id)}"
  end

  defp run_id_from_opts(opts) do
    case Keyword.fetch(opts, :run_id) do
      {:ok, run_id} -> run_id
      :error -> generated_run_id()
    end
  end

  defp generated_run_id do
    "run-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp find_run_by_ref(runs, ref) do
    Enum.find_value(runs, fn {run_id, run} ->
      if Map.has_key?(run.tasks, ref), do: {run_id, run}
    end)
  end

  defp put_result(run, ref, result) do
    tasks = Map.delete(run.tasks, ref)
    results = Map.put(run.results, result.agent_id, result)

    status =
      if map_size(tasks) == 0 do
        :completed
      else
        :running
      end

    finished_at =
      if status == :completed do
        DateTime.utc_now()
      else
        nil
      end

    usage =
      if status == :completed do
        aggregate_usage(results)
      else
        nil
      end

    %{
      run
      | tasks: tasks,
        results: results,
        usage: usage,
        status: status,
        finished_at: finished_at
    }
  end

  defp aggregate_usage(results) do
    results
    |> Map.values()
    |> Enum.reduce(
      %{
        agents: 0,
        input_tokens: 0,
        output_tokens: 0,
        total_tokens: 0,
        cost_usd: 0.0
      },
      fn
        %{status: :ok, usage: usage}, acc ->
          %{
            agents: acc.agents + 1,
            input_tokens: acc.input_tokens + usage.input_tokens,
            output_tokens: acc.output_tokens + usage.output_tokens,
            total_tokens: acc.total_tokens + usage.total_tokens,
            cost_usd: acc.cost_usd + usage.cost_usd
          }

        _result, acc ->
          acc
      end
    )
  end
end
