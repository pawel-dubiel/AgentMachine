defmodule AgentMachine.Tools.PathGuard do
  @moduledoc false

  @max_symlink_depth 40

  def root!(opts) do
    root =
      opts |> Keyword.fetch!(:tool_root) |> require_non_empty_binary!(:tool_root) |> Path.expand()

    case realpath(root) do
      {:ok, real_root} ->
        require_directory!(real_root, :tool_root)
        real_root

      {:error, _reason} ->
        raise ArgumentError, "tool root does not exist: #{inspect(root)}"
    end
  end

  def target!(root, path) do
    path = require_non_empty_binary!(path, "path")

    target =
      if Path.type(path) == :absolute do
        Path.expand(path)
      else
        Path.expand(path, root)
      end

    if inside_root?(target, root) do
      target
    else
      raise ArgumentError, "path #{inspect(target)} is outside tool root #{inspect(root)}"
    end
  end

  def existing_target!(root, path) do
    target = target!(root, path)

    case realpath(target) do
      {:ok, real_target} ->
        if inside_root?(real_target, root) do
          real_target
        else
          raise ArgumentError,
                "path #{inspect(real_target)} is outside tool root #{inspect(root)}"
        end

      {:error, _reason} ->
        raise ArgumentError, "path does not exist: #{inspect(target)}"
    end
  end

  def writable_target!(root, path) do
    target = target!(root, path)
    parent = Path.dirname(target)

    case File.lstat(target) do
      {:ok, %{type: :symlink}} ->
        raise ArgumentError, "write_file path must not be a symlink: #{inspect(target)}"

      _other ->
        :ok
    end

    case realpath(parent) do
      {:ok, real_parent} ->
        if inside_root?(real_parent, root) do
          target
        else
          raise ArgumentError,
                "parent #{inspect(real_parent)} is outside tool root #{inspect(root)}"
        end

      {:error, _reason} ->
        raise ArgumentError, "parent directory does not exist: #{inspect(parent)}"
    end
  end

  def require_non_empty_binary!(value, _field) when is_binary(value) and byte_size(value) > 0,
    do: value

  def require_non_empty_binary!(value, field) do
    raise ArgumentError, "#{field} must be a non-empty binary, got: #{inspect(value)}"
  end

  defp inside_root?(target, root), do: target == root or String.starts_with?(target, root <> "/")

  defp realpath(path), do: path |> Path.expand() |> do_realpath(0)

  defp do_realpath(_path, depth) when depth > @max_symlink_depth, do: {:error, :eloop}

  defp do_realpath(path, depth) do
    case Path.split(path) do
      ["/" | parts] -> resolve_parts("/", parts, depth)
      parts -> resolve_parts("", parts, depth)
    end
  end

  defp resolve_parts(current, [], _depth), do: {:ok, current}

  defp resolve_parts(current, [part | rest], depth) do
    next = join_part(current, part)

    case File.lstat(next) do
      {:ok, %{type: :symlink}} ->
        resolve_symlink(next, current, rest, depth)

      {:ok, _stat} ->
        resolve_parts(next, rest, depth)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_symlink(next, current, rest, depth) do
    with {:ok, link} <- File.read_link(next) do
      target =
        if Path.type(link) == :absolute do
          link
        else
          Path.expand(link, current)
        end

      [target | rest] |> Path.join() |> do_realpath(depth + 1)
    end
  end

  defp join_part("/", part), do: "/" <> part
  defp join_part("", part), do: part
  defp join_part(current, part), do: Path.join(current, part)

  defp require_directory!(target, field) do
    case File.stat!(target) do
      %{type: :directory} ->
        :ok

      %{type: type} ->
        raise ArgumentError, "#{field} must be a directory, got: #{inspect(type)}"
    end
  end
end
