defmodule AgentMachine.ShellCommandRegistry do
  @moduledoc false

  use GenServer

  alias AgentMachine.Tools.ShellCommandRunner

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def start_command(input, opts) when is_map(input) and is_list(opts) do
    GenServer.call(__MODULE__, {:start_command, input, opts})
  end

  def read_command(command_id, opts) when is_binary(command_id) and is_list(opts) do
    GenServer.call(__MODULE__, {:read_command, command_id, opts})
  end

  def stop_command(command_id, opts) when is_binary(command_id) and is_list(opts) do
    GenServer.call(__MODULE__, {:stop_command, command_id, opts})
  end

  def list_commands(opts) when is_list(opts) do
    GenServer.call(__MODULE__, {:list_commands, opts})
  end

  @impl true
  def init(_opts), do: {:ok, %{commands: %{}, ports: %{}}}

  @impl true
  def handle_call({:start_command, input, opts}, _from, state) do
    prepared = ShellCommandRunner.prepare!(input, opts, "start_shell_command")
    {port, os_pid} = ShellCommandRunner.open_port!(prepared.command, prepared.cwd)
    command_id = new_command_id()
    timeout_ref = Process.send_after(self(), {:shell_timeout, command_id}, prepared.timeout_ms)
    owner = owner!(opts)

    command =
      prepared
      |> Map.merge(owner)
      |> Map.merge(%{
        id: command_id,
        port: port,
        os_pid: os_pid,
        status: :running,
        output: "",
        output_truncated: false,
        exit_status: nil,
        timed_out: false,
        stopped: false,
        started_at: System.monotonic_time(:millisecond),
        timeout_ref: timeout_ref,
        checkpoint_error: nil,
        summary: nil
      })

    state = put_command(state, command)
    {:reply, {:ok, public_result(command)}, state}
  rescue
    exception in [ArgumentError, File.Error] ->
      {:reply, {:error, Exception.message(exception)}, state}
  end

  def handle_call({:read_command, command_id, opts}, _from, state) do
    case fetch_owned_command(state, command_id, opts) do
      {:ok, command} -> {:reply, {:ok, public_result(command)}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stop_command, command_id, opts}, _from, state) do
    case fetch_owned_command(state, command_id, opts) do
      {:ok, command} -> stop_owned_command(command, state)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:list_commands, opts}, _from, state) do
    owner = owner!(opts)

    commands =
      state.commands
      |> Map.values()
      |> Enum.filter(&owned_by?(&1, owner))
      |> Enum.sort_by(& &1.started_at)
      |> Enum.map(&public_result/1)

    {:reply, {:ok, %{commands: commands}}, state}
  rescue
    exception in ArgumentError ->
      {:reply, {:error, Exception.message(exception)}, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, state) when is_port(port) and is_binary(data) do
    case Map.fetch(state.ports, port) do
      {:ok, command_id} ->
        command = Map.fetch!(state.commands, command_id)
        {output, truncated_now?} = ShellCommandRunner.append_output(command.output, data)

        command = %{
          command
          | output: output,
            output_truncated: command.output_truncated or truncated_now?
        }

        {:noreply, put_command(state, command)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, state) when is_port(port) do
    case Map.fetch(state.ports, port) do
      {:ok, command_id} ->
        command = Map.fetch!(state.commands, command_id)
        command = finish_command(%{command | exit_status: status})

        state =
          state
          |> put_command(command)
          |> Map.update!(:ports, &Map.delete(&1, port))

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:shell_timeout, command_id}, state) do
    case Map.fetch(state.commands, command_id) do
      {:ok, %{status: :running} = command} ->
        ShellCommandRunner.terminate_os_process(command.os_pid)
        close_port(command.port)
        {:noreply, put_command(state, %{command | timed_out: true, status: :stopping})}

      _other ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    state.commands
    |> Map.values()
    |> Enum.filter(&(&1.status in [:running, :stopping]))
    |> Enum.each(&ShellCommandRunner.terminate_os_process(&1.os_pid))

    :ok
  end

  defp put_command(state, command) do
    state
    |> put_in([:commands, command.id], command)
    |> put_in([:ports, command.port], command.id)
  end

  defp finish_command(command) do
    cancel_timeout(command.timeout_ref)

    command =
      command
      |> Map.put(:status, finished_status(command))
      |> Map.put(:duration_ms, System.monotonic_time(:millisecond) - command.started_at)

    result = ShellCommandRunner.result(command, command)
    result = ShellCommandRunner.put_checkpoint(result, command)

    command
    |> Map.put(:summary, result)
    |> Map.put(:checkpoint_error, Map.get(result, :checkpoint_error))
  end

  defp finished_status(%{timed_out: true}), do: :timeout
  defp finished_status(%{stopped: true}), do: :stopped
  defp finished_status(%{exit_status: 0}), do: :completed
  defp finished_status(_command), do: :failed

  defp stop_owned_command(%{status: :running} = command, state) do
    ShellCommandRunner.terminate_os_process(command.os_pid)
    close_port(command.port)
    command = %{command | status: :stopping, stopped: true}
    {:reply, {:ok, public_result(command)}, put_command(state, command)}
  end

  defp stop_owned_command(command, state) do
    {:reply, {:ok, public_result(command)}, state}
  end

  defp public_result(%{summary: summary} = command) when is_map(summary) do
    summary
    |> Map.put(:command_id, command.id)
    |> Map.put(:background, true)
    |> Map.put(:running_status, Atom.to_string(command.status))
  end

  defp public_result(command) do
    redaction = ShellCommandRunner.redact_command_output(command.command, command.output)

    %{
      command_id: command.id,
      status: Atom.to_string(command.status),
      command: redaction.command.value,
      cwd: command.cwd,
      exit_status: command.exit_status,
      timed_out: command.timed_out,
      stopped: command.stopped,
      duration_ms: System.monotonic_time(:millisecond) - command.started_at,
      output: redaction.output.value,
      output_truncated: command.output_truncated,
      checkpoint_id: command.checkpoint_id,
      checkpoint_path: command.checkpoint_path,
      background: true
    }
    |> ShellCommandRunner.put_redaction_metadata(redaction)
  end

  defp fetch_owned_command(state, command_id, opts) do
    owner = owner!(opts)

    case Map.fetch(state.commands, command_id) do
      {:ok, command} ->
        if owned_by?(command, owner) do
          {:ok, command}
        else
          {:error, "shell command #{inspect(command_id)} does not belong to this run"}
        end

      :error ->
        {:error, "unknown shell command id: #{inspect(command_id)}"}
    end
  rescue
    exception in ArgumentError -> {:error, Exception.message(exception)}
  end

  defp owner!(opts) do
    context = Keyword.fetch!(opts, :tool_event_context)
    run_id = Map.fetch!(context, :run_id)

    unless is_binary(run_id) and run_id != "" do
      raise ArgumentError, "shell command owner run_id must be a non-empty string"
    end

    %{run_id: run_id, agent_id: Map.get(context, :agent_id)}
  end

  defp owned_by?(command, owner), do: command.run_id == owner.run_id

  defp new_command_id do
    "shell-" <> Integer.to_string(System.unique_integer([:positive]))
  end

  defp cancel_timeout(nil), do: :ok
  defp cancel_timeout(ref), do: Process.cancel_timer(ref)

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
