defmodule AgentMachine.Tools.ApplyPatch do
  @moduledoc """
  Unified-diff patch tool constrained to an explicit tool root.
  """

  @behaviour AgentMachine.Tool

  alias AgentMachine.Tools.{CodeEditSupport, PathGuard}

  @impl true
  def permission, do: :code_edit_apply_patch

  @impl true
  def definition do
    %{
      name: "apply_patch",
      description:
        "Apply a bounded unified diff patch under the configured tool root without shelling out.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "patch" => %{
            "type" => "string",
            "maxLength" => CodeEditSupport.max_patch_bytes()
          }
        },
        "required" => ["patch"],
        "additionalProperties" => false
      }
    }
  end

  @impl true
  def run(input, opts) when is_map(input) do
    root = PathGuard.root!(opts)

    patch =
      input
      |> fetch!("patch")
      |> CodeEditSupport.require_text!("patch", CodeEditSupport.max_patch_bytes())

    files = parse_patch!(patch)
    plan = files |> Enum.map(&stage_file!(root, &1)) |> Map.new()

    CodeEditSupport.write_plan!(plan)

    {:ok,
     %{
       changed: Enum.map(files, &%{path: &1.path, action: Atom.to_string(&1.action)}),
       count: length(files)
     }}
  rescue
    exception in [ArgumentError, File.Error] -> {:error, Exception.message(exception)}
  end

  def run(input, _opts), do: {:error, {:invalid_input, input}}

  defp fetch!(input, key), do: CodeEditSupport.fetch_input!(input, "apply_patch", key)

  defp parse_patch!(patch) do
    lines = normalized_patch_lines!(patch)
    reject_unsupported_patch!(lines)
    {files, []} = parse_files!(lines, [])

    if files == [] do
      raise ArgumentError, "patch must contain at least one file diff"
    end

    Enum.reverse(files)
  end

  defp normalized_patch_lines!(patch) do
    lines = String.split(patch, "\n", trim: false)

    case List.last(lines) do
      "" -> Enum.drop(lines, -1)
      _line -> lines
    end
  end

  defp reject_unsupported_patch!(lines) do
    Enum.each(lines, fn line ->
      cond do
        String.starts_with?(line, "Binary files ") ->
          raise ArgumentError, "binary patches are not supported"

        line == "GIT binary patch" ->
          raise ArgumentError, "binary patches are not supported"

        String.starts_with?(line, "rename from ") or String.starts_with?(line, "rename to ") ->
          raise ArgumentError, "rename patches are not supported; use apply_edits rename_path"

        true ->
          :ok
      end
    end)
  end

  defp parse_files!([], files), do: {files, []}

  defp parse_files!(["diff --git " <> _diff | rest], files), do: parse_files!(rest, files)
  defp parse_files!(["index " <> _index | rest], files), do: parse_files!(rest, files)
  defp parse_files!(["new file mode " <> _mode | rest], files), do: parse_files!(rest, files)
  defp parse_files!(["deleted file mode " <> _mode | rest], files), do: parse_files!(rest, files)

  defp parse_files!(["--- " <> old_header, "+++ " <> new_header | rest], files) do
    old_path = parse_header_path!(old_header)
    new_path = parse_header_path!(new_header)
    {hunks, rest} = parse_hunks!(rest, [])
    action = action!(old_path, new_path)
    path = patch_path!(old_path, new_path)

    if hunks == [] do
      raise ArgumentError, "file patch for #{inspect(path)} must contain at least one hunk"
    end

    parse_files!(rest, [%{action: action, path: path, hunks: Enum.reverse(hunks)} | files])
  end

  defp parse_files!([line | _rest], _files) do
    raise ArgumentError, "malformed patch near line: #{inspect(line)}"
  end

  defp parse_hunks!([], hunks), do: {hunks, []}

  defp parse_hunks!(["diff --git " <> _diff | _rest] = rest, hunks), do: {hunks, rest}
  defp parse_hunks!(["--- " <> _header | _rest] = rest, hunks), do: {hunks, rest}

  defp parse_hunks!(["@@ " <> _ = header | rest], hunks) do
    hunk = parse_hunk_header!(header)
    {body, rest} = take_hunk_body!(rest, [])

    parse_hunks!(rest, [%{hunk | body: normalize_no_newline_markers!(Enum.reverse(body))} | hunks])
  end

  defp parse_hunks!([line | _rest], _hunks) do
    raise ArgumentError, "malformed hunk near line: #{inspect(line)}"
  end

  defp parse_hunk_header!(header) do
    captures =
      Regex.named_captures(
        ~r/^@@ -(?<old_start>\d+)(?:,(?<old_count>\d+))? \+(?<new_start>\d+)(?:,(?<new_count>\d+))? @@/,
        header
      )

    case captures do
      %{
        "old_start" => old_start,
        "old_count" => old_count,
        "new_start" => new_start,
        "new_count" => new_count
      } ->
        %{
          old_start: String.to_integer(old_start),
          old_count: count_from_header(old_count),
          new_start: String.to_integer(new_start),
          new_count: count_from_header(new_count),
          body: []
        }

      nil ->
        raise ArgumentError, "malformed hunk header: #{inspect(header)}"
    end
  end

  defp take_hunk_body!([], body), do: {body, []}

  defp take_hunk_body!(["diff --git " <> _diff | _rest] = rest, body), do: {body, rest}
  defp take_hunk_body!(["--- " <> _header | _rest] = rest, body), do: {body, rest}
  defp take_hunk_body!(["@@ " <> _header | _rest] = rest, body), do: {body, rest}

  defp take_hunk_body!(["\\" <> _marker = line | rest], body) do
    take_hunk_body!(rest, [{:marker, line} | body])
  end

  defp take_hunk_body!([<<prefix::binary-size(1), text::binary>> | rest], body)
       when prefix in [" ", "+", "-"] do
    take_hunk_body!(rest, [{prefix, text <> "\n"} | body])
  end

  defp take_hunk_body!([line | _rest], _body) do
    raise ArgumentError, "invalid hunk line: #{inspect(line)}"
  end

  defp normalize_no_newline_markers!([]), do: []

  defp normalize_no_newline_markers!([{:marker, "\\ No newline at end of file"} | _rest]) do
    raise ArgumentError, "no-newline marker cannot appear before a patch line"
  end

  defp normalize_no_newline_markers!([line, {:marker, "\\ No newline at end of file"} | rest]) do
    [trim_line_newline(line) | normalize_no_newline_markers!(rest)]
  end

  defp normalize_no_newline_markers!([{:marker, marker} | _rest]) do
    raise ArgumentError, "unsupported patch marker: #{inspect(marker)}"
  end

  defp normalize_no_newline_markers!([line | rest]) do
    [line | normalize_no_newline_markers!(rest)]
  end

  defp trim_line_newline({prefix, text}) do
    {prefix, String.trim_trailing(text, "\n")}
  end

  defp parse_header_path!("/dev/null"), do: :dev_null

  defp parse_header_path!(header) do
    header
    |> String.split("\t", parts: 2)
    |> hd()
    |> strip_git_prefix()
    |> validate_patch_path!()
  end

  defp strip_git_prefix("a/" <> path), do: path
  defp strip_git_prefix("b/" <> path), do: path
  defp strip_git_prefix(path), do: path

  defp validate_patch_path!(path) do
    cond do
      path == "" ->
        raise ArgumentError, "patch path must not be empty"

      Path.type(path) == :absolute ->
        raise ArgumentError, "patch path must be relative, got: #{inspect(path)}"

      Enum.member?(Path.split(path), "..") ->
        raise ArgumentError, "patch path must not contain .., got: #{inspect(path)}"

      true ->
        path
    end
  end

  defp action!(:dev_null, path) when is_binary(path), do: :create
  defp action!(path, :dev_null) when is_binary(path), do: :delete
  defp action!(path, path) when is_binary(path), do: :update

  defp action!(old_path, new_path) do
    raise ArgumentError,
          "rename patches are not supported: #{inspect(old_path)} -> #{inspect(new_path)}"
  end

  defp patch_path!(:dev_null, path), do: path
  defp patch_path!(path, :dev_null), do: path
  defp patch_path!(path, path), do: path

  defp stage_file!(root, %{action: :create, path: path, hunks: hunks}) do
    target = CodeEditSupport.resolve_new_or_existing_file!(root, path, "apply_patch path")

    if File.exists?(target) do
      raise ArgumentError, "apply_patch create target already exists: #{inspect(target)}"
    end

    {target, {:write, apply_hunks!("", hunks, path)}}
  end

  defp stage_file!(root, %{action: :update, path: path, hunks: hunks}) do
    target = CodeEditSupport.resolve_existing_file!(root, path, "apply_patch path")
    content = CodeEditSupport.read_text_file!(target, "apply_patch path")
    {target, {:write, apply_hunks!(content, hunks, path)}}
  end

  defp stage_file!(root, %{action: :delete, path: path, hunks: hunks}) do
    target = CodeEditSupport.resolve_existing_file!(root, path, "apply_patch path")
    content = CodeEditSupport.read_text_file!(target, "apply_patch path")

    case apply_hunks!(content, hunks, path) do
      "" -> {target, :delete}
      _content -> raise ArgumentError, "delete patch for #{inspect(path)} must remove all content"
    end
  end

  defp apply_hunks!(content, hunks, path) do
    require_hunk_limit!(hunks)
    lines = CodeEditSupport.split_lines(content)
    {output, cursor} = Enum.reduce(hunks, {[], 0}, &apply_hunk!(&1, &2, lines, path))
    updated = Enum.reverse(output) ++ Enum.drop(lines, cursor)
    result = IO.iodata_to_binary(updated)

    if byte_size(result) <= CodeEditSupport.max_file_bytes() do
      result
    else
      raise ArgumentError,
            "patched file #{inspect(path)} must be at most #{CodeEditSupport.max_file_bytes()} bytes"
    end
  end

  defp apply_hunk!(hunk, {output, cursor}, lines, path) do
    hunk_index = max(hunk.old_start - 1, 0)

    if hunk_index < cursor or hunk_index > length(lines) do
      raise ArgumentError, "hunk for #{inspect(path)} starts outside file content"
    end

    output = Enum.reverse(Enum.slice(lines, cursor, hunk_index - cursor), output)

    {output, cursor, old_seen, new_seen} =
      apply_hunk_body!(hunk.body, output, hunk_index, lines, path)

    require_hunk_counts!(hunk, old_seen, new_seen, path)
    {output, cursor}
  end

  defp apply_hunk_body!(body, output, cursor, lines, path) do
    Enum.reduce(body, {output, cursor, 0, 0}, fn
      {" ", text}, {output, cursor, old_seen, new_seen} ->
        require_context_line!(lines, cursor, text, path)
        {[text | output], cursor + 1, old_seen + 1, new_seen + 1}

      {"-", text}, {output, cursor, old_seen, new_seen} ->
        require_context_line!(lines, cursor, text, path)
        {output, cursor + 1, old_seen + 1, new_seen}

      {"+", text}, {output, cursor, old_seen, new_seen} ->
        {[text | output], cursor, old_seen, new_seen + 1}
    end)
  end

  defp require_context_line!(lines, cursor, text, path) do
    if Enum.at(lines, cursor) != text do
      raise ArgumentError, "patch context mismatch for #{inspect(path)}"
    end
  end

  defp require_hunk_counts!(hunk, old_seen, new_seen, path) do
    if hunk.old_count != old_seen or hunk.new_count != new_seen do
      raise ArgumentError,
            "hunk line counts do not match header for #{inspect(path)}"
    end
  end

  defp require_hunk_limit!(hunks) do
    if length(hunks) <= CodeEditSupport.max_hunks() do
      :ok
    else
      raise ArgumentError, "patch must contain at most #{CodeEditSupport.max_hunks()} hunks"
    end
  end

  defp count_from_header(nil), do: 1
  defp count_from_header(""), do: 1
  defp count_from_header(value), do: String.to_integer(value)
end
