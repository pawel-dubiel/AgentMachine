defmodule AgentMachine.ShellCommandToolsTest do
  use ExUnit.Case, async: false

  alias AgentMachine.ToolHarness

  alias AgentMachine.Tools.{
    ReadShellCommandOutput,
    RollbackCheckpoint,
    RunShellCommand,
    StartShellCommand,
    StopShellCommand
  }

  test "code-edit exposes shell tools only for full or prompted command access" do
    refute RunShellCommand in ToolHarness.builtin_many!([:code_edit],
             tool_approval_mode: :auto_approved_safe
           )

    assert RunShellCommand in ToolHarness.builtin_many!([:code_edit],
             tool_approval_mode: :full_access
           )

    assert RunShellCommand in ToolHarness.builtin_many!([:code_edit],
             tool_approval_mode: :ask_before_write
           )
  end

  test "foreground shell command runs under root and creates rollback checkpoint" do
    root = tmp_root("agent-machine-shell-fg")

    assert {:ok, result} =
             RunShellCommand.run(
               %{
                 "command" => "printf hello > hello.txt",
                 "cwd" => ".",
                 "timeout_ms" => 1_000
               },
               tool_opts(root)
             )

    assert result.status == "ok"
    assert result.exit_status == 0
    assert File.read!(Path.join(root, "hello.txt")) == "hello"
    assert result.summary.changed_count == 1
    assert [%{path: "hello.txt", action: "created"}] = result.changed_files

    assert {:ok, rollback} =
             RollbackCheckpoint.run(%{"checkpoint_id" => result.checkpoint_id}, tool_opts(root))

    assert rollback.summary.deleted_count == 1
    refute File.exists?(Path.join(root, "hello.txt"))
  end

  test "foreground shell command rejects cwd outside root" do
    root = tmp_root("agent-machine-shell-cwd")

    assert {:error, reason} =
             RunShellCommand.run(
               %{
                 "command" => "printf bad",
                 "cwd" => System.tmp_dir!(),
                 "timeout_ms" => 1_000
               },
               tool_opts(root)
             )

    assert reason =~ "outside tool root"
  end

  test "foreground shell command times out and returns bounded result" do
    root = tmp_root("agent-machine-shell-timeout")

    assert {:ok, result} =
             RunShellCommand.run(
               %{
                 "command" => "sleep 2",
                 "cwd" => ".",
                 "timeout_ms" => 100
               },
               tool_opts(root, tool_timeout_ms: 500)
             )

    assert result.status == "timeout"
    assert result.timed_out == true
  end

  test "background shell command can be read and stopped" do
    root = tmp_root("agent-machine-shell-bg")
    opts = tool_opts(root, tool_timeout_ms: 2_000)

    assert {:ok, started} =
             StartShellCommand.run(
               %{
                 "command" => "printf started; sleep 1; printf done",
                 "cwd" => ".",
                 "timeout_ms" => 2_000
               },
               opts
             )

    assert started.status == "running"
    assert started.command_id =~ "shell-"

    wait_until(fn ->
      {:ok, output} =
        ReadShellCommandOutput.run(%{"command_id" => started.command_id}, opts)

      output.output =~ "started"
    end)

    assert {:ok, stopped} = StopShellCommand.run(%{"command_id" => started.command_id}, opts)
    assert stopped.status in ["stopping", "stopped"]
  end

  test "background shell command progress output is redacted" do
    root = tmp_root("agent-machine-shell-bg-redact")
    opts = tool_opts(root, tool_timeout_ms: 2_000)
    secret = "sk-proj-abcdefghijklmnopqrstuvwxyz123456"

    assert {:ok, started} =
             StartShellCommand.run(
               %{
                 "command" => "printf 'OPENAI_API_KEY=#{secret}'; sleep 1",
                 "cwd" => ".",
                 "timeout_ms" => 2_000
               },
               opts
             )

    wait_until(fn ->
      {:ok, output} =
        ReadShellCommandOutput.run(%{"command_id" => started.command_id}, opts)

      output.output =~ "[REDACTED:secret_assignment]"
    end)

    assert {:ok, output} =
             ReadShellCommandOutput.run(%{"command_id" => started.command_id}, opts)

    refute output.output =~ secret
    refute output.command =~ secret
    assert output.redacted == true

    assert {:ok, _stopped} = StopShellCommand.run(%{"command_id" => started.command_id}, opts)
  end

  defp tool_opts(root, overrides \\ []) do
    Keyword.merge(
      [
        tool_root: root,
        tool_timeout_ms: 1_000,
        tool_event_context: %{run_id: "run-shell-test", agent_id: "agent-shell-test"}
      ],
      overrides
    )
  end

  defp tmp_root(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end

  defp wait_until(callback, attempts \\ 100)

  defp wait_until(callback, attempts) when attempts > 0 do
    if callback.() do
      :ok
    else
      Process.sleep(10)
      wait_until(callback, attempts - 1)
    end
  end

  defp wait_until(_callback, 0), do: flunk("condition was not met before timeout")
end
