defmodule AgentMachine.Tools.ReadFileTest do
  use ExUnit.Case, async: true

  alias AgentMachine.Tools.ReadFile

  test "reads files under the configured tool root" do
    root =
      Path.expand(Path.join(System.tmp_dir!(), "agent-machine-read-#{System.unique_integer()}"))

    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "hello.md"), "hello")

    assert {:ok, %{path: path, content: "hello", bytes: 5, truncated: false}} =
             ReadFile.run(%{"path" => "hello.md", "max_bytes" => 100}, tool_root: root)

    assert Path.basename(path) == "hello.md"
  end

  test "truncates reads at the explicit byte limit" do
    root =
      Path.expand(Path.join(System.tmp_dir!(), "agent-machine-read-#{System.unique_integer()}"))

    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "hello.md"), "hello")

    assert {:ok, %{content: "he", bytes: 2, truncated: true}} =
             ReadFile.run(%{"path" => "hello.md", "max_bytes" => 2}, tool_root: root)
  end

  test "rejects read paths outside the configured root" do
    root =
      Path.expand(Path.join(System.tmp_dir!(), "agent-machine-read-#{System.unique_integer()}"))

    outside = Path.expand(Path.join(System.tmp_dir!(), "outside.md"))

    File.mkdir_p!(root)

    assert {:error, message} =
             ReadFile.run(%{"path" => outside, "max_bytes" => 100}, tool_root: root)

    assert message =~ outside
    assert message =~ root
  end

  test "rejects directory reads" do
    root =
      Path.expand(Path.join(System.tmp_dir!(), "agent-machine-read-#{System.unique_integer()}"))

    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)

    assert {:error, message} =
             ReadFile.run(%{"path" => ".", "max_bytes" => 100}, tool_root: root)

    assert message =~ "regular file"
  end

  test "rejects symlinks that resolve outside the configured root" do
    root =
      Path.expand(Path.join(System.tmp_dir!(), "agent-machine-read-#{System.unique_integer()}"))

    outside = Path.expand(Path.join(System.tmp_dir!(), "outside-#{System.unique_integer()}.md"))

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(outside)
    end)

    File.mkdir_p!(root)
    File.write!(outside, "outside")
    File.ln_s!(outside, Path.join(root, "link.md"))

    assert {:error, message} =
             ReadFile.run(%{"path" => "link.md", "max_bytes" => 100}, tool_root: root)

    assert message =~ "outside tool root"
  end
end
