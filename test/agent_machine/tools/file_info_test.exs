defmodule AgentMachine.Tools.FileInfoTest do
  use ExUnit.Case, async: true

  alias AgentMachine.Tools.FileInfo

  test "returns metadata without following a final symlink" do
    root = tmp_root("agent-machine-file-info")
    outside = Path.expand(Path.join(System.tmp_dir!(), "outside-#{System.unique_integer()}.md"))

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(outside)
    end)

    File.mkdir_p!(root)
    File.write!(outside, "outside")
    File.ln_s!(outside, Path.join(root, "link.md"))

    assert {:ok, %{path: path, type: "symlink", size: _size, mtime: mtime}} =
             FileInfo.run(%{"path" => "link.md"}, tool_root: root)

    assert Path.basename(path) == "link.md"
    assert mtime =~ "T"
  end

  test "rejects parent symlinks that escape the configured root" do
    root = tmp_root("agent-machine-file-info")
    outside = tmp_root("agent-machine-file-info-outside")

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(outside)
    end)

    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.md"), "secret")
    File.ln_s!(outside, Path.join(root, "outside"))

    assert {:error, message} =
             FileInfo.run(%{"path" => "outside/secret.md"}, tool_root: root)

    assert message =~ "outside tool root"
  end

  defp tmp_root(prefix),
    do: Path.expand(Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer()}"))
end
