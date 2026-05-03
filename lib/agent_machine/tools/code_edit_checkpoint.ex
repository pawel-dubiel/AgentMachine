defmodule AgentMachine.Tools.CodeEditCheckpoint do
  @moduledoc false

  alias AgentMachine.JSON
  alias AgentMachine.Tools.{CodeEditSupport, PathGuard, ToolResultSummary}

  @checkpoint_parent [".agent-machine", "checkpoints"]
  @checkpoint_id_pattern ~r/\A\d{8}T\d{6}Z-\d+\z/
  @snapshot_max_files 1_000
  @snapshot_skip_dirs MapSet.new([
                        ".agent-machine",
                        ".agent_machine",
                        ".git",
                        "_build",
                        "deps",
                        "node_modules"
                      ])

  def apply_plan!(root, tool_name, plan) when is_binary(root) and is_binary(tool_name) do
    root = PathGuard.root!(tool_root: root)
    require_plan!(plan)
    plan = secure_plan!(root, plan)

    checkpoint_id = new_checkpoint_id()
    checkpoint_dir = checkpoint_dir(root, checkpoint_id)
    contents_dir = Path.join(checkpoint_dir, "contents")

    ensure_checkpoint_dir!(root, checkpoint_dir, contents_dir)

    manifest =
      root
      |> build_manifest!(checkpoint_id, tool_name, checkpoint_dir, plan)
      |> Map.put("status", "prepared")

    write_manifest!(checkpoint_dir, manifest)

    try do
      CodeEditSupport.write_plan!(plan)
    rescue
      exception in [ArgumentError, File.Error] ->
        reraise ArgumentError,
                [
                  message:
                    "failed applying write plan after checkpoint #{checkpoint_id}: #{Exception.message(exception)}"
                ],
                __STACKTRACE__
    end

    applied_manifest =
      manifest
      |> Map.put("status", "applied")
      |> Map.put("entries", actual_after_entries!(root, checkpoint_dir, manifest["entries"]))

    write_manifest!(checkpoint_dir, applied_manifest)
    result_from_manifest(applied_manifest)
  end

  def rollback!(root, checkpoint_id) when is_binary(root) do
    root = PathGuard.root!(tool_root: root)
    checkpoint_id = require_checkpoint_id!(checkpoint_id)
    manifest = read_manifest!(root, checkpoint_id)
    entries = require_entries!(manifest)
    checkpoint_dir = checkpoint_dir(root, checkpoint_id)

    Enum.each(entries, &verify_current_after_state!(root, &1))

    plan =
      entries
      |> Enum.map(&rollback_plan_entry!(root, checkpoint_dir, &1))
      |> Map.new()

    rollback = apply_plan!(root, "rollback_checkpoint", plan)

    Map.merge(rollback, %{
      rolled_back_checkpoint_id: checkpoint_id,
      restored: rollback.changed
    })
  end

  def prepare_snapshot!(root, tool_name) when is_binary(root) and is_binary(tool_name) do
    root = PathGuard.root!(tool_root: root)
    checkpoint_id = new_checkpoint_id()
    checkpoint_dir = checkpoint_dir(root, checkpoint_id)
    contents_dir = Path.join(checkpoint_dir, "contents")
    ensure_checkpoint_dir!(root, checkpoint_dir, contents_dir)

    paths = snapshot_paths!(root)

    entries =
      Enum.map(paths, fn path ->
        %{
          "path" => relative_path!(root, path),
          "before" => path |> read_disk_state!() |> store_state_content!(checkpoint_dir)
        }
      end)

    manifest = %{
      "id" => checkpoint_id,
      "created_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "tool" => tool_name,
      "checkpoint_path" => checkpoint_dir,
      "status" => "prepared",
      "snapshot" => true,
      "entries" => entries
    }

    write_manifest!(checkpoint_dir, manifest)

    %{
      checkpoint_id: checkpoint_id,
      checkpoint_path: checkpoint_dir,
      checkpoint: %{id: checkpoint_id, path: checkpoint_dir},
      count: length(entries)
    }
  end

  def finalize_snapshot!(root, checkpoint_id) when is_binary(root) and is_binary(checkpoint_id) do
    root = PathGuard.root!(tool_root: root)
    manifest = read_manifest!(root, checkpoint_id)

    unless manifest["snapshot"] == true do
      raise ArgumentError, "checkpoint is not a shell snapshot: #{inspect(checkpoint_id)}"
    end

    checkpoint_dir = checkpoint_dir(root, checkpoint_id)
    before_entries = Map.get(manifest, "entries", [])
    before_by_path = Map.new(before_entries, &{Map.fetch!(&1, "path"), Map.fetch!(&1, "before")})
    after_paths = snapshot_paths!(root) |> Enum.map(&relative_path!(root, &1))

    entries =
      before_by_path
      |> Map.keys()
      |> Kernel.++(after_paths)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn relative ->
        path = Path.expand(relative, root)
        before = Map.get(before_by_path, relative, missing_state())
        after_state = path |> read_disk_state!() |> store_state_content!(checkpoint_dir)

        %{
          "path" => relative,
          "before" => before,
          "after" => after_state
        }
      end)
      |> Enum.reject(fn entry ->
        comparable_state(entry["before"]) == comparable_state(entry["after"])
      end)

    applied_manifest =
      manifest
      |> Map.put("status", "applied")
      |> Map.put("affected_paths", Enum.map(entries, & &1["path"]))
      |> Map.put("entries", entries)

    write_manifest!(checkpoint_dir, applied_manifest)
    result_from_manifest(applied_manifest)
  end

  def checkpoint_dir(root, checkpoint_id) do
    Path.join([root | @checkpoint_parent] ++ [checkpoint_id])
  end

  def manifest_path(root, checkpoint_id) do
    root
    |> checkpoint_dir(checkpoint_id)
    |> Path.join("manifest.json")
  end

  def require_checkpoint_id!(checkpoint_id)
      when is_binary(checkpoint_id) and byte_size(checkpoint_id) > 0 do
    if Regex.match?(@checkpoint_id_pattern, checkpoint_id) do
      checkpoint_id
    else
      raise ArgumentError, "checkpoint_id is invalid: #{inspect(checkpoint_id)}"
    end
  end

  def require_checkpoint_id!(checkpoint_id) do
    raise ArgumentError,
          "checkpoint_id must be a non-empty binary, got: #{inspect(checkpoint_id)}"
  end

  defp require_plan!(plan) when is_map(plan) and map_size(plan) > 0 do
    Enum.each(plan, fn
      {path, :delete} when is_binary(path) ->
        :ok

      {path, {:write, content}} when is_binary(path) and is_binary(content) ->
        CodeEditSupport.require_text!(content, "planned content")

      entry ->
        raise ArgumentError, "invalid write plan entry: #{inspect(entry)}"
    end)
  end

  defp require_plan!(plan) do
    raise ArgumentError, "write plan must be a non-empty map, got: #{inspect(plan)}"
  end

  defp secure_plan!(root, plan) do
    Enum.reduce(plan, %{}, fn {path, action}, acc ->
      target = PathGuard.writable_target!(root, path)
      CodeEditSupport.reject_checkpoint_path!(root, target, "write plan path")

      if Map.has_key?(acc, target) do
        raise ArgumentError, "write plan contains duplicate target path: #{inspect(target)}"
      end

      Map.put(acc, target, action)
    end)
  end

  defp new_checkpoint_id do
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")
    timestamp <> "-" <> Integer.to_string(System.unique_integer([:positive]))
  end

  defp ensure_checkpoint_dir!(root, checkpoint_dir, contents_dir) do
    root
    |> Path.join(".agent-machine")
    |> ensure_directory_no_symlink!()

    root
    |> Path.join(@checkpoint_parent)
    |> ensure_directory_no_symlink!()

    ensure_new_directory_no_symlink!(checkpoint_dir)
    ensure_directory_no_symlink!(contents_dir)
  end

  defp ensure_directory_no_symlink!(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} ->
        raise ArgumentError, "checkpoint directory must not be a symlink: #{inspect(path)}"

      {:ok, %{type: :directory}} ->
        :ok

      {:ok, %{type: type}} ->
        raise ArgumentError, "checkpoint path must be a directory, got: #{inspect(type)}"

      {:error, :enoent} ->
        File.mkdir_p!(path)
        ensure_directory_no_symlink!(path)

      {:error, reason} ->
        raise File.Error, reason: reason, action: "inspect checkpoint directory", path: path
    end
  end

  defp ensure_new_directory_no_symlink!(path) do
    case File.lstat(path) do
      {:ok, _stat} ->
        raise ArgumentError, "checkpoint already exists: #{inspect(path)}"

      {:error, :enoent} ->
        File.mkdir_p!(Path.join(path, "contents"))
        ensure_directory_no_symlink!(path)

      {:error, reason} ->
        raise File.Error, reason: reason, action: "inspect checkpoint directory", path: path
    end
  end

  defp build_manifest!(root, checkpoint_id, tool_name, checkpoint_dir, plan) do
    entries =
      plan
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map(fn path ->
        %{
          "path" => relative_path!(root, path),
          "before" => state_from_disk!(path, checkpoint_dir),
          "after" => state_from_plan!(Map.fetch!(plan, path), checkpoint_dir)
        }
      end)

    %{
      "id" => checkpoint_id,
      "created_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "tool" => tool_name,
      "checkpoint_path" => checkpoint_dir,
      "affected_paths" => Enum.map(entries, & &1["path"]),
      "entries" => entries
    }
  end

  defp actual_after_entries!(root, checkpoint_dir, entries) do
    Enum.map(entries, fn entry ->
      path = Path.expand(entry["path"], root)
      Map.put(entry, "after", state_from_disk!(path, checkpoint_dir))
    end)
  end

  defp state_from_plan!(:delete, _checkpoint_dir), do: missing_state()

  defp state_from_plan!({:write, content}, checkpoint_dir) do
    write_content_state!(checkpoint_dir, content)
  end

  defp state_from_disk!(path, checkpoint_dir) do
    path
    |> read_disk_state!()
    |> store_state_content!(checkpoint_dir)
  end

  defp read_disk_state!(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} ->
        raise ArgumentError, "checkpointed path must not be a symlink: #{inspect(path)}"

      {:ok, %{type: :regular, size: size}} ->
        if size <= CodeEditSupport.max_file_bytes() do
          content =
            path
            |> File.read!()
            |> CodeEditSupport.require_text!("checkpointed content")

          file_state(content)
        else
          raise ArgumentError,
                "checkpointed content must be at most #{CodeEditSupport.max_file_bytes()} bytes, got: #{size}"
        end

      {:ok, %{type: type}} ->
        raise ArgumentError, "checkpointed path must be a regular file, got: #{inspect(type)}"

      {:error, :enoent} ->
        missing_state()

      {:error, reason} ->
        raise File.Error, reason: reason, action: "inspect checkpointed path", path: path
    end
  end

  defp snapshot_paths!(root) do
    root
    |> do_snapshot_paths!([])
    |> Enum.sort()
    |> tap(fn paths ->
      if length(paths) > @snapshot_max_files do
        raise ArgumentError,
              "shell checkpoint can include at most #{@snapshot_max_files} text files, got: #{length(paths)}"
      end
    end)
  end

  defp do_snapshot_paths!(dir, acc) do
    dir
    |> File.ls!()
    |> Enum.reduce(acc, &snapshot_path_entry!(dir, &1, &2))
  end

  defp snapshot_path_entry!(dir, name, acc) do
    path = Path.join(dir, name)

    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        maybe_snapshot_dir!(path, name, acc)

      {:ok, %{type: :regular, size: size}} ->
        maybe_snapshot_file(path, size, acc)

      {:ok, _stat} ->
        acc

      {:error, reason} ->
        raise File.Error, reason: reason, action: "inspect snapshot path", path: path
    end
  end

  defp maybe_snapshot_dir!(path, name, acc) do
    if MapSet.member?(@snapshot_skip_dirs, name) do
      acc
    else
      do_snapshot_paths!(path, acc)
    end
  end

  defp maybe_snapshot_file(path, size, acc) do
    if size <= CodeEditSupport.max_file_bytes() and snapshot_text_file?(path) do
      [path | acc]
    else
      acc
    end
  end

  defp snapshot_text_file?(path) do
    path
    |> File.read!()
    |> String.valid?()
  rescue
    File.Error -> false
  end

  defp store_state_content!(%{"state" => "missing"} = state, _checkpoint_dir), do: state

  defp store_state_content!(%{"state" => "file", "content" => content} = state, checkpoint_dir) do
    state
    |> Map.delete("content")
    |> Map.put("content_path", write_content!(checkpoint_dir, content))
  end

  defp write_content_state!(checkpoint_dir, content) do
    content
    |> file_state()
    |> store_state_content!(checkpoint_dir)
  end

  defp file_state(content) do
    sha = CodeEditSupport.sha256(content)

    %{
      "state" => "file",
      "sha256" => sha,
      "bytes" => byte_size(content),
      "content" => content
    }
  end

  defp write_content!(checkpoint_dir, content) do
    relative = Path.join("contents", CodeEditSupport.sha256(content))
    path = Path.join(checkpoint_dir, relative)

    unless File.exists?(path) do
      File.write!(path, content)
    end

    relative
  end

  defp missing_state, do: %{"state" => "missing"}

  defp write_manifest!(checkpoint_dir, manifest) do
    File.write!(Path.join(checkpoint_dir, "manifest.json"), JSON.encode!(manifest))
  end

  defp result_from_manifest(manifest) do
    summary =
      ToolResultSummary.from_checkpoint(
        manifest["tool"],
        manifest["checkpoint_path"],
        manifest["entries"]
      )

    %{
      checkpoint_id: manifest["id"],
      checkpoint_path: manifest["checkpoint_path"],
      checkpoint: %{id: manifest["id"], path: manifest["checkpoint_path"]},
      changed: summary.changed_files,
      changed_files: summary.changed_files,
      summary: summary.summary,
      count: length(manifest["entries"])
    }
  end

  defp read_manifest!(root, checkpoint_id) do
    path = manifest_path(root, checkpoint_id)

    unless File.exists?(path) do
      raise ArgumentError, "unknown checkpoint_id: #{inspect(checkpoint_id)}"
    end

    path
    |> File.read!()
    |> JSON.decode!()
    |> require_manifest!(checkpoint_id)
  end

  defp require_manifest!(manifest, checkpoint_id) when is_map(manifest) do
    if manifest["id"] == checkpoint_id do
      manifest
    else
      raise ArgumentError, "checkpoint manifest id does not match #{inspect(checkpoint_id)}"
    end
  end

  defp require_manifest!(manifest, _checkpoint_id) do
    raise ArgumentError, "checkpoint manifest must be a JSON object, got: #{inspect(manifest)}"
  end

  defp require_entries!(manifest) do
    case Map.fetch(manifest, "entries") do
      {:ok, entries} when is_list(entries) and entries != [] ->
        entries

      {:ok, entries} ->
        raise ArgumentError,
              "checkpoint entries must be a non-empty list, got: #{inspect(entries)}"

      :error ->
        raise ArgumentError, "checkpoint manifest is missing entries"
    end
  end

  defp verify_current_after_state!(root, entry) do
    path = path_from_entry!(root, entry)
    current = comparable_state(read_disk_state!(path))
    expected = comparable_state(require_state!(entry, "after"))

    if current != expected do
      raise ArgumentError,
            "current path state differs from checkpoint after state: #{inspect(entry["path"])}"
    end
  end

  defp rollback_plan_entry!(root, checkpoint_dir, entry) do
    path = path_from_entry!(root, entry)

    case require_state!(entry, "before") do
      %{"state" => "missing"} ->
        {path, :delete}

      %{"state" => "file", "content_path" => content_path} ->
        {path, {:write, read_checkpoint_content!(checkpoint_dir, content_path)}}

      state ->
        raise ArgumentError, "unsupported checkpoint before state: #{inspect(state)}"
    end
  end

  defp read_checkpoint_content!(checkpoint_dir, content_path) do
    validate_content_path!(content_path)
    path = Path.join(checkpoint_dir, content_path)

    path
    |> File.read!()
    |> CodeEditSupport.require_text!("checkpoint content")
  end

  defp validate_content_path!(content_path) when is_binary(content_path) do
    case Path.split(content_path) do
      ["contents", sha] ->
        CodeEditSupport.require_sha256!(sha)
        :ok

      _other ->
        raise ArgumentError, "checkpoint content_path is invalid: #{inspect(content_path)}"
    end
  end

  defp validate_content_path!(content_path) do
    raise ArgumentError, "checkpoint content_path must be a binary, got: #{inspect(content_path)}"
  end

  defp require_state!(entry, key) do
    case Map.fetch(entry, key) do
      {:ok, %{"state" => state} = value} when state in ["missing", "file"] -> value
      {:ok, value} -> raise ArgumentError, "checkpoint #{key} state is invalid: #{inspect(value)}"
      :error -> raise ArgumentError, "checkpoint entry is missing #{key}"
    end
  end

  defp comparable_state(%{"state" => "missing"}), do: %{"state" => "missing"}

  defp comparable_state(%{"state" => "file", "sha256" => sha}) do
    %{"state" => "file", "sha256" => sha}
  end

  defp path_from_entry!(root, entry) do
    path = checkpoint_relative_path!(Map.fetch!(entry, "path"))
    target = PathGuard.writable_target!(root, path)
    CodeEditSupport.reject_checkpoint_path!(root, target, "checkpoint path")
    target
  rescue
    exception in ArgumentError ->
      reraise ArgumentError,
              [message: "checkpoint path is outside tool root: #{Exception.message(exception)}"],
              __STACKTRACE__
  end

  defp checkpoint_relative_path!(path) do
    path = PathGuard.require_non_empty_binary!(path, "checkpoint path")
    parts = Path.split(path)

    cond do
      Path.type(path) != :relative ->
        raise ArgumentError, "checkpoint path must be relative, got: #{inspect(path)}"

      parts in [[], ["."]] or Enum.member?(parts, "..") ->
        raise ArgumentError, "checkpoint path must not contain traversal: #{inspect(path)}"

      true ->
        path
    end
  end

  defp relative_path!(root, path) do
    relative = Path.relative_to(path, root)

    if Path.type(relative) == :relative and not Enum.member?(Path.split(relative), "..") do
      relative
    else
      raise ArgumentError, "checkpoint path is outside tool root: #{inspect(path)}"
    end
  end
end
