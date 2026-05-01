defmodule AgentMachine.Tools.WriteFileTest do
  use ExUnit.Case, async: true

  alias AgentMachine.Tools.WriteFile

  test "writes files under the configured tool root" do
    root =
      Path.expand(Path.join(System.tmp_dir!(), "agent-machine-tools-#{System.unique_integer()}"))

    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)

    assert {:ok, %{path: path, bytes: 5, summary: summary, changed_files: [changed]}} =
             WriteFile.run(%{"path" => "hello.md", "content" => "hello"}, tool_root: root)

    assert path == "hello.md"
    assert summary.tool == "write_file"
    assert summary.created_count == 1
    assert changed.path == "hello.md"
    assert changed.action == "created"
    assert changed.after_bytes == 5
    assert changed.diff_summary == %{added_lines: 1, removed_lines: 0}
    refute Map.has_key?(changed, :content)
    assert File.read!(Path.join(root, path)) == "hello"
  end

  test "reports identical rewrites as unchanged" do
    root =
      Path.expand(Path.join(System.tmp_dir!(), "agent-machine-tools-#{System.unique_integer()}"))

    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "hello.md"), "hello")

    assert {:ok, %{summary: summary, changed_files: [changed]}} =
             WriteFile.run(%{"path" => "hello.md", "content" => "hello"}, tool_root: root)

    assert summary.status == "unchanged"
    assert summary.changed_count == 0
    assert summary.updated_count == 0
    assert changed.action == "unchanged"
    assert changed.before_sha256 == changed.after_sha256
    assert changed.diff_summary == %{added_lines: 0, removed_lines: 0}
  end

  test "rejects paths outside the configured tool root" do
    root =
      Path.expand(Path.join(System.tmp_dir!(), "agent-machine-tools-#{System.unique_integer()}"))

    outside = Path.expand(Path.join(System.tmp_dir!(), "outside.md"))

    File.mkdir_p!(root)

    assert {:error, message} =
             WriteFile.run(%{"path" => outside, "content" => "hello"}, tool_root: root)

    assert message =~ outside
    assert message =~ root
  end

  test "accepts absolute paths through a symlinked parent when they resolve inside root" do
    real_parent =
      Path.expand(Path.join(System.tmp_dir!(), "agent-machine-real-#{System.unique_integer()}"))

    link_parent =
      Path.expand(Path.join(System.tmp_dir!(), "agent-machine-link-#{System.unique_integer()}"))

    on_exit(fn ->
      File.rm_rf(real_parent)
      File.rm_rf(link_parent)
    end)

    File.mkdir_p!(real_parent)
    File.ln_s!(real_parent, link_parent)

    root = Path.join(link_parent, "root")
    File.mkdir_p!(root)

    assert {:ok, %{path: "hello.md"}} =
             WriteFile.run(%{"path" => Path.join(root, "hello.md"), "content" => "hello"},
               tool_root: root
             )

    assert File.read!(Path.join([real_parent, "root", "hello.md"])) == "hello"
  end

  test "rejects symlink write targets" do
    root =
      Path.expand(Path.join(System.tmp_dir!(), "agent-machine-tools-#{System.unique_integer()}"))

    outside = Path.expand(Path.join(System.tmp_dir!(), "outside-#{System.unique_integer()}.md"))

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(outside)
    end)

    File.mkdir_p!(root)
    File.write!(outside, "outside")
    File.ln_s!(outside, Path.join(root, "link.md"))

    assert {:error, message} =
             WriteFile.run(%{"path" => "link.md", "content" => "hello"}, tool_root: root)

    assert message =~ "symlink"
    assert File.read!(outside) == "outside"
  end

  test "rejects oversized writes" do
    root =
      Path.expand(Path.join(System.tmp_dir!(), "agent-machine-tools-#{System.unique_integer()}"))

    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)

    content = String.duplicate("a", 200_001)

    assert {:error, message} =
             WriteFile.run(%{"path" => "large.md", "content" => content}, tool_root: root)

    assert message =~ "at most 200000 bytes"
    refute File.exists?(Path.join(root, "large.md"))
  end
end
