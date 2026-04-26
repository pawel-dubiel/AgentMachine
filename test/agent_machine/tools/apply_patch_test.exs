defmodule AgentMachine.Tools.ApplyPatchTest do
  use ExUnit.Case, async: true

  alias AgentMachine.Tools.ApplyPatch

  test "applies a multi-file patch with update, create, and delete" do
    root = tmp_root()
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "one.txt"), "alpha\nold\nomega\n")
    File.write!(Path.join(root, "delete.txt"), "remove\n")

    patch = """
    diff --git a/one.txt b/one.txt
    --- a/one.txt
    +++ b/one.txt
    @@ -1,3 +1,3 @@
     alpha
    -old
    +new
     omega
    diff --git a/new.txt b/new.txt
    --- /dev/null
    +++ b/new.txt
    @@ -0,0 +1,2 @@
    +hello
    +world
    diff --git a/delete.txt b/delete.txt
    --- a/delete.txt
    +++ /dev/null
    @@ -1 +0,0 @@
    -remove
    """

    assert {:ok, %{count: 3}} = ApplyPatch.run(%{"patch" => patch}, tool_root: root)
    assert File.read!(Path.join(root, "one.txt")) == "alpha\nnew\nomega\n"
    assert File.read!(Path.join(root, "new.txt")) == "hello\nworld\n"
    refute File.exists?(Path.join(root, "delete.txt"))
  end

  test "rejects malformed patches" do
    root = tmp_root()
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)

    assert {:error, message} = ApplyPatch.run(%{"patch" => "not a patch"}, tool_root: root)
    assert message =~ "malformed patch"
  end

  test "rejects context mismatches without writing" do
    root = tmp_root()
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)
    path = Path.join(root, "one.txt")
    File.write!(path, "actual\n")

    patch = """
    --- a/one.txt
    +++ b/one.txt
    @@ -1 +1 @@
    -expected
    +changed
    """

    assert {:error, message} = ApplyPatch.run(%{"patch" => patch}, tool_root: root)
    assert message =~ "context mismatch"
    assert File.read!(path) == "actual\n"
  end

  test "rejects binary and rename patches" do
    root = tmp_root()
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)

    assert {:error, binary_message} =
             ApplyPatch.run(%{"patch" => "Binary files a/a.png and b/a.png differ"},
               tool_root: root
             )

    assert binary_message =~ "binary patches"

    rename_patch = """
    diff --git a/old.txt b/new.txt
    rename from old.txt
    rename to new.txt
    """

    assert {:error, rename_message} = ApplyPatch.run(%{"patch" => rename_patch}, tool_root: root)
    assert rename_message =~ "rename patches are not supported"
  end

  test "rejects absolute and traversal patch paths" do
    root = tmp_root()
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)

    absolute_patch = """
    --- /tmp/file.txt
    +++ /tmp/file.txt
    @@ -0,0 +1 @@
    +bad
    """

    assert {:error, absolute_message} =
             ApplyPatch.run(%{"patch" => absolute_patch}, tool_root: root)

    assert absolute_message =~ "patch path must be relative"

    traversal_patch = """
    --- a/../file.txt
    +++ b/../file.txt
    @@ -0,0 +1 @@
    +bad
    """

    assert {:error, traversal_message} =
             ApplyPatch.run(%{"patch" => traversal_patch}, tool_root: root)

    assert traversal_message =~ "must not contain .."
  end

  test "rejects symlink patch targets" do
    root = tmp_root()
    outside = Path.join(System.tmp_dir!(), "outside-#{System.unique_integer()}.txt")

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(outside)
    end)

    File.mkdir_p!(root)
    File.write!(outside, "old\n")
    File.ln_s!(outside, Path.join(root, "link.txt"))

    patch = """
    --- a/link.txt
    +++ b/link.txt
    @@ -1 +1 @@
    -old
    +new
    """

    assert {:error, message} = ApplyPatch.run(%{"patch" => patch}, tool_root: root)
    assert message =~ "symlink"
    assert File.read!(outside) == "old\n"
  end

  test "rejects oversized patch text" do
    root = tmp_root()
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)

    patch = String.duplicate("a", 400_001)
    assert {:error, message} = ApplyPatch.run(%{"patch" => patch}, tool_root: root)
    assert message =~ "patch must be at most 400000 bytes"
  end

  defp tmp_root do
    Path.expand(
      Path.join(System.tmp_dir!(), "agent-machine-apply-patch-#{System.unique_integer()}")
    )
  end
end
