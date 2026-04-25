defmodule AgentMachine.Tools.WriteFileTest do
  use ExUnit.Case, async: true

  alias AgentMachine.Tools.WriteFile

  test "writes files under the configured tool root" do
    root =
      Path.expand(Path.join(System.tmp_dir!(), "agent-machine-tools-#{System.unique_integer()}"))

    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, %{path: path, bytes: 5}} =
             WriteFile.run(%{"path" => "hello.md", "content" => "hello"}, tool_root: root)

    assert path == Path.join(root, "hello.md")
    assert File.read!(path) == "hello"
  end

  test "rejects paths outside the configured tool root" do
    root =
      Path.expand(Path.join(System.tmp_dir!(), "agent-machine-tools-#{System.unique_integer()}"))

    outside = Path.expand(Path.join(System.tmp_dir!(), "outside.md"))

    assert {:error, {:outside_tool_root, ^outside, ^root}} =
             WriteFile.run(%{"path" => outside, "content" => "hello"}, tool_root: root)
  end
end
