defmodule AgentMachine.Orchestrator do
  @moduledoc """
  Public facade for starting and observing agent runs.
  """

  use GenServer

  alias AgentMachine.{Agent, RunServer, RunSupervisor}

  @poll_ms 25
  @leased_poll_ms 250
  @lease_extension_min_interval_ms 1_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def run(agent_specs, opts) when is_list(opts) do
    timeout = Keyword.fetch!(opts, :timeout)

    with {:ok, run_id} <- start_run(agent_specs, opts) do
      await_started_run(run_id, timeout, opts)
    end
  end

  def start_run(agent_specs, opts \\ []) when is_list(opts) do
    agents = validate_agents!(agent_specs)
    finalizer = finalizer_from_opts(opts)
    validate_unique_agent_ids!(agents, finalizer)
    validate_dependency_graph!(agents)
    validate_run_limits!(agents, opts)
    validate_event_sink!(opts)
    run_id = opts |> run_id_from_opts() |> validate_run_id!()

    if registered_run?(run_id) do
      {:error, {:run_exists, run_id}}
    else
      opts = Keyword.put(opts, :run_id, run_id)

      case RunSupervisor.start_run(run_id, agents, finalizer, opts) do
        {:ok, _pid} ->
          {:ok, run_id}

        {:error, {:already_started, _pid}} ->
          {:error, {:run_exists, run_id}}

        {:error, {:shutdown, {:failed_to_start_child, RunServer, {:already_started, _pid}}}} ->
          {:error, {:run_exists, run_id}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def get_run(run_id) when is_binary(run_id) do
    case Registry.lookup(AgentMachine.RunRegistry, {:run, run_id}) do
      [{pid, _value}] -> RunServer.snapshot(pid)
      [] -> nil
    end
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
  def init(:ok), do: {:ok, :ok}

  defp await_loop(run_id, deadline) do
    case get_run(run_id) do
      nil ->
        {:error, :not_found}

      %{status: :completed} = run ->
        {:ok, run}

      %{status: :failed} = run ->
        {:error, {:failed, run}}

      %{status: :timeout} = run ->
        {:error, {:timeout, run}}

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

  defp await_started_run(run_id, timeout_ms, opts) do
    if Keyword.has_key?(opts, :idle_timeout_ms) or Keyword.has_key?(opts, :hard_timeout_ms) do
      await_run(run_id, timeout_ms,
        idle_timeout_ms: Keyword.fetch!(opts, :idle_timeout_ms),
        hard_timeout_ms: Keyword.fetch!(opts, :hard_timeout_ms)
      )
    else
      await_run(run_id, timeout_ms)
    end
  end

  def await_run(run_id, timeout_ms, opts)
      when is_binary(run_id) and is_integer(timeout_ms) and timeout_ms >= 0 and is_list(opts) do
    validate_await_opts!(opts)
    idle_timeout_ms = Keyword.fetch!(opts, :idle_timeout_ms)
    hard_timeout_ms = Keyword.fetch!(opts, :hard_timeout_ms)
    require_positive_integer!(idle_timeout_ms, :idle_timeout_ms)
    require_positive_integer!(hard_timeout_ms, :hard_timeout_ms)

    if hard_timeout_ms < idle_timeout_ms do
      raise ArgumentError,
            ":hard_timeout_ms must be greater than or equal to :idle_timeout_ms, got: #{inspect({idle_timeout_ms, hard_timeout_ms})}"
    end

    now = System.monotonic_time(:millisecond)
    run = get_run(run_id)

    state = %{
      idle_timeout_ms: idle_timeout_ms,
      hard_timeout_ms: hard_timeout_ms,
      started_at_ms: now,
      idle_deadline_ms: now + idle_timeout_ms,
      hard_deadline_ms: now + hard_timeout_ms,
      last_health_count: health_event_count(run),
      last_extension_at_ms: now - @lease_extension_min_interval_ms,
      permission_pause_started_ms: nil
    }

    await_leased_loop(run_id, state)
  end

  def await_run(run_id, timeout_ms, opts) do
    raise ArgumentError,
          "await_run/3 requires a binary run_id, non-negative integer timeout_ms, and keyword opts, got: #{inspect({run_id, timeout_ms, opts})}"
  end

  defp await_leased_loop(run_id, lease) do
    case get_run(run_id) do
      nil ->
        {:error, :not_found}

      %{status: :completed} = run ->
        {:ok, run}

      %{status: :failed} = run ->
        {:error, {:failed, run}}

      %{status: :timeout} = run ->
        {:error, {:timeout, run}}

      run ->
        await_active_run(run_id, run, lease)
    end
  end

  defp await_active_run(run_id, run, lease) do
    now = System.monotonic_time(:millisecond)

    lease = maybe_extend_lease(run_id, run, lease, now)
    lease = maybe_pause_for_permission_wait(run, lease, now)

    continue_or_timeout(run_id, lease, now)
  end

  defp continue_or_timeout(run_id, lease, now) do
    case lease_decision(lease, now) do
      :continue ->
        sleep_and_await(run_id, lease, now)

      :permission_pause ->
        sleep_and_await(run_id, lease, now)

      {:timeout, reason} ->
        timeout_run(run_id, reason, timeout_metadata(lease, now))
    end
  end

  defp lease_decision(%{permission_pause_started_ms: pause_started}, _now)
       when is_integer(pause_started),
       do: :permission_pause

  defp lease_decision(lease, now) when now >= lease.hard_deadline_ms,
    do: {:timeout, "hard timeout reached after #{lease.hard_timeout_ms}ms"}

  defp lease_decision(lease, now) when now >= lease.idle_deadline_ms,
    do: {:timeout, "idle lease expired after #{lease.idle_timeout_ms}ms without runtime activity"}

  defp lease_decision(_lease, _now), do: :continue

  defp sleep_and_await(run_id, lease, now) do
    sleep_ms = next_sleep_ms(lease, now)
    Process.sleep(sleep_ms)
    await_leased_loop(run_id, lease)
  end

  defp maybe_pause_for_permission_wait(%{permission_waiting_count: count}, lease, now)
       when is_integer(count) and count > 0 do
    case lease.permission_pause_started_ms do
      nil -> %{lease | permission_pause_started_ms: now}
      _started_at -> lease
    end
  end

  defp maybe_pause_for_permission_wait(_run, %{permission_pause_started_ms: nil} = lease, _now),
    do: lease

  defp maybe_pause_for_permission_wait(_run, lease, now) do
    paused_ms = max(now - lease.permission_pause_started_ms, 0)

    %{
      lease
      | idle_deadline_ms: lease.idle_deadline_ms + paused_ms,
        hard_deadline_ms: lease.hard_deadline_ms + paused_ms,
        permission_pause_started_ms: nil
    }
  end

  defp maybe_extend_lease(run_id, run, lease, now) do
    health_count = health_event_count(run)

    if is_integer(health_count) and health_count > lease.last_health_count do
      idle_deadline_ms = min(now + lease.idle_timeout_ms, lease.hard_deadline_ms)

      lease = %{
        lease
        | idle_deadline_ms: idle_deadline_ms,
          last_health_count: health_count
      }

      if now - lease.last_extension_at_ms >= @lease_extension_min_interval_ms do
        record_lease_extended(run_id, lease_metadata(lease, now))
        %{lease | last_extension_at_ms: now}
      else
        lease
      end
    else
      lease
    end
  end

  defp next_sleep_ms(lease, now) do
    lease
    |> Map.take([:idle_deadline_ms, :hard_deadline_ms])
    |> Map.values()
    |> Enum.map(&max(&1 - now, 0))
    |> Enum.min()
    |> min(@leased_poll_ms)
  end

  defp timeout_run(run_id, reason, metadata) do
    case lookup_run_server(run_id) do
      nil ->
        {:error, :not_found}

      pid ->
        run = RunServer.timeout(pid, reason, metadata)
        {:error, {:timeout, run}}
    end
  end

  defp record_lease_extended(run_id, metadata) do
    case lookup_run_server(run_id) do
      nil -> :ok
      pid -> RunServer.extend_lease(pid, metadata)
    end
  end

  defp lookup_run_server(run_id) do
    case Registry.lookup(AgentMachine.RunRegistry, {:run, run_id}) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  defp lease_metadata(lease, now) do
    %{
      reason: "runtime activity",
      idle_timeout_ms: lease.idle_timeout_ms,
      hard_timeout_ms: lease.hard_timeout_ms,
      elapsed_ms: now - lease.started_at_ms,
      remaining_idle_ms: max(lease.idle_deadline_ms - now, 0),
      remaining_hard_ms: max(lease.hard_deadline_ms - now, 0)
    }
  end

  defp timeout_metadata(lease, now) do
    %{
      idle_timeout_ms: lease.idle_timeout_ms,
      hard_timeout_ms: lease.hard_timeout_ms,
      elapsed_ms: now - lease.started_at_ms
    }
  end

  defp health_event_count(nil), do: 0
  defp health_event_count(%{health_event_count: count}) when is_integer(count), do: count
  defp health_event_count(_run), do: 0

  defp validate_await_opts!(opts) do
    allowed_keys = [:idle_timeout_ms, :hard_timeout_ms]
    unknown_keys = opts |> Keyword.keys() |> Enum.reject(&(&1 in allowed_keys))

    if unknown_keys != [] do
      raise ArgumentError, "unknown await option(s): #{inspect(unknown_keys)}"
    end
  end

  defp registered_run?(run_id) do
    Registry.lookup(AgentMachine.RunRegistry, {:run, run_id}) != []
  end

  defp validate_agents!([_agent | _rest] = agent_specs) do
    Enum.map(agent_specs, &Agent.new!/1)
  end

  defp validate_agents!(agent_specs) do
    raise ArgumentError, "agent_specs must be a non-empty list, got: #{inspect(agent_specs)}"
  end

  defp validate_unique_agent_ids!(agents, finalizer) do
    ids = agents |> maybe_append_agent(finalizer) |> Enum.map(& &1.id)
    duplicates = duplicate_values(ids)

    case duplicates do
      [] -> :ok
      ids -> raise ArgumentError, "agent ids must be unique, duplicates: #{inspect(ids)}"
    end
  end

  defp validate_run_limits!(agents, opts) do
    validate_max_attempts!(opts)

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

  defp validate_event_sink!(opts) do
    case Keyword.fetch(opts, :event_sink) do
      :error ->
        :ok

      {:ok, sink} when is_function(sink, 1) ->
        :ok

      {:ok, sink} ->
        raise ArgumentError, ":event_sink must be a function of arity 1, got: #{inspect(sink)}"
    end
  end

  defp validate_max_attempts!(opts) do
    case Keyword.fetch(opts, :max_attempts) do
      :error -> :ok
      {:ok, max_attempts} -> require_positive_integer!(max_attempts, :max_attempts)
    end
  end

  defp validate_dependency_graph!(agents) do
    agent_ids = MapSet.new(Enum.map(agents, & &1.id))

    Enum.each(agents, &validate_agent_dependencies!(&1, agent_ids))
    detect_dependency_cycles!(agents)
  end

  defp validate_agent_dependencies!(agent, agent_ids) do
    cond do
      agent.id in agent.depends_on ->
        raise ArgumentError, "agent #{inspect(agent.id)} must not depend on itself"

      duplicate_values(agent.depends_on) != [] ->
        raise ArgumentError,
              "agent #{inspect(agent.id)} has duplicate depends_on entries: #{inspect(duplicate_values(agent.depends_on))}"

      true ->
        missing_dependencies = Enum.reject(agent.depends_on, &MapSet.member?(agent_ids, &1))

        if missing_dependencies != [] do
          raise ArgumentError,
                "agent #{inspect(agent.id)} depends on missing agent id(s): #{inspect(missing_dependencies)}"
        end
    end
  end

  defp detect_dependency_cycles!(agents) do
    dependencies_by_id = Map.new(agents, &{&1.id, &1.depends_on})

    Enum.each(agents, fn agent ->
      visit_dependency!(agent.id, dependencies_by_id, MapSet.new())
    end)
  end

  defp visit_dependency!(agent_id, dependencies_by_id, visiting) do
    if MapSet.member?(visiting, agent_id) do
      raise ArgumentError,
            "agent dependency graph contains a cycle involving #{inspect(agent_id)}"
    end

    dependencies_by_id
    |> Map.fetch!(agent_id)
    |> Enum.each(fn dependency_id ->
      visit_dependency!(dependency_id, dependencies_by_id, MapSet.put(visiting, agent_id))
    end)
  end

  defp finalizer_from_opts(opts) do
    case Keyword.fetch(opts, :finalizer) do
      :error -> nil
      {:ok, finalizer} -> Agent.new!(finalizer)
    end
  end

  defp maybe_append_agent(agents, nil), do: agents
  defp maybe_append_agent(agents, finalizer), do: agents ++ [finalizer]

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
end
