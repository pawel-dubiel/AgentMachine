defmodule AgentMachine.Tools.CodeEditSupport do
  @moduledoc false

  alias AgentMachine.Tools.PathGuard

  @max_file_bytes 200_000
  @max_patch_bytes 400_000
  @max_changes 50
  @max_hunks 200

  def max_file_bytes, do: @max_file_bytes
  def max_patch_bytes, do: @max_patch_bytes
  def max_changes, do: @max_changes
  def max_hunks, do: @max_hunks

  def fetch_input!(input, tool, key) do
    atom_key = input_atom_key!(key)

    cond do
      Map.has_key?(input, key) -> Map.fetch!(input, key)
      Map.has_key?(input, atom_key) -> Map.fetch!(input, atom_key)
      true -> raise ArgumentError, "#{tool} input is missing #{inspect(key)}"
    end
  end

  def require_text!(value, field, max_bytes \\ @max_file_bytes)

  def require_text!(value, _field, max_bytes)
      when is_binary(value) and byte_size(value) <= max_bytes do
    if String.valid?(value) do
      value
    else
      raise ArgumentError, "text content must be valid UTF-8"
    end
  end

  def require_text!(value, field, max_bytes) when is_binary(value) do
    raise ArgumentError, "#{field} must be at most #{max_bytes} bytes, got: #{byte_size(value)}"
  end

  def require_text!(value, field, _max_bytes) do
    raise ArgumentError, "#{field} must be a binary, got: #{inspect(value)}"
  end

  def require_non_empty_text!(value, field, max_bytes \\ @max_file_bytes) do
    value = require_text!(value, field, max_bytes)

    if byte_size(value) > 0 do
      value
    else
      raise ArgumentError, "#{field} must be a non-empty binary"
    end
  end

  def require_boolean!(value, _field) when is_boolean(value), do: value

  def require_boolean!(value, field) do
    raise ArgumentError, "#{field} must be a boolean, got: #{inspect(value)}"
  end

  def require_expected_count!(value, _field) when is_integer(value) and value in 1..100,
    do: value

  def require_expected_count!(value, field) do
    raise ArgumentError, "#{field} must be an integer from 1 to 100, got: #{inspect(value)}"
  end

  def require_changes!(changes) when is_list(changes) and changes != [] do
    if length(changes) <= @max_changes do
      changes
    else
      raise ArgumentError, "changes must contain at most #{@max_changes} entries"
    end
  end

  def require_changes!(changes) do
    raise ArgumentError, "changes must be a non-empty list, got: #{inspect(changes)}"
  end

  def resolve_new_or_existing_file!(root, path, label) do
    target = PathGuard.writable_target!(root, path)
    reject_directory!(target, label)
    target
  end

  def resolve_existing_file!(root, path, label) do
    target = PathGuard.existing_writable_target!(root, path, label)
    require_regular_file!(target, label)
    target
  end

  def read_text_file!(path, label) do
    case File.stat!(path) do
      %{type: :regular, size: size} when size <= @max_file_bytes ->
        path
        |> File.read!()
        |> require_text!(label)

      %{type: :regular, size: size} ->
        raise ArgumentError, "#{label} must be at most #{@max_file_bytes} bytes, got: #{size}"

      %{type: type} ->
        raise ArgumentError, "#{label} must be a regular file, got: #{inspect(type)}"
    end
  end

  def sha256(content) when is_binary(content) do
    :sha256
    |> :crypto.hash(content)
    |> Base.encode16(case: :lower)
  end

  def require_sha256!(value) when is_binary(value) and byte_size(value) == 64 do
    if String.match?(value, ~r/\A[0-9a-fA-F]{64}\z/) do
      String.downcase(value)
    else
      raise ArgumentError, "expected_sha256 must be a lowercase or uppercase hex SHA-256"
    end
  end

  def require_sha256!(value) do
    raise ArgumentError,
          "expected_sha256 must be a 64-character hex string, got: #{inspect(value)}"
  end

  def split_lines(content) when is_binary(content) do
    cond do
      content == "" ->
        []

      String.ends_with?(content, "\n") ->
        content
        |> String.split("\n", trim: false)
        |> Enum.drop(-1)
        |> Enum.map(&(&1 <> "\n"))

      true ->
        parts = String.split(content, "\n", trim: false)
        {body, [last]} = Enum.split(parts, -1)
        Enum.map(body, &(&1 <> "\n")) ++ [last]
    end
  end

  def write_plan!(plan) when is_map(plan) do
    Enum.each(plan, fn
      {path, :delete} ->
        case File.rm(path) do
          :ok -> :ok
          {:error, :enoent} -> :ok
          {:error, reason} -> raise File.Error, reason: reason, action: "remove file", path: path
        end

      {path, {:write, content}} ->
        require_text!(content, "planned content")
        write_text_atomic!(path, content)
    end)
  end

  defp input_atom_key!(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp reject_directory!(target, label) do
    case File.lstat(target) do
      {:ok, %{type: :directory}} ->
        raise ArgumentError, "#{label} must not be a directory: #{inspect(target)}"

      _other ->
        :ok
    end
  end

  defp require_regular_file!(target, label) do
    case File.stat!(target) do
      %{type: :regular} ->
        :ok

      %{type: type} ->
        raise ArgumentError, "#{label} must be a regular file, got: #{inspect(type)}"
    end
  end

  defp write_text_atomic!(path, content) do
    tmp =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.agent-machine-#{System.unique_integer()}.tmp"
      )

    try do
      File.write!(tmp, content)
      File.rename!(tmp, path)
    after
      File.rm(tmp)
    end
  end
end
