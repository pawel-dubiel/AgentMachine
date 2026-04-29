defmodule AgentMachine.RunServer do
  @moduledoc """
  Owns the orchestration state for one supervised run.
  """

  use GenServer

  alias AgentMachine.{AgentResult, AgentRunner}

  def start_link({run_id, agents, finalizer, opts})
      when is_binary(run_id) and is_list(agents) and is_list(opts) do
    GenServer.start_link(__MODULE__, {run_id, agents, finalizer, opts}, name: via_name(run_id))
  end

  def snapshot(pid) when is_pid(pid) do
    GenServer.call(pid, :snapshot)
  end

  def via_name(run_id) when is_binary(run_id) do
    {:via, Registry, {AgentMachine.RunRegistry, {:run, run_id}}}
  end

  @impl true
  def init({run_id, agents, finalizer, opts}) do
    run_context = %{results: %{}, artifacts: %{}}
    {ready_agents, pending_agents} = split_ready_agents(agents, %{})
    initial_events = [run_started_event(run_id)] ++ skills_events(run_id, opts)
    emit_events!(opts, initial_events)
    {tasks, agent_events} = spawn_agents(ready_agents, opts, run_context, nil)
    emit_events!(opts, agent_events)
    events = initial_events ++ agent_events

    run = %{
      id: run_id,
      status: :running,
      agent_order: Enum.map(ready_agents, & &1.id),
      pending_agents: pending_agents,
      tasks: tasks,
      results: %{},
      artifacts: %{},
      events: events,
      finalizer: finalizer,
      finalizer_started: false,
      usage: nil,
      opts: opts,
      step_count: length(agents),
      error: nil,
      started_at: DateTime.utc_now(),
      finished_at: nil
    }

    {:ok, run}
  end

  @impl true
  def handle_call(:snapshot, _from, run) do
    {:reply, run, run}
  end

  @impl true
  def handle_info({ref, %AgentResult{} = result}, run) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    if Map.has_key?(run.tasks, ref) do
      {:noreply, put_result(run, ref, result)}
    else
      {:noreply, run}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, run) do
    if Map.has_key?(run.tasks, ref) do
      task = Map.fetch!(run.tasks, ref)

      result = %AgentResult{
        run_id: run.id,
        agent_id: task.agent_id,
        status: :error,
        attempt: task.attempt,
        error: "agent task exited before returning a result: #{inspect(reason)}",
        started_at: nil,
        finished_at: DateTime.utc_now()
      }

      {:noreply, put_result(run, ref, result)}
    else
      {:noreply, run}
    end
  end

  defp split_ready_agents(agents, results) do
    Enum.split_with(agents, &dependencies_satisfied?(&1, results))
  end

  defp dependencies_satisfied?(agent, results) do
    Enum.all?(agent.depends_on, &Map.has_key?(results, &1))
  end

  defp spawn_agents(agents, opts, run_context, parent_agent_id, attempt \\ 1) do
    run_id = Keyword.fetch!(opts, :run_id)
    task_supervisor = Keyword.fetch!(opts, :task_supervisor)

    agents
    |> Enum.map(fn agent ->
      agent_opts =
        opts
        |> Keyword.put(:attempt, attempt)
        |> Keyword.put(
          :run_context,
          build_agent_context(opts, agent, run_context, parent_agent_id)
        )

      task =
        Task.Supervisor.async_nolink(task_supervisor, AgentRunner, :run, [
          agent,
          agent_opts
        ])

      task_entry = {
        task.ref,
        %{
          pid: task.pid,
          agent: agent,
          agent_id: agent.id,
          attempt: attempt,
          parent_agent_id: parent_agent_id
        }
      }

      event = agent_started_event(run_id, agent.id, parent_agent_id, attempt)

      {task_entry, event}
    end)
    |> Enum.unzip()
    |> then(fn {task_entries, events} -> {Map.new(task_entries), events} end)
  end

  defp put_result(run, ref, result) do
    task = Map.fetch!(run.tasks, ref)
    tasks = Map.delete(run.tasks, ref)

    run =
      %{run | tasks: tasks}
      |> append_stored_events(result.events || [])
      |> append_event(agent_finished_event(run.id, result))

    if should_retry?(run, task, result) do
      retry_agent(run, task, result)
    else
      store_result(run, result)
    end
  end

  defp store_result(run, result) do
    run = %{run | results: Map.put(run.results, result.agent_id, result)}

    case merge_result_artifacts(run, result) do
      {:ok, run} -> continue_run_after_result(run, result)
      {:error, reason} -> fail_run(run, reason)
    end
  end

  defp should_retry?(run, task, %{status: :error}) do
    case Keyword.fetch(run.opts, :max_attempts) do
      :error -> false
      {:ok, max_attempts} -> task.attempt < max_attempts
    end
  end

  defp should_retry?(_run, _task, _result), do: false

  defp retry_agent(run, task, result) do
    next_attempt = task.attempt + 1
    run_context = %{results: run.results, artifacts: run.artifacts}

    {tasks, events} =
      spawn_agents([task.agent], run.opts, run_context, task.parent_agent_id, next_attempt)

    run
    |> Map.update!(:tasks, &Map.merge(&1, tasks))
    |> append_event(
      agent_retry_scheduled_event(run.id, task.agent_id, next_attempt, result.error)
    )
    |> append_events(events)
    |> mark_running()
  end

  defp continue_run_after_result(run, result) do
    cond do
      finalizer_result?(run, result) and has_next_agents?(result) ->
        fail_run(run, "finalizer must not delegate follow-up agents")

      result.status == :ok and has_next_agents?(result) ->
        schedule_next_agents(run, result)
        |> finish_or_fail(run)
        |> start_ready_pending_agents()

      true ->
        start_ready_pending_agents(run)
    end
  end

  defp finish_or_fail({:ok, updated_run}, _run), do: finish_if_idle(updated_run)
  defp finish_or_fail({:error, reason}, run), do: fail_run(run, reason)

  defp start_ready_pending_agents(%{status: :failed} = run), do: run

  defp start_ready_pending_agents(run) do
    {ready_agents, pending_agents} = split_ready_agents(run.pending_agents, run.results)

    if ready_agents == [] do
      finish_if_idle(run)
    else
      run_context = %{results: run.results, artifacts: run.artifacts}
      {new_tasks, events} = spawn_agents(ready_agents, run.opts, run_context, nil)

      run
      |> Map.merge(%{
        tasks: Map.merge(run.tasks, new_tasks),
        pending_agents: pending_agents,
        agent_order: run.agent_order ++ Enum.map(ready_agents, & &1.id)
      })
      |> append_events(events)
      |> finish_if_idle()
    end
  end

  defp schedule_next_agents(run, result) do
    with {:ok, max_steps} <- fetch_max_steps(run.opts),
         {:ok, next_agents} <- validate_next_agents(run, result.next_agents),
         {:ok, step_count} <- reserve_steps(run.step_count, length(next_agents), max_steps) do
      run_context = %{results: run.results, artifacts: run.artifacts}

      {new_tasks, events} = spawn_agents(next_agents, run.opts, run_context, result.agent_id)
      tasks = Map.merge(run.tasks, new_tasks)

      agent_order = run.agent_order ++ Enum.map(next_agents, & &1.id)
      delegation_event = agent_delegation_scheduled_event(run.id, result.agent_id, next_agents)

      {:ok,
       run
       |> Map.merge(%{tasks: tasks, agent_order: agent_order, step_count: step_count})
       |> append_event(delegation_event)
       |> append_events(events)}
    end
  end

  defp finish_if_idle(run) do
    cond do
      map_size(run.tasks) > 0 ->
        mark_running(run)

      run.pending_agents != [] ->
        mark_running(run)

      should_start_finalizer?(run) ->
        start_finalizer(run)

      true ->
        complete_run(run)
    end
  end

  defp mark_running(run) do
    %{run | status: :running, usage: nil, finished_at: nil}
  end

  defp complete_run(run) do
    %{
      run
      | usage: aggregate_usage(run.results),
        status: :completed,
        finished_at: DateTime.utc_now()
    }
    |> append_event(run_completed_event(run.id))
  end

  defp should_start_finalizer?(%{finalizer: nil}), do: false
  defp should_start_finalizer?(%{finalizer_started: true}), do: false
  defp should_start_finalizer?(run), do: not direct_planner_result?(run)

  defp direct_planner_result?(%{results: %{"planner" => %{status: :ok, decision: decision}}}) do
    direct_decision?(decision)
  end

  defp direct_planner_result?(_run), do: false

  defp direct_decision?(%{mode: "direct"}), do: true
  defp direct_decision?(%{"mode" => "direct"}), do: true
  defp direct_decision?(_decision), do: false

  defp finalizer_result?(%{finalizer: nil}, _result), do: false
  defp finalizer_result?(%{finalizer: finalizer}, result), do: result.agent_id == finalizer.id

  defp start_finalizer(run) do
    case reserve_optional_step(run) do
      {:ok, step_count} ->
        run_context = %{results: run.results, artifacts: run.artifacts}
        {tasks, events} = spawn_agents([run.finalizer], run.opts, run_context, nil)

        run
        |> Map.merge(%{
          tasks: tasks,
          agent_order: run.agent_order ++ [run.finalizer.id],
          finalizer_started: true,
          step_count: step_count,
          status: :running,
          usage: nil,
          finished_at: nil
        })
        |> append_events(events)

      {:error, reason} ->
        fail_run(run, reason)
    end
  end

  defp reserve_optional_step(run) do
    case Keyword.fetch(run.opts, :max_steps) do
      :error -> {:ok, run.step_count + 1}
      {:ok, max_steps} -> reserve_steps(run.step_count, 1, max_steps)
    end
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
    |> append_event(run_failed_event(run.id, reason))
  end

  defp has_next_agents?(%AgentResult{next_agents: agents}) when is_list(agents), do: agents != []
  defp has_next_agents?(_result), do: false

  defp merge_result_artifacts(run, %{status: :ok, artifacts: artifacts})
       when is_map(artifacts) and map_size(artifacts) > 0 do
    duplicate_keys = artifacts |> Map.keys() |> Enum.filter(&Map.has_key?(run.artifacts, &1))

    case duplicate_keys do
      [] ->
        {:ok, %{run | artifacts: Map.merge(run.artifacts, artifacts)}}

      keys ->
        {:error, "agent artifacts must not overwrite existing keys: #{inspect(keys)}"}
    end
  end

  defp merge_result_artifacts(run, _result), do: {:ok, run}

  defp build_agent_context(opts, agent, run_context, parent_agent_id) do
    %{
      run_id: Keyword.fetch!(opts, :run_id),
      agent_id: agent.id,
      parent_agent_id: parent_agent_id,
      results: context_results(run_context.results),
      artifacts: run_context.artifacts
    }
  end

  defp context_results(results) do
    Map.new(results, fn {agent_id, result} ->
      {agent_id,
       %{
         status: result.status,
         output: result.output,
         decision: result.decision,
         error: result.error,
         artifacts: result.artifacts || %{},
         tool_results: result.tool_results || %{}
       }}
    end)
  end

  defp append_event(run, event) do
    emit_event!(run.opts, event)
    %{run | events: run.events ++ [event]}
  end

  defp append_events(run, events) do
    emit_events!(run.opts, events)
    %{run | events: run.events ++ events}
  end

  defp append_stored_events(run, events) do
    %{run | events: run.events ++ events}
  end

  defp emit_events!(opts, events), do: Enum.each(events, &emit_event!(opts, &1))

  defp emit_event!(opts, event) do
    case Keyword.fetch(opts, :event_collector) do
      {:ok, collector} ->
        AgentMachine.RunEventCollector.emit(collector, event)

      :error ->
        case Keyword.fetch(opts, :event_sink) do
          :error -> :ok
          {:ok, sink} -> sink.(event)
        end
    end
  end

  defp run_started_event(run_id) do
    %{
      type: :run_started,
      run_id: run_id,
      at: DateTime.utc_now()
    }
  end

  defp skills_events(run_id, opts) do
    mode = Keyword.get(opts, :skills_mode, :off)
    loaded = Keyword.get(opts, :skills_loaded, [])
    selected = Keyword.get(opts, :skills_selected, [])

    if mode == :off do
      []
    else
      [
        %{
          type: :skills_loaded,
          run_id: run_id,
          mode: mode,
          count: length(loaded),
          skills: Enum.map(loaded, &Map.fetch!(&1, :name)),
          at: DateTime.utc_now()
        },
        %{
          type: :skills_selected,
          run_id: run_id,
          mode: mode,
          count: length(selected),
          skills: selected,
          at: DateTime.utc_now()
        }
      ]
    end
  end

  defp agent_started_event(run_id, agent_id, parent_agent_id, attempt) do
    %{
      type: :agent_started,
      run_id: run_id,
      agent_id: agent_id,
      parent_agent_id: parent_agent_id,
      attempt: attempt,
      at: DateTime.utc_now()
    }
  end

  defp agent_finished_event(run_id, result) do
    %{
      type: :agent_finished,
      run_id: run_id,
      agent_id: result.agent_id,
      status: result.status,
      attempt: result.attempt,
      duration_ms: result_duration_ms(result),
      at: result.finished_at || DateTime.utc_now()
    }
  end

  defp agent_retry_scheduled_event(run_id, agent_id, next_attempt, reason) do
    %{
      type: :agent_retry_scheduled,
      run_id: run_id,
      agent_id: agent_id,
      next_attempt: next_attempt,
      reason: reason,
      at: DateTime.utc_now()
    }
  end

  defp agent_delegation_scheduled_event(run_id, agent_id, next_agents) do
    %{
      type: :agent_delegation_scheduled,
      run_id: run_id,
      agent_id: agent_id,
      count: length(next_agents),
      delegated_agent_ids: Enum.map(next_agents, & &1.id),
      at: DateTime.utc_now()
    }
  end

  defp run_completed_event(run_id) do
    %{
      type: :run_completed,
      run_id: run_id,
      at: DateTime.utc_now()
    }
  end

  defp run_failed_event(run_id, reason) do
    %{
      type: :run_failed,
      run_id: run_id,
      reason: reason,
      at: DateTime.utc_now()
    }
  end

  defp result_duration_ms(%{
         started_at: %DateTime{} = started_at,
         finished_at: %DateTime{} = finished_at
       }) do
    DateTime.diff(finished_at, started_at, :millisecond)
  end

  defp result_duration_ms(_result), do: nil

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

      duplicate_values(existing_agent_ids(run) ++ next_ids) != [] ->
        existing_ids = MapSet.new(existing_agent_ids(run))

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

  defp existing_agent_ids(%{
         agent_order: agent_order,
         pending_agents: pending_agents,
         finalizer: nil
       }) do
    agent_order ++ Enum.map(pending_agents, & &1.id)
  end

  defp existing_agent_ids(%{
         agent_order: agent_order,
         pending_agents: pending_agents,
         finalizer: finalizer
       }) do
    Enum.uniq(agent_order ++ Enum.map(pending_agents, & &1.id) ++ [finalizer.id])
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
