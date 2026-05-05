defmodule AgentMachine.SessionWriterTest do
  use ExUnit.Case, async: true

  alias AgentMachine.SessionWriter

  test "write_line_async writes a JSONL line without requiring a synchronous caller reply" do
    {:ok, output} = StringIO.open("")
    {:ok, writer} = SessionWriter.start_link(output: output)

    assert :ok = SessionWriter.write_line_async(writer, ~s({"type":"event"}))

    wait_until(fn ->
      output
      |> StringIO.contents()
      |> elem(1)
      |> String.contains?(~s("type":"event"))
    end)
  end

  defp wait_until(fun, attempts \\ 40)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: flunk("condition was not met")
end
