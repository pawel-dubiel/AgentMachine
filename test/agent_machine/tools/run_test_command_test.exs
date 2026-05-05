defmodule AgentMachine.Tools.RunTestCommandTest do
  use ExUnit.Case, async: true

  alias AgentMachine.Tools.RunTestCommand

  test "runs an exact allowlisted command under the tool root" do
    root = tmp_root()

    assert {:ok, result} =
             RunTestCommand.run(%{"command" => "elixir -e IO.puts(1)", "cwd" => "."},
               tool_root: root,
               test_commands: ["elixir -e IO.puts(1)"],
               tool_timeout_ms: 15_000
             )

    assert result.command == "elixir -e IO.puts(1)"
    assert Path.basename(result.cwd) == Path.basename(root)
    assert result.exit_status == 0
    assert result.timed_out == false
    assert result.output =~ "1"
    assert result.output_truncated == false
    assert is_integer(result.duration_ms)
  end

  test "returns nonzero exit status as a tool result" do
    root = tmp_root()

    assert {:ok, %{exit_status: 7, timed_out: false}} =
             RunTestCommand.run(%{"command" => "elixir -e System.halt(7)", "cwd" => "."},
               tool_root: root,
               test_commands: ["elixir -e System.halt(7)"],
               tool_timeout_ms: 15_000
             )
  end

  test "rejects unknown command variants" do
    root = tmp_root()

    assert {:error, message} =
             RunTestCommand.run(%{"command" => "mix test --trace", "cwd" => "."},
               tool_root: root,
               test_commands: ["mix test"],
               tool_timeout_ms: 1_000
             )

    assert message =~ "not in allowed test commands"
  end

  test "rejects unsafe command syntax" do
    root = tmp_root()

    for command <- [
          "mix test && rm -rf tmp",
          "mix test | cat",
          "mix test > out.txt",
          "FOO=bar mix test",
          "mix $(echo test)",
          "mix `echo test`",
          "/bin/echo hello",
          ""
        ] do
      assert {:error, message} =
               RunTestCommand.run(%{"command" => command, "cwd" => "."},
                 tool_root: root,
                 test_commands: [command],
                 tool_timeout_ms: 1_000
               )

      assert message =~ "command"
    end
  end

  test "rejects missing or outside cwd" do
    root = tmp_root()
    outside = tmp_root()

    assert {:error, missing} =
             RunTestCommand.run(%{"command" => "elixir -v", "cwd" => "missing"},
               tool_root: root,
               test_commands: ["elixir -v"],
               tool_timeout_ms: 1_000
             )

    assert missing =~ "path does not exist"

    assert {:error, outside_message} =
             RunTestCommand.run(%{"command" => "elixir -v", "cwd" => outside},
               tool_root: root,
               test_commands: ["elixir -v"],
               tool_timeout_ms: 1_000
             )

    assert outside_message =~ "outside tool root"
  end

  test "times out long running commands" do
    root = tmp_root()

    assert {:ok, result} =
             RunTestCommand.run(%{"command" => "elixir -e Process.sleep(1000)", "cwd" => "."},
               tool_root: root,
               test_commands: ["elixir -e Process.sleep(1000)"],
               tool_timeout_ms: 10
             )

    assert result.exit_status == nil
    assert result.timed_out == true
    assert result.duration_ms >= 0
  end

  test "redacts sensitive command output" do
    root = tmp_root()

    assert {:ok, result} =
             RunTestCommand.run(
               %{
                 "command" =>
                   "elixir -e IO.puts(\"OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz123456\")",
                 "cwd" => "."
               },
               tool_root: root,
               test_commands: [
                 "elixir -e IO.puts(\"OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz123456\")"
               ],
               tool_timeout_ms: 15_000
             )

    refute result.output =~ "sk-proj-abcdefghijklmnopqrstuvwxyz123456"
    assert result.redacted == true
  end

  defp tmp_root do
    root =
      Path.expand(
        Path.join(System.tmp_dir!(), "agent-machine-test-command-#{System.unique_integer()}")
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end
end
