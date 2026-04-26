defmodule AgentMachine.Tools.RunTestCommand do
  @moduledoc """
  Runs an explicitly allowlisted test command under the configured tool root.
  """

  @behaviour AgentMachine.Tool

  alias AgentMachine.Secrets.Redactor
  alias AgentMachine.Tools.PathGuard

  @max_output_bytes 20_000
  @forbidden_command_chars ["|", ">", "<", ";", "&", "$", "`", "\n", "\r"]

  @impl true
  def permission, do: :test_command_run

  @impl true
  def approval_risk, do: :command

  @impl true
  def definition do
    %{
      name: "run_test_command",
      description:
        "Run one exact allowlisted test command under the configured tool root without a shell.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "command" => %{
            "type" => "string",
            "description" => "Exact command string from the configured test command allowlist."
          },
          "cwd" => %{
            "type" => "string",
            "description" =>
              "Relative working directory under the configured root, or an absolute path inside that root."
          }
        },
        "required" => ["command", "cwd"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def run(input, opts) when is_map(input) do
    root = PathGuard.root!(opts)
    command = input |> fetch_input!("command") |> PathGuard.require_non_empty_binary!("command")
    cwd = input |> fetch_input!("cwd") |> PathGuard.require_non_empty_binary!("cwd")
    allowed_commands = allowed_commands!(opts)
    timeout_ms = tool_timeout_ms!(opts)

    validate_allowed_command!(command, allowed_commands)
    argv = parse!(command)
    cwd = existing_directory!(root, cwd)

    {:ok, execute(argv, command, cwd, timeout_ms)}
  rescue
    exception in [ArgumentError, File.Error] -> {:error, Exception.message(exception)}
  end

  def run(input, _opts), do: {:error, {:invalid_input, input}}

  def parse!(command) when is_binary(command) do
    command = String.trim(command)

    cond do
      command == "" ->
        raise ArgumentError, "test command must be a non-empty string"

      Enum.any?(@forbidden_command_chars, &String.contains?(command, &1)) ->
        raise ArgumentError, "test command contains unsupported shell syntax: #{inspect(command)}"

      true ->
        argv = String.split(command, ~r/\s+/, trim: true)
        validate_argv!(argv, command)
    end
  end

  def parse!(command) do
    raise ArgumentError, "test command must be a string, got: #{inspect(command)}"
  end

  def validate_allowlist!(nil), do: nil

  def validate_allowlist!(commands) when is_list(commands) and commands != [] do
    Enum.each(commands, &parse!/1)

    duplicates =
      commands
      |> Enum.frequencies()
      |> Enum.filter(fn {_command, count} -> count > 1 end)
      |> Enum.map(fn {command, _count} -> command end)

    if duplicates != [] do
      raise ArgumentError, "test_commands must not contain duplicates: #{inspect(duplicates)}"
    end

    commands
  end

  def validate_allowlist!(commands) do
    raise ArgumentError,
          "test_commands must be a non-empty list when provided, got: #{inspect(commands)}"
  end

  defp fetch_input!(input, key) do
    atom_key = input_atom_key!(key)

    cond do
      Map.has_key?(input, key) -> Map.fetch!(input, key)
      Map.has_key?(input, atom_key) -> Map.fetch!(input, atom_key)
      true -> raise ArgumentError, "run_test_command input is missing #{inspect(key)}"
    end
  end

  defp input_atom_key!("command"), do: :command
  defp input_atom_key!("cwd"), do: :cwd

  defp validate_argv!([executable | _args] = argv, command) do
    cond do
      Enum.any?(argv, &(&1 == "")) ->
        raise ArgumentError, "test command contains an empty token: #{inspect(command)}"

      String.contains?(executable, "=") and not String.starts_with?(executable, ["./", "../"]) ->
        raise ArgumentError, "test command must not start with an environment assignment"

      Path.type(executable) == :absolute ->
        raise ArgumentError, "test command executable must not be an absolute path"

      true ->
        argv
    end
  end

  defp validate_argv!([], command) do
    raise ArgumentError, "test command contains no executable: #{inspect(command)}"
  end

  defp allowed_commands!(opts) do
    opts
    |> Keyword.fetch!(:test_commands)
    |> validate_allowlist!()
  end

  defp tool_timeout_ms!(opts) do
    case Keyword.fetch(opts, :tool_timeout_ms) do
      {:ok, timeout_ms} when is_integer(timeout_ms) and timeout_ms > 0 ->
        timeout_ms

      {:ok, timeout_ms} ->
        raise ArgumentError,
              ":tool_timeout_ms must be a positive integer, got: #{inspect(timeout_ms)}"

      :error ->
        raise ArgumentError, "run_test_command requires explicit :tool_timeout_ms option"
    end
  end

  defp validate_allowed_command!(command, allowed_commands) do
    if command in allowed_commands do
      :ok
    else
      raise ArgumentError,
            "test command #{inspect(command)} is not in allowed test commands: #{inspect(allowed_commands)}"
    end
  end

  defp existing_directory!(root, cwd) do
    target = PathGuard.existing_target!(root, cwd)

    case File.stat!(target) do
      %{type: :directory} ->
        target

      %{type: type} ->
        raise ArgumentError, "run_test_command cwd must be a directory, got: #{inspect(type)}"
    end
  end

  defp execute(argv, command, cwd, timeout_ms) do
    started_at = System.monotonic_time(:millisecond)

    task =
      Task.async(fn ->
        [executable | args] = argv

        {output, status} =
          System.cmd(env_executable!(), env_args(executable, args), command_opts(cwd))

        {truncate_output(output), status}
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {{output, truncated}, status}} ->
        result(command, cwd, status, false, output, truncated, started_at)

      nil ->
        result(command, cwd, nil, true, "", false, started_at)
    end
  end

  defp command_opts(cwd) do
    [
      cd: cwd,
      stderr_to_stdout: true
    ]
  end

  defp env_executable! do
    System.find_executable("env") ||
      raise ArgumentError,
            "env executable is required for run_test_command but was not found in PATH"
  end

  defp env_args(executable, args) do
    ["-i"] ++ env_assignments() ++ [executable | args]
  end

  defp env_assignments do
    [
      "PATH=#{System.get_env("PATH") || ""}",
      "HOME=#{System.get_env("HOME") || ""}",
      "LANG=#{System.get_env("LANG") || "C"}",
      "LC_ALL=#{System.get_env("LC_ALL") || "C"}",
      "MIX_ENV=test"
    ]
  end

  defp truncate_output(output) when byte_size(output) <= @max_output_bytes, do: {output, false}

  defp truncate_output(output) do
    {binary_part(output, 0, @max_output_bytes), true}
  end

  defp result(command, cwd, status, timed_out, output, truncated, started_at) do
    redaction = Redactor.redact_string(output)

    %{
      command: command,
      cwd: cwd,
      exit_status: status,
      duration_ms: System.monotonic_time(:millisecond) - started_at,
      timed_out: timed_out,
      output: redaction.value,
      output_truncated: truncated
    }
    |> Redactor.put_tool_metadata(redaction)
  end
end
