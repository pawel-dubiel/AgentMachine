defmodule AgentMachine.Tools.ToolResultSummary do
  @moduledoc false

  alias AgentMachine.Tools.CodeEditSupport

  def from_checkpoint(tool, checkpoint_path, entries) when is_binary(tool) and is_list(entries) do
    changed_files = Enum.map(entries, &checkpoint_entry(checkpoint_path, &1))

    %{
      summary: summary(tool, changed_files),
      changed_files: changed_files
    }
  end

  def from_file_states(tool, root, path, before_state, after_state)
      when is_binary(tool) and is_binary(root) and is_binary(path) do
    changed_file =
      file_change(
        relative_path!(root, path),
        normalize_state(before_state),
        normalize_state(after_state)
      )

    %{
      summary: summary(tool, [changed_file]),
      changed_files: [changed_file]
    }
  end

  def directory_result(tool, root, path, created)
      when is_binary(tool) and is_binary(root) and is_binary(path) and is_boolean(created) do
    action = if created, do: "created", else: "unchanged"
    changed_count = if created, do: 1, else: 0

    %{
      summary: %{
        tool: tool,
        status: if(created, do: "changed", else: "unchanged"),
        changed_count: changed_count,
        created_count: changed_count,
        updated_count: 0,
        deleted_count: 0,
        renamed_count: 0
      },
      changed_files: [],
      changed_paths: [%{path: relative_path!(root, path), type: "directory", action: action}]
    }
  end

  def operation_stats(changes) when is_list(changes) do
    %{
      requested_count: length(changes),
      renamed_count: Enum.count(changes, &match?(%{op: "rename_path"}, &1))
    }
  end

  def missing_state, do: %{"state" => "missing"}

  def file_state(content) when is_binary(content) do
    %{
      "state" => "file",
      "sha256" => CodeEditSupport.sha256(content),
      "bytes" => byte_size(content),
      "content" => content
    }
  end

  def relative_path!(root, path) do
    relative = Path.relative_to(path, root)

    if Path.type(relative) == :relative and not Enum.member?(Path.split(relative), "..") do
      relative
    else
      raise ArgumentError, "summary path is outside tool root: #{inspect(path)}"
    end
  end

  defp checkpoint_entry(checkpoint_path, entry) do
    before_state = load_checkpoint_content(checkpoint_path, Map.fetch!(entry, "before"))
    after_state = load_checkpoint_content(checkpoint_path, Map.fetch!(entry, "after"))
    file_change(Map.fetch!(entry, "path"), before_state, after_state)
  end

  defp load_checkpoint_content(_checkpoint_path, %{"state" => "missing"} = state), do: state

  defp load_checkpoint_content(
         checkpoint_path,
         %{"state" => "file", "content_path" => content_path} = state
       ) do
    validate_content_path!(content_path)
    content = File.read!(Path.join(checkpoint_path, content_path))
    Map.put(state, "content", content)
  end

  defp file_change(path, before_state, after_state) do
    %{
      path: path,
      action: action_from_states(before_state["state"], after_state["state"]),
      before_state: before_state["state"],
      before_sha256: before_state["sha256"],
      before_bytes: before_state["bytes"],
      after_state: after_state["state"],
      after_sha256: after_state["sha256"],
      after_bytes: after_state["bytes"],
      diff_summary: diff_summary(before_state, after_state)
    }
  end

  defp summary(tool, changed_files) do
    changed_files = Enum.reject(changed_files, &(&1.action == "unchanged"))

    %{
      tool: tool,
      status: if(changed_files == [], do: "unchanged", else: "changed"),
      changed_count: length(changed_files),
      created_count: Enum.count(changed_files, &(&1.action == "created")),
      updated_count: Enum.count(changed_files, &(&1.action == "updated")),
      deleted_count: Enum.count(changed_files, &(&1.action == "deleted")),
      renamed_count: 0
    }
  end

  defp action_from_states("missing", "file"), do: "created"
  defp action_from_states("file", "missing"), do: "deleted"

  defp action_from_states("file", "file") do
    "updated"
  end

  defp action_from_states("missing", "missing"), do: "unchanged"
  defp action_from_states(before_state, after_state), do: before_state <> "_to_" <> after_state

  defp diff_summary(%{"state" => "missing"}, %{"state" => "missing"}) do
    %{added_lines: 0, removed_lines: 0}
  end

  defp diff_summary(%{"state" => "missing"}, %{"state" => "file", "content" => content}) do
    %{added_lines: line_count(content), removed_lines: 0}
  end

  defp diff_summary(%{"state" => "file", "content" => content}, %{"state" => "missing"}) do
    %{added_lines: 0, removed_lines: line_count(content)}
  end

  defp diff_summary(
         %{"state" => "file", "content" => before_content},
         %{"state" => "file", "content" => after_content}
       ) do
    before_counts = line_frequencies(before_content)
    after_counts = line_frequencies(after_content)

    %{
      added_lines: positive_delta(after_counts, before_counts),
      removed_lines: positive_delta(before_counts, after_counts)
    }
  end

  defp line_count(content), do: content |> CodeEditSupport.split_lines() |> length()

  defp line_frequencies(content) do
    content
    |> CodeEditSupport.split_lines()
    |> Enum.frequencies()
  end

  defp positive_delta(left, right) do
    left
    |> Enum.map(fn {line, count} -> max(count - Map.get(right, line, 0), 0) end)
    |> Enum.sum()
  end

  defp normalize_state(:missing), do: missing_state()
  defp normalize_state(content) when is_binary(content), do: file_state(content)
  defp normalize_state(%{} = state), do: state

  defp validate_content_path!(content_path) when is_binary(content_path) do
    case Path.split(content_path) do
      ["contents", sha] ->
        CodeEditSupport.require_sha256!(sha)
        :ok

      _other ->
        raise ArgumentError, "checkpoint content_path is invalid: #{inspect(content_path)}"
    end
  end
end
