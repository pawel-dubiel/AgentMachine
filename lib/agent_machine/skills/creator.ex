defmodule AgentMachine.Skills.Creator do
  @moduledoc false

  alias AgentMachine.Skills.Manifest

  @valid_resource_dirs ["references", "assets", "scripts"]

  def create!(name, opts) when is_list(opts) do
    name = Manifest.validate_name!(name)

    skills_dir =
      Keyword.fetch!(opts, :skills_dir)
      |> require_non_empty_binary!("skills dir")
      |> Path.expand()

    description = Keyword.fetch!(opts, :description) |> require_non_empty_binary!("description")
    resources = Keyword.get(opts, :resources, []) |> validate_resources!()
    force? = Keyword.get(opts, :force, false)
    root = Path.join(skills_dir, name)

    if File.exists?(root) and not force? do
      raise ArgumentError, "skill already exists: #{inspect(name)}"
    end

    if force? do
      File.rm_rf!(root)
    end

    File.mkdir_p!(root)

    File.write!(
      Path.join(root, "SKILL.md"),
      """
      ---
      name: #{name}
      description: #{description}
      ---
      Describe when and how agents should use this skill.
      """
    )

    Enum.each(resources, &File.mkdir_p!(Path.join(root, &1)))

    Manifest.load!(root)
  end

  defp validate_resources!(resources) when is_list(resources) do
    Enum.each(resources, fn resource ->
      unless resource in @valid_resource_dirs do
        raise ArgumentError,
              "skill resource must be references, assets, or scripts, got: #{inspect(resource)}"
      end
    end)

    Enum.uniq(resources)
  end

  defp validate_resources!(resources) do
    raise ArgumentError, "skill resources must be a list, got: #{inspect(resources)}"
  end

  defp require_non_empty_binary!(value, _label) when is_binary(value) and byte_size(value) > 0,
    do: value

  defp require_non_empty_binary!(value, label) do
    raise ArgumentError, "#{label} must be a non-empty binary, got: #{inspect(value)}"
  end
end
