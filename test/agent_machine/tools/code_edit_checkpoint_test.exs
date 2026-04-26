defmodule AgentMachine.Tools.CodeEditCheckpointTest do
  use ExUnit.Case, async: true

  alias AgentMachine.JSON
  alias AgentMachine.Tools.{ApplyEdits, ApplyPatch, RollbackCheckpoint}

  test "apply_edits creates a checkpoint for create, update, delete, and rename" do
    root = tmp_root()
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "source.txt"), "old\n")
    File.write!(Path.join(root, "delete.txt"), "remove\n")
    File.write!(Path.join(root, "rename.txt"), "move\n")

    assert {:ok, result} =
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
                     "op" => "delete_file",
                     "path" => "delete.txt",
                     "expected_sha256" => sha256("remove\n")
                   },
                   %{
                     "op" => "rename_path",
                     "from_path" => "rename.txt",
                     "to_path" => "renamed.txt",
                     "overwrite" => false
                   }
                 ]
               },
               tool_root: root
             )

    assert result.summary.tool == "apply_edits"
    assert result.summary.status == "changed"
    assert result.summary.requested_count == 4
    assert result.summary.renamed_count == 1
    assert result.summary.created_count == 2
    assert result.summary.updated_count == 1
    assert result.summary.deleted_count == 2
    assert result.checkpoint.id == result.checkpoint_id
    assert result.checkpoint.path == result.checkpoint_path
    assert Enum.all?(result.changed_files, &(not String.starts_with?(&1.path, root)))
    assert Enum.all?(result.changed_files, &(not Map.has_key?(&1, :content)))

    source_summary = Enum.find(result.changed_files, &(&1.path == "source.txt"))
    assert source_summary.before_bytes == 4
    assert source_summary.after_bytes == 4
    assert source_summary.diff_summary == %{added_lines: 1, removed_lines: 1}

    manifest = read_manifest!(result)
    assert manifest["tool"] == "apply_edits"
    assert manifest["status"] == "applied"

    assert manifest["affected_paths"] |> Enum.sort() ==
             ["created.txt", "delete.txt", "rename.txt", "renamed.txt", "source.txt"]

    created = entry!(manifest, "created.txt")
    assert created["before"]["state"] == "missing"
    assert created["after"]["sha256"] == sha256("created\n")

    updated = entry!(manifest, "source.txt")
    assert updated["before"]["sha256"] == sha256("old\n")
    assert updated["after"]["sha256"] == sha256("new\n")

    deleted = entry!(manifest, "delete.txt")
    assert deleted["before"]["sha256"] == sha256("remove\n")
    assert deleted["after"]["state"] == "missing"

    renamed_from = entry!(manifest, "rename.txt")
    renamed_to = entry!(manifest, "renamed.txt")
    assert renamed_from["before"]["sha256"] == sha256("move\n")
    assert renamed_from["after"]["state"] == "missing"
    assert renamed_to["before"]["state"] == "missing"
    assert renamed_to["after"]["sha256"] == sha256("move\n")
  end

  test "apply_patch creates a checkpoint for create, update, and delete" do
    root = tmp_root()
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "source.txt"), "old\n")
    File.write!(Path.join(root, "delete.txt"), "remove\n")

    patch = """
    --- a/source.txt
    +++ b/source.txt
    @@ -1 +1 @@
    -old
    +new
    --- /dev/null
    +++ b/created.txt
    @@ -0,0 +1 @@
    +created
    --- a/delete.txt
    +++ /dev/null
    @@ -1 +0,0 @@
    -remove
    """

    assert {:ok, result} = ApplyPatch.run(%{"patch" => patch}, tool_root: root)

    assert result.summary.tool == "apply_patch"
    assert result.summary.created_count == 1
    assert result.summary.updated_count == 1
    assert result.summary.deleted_count == 1

    assert Enum.find(result.changed_files, &(&1.path == "source.txt")).diff_summary ==
             %{added_lines: 1, removed_lines: 1}

    assert Enum.find(result.changed_files, &(&1.path == "created.txt")).diff_summary ==
             %{added_lines: 1, removed_lines: 0}

    assert result.patch_files == [
             %{path: "source.txt", action: "update"},
             %{path: "created.txt", action: "create"},
             %{path: "delete.txt", action: "delete"}
           ]

    manifest = read_manifest!(result)
    assert manifest["tool"] == "apply_patch"

    assert manifest["affected_paths"] |> Enum.sort() == [
             "created.txt",
             "delete.txt",
             "source.txt"
           ]

    assert entry!(manifest, "source.txt")["after"]["sha256"] == sha256("new\n")
    assert entry!(manifest, "created.txt")["before"]["state"] == "missing"
    assert entry!(manifest, "delete.txt")["after"]["state"] == "missing"
  end

  test "validation failures do not create checkpoints or write files" do
    root = tmp_root()
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "source.txt"), "old")

    assert {:error, message} =
             ApplyEdits.run(
               %{
                 "changes" => [
                   %{
                     "op" => "replace",
                     "path" => "source.txt",
                     "old_text" => "missing",
                     "new_text" => "new",
                     "expected_replacements" => 1
                   }
                 ]
               },
               tool_root: root
             )

    assert message =~ "expected 1 replacements but found 0"
    assert File.read!(Path.join(root, "source.txt")) == "old"
    refute File.exists?(Path.join(root, ".agent_machine/checkpoints"))
  end

  test "code-edit mutations reject checkpoint storage paths" do
    root = tmp_root()
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(Path.join(root, ".agent_machine/checkpoints"))

    assert {:error, message} =
             ApplyEdits.run(
               %{
                 "changes" => [
                   %{
                     "op" => "create_file",
                     "path" => ".agent_machine/checkpoints/tamper.txt",
                     "content" => "bad",
                     "overwrite" => false
                   }
                 ]
               },
               tool_root: root
             )

    assert message =~ "checkpoint storage"
  end

  test "rollback restores changed files and creates a rollback checkpoint" do
    root = tmp_root()
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "source.txt"), "old")

    {:ok, edit} =
      ApplyEdits.run(
        %{
          "changes" => [
            %{
              "op" => "replace",
              "path" => "source.txt",
              "old_text" => "old",
              "new_text" => "new",
              "expected_replacements" => 1
            }
          ]
        },
        tool_root: root
      )

    assert File.read!(Path.join(root, "source.txt")) == "new"

    assert {:ok, rollback} =
             RollbackCheckpoint.run(%{"checkpoint_id" => edit.checkpoint_id}, tool_root: root)

    assert File.read!(Path.join(root, "source.txt")) == "old"
    assert rollback.rolled_back_checkpoint_id == edit.checkpoint_id
    assert rollback.checkpoint_id != edit.checkpoint_id
    assert rollback.summary.tool == "rollback_checkpoint"
    assert rollback.summary.updated_count == 1
    assert read_manifest!(rollback)["tool"] == "rollback_checkpoint"
  end

  test "rollback removes files that did not exist before" do
    root = tmp_root()
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)

    {:ok, edit} =
      ApplyEdits.run(
        %{
          "changes" => [
            %{
              "op" => "create_file",
              "path" => "created.txt",
              "content" => "created",
              "overwrite" => false
            }
          ]
        },
        tool_root: root
      )

    assert {:ok, _rollback} =
             RollbackCheckpoint.run(%{"checkpoint_id" => edit.checkpoint_id}, tool_root: root)

    refute File.exists?(Path.join(root, "created.txt"))
  end

  test "rollback recreates deleted files" do
    root = tmp_root()
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "delete.txt"), "remove")

    {:ok, edit} =
      ApplyEdits.run(
        %{
          "changes" => [
            %{
              "op" => "delete_file",
              "path" => "delete.txt",
              "expected_sha256" => sha256("remove")
            }
          ]
        },
        tool_root: root
      )

    refute File.exists?(Path.join(root, "delete.txt"))

    assert {:ok, _rollback} =
             RollbackCheckpoint.run(%{"checkpoint_id" => edit.checkpoint_id}, tool_root: root)

    assert File.read!(Path.join(root, "delete.txt")) == "remove"
  end

  test "rollback handles renamed files" do
    root = tmp_root()
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "old.txt"), "move")

    {:ok, edit} =
      ApplyEdits.run(
        %{
          "changes" => [
            %{
              "op" => "rename_path",
              "from_path" => "old.txt",
              "to_path" => "new.txt",
              "overwrite" => false
            }
          ]
        },
        tool_root: root
      )

    assert File.read!(Path.join(root, "new.txt")) == "move"
    refute File.exists?(Path.join(root, "old.txt"))

    assert {:ok, _rollback} =
             RollbackCheckpoint.run(%{"checkpoint_id" => edit.checkpoint_id}, tool_root: root)

    assert File.read!(Path.join(root, "old.txt")) == "move"
    refute File.exists?(Path.join(root, "new.txt"))
  end

  test "rollback fails without writing when files changed after the checkpoint" do
    root = tmp_root()
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "source.txt"), "old")

    {:ok, edit} =
      ApplyEdits.run(
        %{
          "changes" => [
            %{
              "op" => "replace",
              "path" => "source.txt",
              "old_text" => "old",
              "new_text" => "new",
              "expected_replacements" => 1
            }
          ]
        },
        tool_root: root
      )

    File.write!(Path.join(root, "source.txt"), "manual")

    assert {:error, message} =
             RollbackCheckpoint.run(%{"checkpoint_id" => edit.checkpoint_id}, tool_root: root)

    assert message =~ "current path state differs"
    assert File.read!(Path.join(root, "source.txt")) == "manual"
  end

  test "rollback rejects path traversal and unknown checkpoint ids" do
    root = tmp_root()
    on_exit(fn -> File.rm_rf(root) end)
    File.mkdir_p!(root)

    assert {:error, traversal_message} =
             RollbackCheckpoint.run(%{"checkpoint_id" => "../bad"}, tool_root: root)

    assert traversal_message =~ "checkpoint_id is invalid"

    assert {:error, unknown_message} =
             RollbackCheckpoint.run(%{"checkpoint_id" => "20260426T000000Z-1"}, tool_root: root)

    assert unknown_message =~ "unknown checkpoint_id"
  end

  defp read_manifest!(%{checkpoint_path: checkpoint_path}) do
    checkpoint_path
    |> Path.join("manifest.json")
    |> File.read!()
    |> JSON.decode!()
  end

  defp entry!(manifest, path) do
    Enum.find(manifest["entries"], &(&1["path"] == path)) ||
      flunk("missing manifest entry for #{path}")
  end

  defp tmp_root do
    Path.expand(
      Path.join(
        System.tmp_dir!(),
        "agent-machine-code-edit-checkpoint-#{System.unique_integer()}"
      )
    )
  end

  defp sha256(content) do
    :sha256
    |> :crypto.hash(content)
    |> Base.encode16(case: :lower)
  end
end
