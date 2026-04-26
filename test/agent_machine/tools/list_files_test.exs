defmodule AgentMachine.Tools.ListFilesTest do
  use ExUnit.Case, async: true

  alias AgentMachine.Tools.ListFiles

  test "lists direct children under the configured tool root" do
    root =
      Path.expand(Path.join(System.tmp_dir!(), "agent-machine-list-#{System.unique_integer()}"))

    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(Path.join(root, "notes"))
    File.write!(Path.join(root, "hello.md"), "hello")

    assert {:ok, %{path: path, entries: entries, truncated: false}} =
             ListFiles.run(%{"path" => ".", "max_entries" => 10}, tool_root: root)

    assert Path.basename(path) == Path.basename(root)
    assert Enum.map(entries, & &1.name) == ["hello.md", "notes"]
    assert Enum.find(entries, &(&1.name == "hello.md")).type == "regular"
    assert Enum.find(entries, &(&1.name == "notes")).type == "directory"
  end

  test "limits listed entries" do
    root =
      Path.expand(Path.join(System.tmp_dir!(), "agent-machine-list-#{System.unique_integer()}"))

    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "a.md"), "a")
    File.write!(Path.join(root, "b.md"), "b")

    assert {:ok, %{entries: [%{name: "a.md"}], truncated: true}} =
             ListFiles.run(%{"path" => ".", "max_entries" => 1}, tool_root: root)
  end

  test "rejects list paths outside the configured root" do
    root =
      Path.expand(Path.join(System.tmp_dir!(), "agent-machine-list-#{System.unique_integer()}"))

    outside = Path.expand(System.tmp_dir!())

    File.mkdir_p!(root)

    assert {:error, message} =
             ListFiles.run(%{"path" => outside, "max_entries" => 10}, tool_root: root)

    assert message =~ outside
    assert message =~ root
  end

  test "rejects file paths" do
    root =
      Path.expand(Path.join(System.tmp_dir!(), "agent-machine-list-#{System.unique_integer()}"))

    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "hello.md"), "hello")

    assert {:error, message} =
             ListFiles.run(%{"path" => "hello.md", "max_entries" => 10}, tool_root: root)

    assert message =~ "directory"
  end
end
