defmodule AgentMachine.Tools.CodeEditCheckpoint do
  @moduledoc false

  alias AgentMachine.JSON
  alias AgentMachine.Tools.CodeEditSupport

  @checkpoint_parent [".agent_machine", "checkpoints"]
  @checkpoint_id_pattern ~r/\A\d{8}T\d{6}Z-\d+\z/

  def apply_plan!(root, tool_name, plan) when is_binary(root) and is_binary(tool_name) do
    require_plan!(plan)

    Enum.each(
      Map.keys(plan),
      &CodeEditSupport.reject_checkpoint_path!(root, &1, "write plan path")
    )

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

  defp new_checkpoint_id do
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")
    timestamp <> "-" <> Integer.to_string(System.unique_integer([:positive]))
  end

  defp ensure_checkpoint_dir!(root, checkpoint_dir, contents_dir) do
    root
    |> Path.join(".agent_machine")
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
    %{
      checkpoint_id: manifest["id"],
      checkpoint_path: manifest["checkpoint_path"],
      changed: Enum.map(manifest["entries"], &changed_summary/1),
      count: length(manifest["entries"])
    }
  end

  defp changed_summary(entry) do
    before_state = entry["before"]["state"]
    after_state = entry["after"]["state"]

    %{
      path: entry["path"],
      action: action_from_states(before_state, after_state),
      before_state: before_state,
      before_sha256: entry["before"]["sha256"],
      after_state: after_state,
      after_sha256: entry["after"]["sha256"]
    }
  end

  defp action_from_states("missing", "file"), do: "created"
  defp action_from_states("file", "missing"), do: "deleted"
  defp action_from_states("file", "file"), do: "updated"
  defp action_from_states(before_state, after_state), do: before_state <> "_to_" <> after_state

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
    path = Map.fetch!(entry, "path")
    target = Path.expand(path, root)

    if target == root or String.starts_with?(target, root <> "/") do
      CodeEditSupport.reject_checkpoint_path!(root, target, "checkpoint path")
      target
    else
      raise ArgumentError, "checkpoint path is outside tool root: #{inspect(path)}"
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
