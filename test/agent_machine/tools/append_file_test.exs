defmodule AgentMachine.Tools.AppendFileTest do
  use ExUnit.Case, async: true

  alias AgentMachine.Tools.AppendFile

  test "appends text to an existing file under the configured root" do
    root = tmp_root("agent-machine-append")

    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "notes.md"), "hello")

    assert {:ok,
            %{path: path, bytes: 6, total_bytes: 11, summary: summary, changed_files: [changed]}} =
             AppendFile.run(%{"path" => "notes.md", "content" => " world"}, tool_root: root)

    assert path == "notes.md"
    assert summary.updated_count == 1
    assert changed.before_bytes == 5
    assert changed.after_bytes == 11
    assert changed.diff_summary == %{added_lines: 1, removed_lines: 1}
    assert File.read!(Path.join(root, path)) == "hello world"
  end

  test "requires the target file to already exist" do
    root = tmp_root("agent-machine-append")

    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)

    assert {:error, message} =
             AppendFile.run(%{"path" => "missing.md", "content" => "hello"}, tool_root: root)

    assert message =~ "does not exist"
  end

  test "rejects symlink append targets" do
    root = tmp_root("agent-machine-append")
    outside = Path.expand(Path.join(System.tmp_dir!(), "outside-#{System.unique_integer()}.md"))

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(outside)
    end)

    File.mkdir_p!(root)
    File.write!(outside, "outside")
    File.ln_s!(outside, Path.join(root, "link.md"))

    assert {:error, message} =
             AppendFile.run(%{"path" => "link.md", "content" => "hello"}, tool_root: root)

    assert message =~ "symlink"
    assert File.read!(outside) == "outside"
  end

  test "rejects appends that would exceed the size limit" do
    root = tmp_root("agent-machine-append")

    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "large.md"), String.duplicate("a", 199_999))

    assert {:error, message} =
             AppendFile.run(%{"path" => "large.md", "content" => "aa"}, tool_root: root)

    assert message =~ "at most 200000 bytes"
  end

  defp tmp_root(prefix),
    do: Path.expand(Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer()}"))
end
