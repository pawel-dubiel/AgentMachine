defmodule AgentMachine.Tools.ReplaceInFileTest do
  use ExUnit.Case, async: true

  alias AgentMachine.Tools.ReplaceInFile

  test "replaces exact text when the expected count matches" do
    root = tmp_root("agent-machine-replace")

    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "notes.md"), "hello old\nold")

    assert {:ok,
            %{path: path, replacements: 2, bytes: 17, summary: summary, changed_files: [changed]}} =
             ReplaceInFile.run(
               %{
                 "path" => "notes.md",
                 "old_text" => "old",
                 "new_text" => "newer",
                 "expected_replacements" => 2
               },
               tool_root: root
             )

    assert path == "notes.md"
    assert summary.tool == "replace_in_file"
    assert summary.updated_count == 1
    assert changed.diff_summary == %{added_lines: 2, removed_lines: 2}
    assert File.read!(Path.join(root, path)) == "hello newer\nnewer"
  end

  test "rejects replacement count mismatches without writing" do
    root = tmp_root("agent-machine-replace")
    path = Path.join(root, "notes.md")

    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)
    File.write!(path, "hello old")

    assert {:error, message} =
             ReplaceInFile.run(
               %{
                 "path" => "notes.md",
                 "old_text" => "old",
                 "new_text" => "new",
                 "expected_replacements" => 2
               },
               tool_root: root
             )

    assert message =~ "expected 2 replacements but found 1"
    assert File.read!(path) == "hello old"
  end

  test "rejects symlink replacement targets" do
    root = tmp_root("agent-machine-replace")
    outside = Path.expand(Path.join(System.tmp_dir!(), "outside-#{System.unique_integer()}.md"))

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(outside)
    end)

    File.mkdir_p!(root)
    File.write!(outside, "outside old")
    File.ln_s!(outside, Path.join(root, "link.md"))

    assert {:error, message} =
             ReplaceInFile.run(
               %{
                 "path" => "link.md",
                 "old_text" => "old",
                 "new_text" => "new",
                 "expected_replacements" => 1
               },
               tool_root: root
             )

    assert message =~ "symlink"
    assert File.read!(outside) == "outside old"
  end

  test "rejects oversized replacement results" do
    root = tmp_root("agent-machine-replace")
    path = Path.join(root, "notes.md")

    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)
    File.write!(path, "x")

    assert {:error, message} =
             ReplaceInFile.run(
               %{
                 "path" => "notes.md",
                 "old_text" => "x",
                 "new_text" => String.duplicate("a", 200_001),
                 "expected_replacements" => 1
               },
               tool_root: root
             )

    assert message =~ "new_text must be at most 200000 bytes"
    assert File.read!(path) == "x"
  end

  defp tmp_root(prefix),
    do: Path.expand(Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer()}"))
end
