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
    validate_unique_agent_ids!(agents)
    validate_run_limits!(agents, opts)
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
      tasks = spawn_agents(agents, opts)

      run = %{
        id: run_id,
        status: :running,
        agent_order: Enum.map(agents, & &1.id),
        tasks: tasks,
        results: %{},
        usage: nil,
        opts: opts,
        step_count: length(agents),
        error: nil,
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

      %{status: :failed} = run ->
        {:error, {:failed, run}}

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

  defp validate_unique_agent_ids!(agents) do
    ids = Enum.map(agents, & &1.id)
    duplicates = duplicate_values(ids)

    case duplicates do
      [] -> :ok
      ids -> raise ArgumentError, "agent ids must be unique, duplicates: #{inspect(ids)}"
    end
  end

  defp validate_run_limits!(agents, opts) do
    case Keyword.fetch(opts, :max_steps) do
      :error ->
        :ok

      {:ok, max_steps} ->
        require_positive_integer!(max_steps, :max_steps)

        if length(agents) > max_steps do
          raise ArgumentError,
                "initial agent count #{length(agents)} exceeds max_steps #{max_steps}"
        end
    end
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

  defp spawn_agents(agents, opts) do
    Map.new(agents, fn agent ->
      task =
        Task.Supervisor.async_nolink(AgentMachine.AgentSupervisor, AgentRunner, :run, [
          agent,
          opts
        ])

      {task.ref, %{pid: task.pid, agent_id: agent.id}}
    end)
  end

  defp put_result(run, ref, result) do
    tasks = Map.delete(run.tasks, ref)
    results = Map.put(run.results, result.agent_id, result)

    run = %{run | tasks: tasks, results: results}

    if result.status == :ok and has_next_agents?(result) do
      case schedule_next_agents(run, result) do
        {:ok, updated_run} -> finish_if_idle(updated_run)
        {:error, reason} -> fail_run(run, reason)
      end
    else
      finish_if_idle(run)
    end
  end

  defp schedule_next_agents(run, result) do
    with {:ok, max_steps} <- fetch_max_steps(run.opts),
         {:ok, next_agents} <- validate_next_agents(run, result.next_agents),
         {:ok, step_count} <- reserve_steps(run.step_count, length(next_agents), max_steps) do
      tasks = Map.merge(run.tasks, spawn_agents(next_agents, run.opts))
      agent_order = run.agent_order ++ Enum.map(next_agents, & &1.id)

      {:ok, %{run | tasks: tasks, agent_order: agent_order, step_count: step_count}}
    end
  end

  defp finish_if_idle(run) do
    status =
      if map_size(run.tasks) == 0 do
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
        aggregate_usage(run.results)
      else
        nil
      end

    %{
      run
      | usage: usage,
        status: status,
        finished_at: finished_at
    }
  end

  defp fail_run(run, reason) do
    Enum.each(run.tasks, fn {_ref, task} ->
      Process.exit(task.pid, :kill)
    end)

    %{
      run
      | tasks: %{},
        status: :failed,
        usage: aggregate_usage(run.results),
        error: reason,
        finished_at: DateTime.utc_now()
    }
  end

  defp has_next_agents?(%AgentResult{next_agents: agents}) when is_list(agents), do: agents != []
  defp has_next_agents?(_result), do: false

  defp fetch_max_steps(opts) do
    case Keyword.fetch(opts, :max_steps) do
      {:ok, max_steps} ->
        require_positive_integer!(max_steps, :max_steps)
        {:ok, max_steps}

      :error ->
        {:error, "dynamic agent delegation requires explicit :max_steps option"}
    end
  end

  defp validate_next_agents(run, next_agents) do
    next_ids = Enum.map(next_agents, & &1.id)

    cond do
      duplicate_values(next_ids) != [] ->
        {:error,
         "delegated agent ids must be unique, duplicates: #{inspect(duplicate_values(next_ids))}"}

      duplicate_values(run.agent_order ++ next_ids) != [] ->
        existing_ids = MapSet.new(run.agent_order)

        duplicate_existing_ids =
          next_ids |> Enum.filter(&MapSet.member?(existing_ids, &1)) |> Enum.uniq()

        {:error,
         "delegated agent ids must not reuse existing ids, duplicates: #{inspect(duplicate_existing_ids)}"}

      true ->
        {:ok, next_agents}
    end
  end

  defp reserve_steps(step_count, next_count, max_steps) do
    next_step_count = step_count + next_count

    if next_step_count <= max_steps do
      {:ok, next_step_count}
    else
      {:error,
       "delegated agent count would exceed max_steps #{max_steps}: #{next_step_count} requested"}
    end
  end

  defp require_positive_integer!(value, _field) when is_integer(value) and value > 0 do
    :ok
  end

  defp require_positive_integer!(value, field) do
    raise ArgumentError, "#{inspect(field)} must be a positive integer, got: #{inspect(value)}"
  end

  defp duplicate_values(values) do
    values
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(fn {value, _count} -> value end)
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
