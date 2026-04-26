defmodule AgentMachine.Skills.Loader do
  @moduledoc false

  alias AgentMachine.Skills.Manifest

  def load_installed!(skills_dir) do
    skills_dir = require_existing_directory!(skills_dir)

    skills_dir
    |> File.ls!()
    |> Enum.reject(&String.starts_with?(&1, "."))
    |> Enum.map(&Path.join(skills_dir, &1))
    |> Enum.filter(&directory?/1)
    |> Enum.map(&Manifest.load!/1)
    |> reject_duplicate_names!()
    |> Enum.sort_by(& &1.name)
  end

  def load_named!(skills_dir, names) when is_list(names) do
    names = normalize_names!(names)
    installed = load_installed!(skills_dir)
    by_name = Map.new(installed, &{&1.name, &1})

    Enum.map(names, fn name ->
      case Map.fetch(by_name, name) do
        {:ok, skill} -> skill
        :error -> raise ArgumentError, "unknown installed skill: #{inspect(name)}"
      end
    end)
  end

  def require_existing_directory!(path) when is_binary(path) and byte_size(path) > 0 do
    expanded = Path.expand(path)

    case File.stat(expanded) do
      {:ok, %{type: :directory}} ->
        expanded

      {:ok, %{type: type}} ->
        raise ArgumentError, "skills dir must be a directory, got: #{inspect(type)}"

      {:error, _reason} ->
        raise ArgumentError, "skills dir does not exist: #{inspect(expanded)}"
    end
  end

  def require_existing_directory!(path) do
    raise ArgumentError, "skills dir must be a non-empty binary, got: #{inspect(path)}"
  end

  def normalize_names!(names) when is_list(names) do
    names =
      Enum.map(names, fn name ->
        name
        |> require_non_empty_binary!("skill name")
        |> Manifest.validate_name!()
      end)

    reject_duplicate_values!(names, "skill names")
    names
  end

  def reject_duplicate_names!(skills) do
    skills
    |> Enum.map(& &1.name)
    |> reject_duplicate_values!("installed skills")

    skills
  end

  defp directory?(path) do
    match?({:ok, %{type: :directory}}, File.stat(path))
  end

  defp reject_duplicate_values!(values, label) do
    duplicates =
      values
      |> Enum.frequencies()
      |> Enum.filter(fn {_value, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    if duplicates != [] do
      raise ArgumentError, "#{label} must not contain duplicates: #{inspect(duplicates)}"
    end
  end

  defp require_non_empty_binary!(value, _label) when is_binary(value) and byte_size(value) > 0,
    do: value

  defp require_non_empty_binary!(value, label) do
    raise ArgumentError, "#{label} must be a non-empty binary, got: #{inspect(value)}"
  end
end
