defmodule AgentMachine.Tools.WriteFileTest do
  use ExUnit.Case, async: true

  alias AgentMachine.Tools.WriteFile

  test "writes files under the configured tool root" do
    root =
      Path.expand(Path.join(System.tmp_dir!(), "agent-machine-tools-#{System.unique_integer()}"))

    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)

    assert {:ok, %{path: path, bytes: 5}} =
             WriteFile.run(%{"path" => "hello.md", "content" => "hello"}, tool_root: root)

    assert Path.basename(path) == "hello.md"
    assert File.read!(path) == "hello"
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
end
