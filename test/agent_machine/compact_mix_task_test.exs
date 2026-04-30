defmodule AgentMachine.CompactMixTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.AgentMachine.Compact

  setup do
    Mix.Task.reenable("agent_machine.compact")
    :ok
  end

  test "mix agent_machine.compact prints a JSON compaction summary" do
    input_file =
      write_input!(%{
        type: "conversation",
        messages: [
          %{role: "user", text: "Research latest Poland news"},
          %{role: "assistant", text: "I need browsing tools"}
        ]
      })

    output =
      capture_io(fn ->
        Compact.run([
          "--provider",
          "echo",
          "--model",
          "echo",
          "--http-timeout-ms",
          "1000",
          "--input-price-per-million",
          "0",
          "--output-price-per-million",
          "0",
          "--input-file",
          input_file,
          "--json"
        ])
      end)

    decoded = output |> String.trim() |> AgentMachine.JSON.decode!()
    assert decoded["status"] == "ok"
    assert decoded["summary"] == "Echo compacted conversation context."
    assert decoded["covered_items"] == ["1", "2"]
    assert decoded["usage"]["total_tokens"] > 0
  end

  test "mix agent_machine.compact fails fast without required options" do
    input_file = write_input!(%{type: "conversation", messages: [%{role: "user", text: "hello"}]})

    assert_raise Mix.Error, ~r/missing required --provider option/, fn ->
      Compact.run([
        "--model",
        "echo",
        "--http-timeout-ms",
        "1000",
        "--input-price-per-million",
        "0",
        "--output-price-per-million",
        "0",
        "--input-file",
        input_file,
        "--json"
      ])
    end
  end

  test "mix agent_machine.compact requires JSON output mode" do
    input_file = write_input!(%{type: "conversation", messages: [%{role: "user", text: "hello"}]})

    assert_raise Mix.Error, ~r/requires --json/, fn ->
      Compact.run([
        "--provider",
        "echo",
        "--model",
        "echo",
        "--http-timeout-ms",
        "1000",
        "--input-price-per-million",
        "0",
        "--output-price-per-million",
        "0",
        "--input-file",
        input_file
      ])
    end
  end

  defp write_input!(payload) do
    path =
      Path.join(System.tmp_dir!(), "agent-machine-compact-test-#{System.unique_integer()}.json")

    File.write!(path, AgentMachine.JSON.encode!(payload))
    on_exit(fn -> File.rm(path) end)
    path
  end
end
