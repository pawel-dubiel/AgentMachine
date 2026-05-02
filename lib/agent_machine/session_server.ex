defmodule AgentMachine.SessionServer do
  @moduledoc """
  Owns one long-lived interactive AgentMachine session.
  """

  use GenServer

  alias AgentMachine.{
    AgentTask,
    CapabilityRequired,
    ClientRunner,
    Orchestrator,
    RunSpec,
    SessionProtocol,
    SessionTranscript,
    SessionWriter,
    ToolHarness,
    ToolPolicy,
    WorkflowOptions,
    WorkflowRouter
  }

  @agent_output_tail_limit 20

  def start_link(opts) when is_list(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via_name(session_id))
  end

  def user_message(pid, command) when is_pid(pid) and is_map(command) do
    GenServer.call(pid, {:user_message, command})
  end

  def spawn_agent(pid, input) when is_pid(pid) and is_map(input) do
    GenServer.call(pid, {:spawn_agent, input}, :infinity)
  end

  def send_agent_message(pid, input) when is_pid(pid) and is_map(input) do
    GenServer.call(pid, {:send_agent_message, input}, :infinity)
  end

  def read_agent_output(pid, input) when is_pid(pid) and is_map(input) do
    GenServer.call(pid, {:read_agent_output, input})
  end

  def list_agents(pid) when is_pid(pid) do
    GenServer.call(pid, :list_agents)
  end

  def cancel_agent(pid, input) when is_pid(pid) and is_map(input) do
    GenServer.call(pid, {:cancel_agent, input})
  end

  def via_name(session_id) when is_binary(session_id) do
    {:via, Registry, {AgentMachine.RunRegistry, {:session, session_id}}}
  end

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id) |> SessionTranscript.validate_session_id!()
    session_dir = require_non_empty_binary!(Keyword.fetch!(opts, :session_dir), :session_dir)
    writer = Keyword.fetch!(opts, :writer)
    permission_control = Keyword.get(opts, :permission_control)

    SessionTranscript.append_session!(session_dir, session_id, %{
      type: "metadata",
      session_id: session_id,
      event: "session_started"
    })

    {:ok,
     %{
       session_id: session_id,
       session_dir: session_dir,
       writer: writer,
       permission_control: permission_control,
       command_ids: MapSet.new(),
       user_message_tasks: %{},
       coordinator_tasks: %{},
       agents: %{},
       names: %{},
       agent_seq: 0,
       current_attrs: nil,
       current_session_tool_opts: nil
     }}
  end

  @impl true
  def handle_call({:user_message, command}, _from, state) do
    with :ok <- unique_command_id(state, command.message_id),
         {:ok, task} <- start_user_message_routing(command, state) do
      state =
        state
        |> put_command_id(command.message_id)
        |> put_in([:user_message_tasks, task.ref], command)
        |> Map.put(:current_attrs, command.run)
        |> Map.put(:current_session_tool_opts, command.session_tool_opts)

      {:reply, {:ok, %{status: "started", message_id: command.message_id}}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:spawn_agent, input}, from, state) do
    case do_spawn_agent(input, from, state) do
      {:reply, reply, state} -> {:reply, reply, state}
      {:noreply, state} -> {:noreply, state}
    end
  end

  def handle_call({:send_agent_message, input}, _from, state) do
    case do_send_agent_message(input, state) do
      {:ok, reply, state} -> {:reply, {:ok, reply}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:read_agent_output, input}, _from, state) do
    case resolve_agent(input, state) do
      {:ok, agent} -> {:reply, {:ok, output_payload(agent, input, state)}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:list_agents, _from, state) do
    agents =
      state.agents
      |> Map.values()
      |> Enum.sort_by(& &1.created_at, fn left, right ->
        DateTime.compare(left, right) != :gt
      end)
      |> Enum.map(&public_agent/1)

    {:reply, {:ok, %{agents: agents}}, state}
  end

  def handle_call({:cancel_agent, input}, _from, state) do
    case resolve_agent(input, state) do
      {:ok, %{status: :running, task_pid: pid} = agent} when is_pid(pid) ->
        Process.exit(pid, :kill)

        agent = %{
          agent
          | status: :stopped,
            task_ref: nil,
            task_pid: nil,
            error: Map.get(input, "reason", "cancelled")
        }

        state = put_agent(state, agent)
        write_agent_event(state, :session_agent_cancelled, agent, %{reason: agent.error})
        {:reply, {:ok, public_agent(agent)}, state}

      {:ok, agent} ->
        {:reply, {:error, "agent #{agent.id} is not running"}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    cond do
      Map.has_key?(state.user_message_tasks, ref) ->
        {:noreply, finish_user_message_routing(ref, result, state)}

      Map.has_key?(state.coordinator_tasks, ref) ->
        {:noreply, finish_coordinator(ref, result, state)}

      agent = agent_by_ref(state, ref) ->
        {:noreply, finish_agent(agent, result, state)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    cond do
      Map.has_key?(state.user_message_tasks, ref) ->
        {command, state} = pop_user_message_task(state, ref)

        {:noreply,
         write_user_message_failure(
           command.message_id,
           "user message routing task exited: #{inspect(reason)}",
           state
         )}

      Map.has_key?(state.coordinator_tasks, ref) ->
        state = Map.update!(state, :coordinator_tasks, &Map.delete(&1, ref))
        {:noreply, state}

      agent = agent_by_ref(state, ref) ->
        {:noreply, fail_agent(agent, "agent task exited: #{inspect(reason)}", state)}

      true ->
        {:noreply, state}
    end
  end

  defp start_user_message_routing(command, state) do
    SessionTranscript.append_session!(state.session_dir, state.session_id, %{
      type: "user_message",
      message_id: command.message_id,
      task: command.run.task
    })

    task =
      Task.Supervisor.async_nolink(AgentMachine.SessionTaskSupervisor, fn ->
        route_user_message(command)
      end)

    {:ok, task}
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp route_user_message(command) do
    spec = RunSpec.new!(command.run)
    {:ok, WorkflowRouter.route!(spec)}
  rescue
    exception in CapabilityRequired -> {:error, exception}
    exception -> {:error, Exception.message(exception)}
  end

  defp finish_user_message_routing(ref, result, state) do
    {command, state} = pop_user_message_task(state, ref)

    case result do
      {:ok, route} ->
        start_routed_user_message(command, route, state)

      {:error, reason} ->
        write_user_message_failure(command.message_id, reason, state)
    end
  end

  defp start_routed_user_message(command, route, state) do
    if coordinator_route?(route) do
      case start_coordinator(command, state) do
        {:ok, task, state} ->
          put_started_user_message(state, {:coordinator, task}, command.message_id)

        {:error, reason} ->
          write_user_message_failure(command.message_id, reason, state)
      end
    else
      case start_primary_agent(command, state) do
        {:ok, agent, state} ->
          put_started_user_message(state, {:agent, agent}, command.message_id)

        {:error, reason} ->
          write_user_message_failure(command.message_id, reason, state)
      end
    end
  end

  defp pop_user_message_task(state, ref) do
    {command, tasks} = Map.pop(state.user_message_tasks, ref)
    {command, %{state | user_message_tasks: tasks}}
  end

  defp write_user_message_failure(message_id, reason, state) do
    maybe_write_primary_summary(message_id, failed_primary_summary(reason), state)
  end

  defp coordinator_route?(%{selected: "chat", tool_intent: "none"}), do: true
  defp coordinator_route?(%{"selected" => "chat", "tool_intent" => "none"}), do: true
  defp coordinator_route?(_route), do: false

  defp put_started_user_message(state, {:coordinator, task}, message_id),
    do: put_in(state, [:coordinator_tasks, task.ref], message_id)

  defp put_started_user_message(state, {:agent, _agent}, _message_id), do: state

  defp start_coordinator(command, state) do
    attrs = command.run
    session_tool_opts = command.session_tool_opts

    session_server = self()

    task =
      Task.Supervisor.async_nolink(AgentMachine.SessionTaskSupervisor, fn ->
        run_coordinator(%{
          attrs: attrs,
          session_tool_opts: session_tool_opts,
          session_id: state.session_id,
          session_dir: state.session_dir,
          writer: state.writer,
          session_server: session_server,
          permission_control: state.permission_control
        })
      end)

    {:ok, task, state}
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp start_primary_agent(command, state) do
    name = primary_agent_name(state)
    {agent, state} = new_agent(state, name, command.run.task, nil, false, false)
    agent = %{agent | primary_message_id: command.message_id}
    state = put_agent(state, agent)
    state = start_agent_attempt(agent, command.run, command.run.task, state)
    agent = Map.fetch!(state.agents, agent.id)

    write_agent_event(state, :session_agent_started, agent, %{
      background: false,
      primary: true,
      message_id: command.message_id
    })

    {:ok, agent, state}
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp primary_agent_name(state), do: "request-" <> Integer.to_string(state.agent_seq + 1)

  defp run_coordinator(context) do
    spec = RunSpec.new!(context.attrs)
    opts = coordinator_opts(spec, context)
    agent = coordinator_agent(spec, context)

    case Orchestrator.run([agent], opts) do
      {:ok, run} ->
        {:ok, ClientRunner.summarize_run!(run)}

      {:error, {:failed, run}} ->
        {:ok, Map.put(ClientRunner.summarize_run!(run), :status, "failed")}

      {:error, {:timeout, run}} ->
        {:ok, Map.put(ClientRunner.summarize_run!(run), :status, "timeout")}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp coordinator_agent(spec, context) do
    %{
      id: "coordinator",
      provider: provider_module(spec),
      model: model(spec),
      pricing: pricing(spec),
      input: coordinator_input(spec, context),
      instructions: coordinator_instructions()
    }
  end

  defp coordinator_opts(spec, context) do
    [
      timeout: spec.timeout_ms,
      max_steps: 1,
      max_attempts: spec.max_attempts,
      stream_response: spec.stream_response,
      allowed_tools: ToolHarness.session_control_tools(),
      tool_policy: ToolPolicy.new!(harness: :session_control, permissions: [:session_control]),
      tool_timeout_ms: context.session_tool_opts.timeout_ms,
      tool_max_rounds: context.session_tool_opts.max_rounds,
      tool_approval_mode: :read_only,
      session_server: context.session_server,
      workflow_route: %{
        requested: "session",
        selected: "session",
        reason: "session daemon coordinator workflow",
        tools_exposed: true,
        session_tools: [
          "spawn_agent",
          "send_agent_message",
          "read_agent_output",
          "list_session_agents"
        ]
      },
      event_sink: fn event ->
        SessionWriter.write_line(context.writer, SessionProtocol.event_line!(event))
      end
    ]
    |> put_http_opts(spec)
    |> WorkflowOptions.put_context_opts(spec)
  end

  defp coordinator_input(spec, context) do
    context_tail =
      context.session_dir
      |> SessionTranscript.session_context_path(context.session_id)
      |> SessionTranscript.load_path!()
      |> Enum.take(-12)

    """
    User message:
    #{spec.task}

    Session context ledger tail:
    #{AgentMachine.JSON.encode!(context_tail)}
    """
    |> String.trim()
  end

  defp coordinator_instructions do
    """
    You are the coordinator for a long-lived AgentMachine session.
    You may answer directly or use session-control tools to start, message, inspect, or list sidechain agents.
    Session-control tools do not grant filesystem, MCP, command, or network capability to you.
    AgentMachine routes new user messages before they reach you; answer directly only for conversational or session-management requests.
    If a request asks for filesystem changes, MCP/browser access, command execution, tests, or other toolful side effects, do not provide paste-in instructions or claim the work is done.
    When delegating, give each worker a precise briefing with all context it needs.
    Use background agents for independent work and read_agent_output only when you need their details.
    Report completed background-agent notifications when they matter to the user.
    """
    |> String.trim()
  end

  defp finish_coordinator(ref, {:ok, summary}, state) do
    state = Map.update!(state, :coordinator_tasks, &Map.delete(&1, ref))
    SessionWriter.write_line(state.writer, SessionProtocol.summary_line!(summary))

    SessionTranscript.append_session!(state.session_dir, state.session_id, %{
      type: "summary",
      summary: summary
    })

    state
  end

  defp finish_coordinator(ref, {:error, reason}, state) do
    state = Map.update!(state, :coordinator_tasks, &Map.delete(&1, ref))
    summary = %{status: "failed", error: reason, final_output: nil, results: %{}, events: []}
    SessionWriter.write_line(state.writer, SessionProtocol.summary_line!(summary))

    SessionTranscript.append_session!(state.session_dir, state.session_id, %{
      type: "error",
      error: reason
    })

    state
  end

  defp do_spawn_agent(input, from, state) do
    with {:ok, attrs} <- current_attrs(state),
         {:ok, name} <- fetch_input_string(input, "name"),
         {:ok, briefing} <- fetch_input_string(input, "briefing"),
         :ok <- unique_agent_name(state, name) do
      background? = Map.get(input, "background", false) == true
      fork? = Map.get(input, "fork_context", false) == true
      instructions = Map.get(input, "instructions")
      {agent, state} = new_agent(state, name, briefing, instructions, background?, fork?)
      state = start_agent_attempt(agent, attrs, first_agent_message(agent, state), state)
      agent = Map.fetch!(state.agents, agent.id)
      write_agent_event(state, :session_agent_started, agent, %{background: background?})

      if background? do
        {:reply, {:ok, public_agent(agent)}, state}
      else
        agent = Map.update!(Map.fetch!(state.agents, agent.id), :waiters, &[from | &1])
        {:noreply, put_agent(state, agent)}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp do_send_agent_message(input, state) do
    with {:ok, agent} <- resolve_agent(input, state),
         {:ok, message} <- fetch_message(input) do
      cond do
        agent.status == :running ->
          agent = %{agent | mailbox: agent.mailbox ++ [message], updated_at: DateTime.utc_now()}
          state = put_agent(state, agent)
          {:ok, %{status: "queued", agent: public_agent(agent)}, state}

        agent.status == :completed ->
          state =
            start_agent_attempt(
              agent,
              state.current_attrs,
              continuation_message(agent, message, state),
              state
            )

          agent = Map.fetch!(state.agents, agent.id)
          {:ok, %{status: "started", agent: public_agent(agent)}, state}

        agent.status in [:failed, :stopped] and Map.get(input, "resume", false) == true ->
          state =
            start_agent_attempt(
              agent,
              state.current_attrs,
              continuation_message(agent, message, state),
              state
            )

          agent = Map.fetch!(state.agents, agent.id)
          {:ok, %{status: "started", agent: public_agent(agent)}, state}

        agent.status in [:failed, :stopped] ->
          {:error, "agent #{agent.id} is #{agent.status}; pass resume=true to continue", state}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp new_agent(state, name, briefing, instructions, background?, fork?) do
    id = "agent-" <> Integer.to_string(state.agent_seq + 1)
    now = DateTime.utc_now()

    agent = %{
      id: id,
      name: name,
      briefing: briefing,
      instructions: instructions,
      background: background?,
      fork_context: fork?,
      status: :queued,
      task_ref: nil,
      task_pid: nil,
      mailbox: [],
      waiters: [],
      attempt: 0,
      summary: nil,
      output: nil,
      error: nil,
      primary_message_id: nil,
      created_at: now,
      updated_at: now
    }

    state =
      state
      |> Map.update!(:agent_seq, &(&1 + 1))
      |> put_agent(agent)

    {agent, state}
  end

  defp start_agent_attempt(agent, attrs, message, state) when is_map(attrs) do
    attempt = agent.attempt + 1
    attrs = Map.put(attrs, :task, message)

    task_context = %{
      session_id: state.session_id,
      session_dir: state.session_dir,
      agent_id: agent.id,
      attrs: attrs,
      message: message,
      writer: state.writer,
      permission_control: state.permission_control,
      attempt: attempt
    }

    task =
      Task.Supervisor.async_nolink(AgentMachine.SessionTaskSupervisor, AgentTask, :run, [
        task_context
      ])

    agent = %{
      agent
      | status: :running,
        task_ref: task.ref,
        task_pid: task.pid,
        attempt: attempt,
        updated_at: DateTime.utc_now()
    }

    put_agent(state, agent)
  end

  defp start_agent_attempt(_agent, nil, _message, _state) do
    raise ArgumentError,
          "cannot start a session agent before a user_message establishes run configuration"
  end

  defp finish_agent(agent, {:ok, summary}, state) do
    waiters = agent.waiters
    primary_message_id = Map.get(agent, :primary_message_id)

    agent = %{
      agent
      | status: :completed,
        task_ref: nil,
        task_pid: nil,
        summary: summary,
        output: Map.get(summary, :final_output) || Map.get(summary, "final_output"),
        error: Map.get(summary, :error) || Map.get(summary, "error"),
        waiters: [],
        primary_message_id: nil,
        updated_at: DateTime.utc_now()
    }

    state = put_agent(state, agent)

    write_agent_event(state, :session_agent_completed, agent, %{
      output_summary: summarize_output(agent.output)
    })

    reply_waiters(waiters, {:ok, output_payload(agent, %{}, state)})

    state = maybe_write_primary_summary(primary_message_id, summary, state)
    maybe_continue_agent(agent, state)
  end

  defp finish_agent(agent, {:error, reason}, state), do: fail_agent(agent, reason, state)

  defp fail_agent(agent, reason, state) do
    waiters = agent.waiters
    primary_message_id = Map.get(agent, :primary_message_id)

    agent = %{
      agent
      | status: :failed,
        task_ref: nil,
        task_pid: nil,
        error: reason,
        waiters: [],
        primary_message_id: nil,
        updated_at: DateTime.utc_now()
    }

    state = put_agent(state, agent)
    write_agent_event(state, :session_agent_failed, agent, %{reason: reason, error: reason})
    reply_waiters(waiters, {:error, reason})

    maybe_write_primary_summary(primary_message_id, failed_primary_summary(reason), state)
  end

  defp maybe_write_primary_summary(nil, _summary, state), do: state

  defp maybe_write_primary_summary(_message_id, summary, state) do
    SessionWriter.write_line(state.writer, SessionProtocol.summary_line!(summary))

    SessionTranscript.append_session!(state.session_dir, state.session_id, %{
      type: "summary",
      summary: summary
    })

    state
  end

  defp failed_primary_summary(%CapabilityRequired{} = reason) do
    event = CapabilityRequired.event(reason)

    %{
      status: "failed",
      error: Exception.message(reason),
      final_output: nil,
      results: %{},
      events: [event],
      capability_required: CapabilityRequired.to_map(reason)
    }
  end

  defp failed_primary_summary(reason) do
    %{status: "failed", error: reason, final_output: nil, results: %{}, events: []}
  end

  defp maybe_continue_agent(%{mailbox: [message | rest]} = agent, state) do
    agent = %{agent | mailbox: rest}
    state = put_agent(state, agent)

    start_agent_attempt(
      agent,
      state.current_attrs,
      continuation_message(agent, message, state),
      state
    )
  end

  defp maybe_continue_agent(_agent, state), do: state

  defp output_payload(agent, input, state) do
    limit = Map.get(input, "limit", @agent_output_tail_limit)

    %{
      agent: public_agent(agent),
      output: agent.output,
      error: agent.error,
      summary: agent.summary,
      transcript_tail:
        SessionTranscript.tail_agent!(state.session_dir, state.session_id, agent.id, limit)
    }
  end

  defp public_agent(agent) do
    %{
      agent_id: agent.id,
      name: agent.name,
      status: Atom.to_string(agent.status),
      background: agent.background,
      attempt: agent.attempt,
      created_at: DateTime.to_iso8601(agent.created_at),
      updated_at: DateTime.to_iso8601(agent.updated_at),
      output_summary: summarize_output(agent.output),
      error: agent.error
    }
  end

  defp first_agent_message(%{fork_context: true} = agent, state) do
    ledger_tail =
      state.session_dir
      |> SessionTranscript.session_context_path(state.session_id)
      |> SessionTranscript.load_path!()
      |> Enum.take(-20)
      |> AgentMachine.JSON.encode!()

    """
    Briefing:
    #{agent.briefing}

    Additional instructions:
    #{agent.instructions || ""}

    Forked session context:
    #{ledger_tail}
    """
    |> String.trim()
  end

  defp first_agent_message(agent, _state) do
    """
    Briefing:
    #{agent.briefing}

    Additional instructions:
    #{agent.instructions || ""}
    """
    |> String.trim()
  end

  defp continuation_message(agent, message, state) do
    tail =
      state.session_dir
      |> SessionTranscript.tail_agent!(state.session_id, agent.id, 20)
      |> AgentMachine.JSON.encode!()

    """
    Continue the prior sidechain agent conversation.

    Transcript tail:
    #{tail}

    New message:
    #{message}
    """
    |> String.trim()
  end

  defp write_agent_event(state, type, agent, extra) do
    event =
      %{
        type: type,
        session_id: state.session_id,
        agent_id: agent.id,
        name: agent.name,
        status: Atom.to_string(agent.status),
        at: DateTime.utc_now()
      }
      |> Map.merge(extra)

    SessionTranscript.append_session!(state.session_dir, state.session_id, %{
      type: "notification",
      event: event
    })

    SessionWriter.write_line(state.writer, SessionProtocol.event_line!(event))
  end

  defp provider_module(%RunSpec{provider: :echo}), do: AgentMachine.Providers.Echo
  defp provider_module(%RunSpec{provider: :openai}), do: AgentMachine.Providers.OpenAIResponses
  defp provider_module(%RunSpec{provider: :openrouter}), do: AgentMachine.Providers.OpenRouterChat

  defp model(%RunSpec{provider: :echo}), do: "echo"
  defp model(%RunSpec{model: model}), do: model

  defp pricing(%RunSpec{provider: :echo}), do: %{input_per_million: 0.0, output_per_million: 0.0}
  defp pricing(%RunSpec{pricing: pricing}), do: pricing

  defp put_http_opts(opts, %RunSpec{provider: :echo}), do: opts

  defp put_http_opts(opts, %RunSpec{http_timeout_ms: http_timeout_ms}) do
    Keyword.put(opts, :http_timeout_ms, http_timeout_ms)
  end

  defp current_attrs(%{current_attrs: attrs}) when is_map(attrs), do: {:ok, attrs}

  defp current_attrs(_state),
    do: {:error, "no run configuration is available in this session yet"}

  defp unique_command_id(state, id) do
    if MapSet.member?(state.command_ids, id) do
      {:error, "duplicate session command id #{inspect(id)}"}
    else
      :ok
    end
  end

  defp put_command_id(state, id), do: Map.update!(state, :command_ids, &MapSet.put(&1, id))

  defp unique_agent_name(state, name) do
    if Map.has_key?(state.names, name) do
      {:error, "session agent name already exists: #{inspect(name)}"}
    else
      :ok
    end
  end

  defp put_agent(state, agent) do
    %{
      state
      | agents: Map.put(state.agents, agent.id, agent),
        names: Map.put(state.names, agent.name, agent.id)
    }
  end

  defp agent_by_ref(state, ref) do
    Enum.find_value(state.agents, fn {_id, agent} ->
      if agent.task_ref == ref, do: agent
    end)
  end

  defp resolve_agent(input, state) do
    cond do
      is_binary(Map.get(input, "agent_id")) ->
        fetch_agent(state, Map.fetch!(input, "agent_id"))

      is_binary(Map.get(input, :agent_id)) ->
        fetch_agent(state, Map.fetch!(input, :agent_id))

      is_binary(Map.get(input, "name")) ->
        input |> Map.fetch!("name") |> agent_id_for_name(state) |> fetch_agent(state)

      is_binary(Map.get(input, :name)) ->
        input |> Map.fetch!(:name) |> agent_id_for_name(state) |> fetch_agent(state)

      true ->
        {:error, "agent reference requires agent_id or name"}
    end
  end

  defp fetch_agent({:error, reason}, _state), do: {:error, reason}
  defp fetch_agent(state, agent_id) when is_map(state), do: fetch_agent(agent_id, state)

  defp fetch_agent(agent_id, state) when is_binary(agent_id) do
    case Map.fetch(state.agents, agent_id) do
      {:ok, agent} -> {:ok, agent}
      :error -> {:error, "unknown session agent #{inspect(agent_id)}"}
    end
  end

  defp agent_id_for_name(name, state) do
    case Map.fetch(state.names, name) do
      {:ok, agent_id} -> agent_id
      :error -> {:error, "unknown session agent name #{inspect(name)}"}
    end
  end

  defp fetch_input_string(input, key) do
    case Map.get(input, key) || Map.get(input, String.to_atom(key)) do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      value -> {:error, "session agent #{key} must be a non-empty string, got: #{inspect(value)}"}
    end
  end

  defp fetch_message(input) do
    case Map.get(input, "message") || Map.get(input, :message) || Map.get(input, "content") do
      value when is_binary(value) and byte_size(value) > 0 ->
        {:ok, value}

      value ->
        {:error, "session agent message must be a non-empty string, got: #{inspect(value)}"}
    end
  end

  defp reply_waiters(waiters, reply) do
    Enum.each(waiters, &GenServer.reply(&1, reply))
  end

  defp summarize_output(nil), do: nil

  defp summarize_output(output) when is_binary(output) do
    if byte_size(output) > 240 do
      binary_part(output, 0, 240) <> "..."
    else
      output
    end
  end

  defp require_non_empty_binary!(value, _field) when is_binary(value) and byte_size(value) > 0,
    do: value

  defp require_non_empty_binary!(value, field) do
    raise ArgumentError,
          "session #{inspect(field)} must be a non-empty binary, got: #{inspect(value)}"
  end
end
