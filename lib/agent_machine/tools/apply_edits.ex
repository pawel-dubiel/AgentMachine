defmodule AgentMachine.Tools.ApplyEdits do
  @moduledoc """
  Structured code edit tool constrained to an explicit tool root.
  """

  @behaviour AgentMachine.Tool

  alias AgentMachine.Tools.{CodeEditCheckpoint, CodeEditSupport, PathGuard, ToolResultSummary}

  @impl true
  def permission, do: :code_edit_apply_edits

  @impl true
  def approval_risk, do: :write

  @impl true
  def definition do
    %{
      name: "apply_edits",
      description:
        "Apply structured UTF-8 file edits under the configured tool root after validating every change.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "changes" => %{
            "type" => "array",
            "minItems" => 1,
            "maxItems" => CodeEditSupport.max_changes(),
            "items" => change_schema()
          }
        },
        "required" => ["changes"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def run(input, opts) when is_map(input) do
    root = PathGuard.root!(opts)
    changes = input |> fetch!("changes") |> CodeEditSupport.require_changes!()
    {plan, touched} = Enum.reduce(changes, {%{}, []}, &stage_change(root, &1, &2))

    checkpoint = CodeEditCheckpoint.apply_plan!(root, "apply_edits", plan)

    {:ok,
     checkpoint
     |> Map.put(:changed_paths, checkpoint.changed)
     |> Map.put(:requested_changes, Enum.reverse(touched))
     |> put_operation_summary(Enum.reverse(touched))
     |> Map.put(:count, length(touched))}
  rescue
    exception in [ArgumentError, File.Error] -> {:error, Exception.message(exception)}
  end

  def run(input, _opts), do: {:error, {:invalid_input, input}}

  defp change_schema do
    %{
      "oneOf" => [
        create_file_schema(),
        replace_schema(),
        insert_schema("insert_before"),
        insert_schema("insert_after"),
        delete_file_schema(),
        rename_path_schema()
      ]
    }
  end

  defp create_file_schema do
    operation_schema(
      "create_file",
      %{
        "path" => path_schema("File path to create under tool_root."),
        "content" => %{
          "type" => "string",
          "description" => "Complete UTF-8 file content to write."
        },
        "overwrite" => %{
          "type" => "boolean",
          "description" => "Whether an existing file may be overwritten."
        }
      },
      ["op", "path", "content", "overwrite"]
    )
  end

  defp replace_schema do
    operation_schema(
      "replace",
      %{
        "path" => path_schema("Existing file path under tool_root."),
        "old_text" => %{"type" => "string", "description" => "Exact existing text to replace."},
        "new_text" => %{"type" => "string", "description" => "Replacement UTF-8 text."},
        "expected_replacements" => expected_replacements_schema()
      },
      ["op", "path", "old_text", "new_text", "expected_replacements"]
    )
  end

  defp insert_schema(op) do
    operation_schema(
      op,
      %{
        "path" => path_schema("Existing file path under tool_root."),
        "anchor" => %{"type" => "string", "description" => "Exact existing anchor text."},
        "text" => %{"type" => "string", "description" => "UTF-8 text to insert."},
        "expected_replacements" => expected_replacements_schema()
      },
      ["op", "path", "anchor", "text", "expected_replacements"]
    )
  end

  defp delete_file_schema do
    operation_schema(
      "delete_file",
      %{
        "path" => path_schema("Existing file path under tool_root."),
        "expected_sha256" => %{
          "type" => "string",
          "description" => "Lowercase SHA-256 of the current file content."
        }
      },
      ["op", "path", "expected_sha256"]
    )
  end

  defp rename_path_schema do
    operation_schema(
      "rename_path",
      %{
        "from_path" => path_schema("Existing source path under tool_root."),
        "to_path" => path_schema("Destination path under tool_root."),
        "overwrite" => %{
          "type" => "boolean",
          "description" => "Whether an existing destination may be overwritten."
        }
      },
      ["op", "from_path", "to_path", "overwrite"]
    )
  end

  defp operation_schema(op, properties, required) do
    %{
      "type" => "object",
      "properties" => Map.put(properties, "op", %{"type" => "string", "enum" => [op]}),
      "required" => required,
      "additionalProperties" => false
    }
  end

  defp path_schema(description), do: %{"type" => "string", "description" => description}

  defp expected_replacements_schema do
    %{
      "type" => "integer",
      "minimum" => 1,
      "maximum" => 100,
      "description" => "Exact number of replacements or insertions expected."
    }
  end

  defp stage_change(root, change, {plan, touched}) when is_map(change) do
    case fetch_change!(change, "op") do
      "create_file" -> stage_create(root, change, plan, touched)
      "replace" -> stage_replace(root, change, plan, touched)
      "insert_before" -> stage_insert(root, change, plan, touched, :before)
      "insert_after" -> stage_insert(root, change, plan, touched, :after)
      "delete_file" -> stage_delete(root, change, plan, touched)
      "rename_path" -> stage_rename(root, change, plan, touched)
      op -> raise ArgumentError, "unsupported apply_edits op: #{inspect(op)}"
    end
  end

  defp stage_change(_root, change, _acc) do
    raise ArgumentError, "each change must be a map, got: #{inspect(change)}"
  end

  defp stage_create(root, change, plan, touched) do
    path = fetch_change!(change, "path")
    content = change |> fetch_change!("content") |> CodeEditSupport.require_text!("content")

    overwrite =
      change |> fetch_change!("overwrite") |> CodeEditSupport.require_boolean!("overwrite")

    target = CodeEditSupport.resolve_new_or_existing_file!(root, path, "create_file path")

    case {Map.fetch(plan, target), File.exists?(target), overwrite} do
      {{:ok, :delete}, _exists, _overwrite} -> :ok
      {{:ok, {:write, _old_content}}, _exists, false} -> raise_exists!(target)
      {:error, true, false} -> raise_exists!(target)
      _other -> :ok
    end

    {Map.put(plan, target, {:write, content}), [%{op: "create_file", path: target} | touched]}
  end

  defp stage_replace(root, change, plan, touched) do
    path = fetch_change!(change, "path")

    old_text =
      change |> fetch_change!("old_text") |> CodeEditSupport.require_non_empty_text!("old_text")

    new_text = change |> fetch_change!("new_text") |> CodeEditSupport.require_text!("new_text")

    expected =
      change
      |> fetch_change!("expected_replacements")
      |> CodeEditSupport.require_expected_count!("expected_replacements")

    target = CodeEditSupport.resolve_existing_file!(root, path, "replace path")
    content = current_content!(plan, target, "replace path")
    actual = content |> :binary.matches(old_text) |> length()
    require_count!(actual, expected)
    updated = String.replace(content, old_text, new_text, global: true)
    require_updated_size!(updated)

    {Map.put(plan, target, {:write, updated}),
     [%{op: "replace", path: target, replacements: actual} | touched]}
  end

  defp stage_insert(root, change, plan, touched, placement) do
    path = fetch_change!(change, "path")

    anchor =
      change |> fetch_change!("anchor") |> CodeEditSupport.require_non_empty_text!("anchor")

    text = change |> fetch_change!("text") |> CodeEditSupport.require_text!("text")

    expected =
      change
      |> fetch_change!("expected_replacements")
      |> CodeEditSupport.require_expected_count!("expected_replacements")

    target = CodeEditSupport.resolve_existing_file!(root, path, "insert path")
    content = current_content!(plan, target, "insert path")
    actual = content |> :binary.matches(anchor) |> length()
    require_count!(actual, expected)
    replacement = insert_replacement(anchor, text, placement)
    updated = String.replace(content, anchor, replacement, global: true)
    require_updated_size!(updated)
    op = if placement == :before, do: "insert_before", else: "insert_after"

    {Map.put(plan, target, {:write, updated}),
     [%{op: op, path: target, insertions: actual} | touched]}
  end

  defp stage_delete(root, change, plan, touched) do
    path = fetch_change!(change, "path")
    expected_sha = change |> fetch_change!("expected_sha256") |> CodeEditSupport.require_sha256!()
    target = CodeEditSupport.resolve_existing_file!(root, path, "delete_file path")
    content = current_content!(plan, target, "delete_file path")

    if CodeEditSupport.sha256(content) != expected_sha do
      raise ArgumentError, "delete_file expected_sha256 does not match #{inspect(target)}"
    end

    {Map.put(plan, target, :delete), [%{op: "delete_file", path: target} | touched]}
  end

  defp stage_rename(root, change, plan, touched) do
    from_path = fetch_change!(change, "from_path")
    to_path = fetch_change!(change, "to_path")

    overwrite =
      change |> fetch_change!("overwrite") |> CodeEditSupport.require_boolean!("overwrite")

    from = CodeEditSupport.resolve_new_or_existing_file!(root, from_path, "rename from_path")
    to = CodeEditSupport.resolve_new_or_existing_file!(root, to_path, "rename to_path")

    if from == to do
      raise ArgumentError, "rename_path from_path and to_path must be different"
    end

    require_rename_source!(plan, from)
    reject_rename_overwrite!(plan, to, overwrite)
    content = current_content!(plan, from, "rename from_path")

    {plan |> Map.put(from, :delete) |> Map.put(to, {:write, content}),
     [%{op: "rename_path", from_path: from, to_path: to} | touched]}
  end

  defp fetch!(input, key), do: CodeEditSupport.fetch_input!(input, "apply_edits", key)

  defp fetch_change!(change, key),
    do: CodeEditSupport.fetch_input!(change, "apply_edits change", key)

  defp current_content!(plan, target, label) do
    case Map.fetch(plan, target) do
      {:ok, {:write, content}} -> content
      {:ok, :delete} -> raise ArgumentError, "#{label} was already deleted in this edit batch"
      :error -> CodeEditSupport.read_text_file!(target, label)
    end
  end

  defp insert_replacement(anchor, text, :before), do: text <> anchor
  defp insert_replacement(anchor, text, :after), do: anchor <> text

  defp require_count!(actual, expected) when actual == expected, do: :ok

  defp require_count!(actual, expected) do
    raise ArgumentError, "expected #{expected} replacements but found #{actual}"
  end

  defp require_updated_size!(updated) do
    if byte_size(updated) <= CodeEditSupport.max_file_bytes() do
      :ok
    else
      raise ArgumentError,
            "updated content must be at most #{CodeEditSupport.max_file_bytes()} bytes, got: #{byte_size(updated)}"
    end
  end

  defp reject_rename_overwrite!(plan, to, true) do
    case Map.fetch(plan, to) do
      {:ok, :delete} -> :ok
      _other -> :ok
    end
  end

  defp reject_rename_overwrite!(plan, to, false) do
    case {Map.fetch(plan, to), File.exists?(to)} do
      {{:ok, :delete}, _exists} -> :ok
      {{:ok, {:write, _content}}, _exists} -> raise_exists!(to)
      {:error, true} -> raise_exists!(to)
      _other -> :ok
    end
  end

  defp require_rename_source!(plan, from) do
    case {Map.fetch(plan, from), File.exists?(from)} do
      {{:ok, {:write, _content}}, _exists} ->
        :ok

      {{:ok, :delete}, _exists} ->
        raise ArgumentError, "rename source was already deleted: #{inspect(from)}"

      {:error, true} ->
        :ok

      {:error, false} ->
        raise ArgumentError, "rename source does not exist: #{inspect(from)}"
    end
  end

  defp raise_exists!(path), do: raise(ArgumentError, "path already exists: #{inspect(path)}")

  defp put_operation_summary(result, touched) do
    stats = ToolResultSummary.operation_stats(touched)

    update_in(result.summary, fn summary ->
      summary
      |> Map.put(:requested_count, stats.requested_count)
      |> Map.put(:renamed_count, stats.renamed_count)
    end)
  end
end
