defmodule AgentMachine.Skills.Manifest do
  @moduledoc """
  Loads and validates Codex-compatible AgentMachine skill manifests.
  """

  @enforce_keys [:name, :description, :root, :skill_file, :body]
  defstruct [
    :name,
    :description,
    :root,
    :skill_file,
    :body,
    metadata: %{},
    resources: %{references: [], assets: [], scripts: []}
  ]

  @type t :: %__MODULE__{
          name: binary(),
          description: binary(),
          root: binary(),
          skill_file: binary(),
          body: binary(),
          metadata: map(),
          resources: %{references: [binary()], assets: [binary()], scripts: [binary()]}
        }

  @name_pattern_source "^[a-z0-9][a-z0-9._-]*$"
  @name_pattern Regex.compile!(@name_pattern_source)
  @resource_dirs %{references: "references", assets: "assets", scripts: "scripts"}

  def load!(path) when is_binary(path) and byte_size(path) > 0 do
    root = skill_root(path)
    validate_no_symlinks!(root)

    skill_file = Path.join(root, "SKILL.md")
    require_regular_file!(skill_file)

    {frontmatter, body} =
      skill_file
      |> File.read!()
      |> split_frontmatter!(skill_file)

    metadata = parse_yaml_map!(frontmatter, skill_file)
    name = metadata |> Map.fetch!("name") |> require_non_empty_binary!("SKILL.md name")

    description =
      metadata |> Map.fetch!("description") |> require_non_empty_binary!("SKILL.md description")

    validate_name!(name)
    validate_root_name!(root, name)
    body = require_non_empty_binary!(String.trim(body), "SKILL.md body")

    %__MODULE__{
      name: name,
      description: description,
      root: root,
      skill_file: skill_file,
      body: body,
      metadata: optional_metadata!(metadata),
      resources: resources!(root)
    }
  rescue
    exception in [File.Error, KeyError] ->
      reraise ArgumentError,
              [
                message:
                  "invalid skill manifest at #{inspect(path)}: #{Exception.message(exception)}"
              ],
              __STACKTRACE__
  end

  def load!(path) do
    raise ArgumentError, "skill path must be a non-empty binary, got: #{inspect(path)}"
  end

  def catalog_entry(%__MODULE__{} = skill) do
    %{
      name: skill.name,
      description: skill.description,
      root: skill.root,
      resources: skill.resources
    }
  end

  def prompt_entry(%__MODULE__{} = skill) do
    %{
      name: skill.name,
      description: skill.description,
      instructions: skill.body,
      resources: skill.resources
    }
  end

  def validate_name!(name) when is_binary(name) do
    if Regex.match?(@name_pattern, name) do
      name
    else
      raise ArgumentError,
            "skill name must match #{@name_pattern_source}, got: #{inspect(name)}"
    end
  end

  def validate_name!(name) do
    raise ArgumentError, "skill name must be a binary, got: #{inspect(name)}"
  end

  def safe_relative_path!(path, label) do
    path = require_non_empty_binary!(path, label)

    cond do
      Path.type(path) == :absolute ->
        raise ArgumentError, "#{label} must be relative, got: #{inspect(path)}"

      String.contains?(path, "\0") ->
        raise ArgumentError, "#{label} must not contain NUL bytes"

      path |> Path.split() |> Enum.any?(&(&1 == "..")) ->
        raise ArgumentError,
              "#{label} must not contain parent path segments, got: #{inspect(path)}"

      true ->
        Path.join(Path.split(path))
    end
  end

  defp skill_root(path) do
    expanded = Path.expand(path)

    case Path.basename(expanded) do
      "SKILL.md" -> Path.dirname(expanded)
      _other -> expanded
    end
  end

  defp validate_no_symlinks!(root) do
    require_directory!(root)
    do_validate_no_symlinks!(root)
  end

  defp do_validate_no_symlinks!(path) do
    case File.lstat!(path) do
      %{type: :symlink} ->
        raise ArgumentError, "skill path must not contain symlinks: #{inspect(path)}"

      %{type: :directory} ->
        path
        |> File.ls!()
        |> Enum.each(&do_validate_no_symlinks!(Path.join(path, &1)))

      _stat ->
        :ok
    end
  end

  defp require_directory!(path) do
    case File.stat!(path) do
      %{type: :directory} ->
        :ok

      %{type: type} ->
        raise ArgumentError, "skill path must be a directory, got: #{inspect(type)}"
    end
  end

  defp require_regular_file!(path) do
    case File.stat!(path) do
      %{type: :regular} ->
        :ok

      %{type: type} ->
        raise ArgumentError, "skill file must be a regular file, got: #{inspect(type)}"
    end
  end

  defp split_frontmatter!(content, skill_file) do
    lines = String.split(content, ~r/\r\n|\n|\r/, trim: false)

    unless List.first(lines) == "---" do
      raise ArgumentError, "#{skill_file} must start with YAML frontmatter delimiter ---"
    end

    closing_index =
      lines
      |> Enum.drop(1)
      |> Enum.find_index(&(&1 == "---"))

    if is_nil(closing_index) do
      raise ArgumentError, "#{skill_file} is missing closing YAML frontmatter delimiter ---"
    end

    yaml_lines = Enum.slice(lines, 1, closing_index)
    body_lines = Enum.drop(lines, closing_index + 2)
    {Enum.join(yaml_lines, "\n"), Enum.join(body_lines, "\n")}
  end

  defp parse_yaml_map!(yaml, skill_file) do
    case :yamerl_constr.string(String.to_charlist(yaml), [:str_node_as_binary]) do
      [document] ->
        document
        |> yaml_value!()
        |> require_map!("YAML frontmatter in #{skill_file}")

      documents ->
        raise ArgumentError,
              "YAML frontmatter in #{skill_file} must contain exactly one document, got: #{inspect(documents)}"
    end
  rescue
    exception ->
      reraise ArgumentError,
              [
                message:
                  "failed to parse YAML frontmatter in #{skill_file}: #{Exception.message(exception)}"
              ],
              __STACKTRACE__
  end

  defp yaml_value!(pairs) when is_list(pairs) do
    if yaml_pairs?(pairs) do
      Map.new(pairs, fn {key, value} -> {yaml_key!(key), yaml_value!(value)} end)
    else
      Enum.map(pairs, &yaml_value!/1)
    end
  end

  defp yaml_value!({key, value}), do: {yaml_key!(key), yaml_value!(value)}
  defp yaml_value!(value) when is_binary(value), do: value
  defp yaml_value!(value) when is_integer(value), do: value
  defp yaml_value!(value) when is_float(value), do: value
  defp yaml_value!(value) when is_boolean(value), do: value
  defp yaml_value!(nil), do: nil

  defp yaml_value!(value) do
    raise ArgumentError, "unsupported YAML value: #{inspect(value)}"
  end

  defp yaml_key!(key) when is_binary(key), do: key

  defp yaml_key!(key) do
    raise ArgumentError, "YAML map keys must be strings, got: #{inspect(key)}"
  end

  defp yaml_pairs?(pairs) do
    Enum.all?(pairs, fn
      {key, _value} when is_binary(key) -> true
      _other -> false
    end)
  end

  defp require_map!(value, _label) when is_map(value), do: value

  defp require_map!(value, label) do
    raise ArgumentError, "#{label} must be a map, got: #{inspect(value)}"
  end

  defp require_non_empty_binary!(value, _label) when is_binary(value) and byte_size(value) > 0,
    do: value

  defp require_non_empty_binary!(value, label) do
    raise ArgumentError, "#{label} must be a non-empty binary, got: #{inspect(value)}"
  end

  defp validate_root_name!(root, name) do
    root_name = Path.basename(root)

    if root_name != name do
      raise ArgumentError,
            "skill directory name #{inspect(root_name)} must match SKILL.md name #{inspect(name)}"
    end
  end

  defp optional_metadata!(%{"metadata" => metadata}) when is_map(metadata), do: metadata
  defp optional_metadata!(%{"metadata" => nil}), do: %{}

  defp optional_metadata!(%{"metadata" => metadata}) do
    raise ArgumentError, "SKILL.md metadata must be a map, got: #{inspect(metadata)}"
  end

  defp optional_metadata!(_metadata), do: %{}

  defp resources!(root) do
    Map.new(@resource_dirs, fn {key, dir} ->
      {key, resource_files(root, dir)}
    end)
  end

  defp resource_files(root, dir) do
    base = Path.join(root, dir)

    case File.stat(base) do
      {:ok, %{type: :directory}} ->
        base
        |> collect_files(base, [])
        |> Enum.sort()

      {:ok, %{type: type}} ->
        raise ArgumentError, "skill #{dir} path must be a directory, got: #{inspect(type)}"

      {:error, :enoent} ->
        []

      {:error, reason} ->
        raise ArgumentError, "failed to inspect skill #{dir} path: #{inspect(reason)}"
    end
  end

  defp collect_files(root, path, acc) do
    path
    |> File.ls!()
    |> Enum.reduce(acc, fn entry, acc ->
      target = Path.join(path, entry)

      case File.stat!(target) do
        %{type: :directory} ->
          collect_files(root, target, acc)

        %{type: :regular} ->
          [Path.relative_to(target, root) | acc]

        %{type: type} ->
          raise ArgumentError,
                "skill resource must be a regular file or directory, got #{inspect(type)} at #{inspect(target)}"
      end
    end)
  end
end
