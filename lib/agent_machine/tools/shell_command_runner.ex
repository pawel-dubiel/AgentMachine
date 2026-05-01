defmodule AgentMachine.Tools.ShellCommandRunner do
  @moduledoc false

  alias AgentMachine.Secrets.Redactor
  alias AgentMachine.Tools.{CodeEditCheckpoint, CodeEditSupport, PathGuard}

  @max_output_bytes 20_000

  def prepare!(input, opts, tool_name) when is_map(input) and is_list(opts) do
    root = PathGuard.root!(opts)
    command = input |> fetch_input!("command", tool_name) |> require_command!()
    cwd = input |> fetch_input!("cwd", tool_name) |> existing_directory!(root)
    timeout_ms = input |> fetch_input!("timeout_ms", tool_name) |> require_timeout!(opts)
    checkpoint = CodeEditCheckpoint.prepare_snapshot!(root, tool_name)

    %{
      root: root,
      command: command,
      cwd: cwd,
      timeout_ms: timeout_ms,
      checkpoint_id: checkpoint.checkpoint_id,
      checkpoint_path: checkpoint.checkpoint_path
    }
  end

  def run_foreground(prepared) when is_map(prepared) do
    started_at = System.monotonic_time(:millisecond)
    {port, os_pid} = open_port!(prepared.command, prepared.cwd)

    execution =
      collect_port(%{
        port: port,
        os_pid: os_pid,
        output: "",
        output_truncated: false,
        exit_status: nil,
        timed_out: false,
        stopped: false,
        started_at: started_at,
        timeout_ms: prepared.timeout_ms
      })

    prepared
    |> result(execution)
    |> put_checkpoint(prepared)
  end

  def open_port!(command, cwd) when is_binary(command) and is_binary(cwd) do
    shell = shell_executable!()
    env = env_executable!()

    port =
      Port.open(
        {:spawn_executable, env},
        [
          :binary,
          :exit_status,
          :hide,
          :stderr_to_stdout,
          :use_stdio,
          {:args, ["-i"] ++ env_assignments(shell) ++ [shell, "-lc", command]},
          {:cd, cwd}
        ]
      )

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} when is_integer(pid) -> pid
        _other -> nil
      end

    {port, os_pid}
  end

  def append_output(output, data) when is_binary(output) and is_binary(data) do
    combined = output <> data

    if byte_size(combined) <= @max_output_bytes do
      {combined, false}
    else
      {binary_part(combined, 0, @max_output_bytes), true}
    end
  end

  def result(prepared, execution) do
    redaction = redact_command_output(prepared.command, execution.output)
    exit_status = execution.exit_status

    status =
      cond do
        execution.timed_out -> "timeout"
        execution.stopped -> "stopped"
        exit_status == 0 -> "ok"
        true -> "error"
      end

    %{
      status: status,
      command: redaction.command.value,
      cwd: prepared.cwd,
      exit_status: exit_status,
      timed_out: execution.timed_out,
      stopped: execution.stopped,
      duration_ms: System.monotonic_time(:millisecond) - execution.started_at,
      output: redaction.output.value,
      output_truncated: execution.output_truncated,
      checkpoint_id: prepared.checkpoint_id,
      checkpoint_path: prepared.checkpoint_path
    }
    |> put_redaction_metadata(redaction)
  end

  def redact_command_output(command, output) when is_binary(command) and is_binary(output) do
    %{command: Redactor.redact_string(command), output: Redactor.redact_string(output)}
  end

  def put_redaction_metadata(map, redactions) when is_map(map) and is_map(redactions) do
    Redactor.put_tool_metadata(map, combined_redaction(redactions))
  end

  def put_checkpoint(result, prepared) do
    checkpoint = CodeEditCheckpoint.finalize_snapshot!(prepared.root, prepared.checkpoint_id)

    result
    |> Map.put(:checkpoint, checkpoint.checkpoint)
    |> Map.put(:changed, checkpoint.changed)
    |> Map.put(:changed_files, checkpoint.changed_files)
    |> Map.put(:summary, checkpoint.summary)
  rescue
    exception in [ArgumentError, File.Error] ->
      result
      |> Map.put(:checkpoint_error, Exception.message(exception))
      |> Map.put(:status, "error")
  end

  def terminate_os_process(nil), do: :ok

  def terminate_os_process(os_pid) when is_integer(os_pid) do
    os_pid
    |> descendant_pids()
    |> Enum.reverse()
    |> Kernel.++([os_pid])
    |> Enum.uniq()
    |> Enum.each(&kill_pid/1)

    :ok
  end

  defp collect_port(state) do
    receive do
      {port, {:data, data}} when port == state.port ->
        {output, truncated_now?} = append_output(state.output, data)

        collect_port(%{
          state
          | output: output,
            output_truncated: state.output_truncated or truncated_now?
        })

      {port, {:exit_status, status}} when port == state.port ->
        %{state | exit_status: status}
    after
      state.timeout_ms ->
        terminate_os_process(state.os_pid)
        close_port(state.port)
        wait_after_kill(%{state | timed_out: true})
    end
  end

  defp wait_after_kill(state) do
    receive do
      {port, {:data, data}} when port == state.port ->
        {output, truncated_now?} = append_output(state.output, data)

        wait_after_kill(%{
          state
          | output: output,
            output_truncated: state.output_truncated or truncated_now?
        })

      {port, {:exit_status, status}} when port == state.port ->
        %{state | exit_status: status}
    after
      500 ->
        %{state | exit_status: nil}
    end
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp combined_redaction(redactions) do
    values = Map.values(redactions)

    %{
      redacted: Enum.any?(values, & &1.redacted),
      count: Enum.reduce(values, 0, &(&1.count + &2)),
      reasons:
        values
        |> Enum.flat_map(& &1.reasons)
        |> Enum.uniq()
        |> Enum.sort()
    }
  end

  defp fetch_input!(input, key, tool_name) do
    atom_key = input_atom_key!(key)

    cond do
      Map.has_key?(input, key) -> Map.fetch!(input, key)
      Map.has_key?(input, atom_key) -> Map.fetch!(input, atom_key)
      true -> raise ArgumentError, "#{tool_name} input is missing #{inspect(key)}"
    end
  end

  defp input_atom_key!(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp require_command!(command) do
    command
    |> CodeEditSupport.require_non_empty_text!("command", 10_000)
    |> String.trim()
    |> case do
      "" -> raise ArgumentError, "command must be a non-empty string"
      trimmed -> trimmed
    end
  end

  defp require_timeout!(timeout_ms, opts) when is_integer(timeout_ms) and timeout_ms > 0 do
    configured = Keyword.fetch!(opts, :tool_timeout_ms)

    unless is_integer(configured) and configured > 0 do
      raise ArgumentError,
            ":tool_timeout_ms must be a positive integer, got: #{inspect(configured)}"
    end

    if timeout_ms <= configured do
      timeout_ms
    else
      raise ArgumentError,
            "timeout_ms must be less than or equal to configured :tool_timeout_ms #{configured}, got: #{timeout_ms}"
    end
  end

  defp require_timeout!(timeout_ms, _opts) do
    raise ArgumentError, "timeout_ms must be a positive integer, got: #{inspect(timeout_ms)}"
  end

  defp existing_directory!(cwd, root) do
    target = PathGuard.existing_target!(root, PathGuard.require_non_empty_binary!(cwd, "cwd"))

    case File.stat!(target) do
      %{type: :directory} -> target
      %{type: type} -> raise ArgumentError, "cwd must be a directory, got: #{inspect(type)}"
    end
  end

  defp shell_executable! do
    shell = System.get_env("SHELL")

    cond do
      supported_shell?(shell) -> shell
      path = System.find_executable("zsh") -> path
      path = System.find_executable("bash") -> path
      path = System.find_executable("sh") -> path
      true -> raise ArgumentError, "no supported POSIX shell found in PATH"
    end
  end

  defp supported_shell?(shell) when is_binary(shell) and shell != "" do
    File.exists?(shell) and
      (String.ends_with?(shell, "/zsh") or String.ends_with?(shell, "/bash") or
         String.ends_with?(shell, "/sh"))
  end

  defp supported_shell?(_shell), do: false

  defp env_executable! do
    System.find_executable("env") ||
      raise ArgumentError,
            "env executable is required for shell commands but was not found in PATH"
  end

  defp env_assignments(shell) do
    [
      "PATH=#{System.get_env("PATH") || ""}",
      "HOME=#{System.get_env("HOME") || ""}",
      "LANG=#{System.get_env("LANG") || "C"}",
      "LC_ALL=#{System.get_env("LC_ALL") || "C"}",
      "SHELL=#{shell}",
      "AGENT_MACHINE=1"
    ]
  end

  defp descendant_pids(os_pid) do
    case System.find_executable("pgrep") do
      nil -> []
      pgrep -> child_pids(pgrep, os_pid)
    end
  end

  defp child_pids(pgrep, os_pid) do
    case System.cmd(pgrep, ["-P", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {output, 0} -> parse_child_pids(output)
      _other -> []
    end
  end

  defp parse_child_pids(output) do
    output
    |> String.split()
    |> Enum.flat_map(&child_pid_with_descendants/1)
  end

  defp child_pid_with_descendants(value) do
    case Integer.parse(value) do
      {pid, ""} -> [pid | descendant_pids(pid)]
      _other -> []
    end
  end

  defp kill_pid(pid) when is_integer(pid) do
    case System.find_executable("kill") do
      nil -> :ok
      kill -> System.cmd(kill, ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
    end

    :ok
  end
end
