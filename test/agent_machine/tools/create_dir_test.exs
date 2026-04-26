defmodule AgentMachine.Tools.CreateDirTest do
  use ExUnit.Case, async: true

  alias AgentMachine.Tools.CreateDir

  test "creates one directory under the configured tool root" do
    root =
      Path.expand(Path.join(System.tmp_dir!(), "agent-machine-mkdir-#{System.unique_integer()}"))

    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)

    assert {:ok, %{path: path, created: true}} =
             CreateDir.run(%{"path" => "notes"}, tool_root: root)

    assert Path.basename(path) == "notes"
    assert File.dir?(path)
  end

  test "reports an existing directory explicitly" do
    root =
      Path.expand(Path.join(System.tmp_dir!(), "agent-machine-mkdir-#{System.unique_integer()}"))

    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(Path.join(root, "notes"))

    assert {:ok, %{path: path, created: false}} =
             CreateDir.run(%{"path" => "notes"}, tool_root: root)

    assert Path.basename(path) == "notes"
  end

  test "requires the parent directory to already exist" do
    root =
      Path.expand(Path.join(System.tmp_dir!(), "agent-machine-mkdir-#{System.unique_integer()}"))

    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)

    assert {:error, message} = CreateDir.run(%{"path" => "missing/notes"}, tool_root: root)
    assert message =~ "parent directory does not exist"
  end

  test "rejects create paths outside the configured root" do
    root =
      Path.expand(Path.join(System.tmp_dir!(), "agent-machine-mkdir-#{System.unique_integer()}"))

    outside = Path.expand(System.tmp_dir!())
    File.mkdir_p!(root)

    assert {:error, message} = CreateDir.run(%{"path" => outside}, tool_root: root)

    assert message =~ outside
    assert message =~ root
  end

  test "rejects symlink paths" do
    root =
      Path.expand(Path.join(System.tmp_dir!(), "agent-machine-mkdir-#{System.unique_integer()}"))

    outside = Path.expand(Path.join(System.tmp_dir!(), "outside-#{System.unique_integer()}"))

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(outside)
    end)

    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    File.ln_s!(outside, Path.join(root, "link"))

    assert {:error, message} = CreateDir.run(%{"path" => "link"}, tool_root: root)
    assert message =~ "symlink"
  end
end
