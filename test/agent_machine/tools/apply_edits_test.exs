defmodule AgentMachine.Tools.ApplyEditsTest do
  use ExUnit.Case, async: true

  alias AgentMachine.Tools.ApplyEdits

  test "creates, replaces, inserts, renames, and deletes in one validated batch" do
    root = tmp_root()
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)

    source = Path.join(root, "source.txt")
    delete_me = Path.join(root, "delete.txt")
    File.write!(source, "one\nanchor\nold\n")
    File.write!(delete_me, "remove me")

    assert {:ok, %{count: 5}} =
             ApplyEdits.run(
               %{
                 "changes" => [
                   %{
                     "op" => "create_file",
                     "path" => "created.txt",
                     "content" => "created\n",
                     "overwrite" => false
                   },
                   %{
                     "op" => "replace",
                     "path" => "source.txt",
                     "old_text" => "old",
                     "new_text" => "new",
                     "expected_replacements" => 1
                   },
                   %{
                     "op" => "insert_after",
                     "path" => "source.txt",
                     "anchor" => "anchor\n",
                     "text" => "inserted\n",
                     "expected_replacements" => 1
                   },
                   %{
                     "op" => "rename_path",
                     "from_path" => "created.txt",
                     "to_path" => "renamed.txt",
                     "overwrite" => false
                   },
                   %{
                     "op" => "delete_file",
                     "path" => "delete.txt",
                     "expected_sha256" => sha256("remove me")
                   }
                 ]
               },
               tool_root: root
             )

    assert File.read!(source) == "one\nanchor\ninserted\nnew\n"
    assert File.read!(Path.join(root, "renamed.txt")) == "created\n"
    refute File.exists?(Path.join(root, "created.txt"))
    refute File.exists?(delete_me)
  end

  test "rejects count mismatches without partial writes" do
    root = tmp_root()
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)

    first = Path.join(root, "first.txt")
    second = Path.join(root, "second.txt")
    File.write!(first, "first")
    File.write!(second, "old")

    assert {:error, message} =
             ApplyEdits.run(
               %{
                 "changes" => [
                   %{
                     "op" => "replace",
                     "path" => "first.txt",
                     "old_text" => "first",
                     "new_text" => "changed",
                     "expected_replacements" => 1
                   },
                   %{
                     "op" => "replace",
                     "path" => "second.txt",
                     "old_text" => "missing",
                     "new_text" => "changed",
                     "expected_replacements" => 1
                   }
                 ]
               },
               tool_root: root
             )

    assert message =~ "expected 1 replacements but found 0"
    assert File.read!(first) == "first"
    assert File.read!(second) == "old"
  end

  test "rejects delete hash mismatches" do
    root = tmp_root()
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)
    path = Path.join(root, "delete.txt")
    File.write!(path, "real content")

    assert {:error, message} =
             ApplyEdits.run(
               %{
                 "changes" => [
                   %{
                     "op" => "delete_file",
                     "path" => "delete.txt",
                     "expected_sha256" => sha256("other content")
                   }
                 ]
               },
               tool_root: root
             )

    assert message =~ "expected_sha256 does not match"
    assert File.exists?(path)
  end

  test "rejects overwrite without explicit permission" do
    root = tmp_root()
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "exists.txt"), "exists")

    assert {:error, message} =
             ApplyEdits.run(
               %{
                 "changes" => [
                   %{
                     "op" => "create_file",
                     "path" => "exists.txt",
                     "content" => "new",
                     "overwrite" => false
                   }
                 ]
               },
               tool_root: root
             )

    assert message =~ "path already exists"
    assert File.read!(Path.join(root, "exists.txt")) == "exists"
  end

  test "rejects invalid UTF-8 content" do
    root = tmp_root()
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)

    assert {:error, message} =
             ApplyEdits.run(
               %{
                 "changes" => [
                   %{
                     "op" => "create_file",
                     "path" => "bad.txt",
                     "content" => <<255>>,
                     "overwrite" => false
                   }
                 ]
               },
               tool_root: root
             )

    assert message =~ "valid UTF-8"
  end

  test "rejects outside-root paths and symlink targets" do
    root = tmp_root()
    outside = Path.join(System.tmp_dir!(), "outside-#{System.unique_integer()}.txt")

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(outside)
    end)

    File.mkdir_p!(root)
    File.write!(outside, "outside")
    File.ln_s!(outside, Path.join(root, "link.txt"))

    assert {:error, outside_message} =
             ApplyEdits.run(
               %{
                 "changes" => [
                   %{
                     "op" => "create_file",
                     "path" => outside,
                     "content" => "new",
                     "overwrite" => true
                   }
                 ]
               },
               tool_root: root
             )

    assert outside_message =~ "outside tool root"

    assert {:error, symlink_message} =
             ApplyEdits.run(
               %{
                 "changes" => [
                   %{
                     "op" => "replace",
                     "path" => "link.txt",
                     "old_text" => "outside",
                     "new_text" => "changed",
                     "expected_replacements" => 1
                   }
                 ]
               },
               tool_root: root
             )

    assert symlink_message =~ "symlink"
    assert File.read!(outside) == "outside"
  end

  test "requires the configured root to exist" do
    root = tmp_root()

    assert {:error, message} =
             ApplyEdits.run(
               %{
                 "changes" => [
                   %{
                     "op" => "create_file",
                     "path" => "new.txt",
                     "content" => "new",
                     "overwrite" => false
                   }
                 ]
               },
               tool_root: root
             )

    assert message =~ "tool root does not exist"
  end

  defp tmp_root do
    Path.expand(
      Path.join(System.tmp_dir!(), "agent-machine-apply-edits-#{System.unique_integer()}")
    )
  end

  defp sha256(content) do
    :sha256
    |> :crypto.hash(content)
    |> Base.encode16(case: :lower)
  end
end
