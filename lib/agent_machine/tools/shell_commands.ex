defmodule AgentMachine.Tools.RunShellCommand do
  @moduledoc false

  @behaviour AgentMachine.Tool

  alias AgentMachine.Tools.ShellCommandRunner

  @impl true
  def permission, do: :code_edit_shell_run

  @impl true
  def approval_risk, do: :command

  @impl true
  def definition do
    %{
      name: "run_shell_command",
      description:
        "Run a foreground POSIX shell command from a cwd under the configured code-edit root. Requires explicit timeout_ms and returns bounded redacted combined output.",
      input_schema: shell_input_schema()
    }
  end

  @impl true
  def run(input, opts) when is_map(input) do
    input
    |> ShellCommandRunner.prepare!(opts, "run_shell_command")
    |> ShellCommandRunner.run_foreground()
    |> then(&{:ok, &1})
  rescue
    exception in [ArgumentError, File.Error] -> {:error, Exception.message(exception)}
  end

  def run(input, _opts), do: {:error, {:invalid_input, input}}

  defp shell_input_schema do
    %{
      "type" => "object",
      "properties" => %{
        "command" => %{
          "type" => "string",
          "description" => "Shell command to run. It is executed with POSIX shell -lc."
        },
        "cwd" => %{
          "type" => "string",
          "description" =>
            "Relative working directory under the configured tool root, or an absolute path inside that root."
        },
        "timeout_ms" => %{
          "type" => "integer",
          "description" =>
            "Command timeout in milliseconds. Must be less than or equal to the configured tool timeout."
        }
      },
      "required" => ["command", "cwd", "timeout_ms"],
      "additionalProperties" => false
    }
  end
end

defmodule AgentMachine.Tools.StartShellCommand do
  @moduledoc false

  @behaviour AgentMachine.Tool

  alias AgentMachine.ShellCommandRegistry

  @impl true
  def permission, do: :code_edit_shell_background

  @impl true
  def approval_risk, do: :command

  @impl true
  def definition do
    %{
      name: "start_shell_command",
      description:
        "Start a background POSIX shell command from a cwd under the configured code-edit root. Use read_shell_command_output to inspect progress and stop_shell_command to stop it.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "command" => %{"type" => "string", "description" => "Shell command to run."},
          "cwd" => %{
            "type" => "string",
            "description" =>
              "Relative working directory under the configured tool root, or an absolute path inside that root."
          },
          "timeout_ms" => %{
            "type" => "integer",
            "description" =>
              "Command timeout in milliseconds. Must be less than or equal to the configured tool timeout."
          }
        },
        "required" => ["command", "cwd", "timeout_ms"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def run(input, opts) when is_map(input), do: ShellCommandRegistry.start_command(input, opts)
  def run(input, _opts), do: {:error, {:invalid_input, input}}
end

defmodule AgentMachine.Tools.ReadShellCommandOutput do
  @moduledoc false

  @behaviour AgentMachine.Tool

  alias AgentMachine.ShellCommandRegistry

  @impl true
  def permission, do: :code_edit_shell_background

  @impl true
  def approval_risk, do: :read

  @impl true
  def definition do
    %{
      name: "read_shell_command_output",
      description: "Read the current bounded output and status for a background shell command.",
      input_schema: command_id_schema()
    }
  end

  @impl true
  def run(input, opts) when is_map(input) do
    command_id = command_id!(input, "read_shell_command_output")
    ShellCommandRegistry.read_command(command_id, opts)
  rescue
    exception in ArgumentError -> {:error, Exception.message(exception)}
  end

  def run(input, _opts), do: {:error, {:invalid_input, input}}

  defp command_id_schema do
    %{
      "type" => "object",
      "properties" => %{
        "command_id" => %{"type" => "string", "description" => "Background shell command id."}
      },
      "required" => ["command_id"],
      "additionalProperties" => false
    }
  end

  defp command_id!(input, tool) do
    value = Map.get(input, "command_id") || Map.get(input, :command_id)

    if is_binary(value) and value != "" do
      value
    else
      raise ArgumentError, "#{tool} input requires non-empty command_id"
    end
  end
end

defmodule AgentMachine.Tools.StopShellCommand do
  @moduledoc false

  @behaviour AgentMachine.Tool

  alias AgentMachine.ShellCommandRegistry

  @impl true
  def permission, do: :code_edit_shell_stop

  @impl true
  def approval_risk, do: :command

  @impl true
  def definition do
    %{
      name: "stop_shell_command",
      description: "Stop a background shell command that belongs to the current run.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "command_id" => %{"type" => "string", "description" => "Background shell command id."}
        },
        "required" => ["command_id"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def run(input, opts) when is_map(input) do
    command_id = Map.get(input, "command_id") || Map.get(input, :command_id)

    if is_binary(command_id) and command_id != "" do
      ShellCommandRegistry.stop_command(command_id, opts)
    else
      {:error, "stop_shell_command input requires non-empty command_id"}
    end
  end

  def run(input, _opts), do: {:error, {:invalid_input, input}}
end

defmodule AgentMachine.Tools.ListShellCommands do
  @moduledoc false

  @behaviour AgentMachine.Tool

  alias AgentMachine.ShellCommandRegistry

  @impl true
  def permission, do: :code_edit_shell_background

  @impl true
  def approval_risk, do: :read

  @impl true
  def definition do
    %{
      name: "list_shell_commands",
      description: "List background shell commands that belong to the current run.",
      input_schema: %{
        "type" => "object",
        "properties" => %{},
        "required" => [],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def run(input, opts) when is_map(input), do: ShellCommandRegistry.list_commands(opts)
  def run(input, _opts), do: {:error, {:invalid_input, input}}
end
