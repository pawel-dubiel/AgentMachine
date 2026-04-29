defmodule AgentMachine.Orchestrator do
  @moduledoc """
  Public facade for starting and observing agent runs.
  """

  use GenServer

  alias AgentMachine.{Agent, RunServer, RunSupervisor}

  @poll_ms 25

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def run(agent_specs, opts) when is_list(opts) do
    timeout = Keyword.fetch!(opts, :timeout)

    with {:ok, run_id} <- start_run(agent_specs, opts) do
      await_run(run_id, timeout)
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
