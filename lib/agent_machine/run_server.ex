defmodule AgentMachine.RunServer do
  @moduledoc """
  Owns the orchestration state for one supervised run.
  """

  use GenServer

  alias AgentMachine.{AgentResult, AgentRunner, ContextBudget, ContextCompactor}
  alias AgentMachine.Tools.PathGuard

  @default_heartbeat_interval_ms 10_000
  @max_children_per_agent 8
  @max_spawn_depth 3
  @runtime_health_events MapSet.new([
                           :provider_request_started,
                           :context_budget,
                           :provider_request_finished,
                           :provider_request_failed,
                           :assistant_delta,
                           :assistant_done,
                           :tool_call_started,
                           :tool_call_finished,
                           :tool_call_failed
                         ])

  def start_link({run_id, agents, finalizer, opts})
      when is_binary(run_id) and is_list(agents) and is_list(opts) do
    GenServer.start_link(__MODULE__, {run_id, agents, finalizer, opts}, name: via_name(run_id))
  end

  def snapshot(pid) when is_pid(pid) do
    GenServer.call(pid, :snapshot)
  end

  def timeout(pid, reason, metadata \\ %{}) when is_pid(pid) and is_binary(reason) do
    GenServer.call(pid, {:timeout, reason, metadata})
  end

  def extend_lease(pid, metadata) when is_pid(pid) and is_map(metadata) do
    GenServer.call(pid, {:extend_lease, metadata})
  end

  def record_runtime_health(run_id, event) when is_binary(run_id) and is_map(event) do
    if runtime_health_event?(event) do
      case Registry.lookup(AgentMachine.RunRegistry, {:run, run_id}) do
        [{pid, _value}] -> GenServer.cast(pid, {:runtime_health, event})
        [] -> :ok
      end
    else
      :ok
    end
  end

  def via_name(run_id) when is_binary(run_id) do
    {:via, Registry, {AgentMachine.RunRegistry, {:run, run_id}}}
  end

  @impl true
  def init({run_id, agents, finalizer, opts}) do
    agent_graph = initial_agent_graph(agents)
    run_context = empty_run_context(agent_graph)
    {ready_agents, pending_agents} = split_ready_agents(agents, %{})
    initial_events = [run_started_event(run_id)] ++ skills_events(run_id, opts)
    emit_events!(opts, initial_events)
    {tasks, agent_events} = spawn_agents(ready_agents, opts, run_context, agent_graph)
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
      artifact_sources: %{},
      compacted_context: nil,
      context_compaction_count: 0,
      context_compaction_usages: [],
      events: events,
      finalizer: finalizer,
      finalizer_started: false,
      agent_graph: agent_graph,
      usage: nil,
      opts: opts,
      step_count: length(agents),
      error: nil,
      started_at: DateTime.utc_now(),
      finished_at: nil,
      heartbeat_interval_ms: heartbeat_interval_ms_from_opts(opts),
      health_event_count: health_event_count(events),
      last_health_at: last_event_time(events)
    }

    schedule_heartbeat(run)
    {:ok, run}
  end

  @impl true
  def handle_call(:snapshot, _from, run) do
    {:reply, run, run}
  end

  def handle_call({:timeout, reason, metadata}, _from, run) do
    run = timeout_run(run, reason, metadata)
    {:reply, run, run}
  end

  def handle_call({:extend_lease, metadata}, _from, run) do
    run = append_event(run, run_lease_extended_event(run.id, metadata))
    {:reply, :ok, run}
  end

  @impl true
  def handle_cast({:runtime_health, event}, %{status: :running} = run) do
    {:noreply, record_health(run, event)}
  end

  def handle_cast({:runtime_health, _event}, run) do
    {:noreply, run}
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

  def handle_info(:agent_heartbeat, run) do
    run =
      if run.status == :running and map_size(run.tasks) > 0 do
        run
        |> append_events(agent_heartbeat_events(run))
      else
        run
      end

    schedule_heartbeat(run)
    {:noreply, run}
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

  defp spawn_agents(agents, opts, run_context, agent_graph, attempt \\ 1) do
    run_id = Keyword.fetch!(opts, :run_id)
    task_supervisor = Keyword.fetch!(opts, :task_supervisor)

    agents
    |> Enum.map(fn agent ->
      graph_entry = Map.fetch!(agent_graph, agent.id)
      parent_agent_id = Map.get(graph_entry, :parent_agent_id)
      agent_opts = effective_agent_opts!(agent, opts, graph_entry)

      agent_opts =
        agent_opts
        |> Keyword.put(:attempt, attempt)
        |> Keyword.put(
          :run_context,
          build_agent_context(agent_opts, agent, run_context, graph_entry)
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
          parent_agent_id: parent_agent_id,
          graph_entry: graph_entry
        }
      }

      event = agent_started_event(run_id, agent.id, parent_agent_id, attempt, graph_entry)

      {task_entry, event}
    end)
    |> Enum.unzip()
    |> then(fn {task_entries, events} -> {Map.new(task_entries), events} end)
  end

  defp effective_agent_opts!(agent, opts, graph_entry) do
    opts = Keyword.put(opts, :agent_event_metadata, event_agent_metadata(graph_entry))

    case swarm_variant_workspace(agent) do
      nil ->
        opts

      workspace ->
        if Keyword.has_key?(opts, :tool_root) do
          root = PathGuard.root!(opts)
          workspace_root = ensure_workspace_dir!(root, workspace)
          Keyword.put(opts, :tool_root, workspace_root)
        else
          opts
        end
    end
  end

  defp swarm_variant_workspace(%{metadata: metadata}) when is_map(metadata) do
    if metadata_value(metadata, :agent_machine_role) == "swarm_variant" do
      case metadata_value(metadata, :workspace) do
        workspace when is_binary(workspace) and byte_size(workspace) > 0 -> workspace
        _other -> nil
      end
    end
  end

  defp swarm_variant_workspace(_agent), do: nil

  defp ensure_workspace_dir!(root, workspace) do
    target = PathGuard.target!(root, workspace)

    if target == root do
      raise ArgumentError, "swarm variant workspace must not be the tool root"
    end

    target
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.reduce(root, fn part, current ->
      ensure_workspace_part!(root, current, part)
    end)
  end

  defp ensure_workspace_part!(_root, _current, part) when part in ["", ".", ".."] do
    raise ArgumentError, "swarm variant workspace contains invalid path segment: #{inspect(part)}"
  end

  defp ensure_workspace_part!(root, current, part) do
    next = Path.join(current, part)

    case File.lstat(next) do
      {:ok, %{type: :symlink}} ->
        raise ArgumentError,
              "swarm variant workspace path must not contain symlinks: #{inspect(next)}"

      {:ok, %{type: :directory}} ->
        PathGuard.existing_target!(root, next)

      {:ok, %{type: type}} ->
        raise ArgumentError,
              "swarm variant workspace path must be a directory or missing, got: #{inspect(type)}"

      {:error, :enoent} ->
        File.mkdir!(next)
        PathGuard.existing_target!(root, next)

      {:error, reason} ->
        raise ArgumentError,
              "could not inspect swarm variant workspace #{inspect(next)}: #{inspect(reason)}"
    end
  end

  defp put_result(run, ref, result) do
    task = Map.fetch!(run.tasks, ref)
    tasks = Map.delete(run.tasks, ref)

    run =
      %{run | tasks: tasks}
      |> append_stored_events(result.events || [])
      |> append_event(agent_finished_event(run.id, result, task))

    if should_retry?(run, task, result) do
      retry_agent(run, task, result)
    else
      store_result(run, task.agent, result)
    end
  end

  defp store_result(run, _agent, result) do
    run = %{run | results: Map.put(run.results, result.agent_id, result)}

    case merge_result_artifacts(run, result) do
      {:ok, run} ->
        continue_run_after_result(run, result)

      {:error, reason} ->
        fail_run(run, reason)
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
    run_context = run_context(run)

    {tasks, events} =
      spawn_agents([task.agent], run.opts, run_context, run.agent_graph, next_attempt)

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
  defp finish_or_fail({:failed_run, failed_run}, _run), do: failed_run
  defp finish_or_fail({:error, reason}, run), do: fail_run(run, reason)

  defp start_ready_pending_agents(%{status: status} = run) when status in [:failed, :timeout],
    do: run

  defp start_ready_pending_agents(run) do
    {ready_agents, pending_agents} = split_ready_agents(run.pending_agents, run.results)

    if ready_agents == [] do
      finish_if_idle(run)
    else
      case maybe_compact_before_spawn(run, ready_agents, nil) do
        {:ok, run} ->
          run_context = run_context(run)
          {new_tasks, events} = spawn_agents(ready_agents, run.opts, run_context, run.agent_graph)

          run
          |> Map.merge(%{
            tasks: Map.merge(run.tasks, new_tasks),
            pending_agents: pending_agents,
            agent_order: run.agent_order ++ Enum.map(ready_agents, & &1.id)
          })
          |> append_events(events)
          |> finish_if_idle()

        {:error, failed_run} ->
          failed_run
      end
    end
  end

  defp schedule_next_agents(run, result) do
    with {:ok, max_steps} <- fetch_max_steps(run.opts),
         {:ok, next_agents} <- validate_next_agents(run, result.next_agents, result.agent_id),
         {:ok, step_count} <- reserve_steps(run.step_count, length(next_agents), max_steps),
         run <- register_delegated_agents(run, next_agents, result.agent_id),
         {ready_agents, pending_next_agents} <- split_ready_agents(next_agents, run.results),
         {:ok, run} <- maybe_compact_before_spawn(run, ready_agents, result.agent_id) do
      run_context = run_context(run)

      {new_tasks, events} = spawn_agents(ready_agents, run.opts, run_context, run.agent_graph)
      tasks = Map.merge(run.tasks, new_tasks)

      agent_order = run.agent_order ++ Enum.map(ready_agents, & &1.id)
      pending_agents = run.pending_agents ++ pending_next_agents

      delegation_event =
        agent_delegation_scheduled_event(run.id, result.agent_id, next_agents, run)

      {:ok,
       run
       |> Map.merge(%{
         tasks: tasks,
         pending_agents: pending_agents,
         agent_order: agent_order,
         step_count: step_count
       })
       |> append_event(delegation_event)
       |> append_events(events)}
    else
      {:error, %{} = failed_run} -> {:failed_run, failed_run}
      other -> other
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
      | usage: aggregate_usage(run),
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
        run = register_finalizer(run)

        case maybe_compact_before_spawn(run, [run.finalizer], nil) do
          {:ok, run} ->
            run_context = run_context(run)

            {tasks, events} =
              spawn_agents([run.finalizer], run.opts, run_context, run.agent_graph)

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

          {:error, failed_run} ->
            failed_run
        end

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
    kill_active_work(run)

    %{
      run
      | tasks: %{},
        status: :failed,
        usage: aggregate_usage(run),
        error: reason,
        finished_at: DateTime.utc_now()
    }
    |> append_event(run_failed_event(run.id, reason))
  end

  defp timeout_run(%{status: status} = run, _reason, _metadata)
       when status in [:completed, :failed, :timeout],
       do: run

  defp timeout_run(run, reason, metadata) do
    kill_active_work(run)

    %{
      run
      | tasks: %{},
        status: :timeout,
        usage: aggregate_usage(run),
        error: reason,
        finished_at: DateTime.utc_now()
    }
    |> append_event(run_timed_out_event(run.id, reason, metadata))
  end

  defp has_next_agents?(%AgentResult{next_agents: agents}) when is_list(agents), do: agents != []
  defp has_next_agents?(_result), do: false

  defp merge_result_artifacts(run, %{status: :ok, artifacts: artifacts} = result)
       when is_map(artifacts) and map_size(artifacts) > 0 do
    duplicate_keys = artifacts |> Map.keys() |> Enum.filter(&Map.has_key?(run.artifacts, &1))

    case duplicate_keys do
      [] ->
        source_updates = Map.new(Map.keys(artifacts), &{&1, result.agent_id})

        {:ok,
         %{
           run
           | artifacts: Map.merge(run.artifacts, artifacts),
             artifact_sources: Map.merge(run.artifact_sources, source_updates)
         }}

      keys ->
        {:error, "agent artifacts must not overwrite existing keys: #{inspect(keys)}"}
    end
  end

  defp merge_result_artifacts(run, _result), do: {:ok, run}

  defp maybe_compact_before_spawn(run, [], _parent_agent_id), do: {:ok, run}

  defp maybe_compact_before_spawn(run, agents, parent_agent_id) do
    if should_measure_compaction_budget?(run) and compactable_result_ids(run) != [] do
      case compaction_budget_decision(run, agents, parent_agent_id) do
        {:compact, agent} ->
          compact_run_context(run, agent)

        {:skip_unknown, agent_id, measurement} ->
          {:ok,
           append_event(
             run,
             run_context_compaction_skipped_event(
               run.id,
               run.context_compaction_count + 1,
               agent_id,
               Map.get(measurement, :reason, "unknown_context_budget"),
               measurement
             )
           )}

        :continue ->
          {:ok, run}
      end
    else
      {:ok, run}
    end
  end

  defp should_measure_compaction_budget?(run) do
    run_context_compaction_enabled?(run) and
      run.context_compaction_count < max_context_compactions!(run)
  end

  defp compaction_budget_decision(run, agents, parent_agent_id) do
    measurements =
      Enum.map(agents, fn agent ->
        {agent, compaction_budget_measurement(run, agent, parent_agent_id)}
      end)

    compact_percent = Keyword.fetch!(run.opts, :run_context_compact_percent)

    case threshold_measurement(measurements, compact_percent) do
      {agent, _measurement} ->
        {:compact, agent}

      nil ->
        unknown_budget_decision(measurements)
    end
  end

  defp threshold_measurement(measurements, compact_percent) do
    Enum.find(measurements, fn {_agent, measurement} ->
      ContextBudget.threshold_reached?(measurement, compact_percent)
    end)
  end

  defp unknown_budget_decision(measurements) do
    case Enum.find(measurements, fn {_agent, measurement} -> measurement.status == "unknown" end) do
      {agent, measurement} -> {:skip_unknown, agent.id, measurement}
      nil -> :continue
    end
  end

  defp compaction_budget_measurement(run, agent, parent_agent_id) do
    run_context = run_context(run)
    graph_entry = Map.get(run.agent_graph, agent.id, agent_graph_entry(agent, parent_agent_id, 0))

    opts =
      run.opts
      |> Keyword.put(:attempt, 1)
      |> Keyword.put(
        :run_context,
        build_agent_context(run.opts, agent, run_context, graph_entry)
      )

    ContextBudget.measure(agent, opts)
  end

  defp run_context_compaction_enabled?(run),
    do: Keyword.get(run.opts, :run_context_compaction) == :on

  defp max_context_compactions!(run), do: Keyword.fetch!(run.opts, :max_context_compactions)

  defp compact_run_context(run, agent) do
    compactable_ids = compactable_result_ids(run)

    if compactable_ids == [] do
      {:ok, run}
    else
      started_event =
        run_context_compaction_started_event(
          run.id,
          run.context_compaction_count + 1,
          compactable_ids
        )

      run = append_event(run, started_event)

      try do
        result =
          ContextCompactor.compact_run_context!(
            run_context(run),
            agent,
            run.opts ++ [allowed_covered_items: compactable_ids]
          )

        covered_items = result.covered_items
        compacted_context = merged_compacted_context(run, result)

        finished_event =
          run_context_compaction_finished_event(
            run.id,
            run.context_compaction_count + 1,
            covered_items,
            result.usage
          )

        run =
          run
          |> Map.put(:compacted_context, compacted_context)
          |> Map.update!(:context_compaction_count, &(&1 + 1))
          |> Map.update!(:context_compaction_usages, &(&1 ++ [result.usage]))
          |> append_event(finished_event)

        {:ok, run}
      rescue
        exception ->
          reason = Exception.message(exception)

          run =
            run
            |> append_event(
              run_context_compaction_failed_event(
                run.id,
                run.context_compaction_count + 1,
                compactable_ids,
                reason
              )
            )
            |> fail_run(reason)

          {:error, run}
      end
    end
  end

  defp compactable_result_ids(run) do
    covered = compacted_result_ids(run.compacted_context)

    run.results
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(covered, &1))
  end

  defp merged_compacted_context(run, result) do
    previous_covered =
      run.compacted_context
      |> compacted_result_ids()
      |> MapSet.to_list()

    %{
      summary: result.summary,
      covered_items: Enum.uniq(previous_covered ++ result.covered_items),
      compaction_count: run.context_compaction_count + 1,
      compacted_at: DateTime.utc_now()
    }
  end

  defp compacted_result_ids(nil), do: MapSet.new()

  defp compacted_result_ids(%{covered_items: items}) when is_list(items),
    do: MapSet.new(items)

  defp compacted_result_ids(%{"covered_items" => items}) when is_list(items),
    do: MapSet.new(items)

  defp compacted_result_ids(_context), do: MapSet.new()

  defp empty_run_context(agent_graph) do
    %{
      results: %{},
      artifacts: %{},
      artifact_sources: %{},
      compacted_context: nil,
      agent_graph: context_agent_graph(agent_graph)
    }
  end

  defp initial_agent_graph(agents) do
    Map.new(agents, fn agent -> {agent.id, agent_graph_entry(agent, nil, 0)} end)
  end

  defp register_delegated_agents(run, agents, parent_agent_id) do
    parent_depth = run.agent_graph |> Map.get(parent_agent_id, %{}) |> Map.get(:spawn_depth, 0)
    child_depth = parent_depth + 1

    updates =
      Map.new(agents, fn agent ->
        {agent.id, agent_graph_entry(agent, parent_agent_id, child_depth)}
      end)

    %{run | agent_graph: Map.merge(run.agent_graph, updates)}
  end

  defp register_finalizer(%{finalizer: nil} = run), do: run

  defp register_finalizer(run) do
    if Map.has_key?(run.agent_graph, run.finalizer.id) do
      run
    else
      %{
        run
        | agent_graph:
            Map.put(run.agent_graph, run.finalizer.id, agent_graph_entry(run.finalizer, nil, 0))
      }
    end
  end

  defp agent_graph_entry(agent, parent_agent_id, spawn_depth) do
    %{
      agent_id: agent.id,
      parent_agent_id: parent_agent_id,
      depends_on: agent.depends_on,
      spawn_depth: spawn_depth
    }
    |> Map.merge(agent_metadata_summary(agent.metadata))
    |> reject_nil_values()
  end

  defp context_agent_graph(agent_graph) when is_map(agent_graph) do
    Map.new(agent_graph, fn {agent_id, entry} -> {agent_id, entry} end)
  end

  defp agent_metadata_summary(metadata) when is_map(metadata) do
    %{
      agent_machine_role: metadata_value(metadata, :agent_machine_role),
      swarm_id: metadata_value(metadata, :swarm_id),
      variant_id: metadata_value(metadata, :variant_id),
      workspace: metadata_value(metadata, :workspace)
    }
  end

  defp agent_metadata_summary(_metadata), do: %{}

  defp metadata_value(metadata, key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp run_context(run) do
    covered = compacted_result_ids(run.compacted_context)

    %{
      results: context_results(run.results, covered),
      artifacts: context_artifacts(run.artifacts, run.artifact_sources, covered),
      artifact_sources: context_artifact_sources(run.artifact_sources, covered),
      compacted_context: run.compacted_context,
      agent_graph: context_agent_graph(run.agent_graph)
    }
  end

  defp build_agent_context(opts, agent, run_context, graph_entry) do
    context = %{
      run_id: Keyword.fetch!(opts, :run_id),
      agent_id: agent.id,
      parent_agent_id: Map.get(graph_entry, :parent_agent_id),
      agent: graph_entry,
      agent_graph: run_context.agent_graph,
      results: run_context.results,
      artifacts: run_context.artifacts
    }

    if is_nil(run_context.compacted_context) do
      context
    else
      Map.put(context, :compacted_context, run_context.compacted_context)
    end
  end

  defp context_results(results, covered) do
    results
    |> Enum.reject(fn {agent_id, _result} -> MapSet.member?(covered, agent_id) end)
    |> Map.new(fn {agent_id, result} ->
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

  defp context_artifacts(artifacts, sources, covered) do
    Map.reject(artifacts, fn {key, _value} ->
      source = Map.get(sources, key)
      is_binary(source) and MapSet.member?(covered, source)
    end)
  end

  defp context_artifact_sources(sources, covered) do
    Map.reject(sources, fn {_key, source} ->
      is_binary(source) and MapSet.member?(covered, source)
    end)
  end

  defp append_event(run, event) do
    emit_event!(run.opts, event)

    run
    |> Map.update!(:events, &(&1 ++ [event]))
    |> record_health(event)
  end

  defp append_events(run, events) do
    emit_events!(run.opts, events)

    run
    |> Map.update!(:events, &(&1 ++ events))
    |> record_health(events)
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

  defp record_health(run, events) when is_list(events) do
    Enum.reduce(events, run, &record_health(&2, &1))
  end

  defp record_health(run, event) when is_map(event) do
    if health_event?(event) do
      %{
        run
        | health_event_count: run.health_event_count + 1,
          last_health_at: Map.get(event, :at) || DateTime.utc_now()
      }
    else
      run
    end
  end

  defp health_event?(%{type: :run_lease_extended}), do: false
  defp health_event?(%{type: type}) when is_atom(type), do: true
  defp health_event?(_event), do: false

  defp runtime_health_event?(%{type: type}) when is_atom(type),
    do: MapSet.member?(@runtime_health_events, type)

  defp runtime_health_event?(_event), do: false

  defp health_event_count(events) do
    Enum.count(events, &health_event?/1)
  end

  defp last_event_time(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(&Map.get(&1, :at))
    |> Kernel.||(DateTime.utc_now())
  end

  defp schedule_heartbeat(%{status: :running, heartbeat_interval_ms: interval_ms})
       when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :agent_heartbeat, interval_ms)
    :ok
  end

  defp schedule_heartbeat(_run), do: :ok

  defp heartbeat_interval_ms_from_opts(opts) do
    case Keyword.fetch(opts, :heartbeat_interval_ms) do
      :error ->
        @default_heartbeat_interval_ms

      {:ok, false} ->
        false

      {:ok, interval_ms} when is_integer(interval_ms) and interval_ms > 0 ->
        interval_ms

      {:ok, interval_ms} ->
        raise ArgumentError,
              ":heartbeat_interval_ms must be a positive integer or false, got: #{inspect(interval_ms)}"
    end
  end

  defp agent_heartbeat_events(run) do
    Enum.map(run.tasks, fn {_ref, task} ->
      %{
        type: :agent_heartbeat,
        run_id: run.id,
        agent_id: task.agent_id,
        parent_agent_id: task.parent_agent_id,
        attempt: task.attempt,
        status: :running,
        at: DateTime.utc_now()
      }
      |> Map.merge(event_agent_metadata(task.graph_entry))
    end)
  end

  defp kill_active_work(run) do
    Enum.each(run.tasks, fn {_ref, task} ->
      Process.exit(task.pid, :kill)
    end)

    stop_tool_sessions(run.opts)
  end

  defp stop_tool_sessions(opts) do
    case Keyword.fetch(opts, :tool_session_supervisor) do
      {:ok, supervisor} ->
        supervisor
        |> safe_supervisor_children()
        |> Enum.each(&terminate_tool_session_child(supervisor, &1))

      :error ->
        :ok
    end
  end

  defp terminate_tool_session_child(supervisor, {_id, pid, _type, _modules}) when is_pid(pid) do
    DynamicSupervisor.terminate_child(supervisor, pid)
  end

  defp terminate_tool_session_child(_supervisor, _child), do: :ok

  defp safe_supervisor_children(supervisor) do
    DynamicSupervisor.which_children(supervisor)
  catch
    :exit, _reason -> []
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

  defp agent_started_event(run_id, agent_id, parent_agent_id, attempt, graph_entry) do
    %{
      type: :agent_started,
      run_id: run_id,
      agent_id: agent_id,
      parent_agent_id: parent_agent_id,
      attempt: attempt,
      at: DateTime.utc_now()
    }
    |> Map.merge(event_agent_metadata(graph_entry))
  end

  defp agent_finished_event(run_id, result, task) do
    %{
      type: :agent_finished,
      run_id: run_id,
      agent_id: result.agent_id,
      parent_agent_id: task.parent_agent_id,
      status: result.status,
      attempt: result.attempt,
      duration_ms: result_duration_ms(result),
      at: result.finished_at || DateTime.utc_now()
    }
    |> Map.merge(event_agent_metadata(task.graph_entry))
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

  defp agent_delegation_scheduled_event(run_id, agent_id, next_agents, run) do
    %{
      type: :agent_delegation_scheduled,
      run_id: run_id,
      agent_id: agent_id,
      count: length(next_agents),
      delegated_agent_ids: Enum.map(next_agents, & &1.id),
      delegated_agents: Enum.map(next_agents, &Map.fetch!(run.agent_graph, &1.id)),
      at: DateTime.utc_now()
    }
  end

  defp event_agent_metadata(graph_entry) when is_map(graph_entry) do
    Map.take(graph_entry, [
      :agent_machine_role,
      :swarm_id,
      :variant_id,
      :workspace,
      :spawn_depth
    ])
  end

  defp event_agent_metadata(_graph_entry), do: %{}

  defp run_context_compaction_started_event(run_id, compaction_count, covered_items) do
    %{
      type: :run_context_compaction_started,
      run_id: run_id,
      compaction_count: compaction_count,
      count: length(covered_items),
      covered_items: covered_items,
      at: DateTime.utc_now()
    }
  end

  defp run_context_compaction_finished_event(run_id, compaction_count, covered_items, usage) do
    %{
      type: :run_context_compaction_finished,
      run_id: run_id,
      compaction_count: compaction_count,
      count: length(covered_items),
      covered_items: covered_items,
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      total_tokens: usage.total_tokens,
      at: DateTime.utc_now()
    }
  end

  defp run_context_compaction_failed_event(run_id, compaction_count, covered_items, reason) do
    %{
      type: :run_context_compaction_failed,
      run_id: run_id,
      compaction_count: compaction_count,
      count: length(covered_items),
      covered_items: covered_items,
      reason: reason,
      at: DateTime.utc_now()
    }
  end

  defp run_context_compaction_skipped_event(
         run_id,
         compaction_count,
         agent_id,
         reason,
         measurement
       ) do
    %{
      type: :run_context_compaction_skipped,
      run_id: run_id,
      compaction_count: compaction_count,
      agent_id: agent_id,
      reason: reason,
      at: DateTime.utc_now()
    }
    |> Map.merge(
      Map.take(measurement, [
        :measurement,
        :status,
        :model,
        :used_tokens,
        :context_window_tokens,
        :reserved_output_tokens,
        :available_tokens,
        :used_percent,
        :remaining_percent
      ])
    )
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

  defp run_lease_extended_event(run_id, metadata) do
    %{
      type: :run_lease_extended,
      run_id: run_id,
      reason: Map.fetch!(metadata, :reason),
      idle_timeout_ms: Map.fetch!(metadata, :idle_timeout_ms),
      hard_timeout_ms: Map.fetch!(metadata, :hard_timeout_ms),
      elapsed_ms: Map.fetch!(metadata, :elapsed_ms),
      remaining_idle_ms: Map.fetch!(metadata, :remaining_idle_ms),
      remaining_hard_ms: Map.fetch!(metadata, :remaining_hard_ms),
      at: DateTime.utc_now()
    }
  end

  defp run_timed_out_event(run_id, reason, metadata) do
    %{
      type: :run_timed_out,
      run_id: run_id,
      reason: reason,
      idle_timeout_ms: Map.fetch!(metadata, :idle_timeout_ms),
      hard_timeout_ms: Map.fetch!(metadata, :hard_timeout_ms),
      elapsed_ms: Map.fetch!(metadata, :elapsed_ms),
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

  defp validate_next_agents(run, next_agents, parent_agent_id) do
    next_ids = Enum.map(next_agents, & &1.id)

    with :ok <- validate_child_count(next_agents),
         :ok <- validate_spawn_depth(run, parent_agent_id),
         :ok <- validate_next_agent_ids(run, next_ids),
         :ok <- validate_next_agent_dependencies(run, next_agents),
         :ok <- validate_next_agent_cycles(next_agents) do
      {:ok, next_agents}
    end
  end

  defp validate_child_count(next_agents) do
    if length(next_agents) <= @max_children_per_agent do
      :ok
    else
      {:error,
       "delegated agent count exceeds max children per agent #{@max_children_per_agent}: #{length(next_agents)} requested"}
    end
  end

  defp validate_spawn_depth(run, parent_agent_id) do
    parent_depth = run.agent_graph |> Map.get(parent_agent_id, %{}) |> Map.get(:spawn_depth, 0)
    child_depth = parent_depth + 1

    if child_depth <= @max_spawn_depth do
      :ok
    else
      {:error,
       "delegated agent spawn depth would exceed max depth #{@max_spawn_depth}: #{child_depth} requested"}
    end
  end

  defp validate_next_agent_ids(run, next_ids) do
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
        :ok
    end
  end

  defp validate_next_agent_dependencies(run, next_agents) do
    known_ids = MapSet.new(Map.keys(run.agent_graph))
    next_ids = MapSet.new(Enum.map(next_agents, & &1.id))
    allowed_ids = MapSet.union(known_ids, next_ids)

    Enum.reduce_while(next_agents, :ok, fn agent, :ok ->
      case validate_next_agent_dependency(agent, allowed_ids) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_next_agent_dependency(agent, allowed_ids) do
    missing_dependencies = Enum.reject(agent.depends_on, &MapSet.member?(allowed_ids, &1))

    cond do
      agent.id in agent.depends_on ->
        {:error, "delegated agent #{inspect(agent.id)} must not depend on itself"}

      duplicate_values(agent.depends_on) != [] ->
        {:error,
         "delegated agent #{inspect(agent.id)} has duplicate depends_on entries: #{inspect(duplicate_values(agent.depends_on))}"}

      missing_dependencies != [] ->
        {:error,
         "delegated agent #{inspect(agent.id)} depends on missing agent id(s): #{inspect(missing_dependencies)}"}

      true ->
        :ok
    end
  end

  defp validate_next_agent_cycles(next_agents) do
    next_ids = MapSet.new(Enum.map(next_agents, & &1.id))

    dependencies_by_id =
      Map.new(next_agents, fn agent ->
        {agent.id, Enum.filter(agent.depends_on, &MapSet.member?(next_ids, &1))}
      end)

    Enum.reduce_while(next_agents, :ok, fn agent, :ok ->
      case visit_next_dependency(agent.id, dependencies_by_id, MapSet.new()) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp visit_next_dependency(agent_id, dependencies_by_id, visiting) do
    if MapSet.member?(visiting, agent_id) do
      {:error, "delegated agent dependency graph contains a cycle involving #{inspect(agent_id)}"}
    else
      dependencies_by_id
      |> Map.fetch!(agent_id)
      |> visit_next_dependency_children(dependencies_by_id, MapSet.put(visiting, agent_id))
    end
  end

  defp visit_next_dependency_children(dependency_ids, dependencies_by_id, visiting) do
    Enum.reduce_while(dependency_ids, :ok, fn dependency_id, :ok ->
      case visit_next_dependency(dependency_id, dependencies_by_id, visiting) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
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

  defp existing_agent_ids(%{agent_graph: agent_graph, finalizer: nil}), do: Map.keys(agent_graph)

  defp existing_agent_ids(%{agent_graph: agent_graph, finalizer: finalizer}) do
    Enum.uniq(Map.keys(agent_graph) ++ [finalizer.id])
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

  defp aggregate_usage(%{results: results, context_compaction_usages: compaction_usages}) do
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
    |> add_compaction_usage(compaction_usages)
  end

  defp add_compaction_usage(usage, compaction_usages) do
    Enum.reduce(compaction_usages, usage, fn compaction_usage, acc ->
      %{
        acc
        | input_tokens: acc.input_tokens + compaction_usage.input_tokens,
          output_tokens: acc.output_tokens + compaction_usage.output_tokens,
          total_tokens: acc.total_tokens + compaction_usage.total_tokens,
          cost_usd: acc.cost_usd + compaction_usage.cost_usd
      }
    end)
  end
end
