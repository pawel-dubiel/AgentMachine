defmodule AgentMachine.Skills.ResourceStore do
  @moduledoc false

  alias AgentMachine.Skills.Manifest

  @readable_resource_keys [:references, :assets]

  def selected_skills!(opts) do
    case Keyword.fetch(opts, :selected_skills) do
      {:ok, skills} when is_list(skills) ->
        Enum.each(skills, fn
          %Manifest{} ->
            :ok

          skill ->
            raise ArgumentError, "selected skill must be a manifest, got: #{inspect(skill)}"
        end)

        skills

      {:ok, skills} ->
        raise ArgumentError, ":selected_skills must be a list, got: #{inspect(skills)}"

      :error ->
        raise ArgumentError, "skill resource tools require :selected_skills"
    end
  end

  def list_resources(skills) when is_list(skills) do
    Enum.map(skills, fn %Manifest{} = skill ->
      %{
        name: skill.name,
        references: skill.resources.references,
        assets: skill.resources.assets,
        scripts: skill.resources.scripts
      }
    end)
  end

  def readable_path!(skills, skill_name, path) do
    skill = skill_by_name!(skills, skill_name)
    path = Manifest.safe_relative_path!(path, "skill resource path")

    Enum.find_value(@readable_resource_keys, fn key ->
      if path in Map.fetch!(skill.resources, key) do
        key |> Atom.to_string() |> then(&Path.join([skill.root, &1, path]))
      end
    end) ||
      raise ArgumentError,
            "skill resource path #{inspect(path)} is not a readable reference or asset for #{inspect(skill.name)}"
  end

  def script_path!(skills, skill_name, path) do
    skill = skill_by_name!(skills, skill_name)
    path = Manifest.safe_relative_path!(path, "skill script path")

    if path in skill.resources.scripts do
      {skill, Path.join([skill.root, "scripts", path])}
    else
      raise ArgumentError,
            "skill script path #{inspect(path)} is not installed for #{inspect(skill.name)}"
    end
  end

  defp skill_by_name!(skills, name) do
    name = Manifest.validate_name!(name)

    case Enum.find(skills, &(&1.name == name)) do
      nil -> raise ArgumentError, "skill is not selected for this run: #{inspect(name)}"
      skill -> skill
    end
  end
end
