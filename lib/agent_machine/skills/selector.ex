defmodule AgentMachine.Skills.Selector do
  @moduledoc false

  alias AgentMachine.RunSpec
  alias AgentMachine.Skills.{Loader, Manifest}

  @max_auto_skills 8

  def select!(%RunSpec{skills_mode: :off, skill_names: []}) do
    %{mode: :off, loaded: [], selected: []}
  end

  def select!(%RunSpec{skill_names: names, skills_dir: skills_dir} = spec) when names != [] do
    skills = Loader.load_named!(skills_dir, names)

    %{
      mode: :explicit,
      loaded: skills,
      selected: Enum.map(skills, &%{skill: &1, reason: "explicitly requested"})
    }
    |> maybe_reject_scripts!(spec)
  end

  def select!(%RunSpec{skills_mode: :auto, skills_dir: skills_dir, task: task} = spec) do
    loaded = Loader.load_installed!(skills_dir)

    selected =
      loaded
      |> Enum.map(&score_skill(task, &1))
      |> Enum.filter(fn %{score: score} -> score > 0 end)
      |> Enum.sort_by(fn %{score: score, skill: skill} -> {-score, skill.name} end)
      |> Enum.take(@max_auto_skills)
      |> Enum.map(fn %{skill: skill, matches: matches} ->
        %{
          skill: skill,
          reason: "matched #{length(matches)} keyword(s): #{Enum.join(matches, ", ")}"
        }
      end)

    %{mode: :auto, loaded: loaded, selected: selected}
    |> maybe_reject_scripts!(spec)
  end

  defp maybe_reject_scripts!(selection, %RunSpec{allow_skill_scripts: true}), do: selection

  defp maybe_reject_scripts!(%{selected: selected} = selection, _spec) do
    script_skills =
      selected
      |> Enum.filter(fn %{skill: skill} -> skill.resources.scripts != [] end)
      |> Enum.map(fn %{skill: skill} -> skill.name end)

    if script_skills == [] do
      selection
    else
      selection
    end
  end

  defp score_skill(task, %Manifest{} = skill) do
    task_tokens = tokens(task)
    skill_tokens = tokens(skill.name <> " " <> skill.description)
    matches = task_tokens |> MapSet.intersection(skill_tokens) |> MapSet.to_list() |> Enum.sort()
    name_bonus = if String.contains?(String.downcase(task), skill.name), do: 3, else: 0

    %{skill: skill, score: length(matches) + name_bonus, matches: matches}
  end

  defp tokens(text) do
    ~r/[a-z0-9]+/
    |> Regex.scan(String.downcase(text || ""))
    |> Enum.map(&List.first/1)
    |> Enum.reject(&(byte_size(&1) < 3))
    |> MapSet.new()
  end
end
